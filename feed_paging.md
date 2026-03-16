# Feed And Paging -- v1.1

## History:
- **v1.0:** Introduce Pagination Algorithms
- **v1.0:** Restructure doc

# Note
Đừng over-engineer pagination

# Feed Storage Evolution
## V1 - Global Feed

**Architecture**
Naive table pagination
```
Client
↓
API
↓
Database (posts table)
```

**Query**
```sql
SELECT * FROM posts
ORDER BY created_at DESC
LIMIT 20 OFFSET 40;
```

**Ưu điểm**

* Code cực đơn giản
* Không cần infra
* Phù hợp khi data nhỏ (<100k rows)

**Nhược điểm**

1. OFFSET càng lớn càng chậm
2. DB phải scan nhiều rows
3. Feed của user không personalized

**Complexity**
```
O(offset + limit)
```

**1 trick cho bảng lớn**

Đó là query trên index trước rồi mới lấy data

Query thường thấy:
```sql
SELECT *
FROM products
ORDER BY created_at DESC
LIMIT 20 OFFSET 1000000;
```
Optimize:
```sql
SELECT p.*
FROM products p
JOIN (
    SELECT id, created_at
    FROM products
    ORDER BY created_at DESC, id DESC
    LIMIT 20 OFFSET 1000000
) t
ON p.id = t.id
ORDER BY t.created_at DESC, t.id DESC;
```

## V2 - Feed By Cursor Pagination (Keyset Pagination)

Thay vì OFFSET.

**Query**
```sql
SELECT *
FROM posts
WHERE (created_at, id) < (:cursor_created_at, :cursor_id)
ORDER BY created_at DESC, id DESC
LIMIT 20
```
**Lưu ý**
```sql
WHERE (created_at, id) < (:cursor_created_at, :cursor_id)
```
tương đương
```sql
WHERE
  (created_at < :cursor_created_at)
OR
  (created_at = :cursor_created_at AND id < :cursor_id)
```
**Ưu điểm**
- Query nhanh
- Không scan offset

**Complexity**
```
O(limit)
```

**Index chuẩn**
```sql
CREATE INDEX idx_posts_created_id
ON posts (created_at DESC, id DESC);
```
Khi đó cursor của chúng ta là cặp giá trị (created_at, id). Ta có thể mã hóa base 64
```
cursor = Base64.strict_encode64("created_at=1700000000,id=100")
API: GET /feed?cursor=Y3JlYXRlZF9hdD0xNzAwMDAwMDAwLGlkPTEwMA==
```

**Rule-of-thumb**
| Dataset       | Pagination        |
| ------------- | ----------------- |
| < 10k rows    | OFFSET ok         |
| 10k – 1M      | cursor tốt hơn    |
| infinite feed | cursor bắt buộc   |
| ranking feed  | snapshot + offset |

## V3 - Feed per User (Fan-out on Read)
Ở version v1, v2 dùng chung single source of truth. Ưu điểm là đơn giản, nhược điểm là không cá nhân hóa theo user. v1, v2 thường gặp ở:
- forum
- blog timeline
- early social apps

Bây giờ feed không phải global nữa.
User chỉ thấy:
- friend posts
- following posts

**Query**
```sql
SELECT *
FROM posts
WHERE author_id IN (friend_ids)
ORDER BY created_at DESC
LIMIT 20
```

**Problem**
- DB scan nhiều author ranges, merge sort
- Khi Friend list 1000+

DB phải
```sql
WHERE author_id IN (...)
```
Query bắt đầu chậm.

**Chi phí**
```
write cost ~ O(1)
read cost ~ O(#followees)
```

v3 phù hợp với hệ thống mà user follow ít người hoặc các app dạng "Community" (vào một sub-group để xem bài). vd:
- subreddit-style apps
- Slack channels
- forum threads

**Index thường dùng**
```sql
INDEX(author_id, created_at DESC)
```

**Trick query**

***1. Join table thay vì IN***

Thay vì:
```sql
WHERE author_id IN (...)
```

nhiều hệ thống dùng join:
```sql
SELECT p.*
FROM posts p
JOIN follows f
  ON p.author_id = f.followee_id
WHERE f.follower_id = :user
ORDER BY p.created_at DESC
LIMIT 20
```

Ưu điểm: planner tối ưu tốt hơn

***2. Time window limit***

Thêm điều kiện:
```sql
WHERE created_at > now() - interval '7 days'
```
để giảm scan.

***3. Fetch per author rồi merge***

Application có thể làm:
```
fetch top 10 posts per author
merge streams
```
Thực chất là: k-way merge


## V4 - Precomputed Feed (Fan-out on Write)
V4 ship post to followers. Giải pháp:

Tạo bảng riêng:
```sql
user_feed
---------
user_id
post_id
created_at
```
Khi user đăng post:
```
fan-out to followers
```
Insert vào feed của họ.
```
Post created
   ↓
Worker
   ↓
Insert into user_feed
```
Query:
```sql
SELECT post_id
FROM user_feed
WHERE user_id = ?
ORDER BY created_at DESC
LIMIT 20
```
**Ưu điểm**
- Query cực nhanh
- Không join
- Không filter

Nhược điểm
- Fan-out cost.

Chi phí
```
write cost ~ O(#followers)
read cost  ~ O(1)
```

Bảng followers
```sql
followers(id, user_id, followered_by_user_id, created_at)
index uniq followers on (user_id, followed_by_user_id)
```

Bảng user_feeds
```sql
user_feeds(id(bigint), user_id, post_id)
index uniq user_feeds on (user_id, post_id)
```

Khi user tạo 1 post thì call
```ruby
FanoutDispatcherJob.perform_async(post_id, user_id)
```
```ruby
class FanoutDispatcherJob
  include Sidekiq::Worker

  def perform(post_id, author_id)
    last_follower_id = 0
    batch_size = 1000

    loop do
      # Tận dụng Index trên (user_id, followed_by_user_id)
      # Query này sẽ thực hiện Index Seek cực nhanh
      follower_ids = Follower.where(user_id: author_id)
                             .where("followed_by_user_id > ?", last_follower_id)
                             .order(:followed_by_user_id)
                             .limit(batch_size)
                             .pluck(:followed_by_user_id)

      break if follower_ids.empty?

      # Đẩy sang job con xử lý
      PushToFeedJob.perform_async(post_id, follower_ids)

      # Cập nhật cursor cho vòng lặp kế tiếp
      last_follower_id = follower_ids.last

      # Ngắt vòng lặp nếu batch cuối cùng không đầy (tiết kiệm 1 query trống)
      break if follower_ids.size < batch_size
    end
  end
end

class PushToFeedJob
  include Sidekiq::Worker
  # Giảm bớt số lần retry nếu đây là data không quá quan trọng
  # Ưu tiên hàng chờ xử lý nhanh cho feed
  sidekiq_options queue: 'fanout_high', retry: 3

  def perform(post_id, follower_ids)
    return if follower_ids.blank?

    # Đảm bảo dữ liệu là số nguyên để chống SQL Injection (vì Rails 4 không có insert_all an toàn)
    p_id = post_id.to_i
    f_ids = follower_ids.map(&:to_i)

    # Khởi tạo mảng chứa các cặp giá trị (user_id, post_id)
    values = f_ids.map { |uid| "(#{uid}, #{p_id})" }.join(",")

    # Sử dụng ON CONFLICT (đã có từ Postgres 9.5) để tránh lỗi khi retry job
    sql = <<-SQL
      INSERT INTO user_feeds (user_id, post_id)
      VALUES #{values}
      ON CONFLICT (user_id, post_id) DO NOTHING;
    SQL

    # Thực thi trực tiếp qua kết nối của ActiveRecord
    begin
      ActiveRecord::Base.connection.execute(sql)
    rescue => e
      # Log lỗi cụ thể nếu cần, Sidekiq sẽ tự động retry theo cấu hình
      Rails.logger.error "PushToFeedJob failed: #{e.message}"
      raise e
    end
  end
end
```

**Future Architecture: Transitioning To Event-driven With Kafka**
- Trong kiến trúc Sidekiq, ta đang thực hiện lệnh: "Này Sidekiq, hãy đi chèn feed cho 1000 người này đi". Đó là mô hình Command-driven.
- Với Kafka, tư duy chuyển sang Event-driven: "Này hệ thống, có một sự kiện là Post #789 vừa được tạo bởi User #1". Sau đó, bất kỳ dịch vụ nào quan tâm (Fan-out service, Notification service, Analytics service) sẽ tự "subscribe" vào sự kiện đó để xử lý.

1\. Khi nào cần chuyển sang Kafka? (The Trigger)

Chúng ta sẽ cân nhắc rời bỏ Sidekiq để chuyển sang Kafka khi gặp một trong các tín hiệu sau:
- Redis RAM Pressure: Lượng job Fan-out quá lớn khiến Redis tiêu tốn RAM vượt quá 70-80% dung lượng server.
- Multi-Consumer Requirement: Khi không chỉ có Feed, mà các dịch vụ khác (Notification, Search Indexing, Real-time Analytics) cũng cần nghe sự kiện "New Post".
- Job Loss Risk: Khi yêu cầu về tính bền vững (durability) cao hơn, cần lưu trữ event lâu dài để replay (chạy lại dữ liệu) khi gặp sự cố.

2\. Mô hình chuyển đổi (The Hybrid Flow)

Thay vì dùng Sidekiq để Command (ra lệnh), chúng ta chuyển sang dùng Kafka để Stream (truyền tin).
- Phase 1 (Producer): Thay vì gọi FanoutJob.perform_async, Application sẽ đẩy 1 message vào Kafka topic social.posts.created.

- Phase 2 (Fan-out Engine): Một service chuyên biệt (có thể vẫn là Ruby hoặc Go/Java để tối ưu) consume từ topic này, tra cứu follower và đẩy tiếp hàng nghìn "Feed Update Events" vào topic social.feed.updates.

- Phase 3 (Final Writer): Các workers sẽ consume từ social.feed.updates theo nhóm (Consumer Groups). Nhờ cơ chế Partitioning của Kafka, việc chèn dữ liệu vào Postgres sẽ được dàn đều, tránh gây nghẽn (bottleneck) tại một thời điểm.

3\. Ưu thế về mặt "Backpressure"

Với Sidekiq, nếu DB chậm, hàng triệu job sẽ kẹt trong Redis. Với Kafka, nếu DB chậm, Consumer sẽ tự động đọc chậm lại (Backpressure). Dữ liệu vẫn nằm an toàn trên đĩa cứng của Kafka broker chờ đến khi DB sẵn sàng, giúp hệ thống Nova của bạn "co giãn" (elastic) tốt hơn trước các đợt cao điểm.


### V4.1 Partial Fanout Write
Ở phiên bản V4, nếu 1 user nổi tiếng, vd: Elon Musk có nhiều người follow thì việc insert vào user_feeds như vậy sẽ có hàng triệu dòng được insert. Ta có thể phân loại user nào được fan-out write và fallback bằng cơ chế fan-out read và catchup bù dữ liệu.

Loại A (Active/High-Priority) và Loại B (Inactive/Low-Priority) để áp dụng Hybrid Fan-out


#### 1. Phân loại Follower (The Scoring Layer)

Thay vì chỉ có bảng followers đơn giản, chúng ta cần một cơ chế để xác định ai là "Loại A".
- Tiêu chí: last_active_at trong vòng 7 ngày hoặc có tương tác gần đây.


#### 2. Kiến trúc Hybrid Fan-out (Write A + Read B)

Luồng xử lý sẽ thay đổi như sau:
- Write Path (Fan-out on Write): Chỉ thực hiện với Follower Loại A.
    - Giúp bài viết xuất hiện ngay lập tức cho những người thực sự đang dùng app.

- Read Path (Fan-out on Read/Pull): Khi Follower Loại B mở app sau một thời gian dài.
    - Hệ thống sẽ thực hiện một câu query "Pull" (lấy bài mới từ những người họ follow) và gộp vào feed hiện tại.

#### 3. Sample ruby code
```ruby
class FanoutDispatcherJob
  include Sidekiq::Worker

  def perform(post_id, author_id)
    batch_size = 1000
    last_follower_id = 0

    loop do
      # Chỉ lấy những Follower Loại A
      # Giả sử chúng ta Join với bảng users để check last_active_at
      # Hoặc check trong một bảng cached_active_users
      active_follower_ids = Follower.joins("INNER JOIN users ON followers.followed_by_user_id = users.id")
                                    .where(user_id: author_id)
                                    .where("followers.followed_by_user_id > ?", last_follower_id)
                                    .where("users.last_active_at > ?", 7.days.ago) # Điều kiện Loại A
                                    .order(:followed_by_user_id)
                                    .limit(batch_size)
                                    .pluck(:followed_by_user_id)

      break if active_follower_ids.empty?

      PushToFeedJob.perform_async(post_id, active_follower_ids)

      last_follower_id = active_follower_ids.last
      break if active_follower_ids.size < batch_size
    end
  end
end
```

#### 4. Cơ chế Fallback (The Pull Model)
Khi một User Loại B quay lại App (vượt qua ngưỡng 7 ngày), API lấy Feed sẽ phải làm thêm một bước:
- Bước 1: Lấy bài từ user_feeds (đã được fan-out trước đó).
- Bước 2: Query trực tiếp bảng posts của những người họ follow nhưng có created_at nằm trong khoảng thời gian họ "vắng mặt".
- Bước 3: Merge và trả về kết quả.

#### 7. Feed Api Sample
API:
```
GET /feed?since={since}&cursor={cursor}
```

json response:
```
{
  meta: {
    current_cursor: ...,
    current_since: ...,
    next_cursor: ...
  }
  data: {
    new_post: [...],
    old_post: [...]
  }
}
```
Sample ruby code
```ruby
class FeedRetrievalService
  PER_PAGE = 20

  def initialize(user:, since_id: nil, cursor_id: nil)
    @user = user
    @since_id = since_id.to_i if since_id.present?
    @cursor_id = cursor_id.to_i if cursor_id.present?
  end

  def call
    # 1. Update last_active_at và trigger Catch-up nếu cần
    handle_user_activity

    # 2. Query lấy data
    # posts là 1 array [ { id: ..., content: ..., user_id: ... }, ... ]
    posts = fetch_new_posts + fetch_older_posts
    {
      meta: {
        # ID thực tế cuối cùng trong DB để load more, chính là cursor_id
        # Server luôn trả về next_cursor là ID vật lý cuối cùng đã quét qua trong DB (kể cả khi bài đó bị lọc) để App không bị mất dấu cursor.
        next_cursor: 85,
        # ID lớn nhất trong list để check bài mới (polling), chính là since_id
        prev_cursor: 100
      },
      data: posts
    }
  end

  private

  def handle_user_activity
    if @user.last_active_at < 7.days.ago
      CatchUpFeedJob.perform_async(@user.id)
    end
    @user.update_column(:last_active_at, Time.current)
  end

  def fetch_new_posts
    return [] unless @since_id

    # Lấy những bài mới hơn since_id
    base_query.where("posts.id > ?", @since_id)
              .order("posts.id DESC")
              .limit(PER_PAGE).to_a
  end

  def fetch_older_posts
    query = base_query.order("posts.id DESC").limit(PER_PAGE)

    # Nếu có cursor_id thì lấy cũ hơn cursor, nếu không lấy mới nhất
    if @cursor_id
      query = query.where("posts.id < ?", @cursor_id)
    end

    query.to_a
  end

  def base_query
    Post.joins("INNER JOIN user_feeds ON user_feeds.post_id = posts.id")
        .where("user_feeds.user_id = ?", @user.id)
        .select("posts.*")
  end
end
```

#### 8. Nhận xét
Với mô hình này, hệ thống của sẽ cực kỳ lì lợm:
- Lúc thấp điểm: Mọi thứ chạy trơn tru.
- Lúc cao điểm (Celebrity đăng bài): Thay vì fan-out cho 1 triệu người, hệ thống chỉ "vất vả" với 100k người thực sự đang online. 900k người còn lại sẽ tự "kéo" dữ liệu khi họ mở app sau. Tải trọng DB được dàn trải ra theo thời gian (Time-shifting), tránh được hiện tượng "DB Spike" (vọt đỉnh) gây sập hệ thống.


### V4.2 - Cơ Chế Follow/Unfollow
Áp dụng cơ chế Eventual Consistency (nhất quán sau một khoảng thời gian) hơn là cố gắng đạt được Real-time Consistency một cách cực đoan.

Để "chiều lòng" những user kỹ tính mà vẫn giữ hệ thống nhẹ, có thể theo hướng "xóa nhanh những gì dễ thấy nhất":
```ruby
# app/workers/unfollow_shallow_cleanup_job.rb
class UnfollowShallowCleanupJob
  include Sidekiq::Worker
  sidekiq_options queue: 'low_priority', retry: 1

  def perform(follower_id, followed_id)
    # Tìm 50 bài gần nhất của Author trong inbox của User A
    # Phép join này chỉ quét trên tập dữ liệu nhỏ nhờ LIMIT
    target_post_ids = Post.joins(:user_feeds)
                          .where(user_id: followed_id)
                          .where(user_feeds: { user_id: follower_id })
                          .order("posts.id DESC")
                          .limit(50)
                          .pluck(:id)

    if target_post_ids.any?
      UserFeed.where(user_id: follower_id, post_id: target_post_ids).delete_all
    end
  end
end
```

### V4.3 - Cơ Chế Chống Click Spam
Nếu có user liên tục toggle Follow/Unfollow và ta cố gắng cực đoan đi xóa user_feeds thì chỉ làm stress DB

Có thể dùng cơ chế Rate Limit đơn giản
```ruby
# app/controllers/concerns/rate_limit_protection.rb
module RateLimitProtection
  extend ActiveSupport::Concern

  def check_rate_limit(action_name, limit: 10, period: 60)
    # Tạo key duy nhất cho mỗi user và mỗi hành động
    # Ví dụ: rate_limit:follow:user_123
    key = "rate_limit:#{action_name}:#{current_user.id}"

    # Sử dụng Redis Pipelining để giảm round-trip
    count, ttl = $redis.pipelined do
      $redis.incr(key)
      $redis.ttl(key)
    end

    # Nếu là request đầu tiên (TTL = -1), set thời gian hết hạn
    $redis.expire(key, period) if ttl < 0

    if count > limit
      render json: {
        error: "Bạn thao tác quá nhanh. Vui lòng thử lại sau #{ttl} giây."
      }, status: 429
      return false
    end
    true
  end
end

class FollowsController < ApplicationController
  include RateLimitProtection

  # Chỉ áp dụng cho các hành động thay đổi trạng thái (POST/DELETE)
  before_action only: [:create, :destroy] do
    check_rate_limit("follow_toggle", limit: 5, period: 60)
  end

  def create
    # Logic follow ở đây...
  end
end
```

## v5 - Celebrity Problem

Nếu user có:
```
10M followers
```
Fan-out = disaster.

Insert:
```
10M rows
```
Giải pháp: **Hybrid Fanout**
```
| user type   | strategy         |
| ----------- | ---------------- |
| Normal user | fan-out on write |
| Celebrity   | fan-out on read  |
```

Khi đọc feed:
```
feed_table
+
celebrity_posts
```

# 6. Feed Cache

Feed là read-heavy.
```
99% read
1% write
```
Cache feed.
```
Redis
feed:user_id
```
Structure
```
Sorted Set
score = timestamp
value = post_id
```

Query
```
ZREVRANGE feed:user_id
```
Latency:
```
< 1ms
```

# 7. Ranking System

Feed không còn chronological nữa.

Ranking theo:
```
engagement
relevance
ML score
```
Score formula:
```
score =
  like_weight * likes
+ comment_weight * comments
+ freshness_decay
+ relationship_strength
```
Feed trở thành:
```
Top K ranking problem
```
Thường dùng
- ML ranking
- feature store
- batch scoring

# 8. Real-time Feed Streaming

Feed update real-time.

Infra:
```
Kafka
Flink
Redis
```
Flow:
```
Post created
   ↓
Kafka
   ↓
Stream processor
   ↓
Update feed cache
   ↓
Push notification
```

# 2. Pagination evolution
## P1 - offset pagination
```sql
LIMIT 20 OFFSET 40
```

## P2 - cursor pagination
Cách làm này thường gặp nhất trong thực tế
```
GET /feed?cursor=abc123
```
Cursor có thể encode(created_at, post_id)
```
WHERE (created_at, id) < cursor
```

## P2.1 Advanced Cursor.
Thay vì dùng Tuple Comparison, ta sử dụng Time-ordered Unique Identifiers (Snowflake, ULID, UUID v7) để biến phân trang phức hợp thành phân trang đơn biến, tối ưu hóa tuyệt đối tốc độ Index Seek trên quy mô dữ liệu cực lớn.


## p3 - Snapshot Pagination
Trong Ranking Feed, điểm số (score) của một bài viết thay đổi theo từng giây (dựa trên like/comment). Nếu dùng Cursor Pagination thông thường, trang 1 bài A có score 100, trang 2 bài B có score 90. Nhưng 1 giây sau bài B lên score 101, user sang trang 2 sẽ thấy bài B biến mất (vì nó nhảy lên trang 1 rồi).

Luồng hoạt động:
- Candidate Generation: Lấy ra ~500-1000 bài viết tiềm năng.
- Ranking: Chạy qua model ML để xếp hạng.
- Snapshot: Lưu kết quả đã xếp hạng này vào Redis/Cache với TTL ngắn (ví dụ 10-20 phút).
- Offset Pagination: Lúc này bạn có thể dùng Offset trên Snapshot thoải mái vì tập dữ liệu này đã "đóng băng" cho riêng session của user đó.

## p4 -  Score based pagination

Nếu ranking feed:
```
cursor = last_score
```
Query:
```
WHERE score < last_score
```

# Industry Architecture (Facebook / Twitter)
```
          write path
             ↓
        Post Service
             ↓
          Kafka
             ↓
        Fanout Workers
             ↓
     Feed Store (Redis)

-------------------------------

          read path
             ↓
        Feed API
             ↓
          Redis
             ↓
         Post Store
             ↓
           Client
```

# Hard problems
1️⃣ Facebook pagination thực sự hoạt động thế nào
(vì ranking feed làm cursor pagination rất khó)

2️⃣ Timeline consistency problem
(tại sao feed đôi khi bị lặp post)

3️⃣ Cold start feed problem

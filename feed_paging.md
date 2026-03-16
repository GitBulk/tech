# Feed And Paging -- v1.1

## History:
- **v1.0:** Introduce Pagination Algorithms
- **v1.0:** Restructure doc

# Note
Đừng over-engineer pagination

# Tech
- Postgres 9.5, Rails, Redis
- Trong các table minh họa bên dưới sẽ dùng kiểu `bigint` để làm id

# Sharding (Optional)

1\. Hiện tại: BigInt + Postgres 9.5 (Lựa chọn tối ưu)
  - Xác nhận: Với bảng đơn (single database), BigInt tự tăng là "vô địch" về hiệu suất. Phân trang cursor hoạt động hoàn hảo vì tính tuần tự (monotonic) và index trên BigInt cực kỳ nhẹ.
  - Lợi thế: Không tốn thêm tài nguyên cho việc tạo ID, và Postgres 9.5 xử lý kiểu số này nhanh nhất có thể.

2\. Tương lai: Khi làm Sharding (Vấn đề ID trùng)
  - Xác nhận: BigInt tự tăng của từng shard sẽ gây xung đột ID khi cần gộp dữ liệu hoặc làm Global Index.
  - Giải pháp Ticket Server: Đây là cách Flickr và Instagram (thời kỳ đầu) đã dùng. Có một DB riêng chỉ để sinh ID.
    - Ưu điểm: ID vẫn là BigInt, ngắn gọn, dễ sort.
    - Nhược điểm: Ticket Server trở thành Single Point of Failure (SPOF). Nếu nó sập, cả hệ thống không insert được bài mới.
  - Giải pháp Snowflake (Twitter): Sinh ID 64-bit dựa trên (Timestamp + WorkerID + Sequence):
    - Ưu điểm: Không cần server trung tâm, ID vẫn mang tính thời gian (sort được).
    - Nhược điểm: Cần duy trì một service sinh ID ổn định.

3\. Vấn đề UUID v7 trên Postgres 9.5
  - Hiệu năng của UUID v7 trên bản 9.5 chưa tốt.
  - Lưu trữ: Postgres 9.5 chưa có các hàm xử lý UUID tối ưu như các bản 13+. UUID v7 chiếm 128 bit (16 bytes), gấp đôi BigInt (8 bytes). Điều này làm Index phình to hơn, dẫn đến tốn RAM cho Buffer Cache hơn.
  - Sắp xếp (Sorting): Mặc dù UUID v7 được thiết kế để có thể sắp xếp theo thời gian (time-ordered), nhưng Postgres 9.5 không "biết" điều này. Nó sẽ so sánh byte-by-byte. So sánh 16 bytes chậm hơn so sánh một số nguyên 8 bytes ở mức CPU.
  - Chưa native: Phải tự implement hàm sinh UUID v7 ở tầng Application (Ruby) hoặc dùng extension, điều này làm phức tạp thêm việc duy trì code.

4\. DB Evolution
|Giai đoạn            |Giải pháp ID   |Đánh giá                                             |
|---------------------|---------------|-----------------------------------------------------|
|Hiện tại (MVP -> Scale)|BigInt (Postgres Serial)|Tốt nhất cho Postgres 9.5. Hiệu suất tối đa.         |
|Sắp Sharding         |Snowflake ID   |Giữ được kiểu dữ liệu BigInt (64-bit) nhưng vẫn đảm bảo duy nhất trên toàn hệ thống.|
|Nâng cấp Postgres 17+|UUID v7        |Lúc này hạ tầng đã đủ mạnh để bù đắp cho sự "cồng kềnh" của UUID, đổi lấy sự tiện lợi tuyệt đối.|

5\. Sample SnowflakeGenerator

Cấu trúc Snowflake ID thường là 64-bit:
```
1 bit: Dự phòng (luôn là 0). Vì 0 sẽ ra số dương, còn 1 ra số âm.

41 bits: Timestamp (miligiây) - dùng được khoảng 69 năm.

10 bits: Worker ID (tối đa 1024 shard/node).

12 bits: Sequence number (tối đa 4096 ID/mili giây trên mỗi node).
```
**Lưu ý: Cách gán WORKER_ID thực tế**

1\. Gán thủ công (Static):
- Server 1: export WORKER_ID=1
- Server 2: export WORKER_ID=2
- ... Cách này dễ làm nhưng khó quản lý khi bạn dùng Auto-scaling (server tự sinh thêm/xóa bớt).

2\. Dùng Redis/ZooKeeper (Dynamic):

Khi App khởi động, nó sẽ "đăng ký" với Redis để lấy một ID trống.

Ví dụ: Server mới lên, hỏi Redis: "Số nào chưa ai dùng?". Redis trả về 5. Server đó sẽ giữ WORKER_ID=5 trong suốt vòng đời của nó.

3\.Dùng Private IP:

Lấy byte cuối cùng của địa chỉ IP nội bộ (ví dụ: 10.0.0.15 -> 15) để làm WORKER_ID. Đây là cách rất phổ biến vì nó tự động và không trùng trong cùng một mạng.

```ruby
# lib/snowflake_id_generator.rb
class SnowflakeIdGenerator
  # Epoch cho dự án: 2026-01-01 00:00:00 UTC
  # (Time.utc(2026, 1, 1).to_f * 1000).to_i
  # Bạn nên chọn mốc thời gian gần với lúc bắt đầu dự án
  EPOCH = 1735689600000

  # Cố định các mốc bit
  UNUSED_BITS = 1 # 1 bit đầu tiên không dùng (để luôn dương)
  WORKER_BITS  = 10 # Tối đa 1024 workers
  SEQ_BITS     = 12 # Tối đa 4096 IDs/ms

  MAX_WORKER_ID = (1 << WORKER_BITS) - 1 # 1023

  def initialize(worker_id)
    if worker_id < 0 || worker_id > MAX_WORKER_ID
      raise "Worker ID phải nằm trong khoảng 0-#{MAX_WORKER_ID}"
    end
    @worker_id = worker_id
    @sequence = 0
    @last_timestamp = -1
    @mutex = Mutex.new
  end

  def next_id
    @mutex.synchronize do
      timestamp = current_timestamp
      # Xử lý khi trùng mili giây
      if timestamp == @last_timestamp
        @sequence = (@sequence + 1) & 0xFFF # Giữ trong 12 bit
        if @sequence == 0
          timestamp = wait_for_next_millis(@last_timestamp)
        end
      else
        @sequence = 0
      end

      @last_timestamp = timestamp

      # Dịch bit để tạo cấu trúc Snowflake
      # Bit 63 (dự phòng) sẽ tự động là 0 vì chúng ta không dịch chuyển tới đó
      ((timestamp - EPOCH) << (WORKER_BITS + SEQ_BITS)) |
      (@worker_id << SEQ_BITS) |
      @sequence
    end
  end

  private

  def current_timestamp
    (Time.now.to_f * 1000).to_i
  end

  def wait_for_next_millis(last)
    ts = current_timestamp
    ts = current_timestamp while ts <= last
    ts
  end
end
```

```ruby
# app/models/post.rb
class Post < ActiveRecord::Base
  before_create :set_snowflake_id

  private

  def set_snowflake_id
    # Trong thực tế, bạn nên dùng một Singleton hoặc Service để quản lý Generator
    # Worker ID có thể lấy từ biến môi trường (ENV['WORKER_ID'])
    @generator ||= SnowflakeIdGenerator.new(ENV['WORKER_ID'].to_i)
    self.id = @generator.next_id if self.id.blank?
  end
end
```
Hoặc
```ruby
# config/initializers/snowflake.rb
require 'snowflake_id_generator'

# Kết nối Redis (tùy biến theo cấu hình của bạn)
redis = Redis.new(host: 'localhost', port: 6379)

# Lấy số thứ tự từ Redis và modulo 1024
# Mỗi lần restart hoặc có web server mới, nó sẽ lấy số tiếp theo
raw_id = redis.incr("nova:global_worker_counter")
assigned_worker_id = raw_id % 1024

# Khởi tạo một biến toàn cục hoặc hằng số để dùng trong toàn App
SNOWFLAKE_GEN = SnowflakeIdGenerator.new(assigned_worker_id)

Rails.logger.info "Snowflake Generator initialized with Worker ID: #{assigned_worker_id}"

# app/models/post.rb
class Post < ActiveRecord::Base
  # Rails 4.x: Sử dụng callback để gán ID trước khi chèn vào DB
  before_create :assign_snowflake_id

  private

  def assign_snowflake_id
    # SNOWFLAKE_GEN được khởi tạo từ initializer ở trên
    self.id ||= SNOWFLAKE_GEN.next_id
  end
end
```

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

Với Sidekiq, nếu DB chậm, hàng triệu job sẽ kẹt trong Redis. Với Kafka, nếu DB chậm, Consumer sẽ tự động đọc chậm lại (Backpressure). Dữ liệu vẫn nằm an toàn trên đĩa cứng của Kafka broker chờ đến khi DB sẵn sàng, giúp hệ thống "co giãn" (elastic) tốt hơn trước các đợt cao điểm.


### V4.1 - Partial Fanout Write (Đối Phó Với Những User Nổi Tiếng)
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

  MAX_FANOUT_THRESHOLD = 10_000
  ACTIVE_THRESHOLD = 7.days.ago

  def perform(post_id)
    post = Post.find_by(id: post_id)
    # bài viết có thể bị xóa
    return if post.nil?

    author = post.user
    return if author.nil?

    author_id = author.id
    # 1. Đếm nhanh số lượng follower active để quyết định chiến lược
    # Giả sử relation tới bảng users là followed_user
    # active_count = Follower.joins(:followed_user)
    #                        .where(user_id: author_id)
    #                        .where("users.last_active_at > ?", ACTIVE_THRESHOLD)
    #                        .count

    # if active_count > MAX_FANOUT_THRESHOLD
    #   # Nếu là "Siêu sao" đang có quá nhiều người online -> Bỏ qua Fan-out write
    #   # Bài viết này sẽ được xử lý bằng Pull Model ở tầng API
    #   Rails.logger.info "Post #{post_id} by #{author_id} skipped fan-out (Active followers: #{active_count})"
    #   return
    # end

    # 1.1 một cách đơn giản hơn là có thể maintain cột follower_count trong bảng user
    # tức là người nổi tiếng
    return unless author.follower_count.to_i > MAX_FANOUT_THRESHOLD

    # 2. Tiến hành Keyset Pagination với Join
    last_follower_id = 0
    batch_size = 1000
    total_import = 0
    loop do
      active_follower_ids = Follower.joins(:followed_user)
                                    .where(user_id: author_id)
                                    .where("users.last_active_at > ?", ACTIVE_THRESHOLD)
                                    .where("followers.followed_by_user_id > ?", last_follower_id)
                                    .order("followers.followed_by_user_id ASC")
                                    .limit(batch_size)
                                    .pluck(:followed_by_user_id)

      break if active_follower_ids.empty?

      PushToFeedJob.perform_async(post_id, active_follower_ids)

      total_import += batch_size
      last_follower_id = active_follower_ids.last
      break if total_import >= MAX_FANOUT_THRESHOLD

      # tiết kiệm 1 query kế vì đây đã là bactch cuối
      break if active_follower_ids.size < batch_size
    end
  end
end
```

#### 4. Lưu trữ danh sách user active
Ta cũng có thể dùng 1 sorted set trong Redis, bloom filter, redis key expiration để lưu trữ Global user active. Thông tin tham khảo: Twitter có khoảng 20-50tr người online cùng lúc (2026).

**Cách A: Dùng Sorted Set (ZSET) - Khuyên dùng**

Dùng ZADD với Score là Timestamp của lần cuối user active.

Update: ZADD global:active_users <current_timestamp> <user_id>

Dọn dẹp (Cronjob mỗi giờ): ZREMRANGEBYSCORE global:active_users -inf <7_days_ago_timestamp>

Lệnh này sẽ xóa sạch tất cả những ai có timestamp cũ hơn 7 ngày chỉ trong một nốt nhạc.

Redis Sorted Set (ZSET), dữ liệu được lưu trữ bằng sự kết hợp của Hash Table và Skip List. Một ZSET lưu trữ các cặp (score, member) là (64-bit timestamp, 64-bit Integer ID):

Mỗi phần tử (entry) tốn khoảng 80 - 100 bytes.

Với 100 triệu phần tử:
```
100,000,000 × 100 bytes ≈ 10 GB RAM.
```
Con số 100 bytes được ước tính như sau:

|Thành phần           |Kích thước (ước tính)|Ghi chú                                              |
|---------------------|---------------------|-----------------------------------------------------|
|Member (User ID)     |8 - 16 bytes         |Nếu dùng Long/Integer. Nếu là String UUID sẽ tốn hơn.|
|Score (Timestamp)    |8 bytes              |Double precision floating point.                     |
|Skip List Node       |~32 bytes            |Pointer tới các node khác (level trung bình).        |
|Hash Table Entry     |~32 bytes            |Để tra cứu O(1) từ member ra score.                  |
|Redis Object Overhead|~16 bytes            |Metadata của Redis cho mỗi object.                   |
|Tổng cộng            |~96 - 104 bytes      |Tùy vào phiên bản Redis và cấu hình hệ thống.        |

**Cách B: Bloom Filter (Nếu RAM là vấn đề)**

Nếu có hàng tỷ user và không muốn tốn nhiều RAM, có thể dùng Bloom Filter. Tuy nhiên, Bloom Filter nguyên bản không hỗ trợ xóa, nên sẽ phải dùng Counting Bloom Filter hoặc đơn giản là tạo một cái Filter mới mỗi tuần và xóa Filter cũ.

**Cách C: Redis Key Expiration (Cần thận trọng)**

Có thể set mỗi user là một key riêng lẻ: active:user_123 với TTL 7 ngày.
- Ưu điểm: Tự động xóa.
- Nhược điểm: Không thể dùng SINTER hay SISMEMBER hàng loạt hiệu quả bằng việc check trong 1 Set duy nhất.


#### 5. Cơ Chế Catch-up: Khi user Cũ Lâu Ngày Quay Lại
Đây là phần quan trọng để đảm bảo trải nghiệm người dùng không bị "hổng". Khi một user mở app sau 10 ngày (đã bị xóa khỏi Global Active Set):

1. **Check:** ZSCORE global:active_users <user_id> trả về nil.
2. Kích hoạt Catch-up:
    - Thêm lại vào Set: ZADD global:active_users <now> <user_id>.
    - Đẩy một Job: CatchUpFeedJob.perform_async(user_id)
3. CatchUpFeedJob: xử lý "Pull" dữ liệu bù. Job này đóng vai trò "vá" lại những lỗ hổng dữ liệu cho các User Loại B hoặc bài viết của Siêu sao (Celebrity) bị bỏ qua không Fan-out lúc đầu.
```ruby
# app/workers/catch_up_feed_job.rb
class CatchUpFeedJob
  include Sidekiq::Worker
  sidekiq_options queue: 'fanout_low', retry: 1

  def perform(user_id)
    user = User.find(user_id)

    # 1. Tìm IDs những người user này đang follow
    following_ids = Follower.where(followed_by_user_id: user_id).pluck(:user_id)
    return if following_ids.empty?

    # 2. Pull bài mới của họ trong 7 ngày qua
    # Chúng ta chỉ lấy tối đa ví dụ 100 bài mới nhất để tránh ngập lụt inbox
    recent_post_ids = Post.where(user_id: following_ids)
                          .where("created_at > ?", 7.days.ago)
                          .order(created_at: :desc)
                          .limit(100)
                          .pluck(:id)

    # 3. Chèn bù vào user_feeds (Sử dụng lại logic SQL thuần đã viết ở PushToFeedJob)
    if recent_post_ids.any?
      values = recent_post_ids.map { |p_id| "(#{user_id}, #{p_id})" }.join(",")

      sql = <<-SQL
        INSERT INTO user_feeds (user_id, post_id)
        VALUES #{values}
        ON CONFLICT (user_id, post_id) DO NOTHING;
      SQL

      ActiveRecord::Base.connection.execute(sql)
    end
  end
end
```

#### 6. Cơ Chế Fallback (The Pull Model)
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
Pseudo logic
```
if author.is_celebrity
    fanout_on_read
else
    fanout_on_write
```
Khi đọc feed:
```
feed_table
+
celebrity_posts
```

## v6 - Feed Cache

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

## v7 - Ranking System

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

## v8 - Real-time Feed Streaming

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

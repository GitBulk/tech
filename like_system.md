# Like System Notes -- v1.6

## Scope

- Hệ thống hiện đại, vừa phải (không lớn như facebook, twitter)
- Mục tiêu: bảo đảm chính xác, atomicity, hiệu suất hợp lý.
- PostgreSQL + Rails.

------------------------------------------------------------------------

# 1. Basic Like / Unlike Model

## Tables

**likes**

-   user_id
-   post_id

Index:

``` sql
CREATE UNIQUE INDEX uniq_like
ON likes(user_id, post_id);
```

Để:

-  1 user chỉ có thể like 1 bài post 1 lần
-  Cho phép thực hiện các idempotent operations.

------------------------------------------------------------------------

**posts**

-   id
-   likes_count (INTEGER NOT NULL DEFAULT 0)

------------------------------------------------------------------------

# 2. Idempotent LIKE Operation

Dùng atomic SQL `INSERT ... ON CONFLICT DO NOTHING`.

``` sql
WITH inserted AS (
  INSERT INTO likes(user_id, post_id)
  VALUES ($1, $2)
  ON CONFLICT DO NOTHING
  RETURNING 1
)
UPDATE posts
SET likes_count = likes_count + 1
WHERE id = $2
AND EXISTS (SELECT 1 FROM inserted);
```

Kết quả:
```
  Case             Result
  ---------------- -------------------------
  First like       insert row + counter +1
  Duplicate like   conflict → no insert
  Request retry    no counter change
```

Lợi ích:

-   Idempotent
-   Atomic
-   Safe for retries

------------------------------------------------------------------------

# 3. Idempotent UNLIKE Operation

``` sql
WITH deleted AS (
  DELETE FROM likes
  WHERE user_id = $1 AND post_id = $2
  RETURNING 1
)
UPDATE posts
SET likes_count = GREATEST(likes_count - 1, 0)
WHERE id = $2
AND EXISTS (SELECT 1 FROM deleted);
```

Kết quả:
```
  Case              Result
  ----------------- -------------------------
  First unlike      delete row + counter -1
  Repeated unlike   delete 0 rows
  Retry request     no counter change
```

------------------------------------------------------------------------
# 4. Race Condition Timelines
## Case 1: Two LIKE requests simultaneously

Initial: likes_count = 0

Timeline:
- T1: INSERT like → success
- T2: INSERT like → conflict (unique index)

Kết quả:
- likes_count = 1
- likes table = 1 row
- Correct.

------------------------------------------------------------------------
## Case 2: LIKE retry

Initial: likes_count = 0

Timeline:
- T1: request sent
- T2: network retry
- T3: request retried

Flow:

- first request → insert +1
- second request → conflict → no update

Kết quả: likes_count = 1

------------------------------------------------------------------------
## Case 3: Two UNLIKE requests simultaneously

Initial: likes_count = 1

Timeline:
- T1 delete like → success
- T2 delete like → 0 rows

Kết quả: likes_count = 0

------------------------------------------------------------------------

# 5. Vì sao không nên xử lý logic trong application code bằng 2 queries?

Example pattern:

```ruby
deleted = Like.where(user_id: user.id, post_id: post.id).delete_all

if deleted > 0
  Post.where(id: post.id)
      .update_all("likes_count = likes_count - 1")
end
```

Vấn đề:

-   Two round trips to DB
-   Potential inconsistency if app crashes between queries
-   Requires explicit transaction

Atomic SQL tránh được các lỗi trên.

------------------------------------------------------------------------

# 6. PostgreSQL Parameter Binding

In PostgreSQL:

    $1, $2, $3 ...

VD:
```sql
INSERT INTO likes(user_id, post_id)
VALUES ($1, $2)
```

Binding in Rails:

``` ruby
exec_query(sql, "LikePost", [[nil, user.id], [nil, post.id]])
```

Alternative approach (cleaner):

``` ruby
sanitize_sql_array([sql, user.id, post.id])
```

------------------------------------------------------------------------

# 7. Primary DB vs Read Replica

Like/Unlike should run on **primary DB** because:

Possible issue:

    replication lag

VD:
1.  User likes a post
2.  Request reads from replica
3.  Replica not yet updated

Kết quả: inconsistent UI.

Rails solution:

```ruby
ActiveRecord::Base.connected_to(role: :writing) do
  ...
end
```

------------------------------------------------------------------------

# 8. DELETE vs TRUNCATE (Important)

## DELETE ... RETURNING

Safe with concurrent inserts because PostgreSQL uses MVCC snapshots.

VD:
```sql
DELETE FROM post_like_deltas
RETURNING post_id, delta;
```

Các inserts mới sau thời điểm snapshot sẽ **không bị deleted**.

------------------------------------------------------------------------

## TRUNCATE

``` sql
TRUNCATE post_like_deltas;
```

Tính chất của Truncate:

-   Requires ACCESS EXCLUSIVE lock
-   Not MVCC based
-   Removes entire table contents instantly

Risk: Concurrent inserts may be lost depending on timing.

Kết luận:
```
  Method             Safe for concurrent writes
  ------------------ ----------------------------
  DELETE             Yes
  DELETE RETURNING   Yes
  TRUNCATE           No
```

------------------------------------------------------------------------
# 9. Code Review Checklist (Like System)
For a moderate-scale system:
When reviewing a Like system, check:

### Database
1.  Use unique constraint on `(user_id, post_id)`
-   [ ] Unique constraint on (user_id, post_id)
-   [ ] likes_count default 0
-   [ ] likes_count NOT NULL
### API correctness
-   [ ] LIKE is idempotent
-   [ ] UNLIKE is idempotent
-   [ ] Retry safe
### SQL design
-   [ ] Avoid read-modify-write pattern
-   [ ] Prefer atomic SQL
-   [ ] Avoid two-step operations when possible
### Infrastructure
-   [ ] Writes go to primary DB
-   [ ] Replica lag considered

------------------------------------------------------------------------

# 10. Current Recommended Approach (v1)

Đối với hệ thống vừa phải:

1.  Dùng unique index `(user_id, post_id)`
2.  Dùng atomic SQL cho like/unlike
3.  Duy trì `posts.likes_count`
4.  Thực hiện việc ghi và primary DB

Lợi ích:

-   Correctness
-   Idempotent API
-   Minimal race conditions
-   Simple architecture

------------------------------------------------------------------------

# 11. Counter Migration for Existing Systems
--------------------------------------

Version **v1.2** giải quyết vấn đề:

> Nếu hệ thống **đã chạy một thời gian** và bảng likes đã rất lớn (ví dụ **10M+ rows**) nhưng **chưa có column posts.likes_count**, thì migrate thế nào cho an toàn?

Vấn đề lúc này không chỉ là:
- Correctness (Tính đúng đắn)

mà còn là:
- Online Migration (Di chuyển dữ liệu khi hệ thống đang chạy)**
- Race Condition (Điều kiện tranh chấp)**
- Write Contention (Tranh chấp ghi)**

## 1. Bối cảnh hệ thống

Giả sử schema ban đầu:
- posts (id)
- likes(id, user_id, post_id)

Sau một thời gian: likes table ≈ 10M rows

Bây giờ ta muốn thêm: posts.likes_count

Để tránh query:

```sql
SELECT COUNT(*)
FROM likes
WHERE post_id = ?
```

## 2. Hai chiến lược migrate

Có hai hướng chính:
  1. Delay Migration (Di chuyển trì hoãn), không migrate ngay, tính likes_count khi cần.
  2. Eager Migration (Di chuyển ngay), Backfill toàn bộ likes_count.

## 3. Delay Migration Strategy
Ý tưởng: Chỉ khi hiển thị post mới tính likes_count. Sample code:
```ruby
def display_likes_count
  if self[:likes_count].nil?
    cnt = Like.where(post_id: id).count
    update_column(:likes_count, cnt)
    cnt
  else
    self[:likes_count]
  end
end
```

Ưu điểm
- Không cần query migrate lớn
- Không gây load database

Nhược điểm
- Race condition:
- Timeline:
```
T1  SELECT COUNT(*) = 10
T2  user LIKE
T3  likes_count update = 10
```

Kết quả mong đợi: likes_count phải là 11

Nhưng database lưu: 10

Đây là: Lost Update (Mất cập nhật)

Ngoài ra: Logic migrate phải giữ mãi trong code.

## 4. Eager Migration Strategy
Các bước:
  1. Add column nullable
  2. Deploy code support likes_count
  3. Backfill data
  4. Validate, Lock schema, drop constraint, ...

`Note:`
- Postgres < 11, thêm 1 column có giá trị default thì Postgres sẽ phải viết lại toàn bộ bảng để chèn giá trị 0 vào từng dòng. Việc này sẽ giữ một lệnh ACCESS EXCLUSIVE LOCK, ngăn chặn mọi thao tác đọc/ghi vào bảng posts cho đến khi hoàn tất, gây ra downtime nghiêm trọng.
- Postgres >= 11 đã optimize việc thêm column với giá trị default nên chiến lược làm sẽ khác một chút, đó là `không cần làm 4. Validate, Lock schema, drop constraint, ...` nhưng `vẫn cần làm 3. Backfill data`

`Postgres >= 11`
- Từ Postgres 11, khi thêm một cột có giá trị mặc định (DEFAULT), Postgres không còn quét toàn bộ bảng để ghi giá trị đó xuống đĩa cứng ngay lập tức. Thay vào đó, nó lưu giá trị mặc định vào bảng hệ thống (pg_attribute).
- Khi SELECT một dòng cũ, Postgres sẽ tự động chèn giá trị mặc định này vào kết quả trả về.
- Chỉ khi dòng đó được UPDATE, giá trị mới thực sự được ghi xuống đĩa.
- DEFAULT value phải là non-volatile expression:
```
DEFAULT 0
DEFAULT false
DEFAULT 'active'
```
- Không OK:
```
DEFAULT now()
DEFAULT gen_random_uuid()
DEFAULT random()
-> table rewrite
```
- Lệnh thực thi an toàn:
```sql
-- Chạy tức thì (instant) dù bảng có 10M hay 100M dòng
ALTER TABLE posts 
ADD COLUMN likes_count INTEGER NOT NULL DEFAULT 0;
```
So sánh:
```
Đặc điểm	 Postgres < 11	                    Postgres >= 11
-----------  ---------------------------------  -----------------------------------
Add Column	 Phải add NULL trước	            Có thể add NOT NULL DEFAULT 0 ngay
Thời gian    Lock	Rất lâu (nếu dùng Default)	Tức thì (O(1))
Độ an toàn	 Cần chia nhỏ nhiều bước	        Rất cao, ít rủi ro lock schema
```
## 5. Step 1 — Add Column (Nullable)
Không nên làm ngay việc thêm column likes_count INTEGER NOT NULL DEFAULT 0
vì **PostgreSQL có thể Table Rewrite (Viết lại toàn bảng)**
→ cực kỳ nặng nếu bảng lớn.

Thay vào đó:
```sql
ALTER TABLE posts ADD COLUMN likes_count INTEGER;
```

## 6. Step 2 — Application Support

Sau khi deploy code mới.

Like:
```sql
UPDATE posts
SET likes_count = COALESCE(likes_count,0) + 1
WHERE id = ?
```

Unlike:
```sql
UPDATE posts
SET likes_count = GREATEST(COALESCE(likes_count,0) - 1,0)
WHERE id = ?
```

Điểm quan trọng:
```sql
COALESCE(likes_count,0)
```
vì giai đoạn này likes_count vẫn có thể là NULL.


## 7. Step 3 — Backfill Existing Data

Query naive:
```qsql
UPDATE posts p
SET likes_count = sub.cnt
FROM (
  SELECT post_id, COUNT(*) cnt
  FROM likes
  GROUP BY post_id
) sub
WHERE p.id = sub.post_id;
```
Nếu **likes = 10M** rows thì query này -> scan toàn bảng -> cực nặng


## 8. Batch Backfill Strategy

Giải pháp: Batch Migration (Di chuyển theo lô)

VD:
```sql
UPDATE posts p
SET likes_count = sub.cnt
FROM (
  SELECT post_id, COUNT(*) cnt
  FROM likes
  WHERE post_id BETWEEN X AND Y
  GROUP BY post_id
) sub
WHERE p.id = sub.post_id;
```

Worker sẽ chạy:
```
- 1 → 10000
- 10001 → 20000
...
```

Ưu điểm:
- giảm load DB
- dễ kiểm soát

Khuyết điểm:
- Vẫn có thể gây slow query nếu một post_id có quá nhiều likes

Cách khác:
- Thay vì chạy một lệnh SQL khổng lồ GROUP BY post_id trên toàn bộ 10 triệu dòng (gây treo DB), chúng ta dùng ID của chính bảng likes làm "con trỏ" (cursor) để kiểm soát khối lượng công việc.
- Cách làm: Chia 10 triệu dòng likes thành các đoạn dựa trên ID (ví dụ: đợt 1 xử lý likes từ ID 1 đến 100.000). Với mỗi đoạn, ta tìm ra danh sách các post_id xuất hiện trong đó. Cập nhật cộng dồn vào bảng posts.
- Giải pháp cho vấn đề "Dữ liệu bị chia cắt", để tránh việc post_id = X bị đếm thiếu do nằm ở nhiều batch, chúng ta không dùng SET likes_count = count, mà dùng Atomic Addition (Cộng dồn nguyên tử).
- Script SQL cho Worker (Chạy theo lô ID của bảng likes):

```sql
-- Giả sử xử lý lô likes có ID từ 1.000.000 đến 1.050.000
UPDATE posts p
SET likes_count = COALESCE(p.likes_count, 0) + sub.batch_cnt
FROM (
  SELECT post_id, COUNT(*) as batch_cnt
   sentiments
  FROM likes
  WHERE id >= 1000000 AND id < 1050000
  GROUP BY post_id
) sub
WHERE p.id = sub.post_id;
```

- Tại sao cách này giải quyết được vấn đề chia cách dữ liệu ?
    - Nếu post_id = X xuất hiện ở lô 1 (có 2 likes) và lô 2 (có 3 likes), lệnh `SET likes_count = likes_count + batch_cnt` sẽ giúp giá trị tăng dần: $0 \to 2 \to 5$.
- Tốc độ: Việc lọc theo id (Primary Key) của bảng likes là thao tác nhanh nhất trong Postgres.
- An toàn: Có thể dừng script bất cứ lúc nào và chạy tiếp từ ID đã dừng mà không sợ mất dữ liệu.
- Sample ruby code:
```ruby
# Batch size cho bảng likes
BATCH_SIZE = 50_000
start_id = Like.minimum(:id)
max_id = Like.maximum(:id)

(start_id..max_id).step(BATCH_SIZE) do |current_id|
  upper_id = current_id + BATCH_SIZE

  # Thực hiện cộng dồn delta từ batch này vào bảng posts
  ActiveRecord::Base.connection.execute(<<-SQL)
    UPDATE posts p
    SET likes_count = COALESCE(p.likes_count, 0) + sub.cnt
    FROM (
      SELECT post_id, COUNT(*) as cnt
      FROM likes
      WHERE id >= #{current_id} AND id < #{upper_id}
      GROUP BY post_id
    ) sub
    WHERE p.id = sub.post_id
  SQL

  puts "Processed likes up to ID: #{upper_id}"
  sleep(0.05) # Giảm áp lực IO cho Disk
end
```

## 9. Vấn đề lớn nhất: Concurrent Writes

Trong lúc backfill vẫn có user like/unlike.

Ví dụ timeline:
```
Initial
likes_count = NULL
T1 backfill read COUNT(*) = 100
T2 user LIKE
T3 backfill write likes_count = 100
```

Giá trị mong đợi: 101

Nhưng database lưu: 100

Đây cũng là: **Lost Update (Mất cập nhật).**

## 10. Production-Safe Pattern

Giải pháp phổ biến: **Delta Buffer (Bộ đệm delta).**

Ý tưởng:
```
Backfill snapshot
+
Record realtime delta
```

Kiến trúc
```
likes table
   ↓
delta buffer
   ↓
likes_count column
```

Data phát sinh (delta) có thể lưu trong Redis hoặc table database

**Dùng Redis để lưu buffer data**

Key:
```
post_likes_buffer:{post_id}
```

User click LIKE:
```
INCR post_likes_buffer:123
```

Worker:
```
likes_count = likes_count + delta
```

**Dùng Delta Table**
```
post_like_deltas(post_id, delta)
```
Worker flush:
```sql
UPDATE posts
SET likes_count = likes_count + delta
```

**Idempotent Delta Buffer:**

Khi "replay" dữ liệu từ Delta Buffer (Redis hoặc Delta Table) vào bảng chính, chúng ta cần đảm bảo: Mỗi Delta chỉ được cộng một lần duy nhất.

1\. Problem

Khi dùng Delta Buffer, flow thường là:
```
Like event
   ↓
delta buffer
   ↓
background worker
   ↓
UPDATE posts.likes_count
```

VD:
```sql
UPDATE posts
SET likes_count = likes_count + 5
WHERE id = 42;
```

Nhưng nếu worker bị retry, crash, replay job thì delta có thể bị apply nhiều lần. Kết quả là likes_count sai


2\. Idempotency Principle

Replay phải đảm bảo:
- replay 1 lần = replay 100 lần
- Kết quả không thay đổi.

Đây gọi là: Idempotent Operation (Phép toán độc lập)

3\. Strategy A — Delta Table + Offset Tracking

Trên bảng posts, ta thêm một cột last_processed_delta_id.
Khi Replay, ta chỉ lấy các delta có id > last_processed_delta_id.
```sql
UPDATE posts p
SET likes_count = p.likes_count + sub.cnt,
    last_processed_delta_id = sub.max_id
FROM (
    SELECT post_id, COUNT(*) as cnt, MAX(id) as max_id
    FROM post_like_deltas
    WHERE id > p.last_processed_delta_id
    GROUP BY post_id
) sub
WHERE p.id = sub.post_id;
```
Lợi ích: Đây là cách làm Idempotent tuyệt đối. Dù Worker có crash và chạy lại 100 lần, nó vẫn chỉ lấy những dữ liệu mới hơn con số max_id đã lưu.

4\. Strategy B — Redis Delta Buffer

Nếu dùng Redis, vấn đề là lệnh GET để lấy delta rồi cập nhật vào DB, rồi SET 0 không atomic (có thể mất Like phát sinh ở giữa 2 lệnh).

Giải pháp: Dùng lệnh GETSET hoặc Lua Script để lấy giá trị và reset về 0 trong một thao tác duy nhất.

```ruby
# Lua script để đảm bảo nguyên tử
script = <<~LUA
  local val = redis.call('get', KEYS[1])
  redis.call('set', KEYS[1], 0)
  return val
LUA

delta = redis.eval(script, keys: ["post_likes_buffer:#{post_id}"])
# Sau đó cộng delta này vào Database
```


## 11. Finalization

Sau khi:
- backfill xong
- replay delta xong

ta mới lock schema:
```sql
ALTER TABLE posts
ALTER COLUMN likes_count SET DEFAULT 0;
```

```sql
ALTER TABLE posts
ALTER COLUMN likes_count SET NOT NULL;
```

**Note:**
Việc Alter table để set not null có thể gây chậm với các version Postgres cũ. Thay vì cố gắng dùng SET NOT NULL, chúng ta có thể sẽ dừng lại ở Check Constraint.

### Use Postgres < 12
**Bước 1: Khai báo Constraint (Lệnh này chạy tức thì)**
```sql
ALTER TABLE posts
ADD CONSTRAINT posts_likes_count_not_null
CHECK (likes_count IS NOT NULL) NOT VALID;
```

**Lưu ý:** NOT VALID giúp Postgres bỏ qua việc kiểm tra 10 triệu dòng cũ, chỉ áp dụng cho các dòng mới từ giây phút này.

**Bước 2: Xác thực dữ liệu cũ (Chạy ngầm)**

```sql
ALTER TABLE posts
VALIDATE CONSTRAINT posts_likes_count_not_null;
```

**Đặc điểm:** Lệnh này quét bảng nhưng không lock việc đọc/ghi. Nếu phát hiện dòng nào NULL, nó sẽ báo lỗi. Lúc này bạn chỉ cần chạy Audit/Fix rồi chạy lại lệnh này.

**Chiến lược Audit:**

`Tầng 1. Quick Check:`

Trước khi đi vào chi tiết, ta kiểm tra tổng số lượng trên toàn hệ thống. Nếu hai con số này lệch nhau, chắc chắn có bước nào đó trong quá trình migrate bị lỗi.

```sql
SELECT
    (SELECT SUM(likes_count) FROM posts) AS total_counter,
    (SELECT COUNT(*) FROM likes) AS total_actual_records;
```


`Tầng 2: Tìm bài post bị lệch (Deep Audit)`

Nếu tầng 1 có lệch, hoặc muốn chắc chắn 100%, hãy dùng câu query này để "chỉ mặt đặt tên" những bài post đang có dữ liệu sai.

Lưu ý: Query này quét toàn bộ 10 triệu dòng nên chỉ chạy vào giờ thấp điểm (Off-peak hours).

```sql
SELECT p.id, p.likes_count, sub.actual_cnt
FROM posts p
JOIN (
    SELECT post_id, COUNT(*) AS actual_cnt
    FROM likes
    GROUP BY post_id
) sub ON p.id = sub.post_id
WHERE p.likes_count != sub.actual_cnt
LIMIT 100; -- Xem trước 100 dòng lỗi đầu tiên
```

`Tầng 3: Tự động sửa lỗi (Auto-Healing)`

Nếu phát hiện có sai lệch (thường do Race Condition cực hiếm hoặc lỗi logic trong script backfill), chúng ta dùng lệnh UPDATE kết hợp JOIN để đồng bộ lại dữ liệu chuẩn từ bảng likes sang posts.

```sql
-- Chỉ cập nhật những dòng bị lệch để tiết kiệm IO
UPDATE posts p
SET likes_count = sub.actual_cnt
FROM (
    SELECT post_id, COUNT(*) AS actual_cnt
    FROM likes
    GROUP BY post_id
) sub
WHERE p.id = sub.post_id
  AND p.likes_count != sub.actual_cnt;
```

`Mindset`
```
Dữ liệu là tài sản, và trong một hệ thống lớn, 'hy vọng' không phải là một chiến lược quản lý rủi ro tốt. Audit là cách để chúng ta biến 'hy vọng' thành 'sự thật'.
```

`Vacuum & Analyze:`

Mục đích để Postgres cập nhật lại bảng thống kê (statistics), giúp Query Planner hoạt động chính xác nhất sau khi thay đổi 10 triệu dòng.

```sql
-- 1. Cập nhật thống kê trước (Rất nhanh, cực kỳ an toàn)
ANALYZE posts;

-- 2. Dọn dẹp rác sau (Chạy lúc thấp điểm để tránh tốn IO)
VACUUM posts;
```
**Bước 3: Quyết định về SET NOT NULL**

- Với hệ thống chạy Postgres cũ (vd: version 9.5): Dừng lại ở đây. Không chạy ALTER COLUMN SET NOT NULL. Vì lệnh này không nhận diện được VALIDATED CHECK CONSTRAINT và sẽ quét bảng lại từ đầu dưới lệnh khóa nặng, gây gián đoạn hệ thống

- Từ Postgres >= 12. Nếu đã tồn tại valid CHECK constraint chứng minh column không thể NULL, PostgreSQL bỏ qua table scan khi SET NOT NULL. Thực ra từ Postgres >= 11 thì việc thêm column có default value đã dễ dàng hơn rất nhiều.


### Use Postgres >= 12
**Bước 4 — Convert to NOT NULL**

Sau khi constraint đã validate:
```sql
ALTER TABLE posts
ALTER COLUMN likes_count SET NOT NULL;
```

Vì PostgreSQL đã biết: `likes_count IS NOT NULL` nên bước này chỉ `update metadata` và không cần scan table nữa.

**Bước 5 — Remove Temporary Constraint (Optional)**

Sau khi column đã NOT NULL:
```sql
ALTER TABLE posts
DROP CONSTRAINT posts_likes_count_not_null;
```

Constraint này không còn cần thiết.

Lúc này:
```
sau khi backfill xong + replay hết delta, thì likes_count đã trở thành nguồn dữ liệu chính xác và đáng tin cậy.
```

### Timeline Visualization
```
ADD nullable COLUMN
    ↓
BACKFILL DATA
    ↓
ADD CHECK NOT VALID
    ↓
VALIDATE CONSTRAINT  (online table scan)
    ↓
SET NOT NULL         (instant)
```

`[Postgres >= 11]`
```
ALTER TABLE ADD COLUMN DEFAULT 0 NOT NULL (Instant)
    ↓
START RECORDING DELTAS (Redis/Table)
    ↓
BATCH BACKFILL (Atomic Update: count + delta)
    ↓
AUDIT & ANALYZE
```

`Mindset`
```
Hiểu về phiên bản Database đang dùng giúp chúng ta chọn được con đường ngắn nhất. Nhưng dù con đường có ngắn đến đâu, nguyên tắc 'Atomic' và 'Audit' vẫn là kim chỉ nam không được phép thay đổi
```

## 12. Online Migration Timeline

Production rollout:
```
Deploy code
   ↓
Add nullable column
   ↓
Start recording deltas
   ↓
Run batch backfill
   ↓
Replay deltas
   ↓
Lock schema constraints
```

Đảm bảo:
- No Downtime (Không downtime)
- No Lost Update (Không mất cập nhật)
- Safe Migration (Di chuyển an toàn)


------------------------------------------------------------------------
# Roadmap:
- **v1.0:**  Basic counter design
- **v1.1:**  Race condition analysis
- **v1.2:**  Counter migration for existing system
- **v1.3:**  Online NOT NULL migration pattern
- **v1.4:**  Support Postgres >= 11
- **v1.5:**  Update migration
- **v1.6:**  Idempotent Delta Replay
- **v2**: Handling higher traffic (counter contention)
- **v3**: Delta tables / batch aggregation
- **v4**: Distributed counters / caching
- **v5**: Large-scale architecture (queues, sharded counters, etc.)

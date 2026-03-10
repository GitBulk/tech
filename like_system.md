# Like System Notes -- v1.1

## Scope

- Hệ thống hiện đại, vừa phải (không lớn như facebook, twitter)
- Mục tiêu: bảo đảm chính xác, atomicity, hiệu suất hợp lý.
- PostgreSQL + Rails.

## History

v1.1:
- Race condition timelines
- Code review checklist for Like systems

v1.2:
- Backfill data sau khi hệ thống đã chạy một thời gian

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

Chiến lược phổ biến trong production.

Các bước:
  1. Add column nullable
  2. Deploy code support likes_count
  3. Backfill data
  4. Lock schema

## 5. Step 1 — Add Column (Nullable)
Không nên làm ngay: likes_count INTEGER NOT NULL DEFAULT 0
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

Lúc này:
```
sau khi backfill xong + replay hết delta, thì likes_count đã trở thành nguồn dữ liệu chính xác và đáng tin cậy.
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
- **v2**: Handling higher traffic (counter contention)
- **v3**: Delta tables / batch aggregation
- **v4**: Distributed counters / caching
- **v5**: Large-scale architecture (queues, sharded counters, etc.)

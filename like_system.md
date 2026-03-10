# Like System Notes -- v1

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

# 4. Vì sao không nên xử lý logic trong application code bằng 2 queries?

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

# 5. PostgreSQL Parameter Binding

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

# 6. Primary DB vs Read Replica

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

# 7. DELETE vs TRUNCATE (Important)

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

# 8. Current Recommended Approach (v1)

For a moderate-scale system:

1.  Dùng unique index `(user_id, post_id)`
2.  Dùng atomic SQL cho like/unlike
3.  Duy trì `posts.likes_count`
4.  Thực hiện việc ghi và primary DB

Lơi ích:

-   Correctness
-   Idempotent API
-   Minimal race conditions
-   Simple architecture

------------------------------------------------------------------------

# Future Versions

-   **v2**: Handling higher traffic (counter contention)
-   **v3**: Delta tables / batch aggregation
-   **v4**: Distributed counters / caching
-   **v5**: Large-scale architecture (queues, sharded counters, etc.)

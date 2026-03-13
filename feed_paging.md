# Feed And Paging -- v1.0

## Roadmap:
- **v1.0:** Introduce Pagination Algorithms

# 1. Naive Database Pagination
-------------------------

**Architecture**

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

**Đây là version mà 90% startup bắt đầu.**

# 2. Cursor Pagination (Keyset Pagination)

Thay vì OFFSET.

**Query**
```sql
SELECT *
FROM posts
WHERE created_at < :cursor
ORDER BY created_at DESC
LIMIT 20
```
Cursor = last item timestamp.

**Ưu điểm**
- Query nhanh
- Không scan offset

**Complexity**
```
O(limit)
```

# 3. Feed per User (Fan-out on Read)

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

Friend list có thể 1000+

DB phải:
```sql
WHERE author_id IN (...)
```
Query bắt đầu chậm.

# 4. Feed Table (Precomputed Feed)

Giải pháp:

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

# 5. Celebrity Problem

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

# Feed Pagination Strategy

2 loại chính.

1\. Cursor pagination (most common)
```
GET /feed?cursor=abc123
```
Cursor có thể encode:
```
(timestamp, post_id)
```

2\. Score based pagination

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

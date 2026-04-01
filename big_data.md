📊 PHASE 1: POSTGRESQL 18 HIGH-PERFORMANCE LAB
===================================================

1\. Cấu hình Phần cứng & Môi trường
-----------------------------------

*   **Thiết bị:** MacBook Pro M3 (8 Cores: 4 Performance, 4 Efficiency).
    
*   **OS/DB:** macOS / PostgreSQL 18 (Native ARM64).
    
*   **Quy mô:** 100,000,000 (100 triệu) dòng dữ liệu mẫu.
    
*   **Dung lượng thực tế:** ~8.5 GB (Data + Indexes).
    

2\. Kiến trúc Partitioning (Chia để trị)
----------------------------------------

Sử dụng **Declarative Partitioning** theo dải thời gian (Range):

*   **Bảng mẹ:** events (Partition Key: created\_at).
    
*   **Chiến lược bảng con:**
    
    *   events\_old: Chứa 10 triệu dòng đầu tiên.
        
    *   events\_2026\_04: Chứa 90 triệu dòng (Dải 2026-04-01 to 2030-01-01).
        
    *   events\_partition\_default: Hứng dữ liệu nằm ngoài các dải trên.

Dump data:
```sql
INSERT INTO events (user_id, category, info, created_at)
SELECT 
    (random()*10000)::int,
    (random()*50)::int,
    md5(random()::text), 
    now() - (random() * interval '100 days')
FROM generate_series(1, 10000000)
```

3\. Chiến lược Indexing (Cân bằng Tốc độ & Lưu trữ)
---------------------------------------------------

So sánh hiệu quả trên bảng 90 triệu dòng:

|Loại Index   |Cột áp dụng     |Kích thước|Mục đích                                           |
|-------------|----------------|----------|---------------------------------------------------|
|B-Tree (PKey)|(id, created_at)|2.7 GB    |Tìm kiếm chính xác ID, đảm bảo Unique.             |
|BRIN         |created_at      |800 KB    |Quét dải thời gian, cực nhẹ (Tiết kiệm 99.9% size).|


**Key takeaway:** Với dữ liệu Log khổng lồ (100B dòng), BRIN là lựa chọn sinh tồn để tránh cạn kiệt SSD.

4\. Tinh chỉnh Cấu hình (postgresql.conf)
-----------------------------------------

Các thông số đã được tối ưu cho chip M3 để nạp và truy vấn dữ liệu lớn:

```sql
-- Nhóm Nạp dữ liệu (Bulk Load)
ALTER SYSTEM SET max_wal_size = '20GB';          -- Giảm tần suất Checkpoint
ALTER SYSTEM SET checkpoint_timeout = '30min';   -- Giảm nghẽn I/O ghi đĩa
ALTER SYSTEM SET synchronous_commit = 'off';    -- Tăng tốc nạp 30%

-- Nhóm Xử lý song song (Parallelism)
ALTER SYSTEM SET max_parallel_workers_per_gather = 4; -- Khớp 4 nhân P-cores
ALTER SYSTEM SET maintenance_work_mem = '4GB';        -- Xây Index thần tốc
```

5\. Quy trình nạp dữ liệu "Pro" (Workflow)
------------------------------------------

Quy trình tối ưu để nạp 100 triệu dòng trong ~2 phút:

1.  **Prepare:** Tạo bảng UNLOGGED (nếu không cần an toàn tuyệt đối khi nạp) và không tạo Index trước.
    
2.  **Split:** Dùng Python/Unix split chia file CSV khổng lồ thành nhiều phần (ví dụ: 4 file).
```bash
# muốn mỗi file có 25tr dòng
split -l 25000000 data_90m.csv data_part_

# muốn mỗi file nặng 1GB
split -b 1024m data_90m.csv data_part_
```

3.  **Parallel Ingest:** Chạy script .sh để kích hoạt 4 lệnh COPY song song vào các Partition khác nhau.
    
4.  **Post-Index:** Sau khi nạp xong dữ liệu thô, mới tiến hành CREATE INDEX.
    

6\. Kết quả Benchmarking (M3 Performance)
-----------------------------------------

*   **Search (Time-range):** ~93ms (Dù dữ liệu tăng 10 lần, tốc độ vẫn giữ mức <100ms nhờ BRIN).
    
*   **Aggregation (Group By):** ~3.0s (Quét toàn bộ 100 triệu dòng, huy động 7-8 workers).
    
*   **Ingestion Speed:** ~100 triệu dòng / 2 phút.
    

7\. Dead tuple (đọc thêm)
-----------------------------------------
PG dùng cơ chế MVCC (Multi-Version Concurrency Control), cho phép nhiều transaction đọc và ghi đồng thời mà không lock nhau.

Giả sử bảng users
```sql
-- Ban đầu
id | name     | age
---+----------+-----
1  | Tran     | 25
```
Khi chạy lênh Update
```sql
UPDATE users SET age = 26 WHERE id = 1;
```
PostgreSQL không sửa trực tiếp dòng cũ. Nó sẽ:
- Tạo ra một phiên bản mới (new tuple): (id=1, name=Tran, age=26)
- Đánh dấu phiên bản cũ (age=25) thành Dead Tuple

Khi chạy lệnh Delete
```sql
DELETE FROM users WHERE id = 1;
```
PostgreSQL cũng không xóa ngay dòng đó, mà chỉ đánh dấu nó là Dead Tuple.

→ Kết quả: Trong file dữ liệu của bảng, vẫn còn tồn tại cả live tuple (phiên bản mới nhất) và dead tuple (phiên bản cũ).

Postgres làm vậy, vì:
- Để hỗ trợ đọc đồng thời (readers never block writers).
- Transaction cũ đang chạy có thể vẫn cần thấy phiên bản cũ của dữ liệu.
- Đảm bảo tính nhất quán (consistency) của transaction.

Hậu quả nếu có quá nhiều Dead Tuples
- Table bloat (bảng phình to): Chiếm nhiều dung lượng đĩa không cần thiết.
- Query chậm hơn: Khi scan bảng (seq scan) hoặc dùng index, PostgreSQL phải bỏ qua (skip) rất nhiều dead tuples → tốn thời gian và I/O.
- Index cũng bị bloat: Index cũng có dead entries tương tự.
- Tăng nguy cơ transaction ID wraparound (vấn đề nghiêm trọng).

Cách xem số lượng Dead Tuples
```sql
-- Xem dead tuples của tất cả tables
SELECT
    schemaname,
    relname,
    n_live_tup AS live_tuples,
    n_dead_tup AS dead_tuples,
    (n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0)) AS dead_percent
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```
Hoặc xem chi tiết một bảng:
```sql
SELECT * FROM pgstattuple('ten_bang_cua_ban');
```

Cách dọn dẹp Dead Tuples:
- VACUUM ten_bang; → Dọn dead tuples, đánh dấu không gian trống để tái sử dụng (không thu hồi dung lượng đĩa ngay).
- VACUUM FULL ten_bang; → Dọn sạch và thu hồi dung lượng đĩa thật sự (nhưng khóa bảng, nặng hơn).
- AUTOVACUUM → PostgreSQL tự động chạy (nên cấu hình tốt).

**Lưu ý:**
VACUUM thông thường không thu hồi dung lượng đĩa cho hệ điều hành (chỉ đánh dấu để dùng lại). Muốn thu hồi thật phải dùng VACUUM FULL hoặc pg_repack.


🚩 Chốt chặn Phase 1
--------------------

PostgreSQL đã làm rất tốt việc lưu trữ và tìm kiếm. Tuy nhiên, khi tiến tới **100 tỷ dòng**:

1.  **Dung lượng:** B-Tree sẽ chiếm hàng Terabyte (vượt quá 700GB SSD hiện có).
    
2.  **Aggregation:** Thời gian 3 giây sẽ nhân lên thành hàng nghìn giây (không thể làm Analytics thời gian thực).
    

👉 **Next Step:** Chuyển hướng sang **Phase 2: ClickHouse (Columnar Storage)** để giải quyết bài toán nén 10x và Aggregate 0.05s.
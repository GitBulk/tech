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


📊 Phase 2: ClickHouse - "Vị thần" tốc độ Aggregate
===================================================
## 1. Overview

Khi Postgres chạm ngưỡng ~500 triệu - 1 tỷ dòng, việc chạy GROUP BY trên 10TB dữ liệu sẽ là thảm họa. ClickHouse sẽ nhảy vào cuộc chơi.
- Tại sao: ClickHouse sử dụng Column-oriented storage. Thay vì đọc cả dòng (row), nó chỉ đọc đúng cột cần tính toán.
- Cơ chế đồng bộ: Sử dụng MaterializedPostgreSQL engine. ClickHouse sẽ đóng vai trò là một "Replica" của Postgres, tự động kéo dữ liệu về để phục vụ Analytics.
- Nén dữ liệu: 10TB CSV có thể chỉ còn ~1TB trong ClickHouse nhờ thuật toán LZ4/ZSTD.
- So sánh:

|Đặc điểm      |PostgreSQL / Oracle / SQL Server       |MongoDB (NoSQL)                          |ClickHouse (Chosen)                            |
|--------------|---------------------------------------|-----------------------------------------|-----------------------------------------------|
|Storage Engine|Row-based (Lưu theo dòng).             |Document-based (BSON).                   |Columnar-based (Lưu theo cột).                 |
|Indexing      |B-Tree (Phình to Terabytes, nghẽn RAM).|B-Tree (Tốn RAM, không tối ưu Analytics).|Sparse Index (Siêu nhẹ, chỉ tốn MBs RAM).      |
|Nén dữ liệu   |Kém (1x - 2x).                         |Trung bình (Tốn chỗ do metadata JSON).   |Cực tốt (5x - 20x) nhờ LZ4/ZSTD.               |
|Tốc độ Query  |Chậm khi Aggregate (phải đọc cả dòng). |Rất chậm khi Group By hàng tỷ docs.      |Thần tốc (1.27 tỷ dòng/s trên M3).             |
|Setup Cost    |~$1M+ (License + SAN Storage cực xịn). |Cao (Cần Cluster RAM khủng).             |~$0 (Open Source, chạy tốt trên máy phổ thông).|


**Key Architect Note:**
- Chuyển sang Oracle/SQL Server thực chất chỉ là "mua bảo hiểm" thương hiệu. Về mặt vật lý, chúng vẫn bị giới hạn bởi I/O của Row-store. ClickHouse giải quyết từ gốc rễ bằng cách chỉ đọc đúng cột cần thiết.
- MongoDB là NoSQL (Document-based), nhanh khi truy cập dữ liệu theo ID hoặc các query đơn giản, nhưng với Big Data Analytics, nó là một thảm họa:
    - Dung lượng: MongoDB lưu dữ liệu dưới dạng BSON (JSON binary). Nó cực kỳ tốn dung lượng (thậm chí tốn hơn cả Postgres). 10TB data thô vào Mongo có thể lên tới 15TB.
    - Aggregation Framework: Khi chạy pipeline (GROUP BY) trên hàng tỷ Document, MongoDB sẽ phải nạp toàn bộ Document đó vào RAM. Nó không có khả năng "chỉ đọc đúng cột cần thiết" một cách hiệu quả như ClickHouse.
    - WiredTiger Engine: Cơ chế khóa (locking) và ghi của Mongo ở quy mô 100 tỷ dòng sẽ có thể làm nghẽn I/O.

Install ClickHouse: https://clickhouse.com/docs/getting-started/quick-start/oss

```bash
# 1. Tạo thư mục làm việc và tải binary
mkdir -p ~/clickhouse_platform && cd ~/clickhouse_platform

# Tải binary native cho Mac M3 (aarch64)
curl https://clickhouse.com/ | sh

# Kiểm tra binary đã tải xong chưa, ~125MB
ls -lh clickhouse

# Cài đặt ClickHouse, lệnh này sẽ tạo các thư mục mặc định:
# /var/lib/clickhouse/ (lưu data), /etc/clickhouse-server/ (config), /var/log/clickhouse-server/
# Tạo user/group clickhouse nếu cần
sudo ./clickhouse install

# config cho clickhouse chạy ngầm trên Macbook
sudo tee /Library/LaunchDaemons/com.clickhouse-server.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clickhouse-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/clickhouse</string>
        <string>server</string>
        <string>--config-file=/etc/clickhouse-server/config.xml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/clickhouse-server/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/clickhouse-server/stderr.log</string>
</dict>
</plist>
EOF


# Phân quyền và Kích hoạt:
sudo chown root:wheel /Library/LaunchDaemons/com.clickhouse-server.plist
sudo chmod 644 /Library/LaunchDaemons/com.clickhouse-server.plist
sudo launchctl load -w /Library/LaunchDaemons/com.clickhouse-server.plist


# kiểm tra clickhouse có chạy ngầm ko?
sudo launchctl list | grep clickhouse

# chạy background như service
sudo clickhouse start

#Dừng Server
sudo clickhouse stop

# Chạy client
clickhouse client
```

## 2. Kiến trúc Triển khai (Lab Result)
Engine: MergeTree (Native Engine mạnh nhất của ClickHouse).

Partitioning: toYYYYMM(created_at) (Chia để trị theo tháng).

Primary Key (Implicit): ORDER BY (id, category, created_at).

Precision: DateTime64(6) để khớp tuyệt đối với Microseconds của Postgres 18.

## 3. Kỹ thuật "Cỗ máy vĩnh cửu" (Materialized View)
Để đạt tốc độ query < 0.01s trên 100 tỷ dòng, NOVA AI sử dụng kiến trúc Pre-aggregation:
1. Source Table: events (Lưu log thô - Source of Truth).
2. Aggregated Table: events_hourly_summary (Dùng AggregatingMergeTree).
3. The Trigger: Materialized View tự động tính toán countState ngay khi Insert.

Kết quả thực tế trên M3:
- Nạp 1 triệu dòng: < 0.2 giây.
- Dung lượng bảng tổng hợp (Summary): 720 Bytes (cho 1 triệu dòng thô).
- Tốc độ truy vấn báo cáo: 0.009 giây.

## 4. Maintenance & Optimization
Data Retention: Sử dụng TTL để tự động dọn dẹp hoặc move data.

Compression: Tối ưu cột String bằng CODEC(ZSTD(3)) cho dữ liệu lạnh.

Migration Path: Sử dụng Database Engine PostgreSQL để tạo "cầu nối" trực tiếp giữa CLH và PG mà không cần file trung gian.

🚩 Chốt chặn Phase 2: ClickHouse đã hoàn thành nhiệm vụ biến 10TB dữ liệu thành những bảng Summary "vài KB", sẵn sàng phục vụ Dashboard AI với độ trễ gần như bằng 0.


## 5. Ingestion, Storage Strategy
Ingestion:
Ưu tiên cơ chế Pull (ClickHouse kéo từ Postgres) ở giai đoạn đầu để giảm độ phức tạp. Sẵn sàng chuyển sang cơ chế Push (Kafka/CDC) khi cần mở rộng.

Storage Strategy:
- Hot Data: ClickHouse MergeTree (Truy vấn ngay).
- Aggregated Data: ClickHouse AggregatingMergeTree (Báo cáo Dashboard).
- Cold Data (Phase 3): Parquet trên MinIO (Lưu trữ vĩnh viễn).


🌊 Phase 3: Data Lake (S3 + Parquet) (tiếp tục ở đây)
===================================================
Dữ liệu 100 tỷ dòng sau 1-2 năm sẽ trở thành "dữ liệu lạnh" (Cold data). Lưu trữ mãi trên SSD của ClickHouse/Postgres là một sự lãng phí ngân sách (Not budget-conscious).
- Chuyển đổi: Export dữ liệu cũ sang định dạng Apache Parquet.
- Lưu trữ: Đẩy lên S3 (hoặc MinIO nếu bạn muốn tự host).
- Hiệu quả: Chi phí lưu trữ giảm 10-20 lần so với chạy DB.

```bash

# Tải bản Native ARM cho chip M-series
curl https://dl.min.io/server/minio/release/darwin-arm64/minio --output minio

# Cấp quyền thực thi
chmod +x minio

# Di chuyển vào thư mục bin hệ thống để gọi từ đâu cũng được
sudo mv minio /usr/local/bin/

# Kiểm tra
minio --version

# Tải bản mc (tức minio client cho console) cho Apple Silicon
curl https://dl.min.io/client/mc/release/darwin-arm64/mc --output mc

# Cấp quyền thực thi
chmod +x mc

# Đưa vào "hàng ngũ" cùng với minio server
sudo mv mc /usr/local/bin/

# Kiểm tra thành quả
mc --version

# tạo folder nơi chứ data cho minio (có thể dùng tên khác)
mkdir -p ~/minio_data


# Vì minio và clickhouse đụng port 9000 nên ta cần sửa port của minio server
# thành 9002 để các lệnh bằng python, ruby, clickhouse, ... có thể giáo tiếp được
# còn phần dashboard admin của minio vẫn dùng port 9001
# thêm dòng alias bên dưới vào file ~/.bash_profile, sau đó gõ source ~/.bash_profile để cập nhật
alias minio_server='minio server ~/minio_data --address ":9002" --console-address ":9001"'

# từ bây giờ, ta dùng alias vừa tạo để start minio server, gõ lệnh
minio_server

# gắn minio_data vào minio server
minio server ~/minio_data --console-address ":9001"

# tạo 1 alias cho minio server, vd alias tên là nova-lake
# dùng minio client để tạo alias
mc alias set nova-lake http://localhost:9002 minioadmin minioadmin

# xem info các alias
mc alias list

# tạo bucket, vd tên bucket minio-bucket
# C1: truy cập localhost:9001, tạo thử 1 bucket
# C2: gõ lệnh, cú pháp `mc mb alias_name/bucket_name`
mc mb nova-lake/minio-bucket

# liệt kê file trong bucket
mc ls nova-lake/minio-bucket

# copy file vào bucket
mc cp "/Users/mingle/Documents/test data.txt" nova-lake/minio-bucket

# kiểm tra các named collection, trong clickhouse client
SELECT name, create_query
FROM system.named_collections
WHERE name = 'minio_lab';
```

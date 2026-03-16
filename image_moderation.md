# Image Moderation System – Design v1.0

## 1. Mục tiêu

Hệ thống moderation nhằm:
1. Phát hiện và chặn nội dung NSFW (sex, porn, nude).
2. Ngăn re-upload ảnh vi phạm bằng perceptual hashing.
3. Cho phép manual review với các trường hợp không chắc chắn.
4. Thiết kế theo microservice để AI có thể phát triển độc lập với hệ thống web.
5. Tech sample: rails, postgres, python, redis, ...

## 2. Kiến trúc tổng thể
```
User Upload
    │
    ▼
Rails API
    │
    ▼
S3 Object Storage
    │
    ▼
Image Record (DB)
    │
    ▼
Sidekiq Worker
    │
    ▼
Moderation Service (Python)
    │
    ├── Layer 1: MD5 duplicate check
    ├── Layer 2: pHash check
    ├── Layer 3: AI NSFW detection
    ▼
Decision Engine
    │
    ├── SAFE   → publish
    ├── REVIEW → admin queue
    └── BLOCK  → reject
```

## 3. Upload Flow

1. Client request presigned_url từ Rails API.
2. Client upload trực tiếp lên S3.
3. Rails lưu record images vào database.

Ví dụ schema:
```sql
images
------

id
image_path
status
phash
created_at
```
Sau khi record được tạo:
```ruby
ModerateImageJob.perform_async(image.id)
```
Worker sẽ gọi moderation service.

## 4. Moderation Worker

Sidekiq worker chịu trách nhiệm:
1. Lấy thông tin image từ DB.
2. Lấy s3_url.
3. Gọi moderation service.

Pseudo flow:
```
ModerateImageJob
1. load image record
2. send image_url to moderation service
3. receive result
4. update image status
```
Response từ moderation service:
```
SAFE
REVIEW
BLOCK
```

## 5. Moderation Service

Moderation service được viết bằng Python, service này thực hiện hai bước:
```
1. pHash duplicate detection
2. AI NSFW classification
```
## 6. Layer 1 – Perceptual Hash (pHash)

Mục tiêu:
```
detect ảnh đã từng upload trước đó
```
Ví dụ:
```
user upload porn
→ system block
→ hash được lưu
user khác upload lại ảnh đó
→ detect ngay
```

Data lưu
```sql
images
------

phash BIGINT
phash_prefix SMALLINT
Lookup
SELECT phash
FROM images
WHERE phash_prefix = ?
AND bit_count(phash XOR new_phash) <= threshold
```

Threshold thường:
```
<= 5
```

Lợi ích
- giảm load AI model
- chặn spam re-upload

## 7. Layer 2 – AI NSFW Detection

Nếu pHash không match, ảnh sẽ được gửi qua AI model.

Model output:
```
nsfw_probability (0.0 → 1.0)
```

Decision rule:
```
> 0.9  → BLOCK
0.5-0.9 → REVIEW
< 0.5 → SAFE
```

## 8. Decision Engine

Decision engine hợp nhất các kết quả.

Logic:
```
if phash_match:
    BLOCK

elif nsfw_prob > 0.9:
    BLOCK

elif nsfw_prob > 0.5:
    REVIEW

else:
    SAFE
```

## 9. Image Normalization

Trước khi tính pHash hoặc chạy model, ảnh cần được chuẩn hóa.

Pipeline:
```
download image
auto rotate (EXIF)
convert RGB
resize fixed size
compute phash
```
Điều này giúp:
```
pHash stable
model stable
```

## 10. Async Moderation vs Synchronous Moderation

Đây là quyết định kiến trúc quan trọng.

### 10.1 Synchronous Moderation

Flow:
```
upload
   │
   ▼
moderation
   │
   ▼
publish
```
User phải **đợi moderation hoàn tất.**

Ưu điểm
- nội dung vi phạm không bao giờ xuất hiện

Nhược điểm
- upload latency cao
- AI inference chậm
- UX kém

### 10.2 Async Moderation

Flow:
```
upload
   │
   ▼
publish (pending)
   │
   ▼
moderation worker
```

Nếu phát hiện vi phạm:
```
image removed
user notified
```

Ưu điểm
- upload rất nhanh
- scale tốt
- AI xử lý background

Nhược điểm
- ảnh vi phạm có thể tồn tại ngắn trong hệ thống

### 10.3 Lựa chọn cho hệ thống hiện tại

Thiết kế hiện tại sử dụng: async moderation
vì:
```
Upload UX tốt hơn
Sidekiq xử lý background tốt
AI service có thể scale độc lập
```

## 11. Flow Upload Image
```
Client
  │
  ▼
presigned_url
  │
  ▼
upload to S3
  │
  ▼
confirm_upload API
  │
  ▼
Rails verify object
  │
  ▼
create image record
  │
  ▼
Sidekiq moderation
```

Lợi ích

Tránh được:
```
DB record rác
moderation job lỗi
404 image
```
và đảm bảo:
```
image chắc chắn tồn tại và đúng yêu cầu
```
## 12. Future Improvements

Có thể mở rộng sau:
```
vector embedding
cropped image detection
```

## 13. Versioning Roadmap
```
v1.0
Postgres + pHash + AI moderation

v1.1
pHash prefix sharding

v2.0
vector similarity search
```
End of document.

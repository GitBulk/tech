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
Sidekiq Worker (download image, compute MD5, DB lookup)
    │
    ▼
Moderation Service (Python)
    │
    ├── Layer 1: pHash check
    ├── Layer 2: AI NSFW detection
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
CREATE TABLE images (
  id BIGSERIAL PRIMARY KEY,
  s3_key VARCHAR NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  md5_hex CHAR(32),
  phash BIGINT,
  phash_prefix SMALLINT,
  nsfw_score FLOAT,
  created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- dùng cho phash search = prefix filter
CREATE INDEX idx_images_phash_prefix ON images(phash_prefix);

-- so sánh re-up image
CREATE UNIQUE INDEX uniq_images_md5_hex ON images(md5_hex)
```
sample data
```
| id | s3_key                 | md5_hex                          | status |
| -- | ---------------------- | -------------------------------- | ------ |
| 42 | uploads/ab/cd/uuid.jpg | 9e107d9d372bb6826bd81d3542a419d6 | safe   |
```

status enum
```
pending
safe
review
blocked
```

Lookup
```sql
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

API request presigned url:
```
POST /images/presign
```

Client Upload Flow
```
compute md5
   │
   ▼
POST /images/presign
   │
   ▼
PUT file → S3
   │
   ▼
POST /images/:id/uploaded
   │
   ▼
Sidekiq moderation
```
```ruby
class ImagesController < ApplicationController

  S3_BUCKET    = ENV["S3_BUCKET"]
  S3_CLIENT    = Aws::S3::Client.new
  S3_PRESIGNER = Aws::S3::Presigner.new

  # -----------------------------
  # STEP 1
  # Request presigned upload URL
  # -----------------------------
  def presign
    client_md5 = params[:md5_base64]
    file_size  = params[:byte_size]

    hex_md5 = base64_to_hex_md5(client_md5)

    # 1️⃣ Instant upload check
    existing = Image
      .where(md5_hex: hex_md5, status: ['safe', 'review'])
      .first

    if existing
      return render json: {
        id: existing.id,
        url: existing.s3_url,
        status: 'instant_upload'
      }
    end

    key = generate_s3_key

    begin
      image = Image.create!(
        s3_key: key,
        md5_hex: hex_md5,
        status: 'pending',
        byte_size: file_size
      )
    rescue ActiveRecord::RecordNotUnique
      existing = Image.find_by(md5_hex: hex_md5)

      return render json: {
        id: existing.id,
        url: existing.s3_url,
        status: 'instant_upload'
      }
    end

    url = S3_PRESIGNER.presigned_url(
      :put_object,
      bucket: S3_BUCKET,
      key: key,
      content_md5: client_md5,
      expires_in: 600
    )

    render json: {
      id: image.id,
      url: url,
      method: 'PUT',
      headers: { 'Content-MD5': client_md5 }
    }
  end


  # -----------------------------
  # STEP 2
  # Client confirm upload finished
  # -----------------------------
  def uploaded
    image = Image.find(params[:id])

    # 1️⃣ Verify object tồn tại trên S3
    begin
      S3_CLIENT.head_object(
        bucket: S3_BUCKET,
        key: image.s3_key
      )
    rescue Aws::S3::Errors::NotFound
      return render json: { error: "file_not_found_on_s3" }, status: 400
    end

    image.update!(status: 'processing')

    ModerateImageJob.perform_async(image.id)

    render json: {
      status: 'processing',
      message: 'moderation_started'
    }
  end


  private

  # Convert Base64 MD5 → Hex MD5
  def base64_to_hex_md5(base64)
    Base64.decode64(base64).unpack1('H*')
  end


  # Generate S3 key với prefix shard
  def generate_s3_key
    uuid = SecureRandom.uuid

    "uploads/#{uuid[0..1]}/#{uuid[2..3]}/#{uuid}.jpg"
  end

end
```
```ruby
class Image < ApplicationRecord

  enum status: {
    pending: 0,
    processing: 1,
    safe: 2,
    review: 3,
    blocked: 4
  }

  def s3_url
    "https://#{ENV['S3_BUCKET']}.s3.amazonaws.com/#{s3_key}"
  end

end
```
```ruby
# app/jobs/moderate_image_job.rb
require "digest"

class ModerateImageJob
  include Sidekiq::Worker

  def perform(image_id)
    image = Image.find(image_id)
    url = s3_url(image.image_path)
    data = download_image(url)
    md5 = Digest::MD5.hexdigest(data)

    if Image.exists?(md5_hash: md5, status: "blocked")
      image.update!(status: "blocked", md5_hash: md5)
      return
    end

    result = ModerationClient.check(url)
    image.update!(
      status: result["status"],
      md5_hash: md5,
      phash: result["phash"],
      phash_prefix: result["phash_prefix"],
      nsfw_score: result["nsfw_score"]
    )

  end

  private

  def download_image(url)
    URI.open(url).read
  end

  def s3_url(path)
    # vd: path = user_85798/u/profile_photo/vSsVLp1YalJ.jpeg
    "http://abcxyz.s3.amazonaws.com/#{path}"
  end
end
```

Moderation Client (Rails → Python)
```ruby
# app/services/moderation_client.rb
class ModerationClient
  def self.check(image_url)
    response = Faraday.post(
      "http://moderation-service/check",
      { image_url: image_url }.to_json,
      "Content-Type" => "application/json"
    )
    JSON.parse(response.body)
  end
end
```

Python Moderation Service

Framework đơn giản: FastAPI

Install:
```
pip install fastapi uvicorn pillow imagehash
```

API Server
```python
# app.py
from fastapi import FastAPI
from pydantic import BaseModel

from moderation import moderate_image

app = FastAPI()

class Request(BaseModel):
    image_url: str

@app.post("/check")
def check(req: Request):

    result = moderate_image(req.image_url)

    return result
```

Image Pipeline
```python
# moderation.py
import requests

from PIL import Image
import imagehash
from io import BytesIO

from decision import decide
from nsfw_model import predict
from phash_db import find_duplicate

def moderate_image(image_url):
  img = download_image(image_url)
  phash = compute_phash(img)
  match = find_duplicate(phash)
  nsfw_score = 0

  if not match:
      nsfw_score = predict(img)

  status = decide(match, nsfw_score)

  return {
      "status": status,
      "phash": int(str(phash), 16),
      "phash_prefix": int(str(phash)[:4], 16),
      "nsfw_score": nsfw_score
  }
```
pHash Compute
```python
def compute_phash(img):
  img = img.convert("RGB")
  img = img.resize((256,256))
  ph = imagehash.phash(img)
  return ph
```

Decision Engine
```python
# decision.py
def decide(phash_match, nsfw_score):
  if phash_match:
      return "blocked"

  if nsfw_score > 0.9:
      return "blocked"

  if nsfw_score > 0.5:
      return "review"

  return "safe"
```

Duplicate Detection (simplified)

Trong v1 ta có thể gọi Rails API để check phash.

Pseudo:
```ruby
def find_duplicate(phash):

    # call rails
    # /phash_lookup

    return False
```
Sau này mới tối ưu:
```
Postgres + bit_count XOR
```

NSFW Model

V1 có thể dùng luôn: nsfw_detector hoặc open_nsfw

```python
def predict(img):
  # fake result
  return 0.2
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

v1.2
robust perceptual hashing

v2.0
vector similarity search
```
End of document.

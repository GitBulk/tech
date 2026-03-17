# Image Moderation System – Design v1.0

## Roadmap
```
v1.0 - Postgres + pHash + AI moderation
v1.1 - pHash prefix sharding
v1.2 - multi-prefix search
v1.3 - LSH index
v1.4 - ban propagation
v1.5 - abuse report graph
v2.0 - vector similarity search
```

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

## 12. pHash Prefix
pHash = 64 bits. Ví dụ:
```
phash = 0x9f1234abcd998877
```
Binary:
```
100111110001001000110100...
```

Tạ chọn 16 bit đầu là prefix, prefix = 16 bits đầu:
```
1001111100010010
```
→ convert sang decimal: 40722
```ruby
def phash_prefix(phash)
  phash >> 48
end
```
Vì:
```
64 bits
shift 48
= giữ lại 16 bits
```

Python service trả: phash_hex

```ruby
class ModerateImageJob
  include Sidekiq::Worker

  def perform(image_id)

    image = Image.find(image_id)

    result = ModerationClient.check(image.s3_url)

    phash_int = result["phash_hex"].to_i(16)

    image.update!(
      phash: phash_int,
      phash_prefix: phash_int >> 48,
      nsfw_score: result["nsfw_score"],
      status: result["status"]
    )

  end
end
```

Tiến hành Near-duplicate search

Giả sử ảnh mới có: phash = 1234567890123
```sql
SELECT *
FROM images
WHERE phash_prefix = ?
AND bit_count(phash # ?) <= 5
```

```ruby
def find_near_duplicates(phash)
  prefix = phash >> 48
  Image.where(phash_prefix: prefix).where("bit_count(phash # ?) <= 5", phash)
end
```

Lợi ích cực lớn

Nếu bạn có: 100M images
-> full scan 100M comparisons

Với prefix shard:
```
100M / 65536
≈ 1500 comparisons
```
nhanh hơn ~60,000 lần.

Query flow
```
new image
    │
compute phash
    │
prefix = phash >> 48
    │
DB filter prefix
    │
Hamming distance check
```

## 13. multi-prefix search (v1.2)
Nếu hai tấm ảnh cực kỳ giống nhau nhưng chỉ khác nhau đúng 1 bit ở vị trí thứ 16 (làm đổi prefix), chúng sẽ rơi vào 2 bucket khác nhau và hàm find_near_duplicates sẽ bỏ sót chúng.

Ta đang dùng:
```
phash_prefix = phash >> 48
```
tức là 16 bit đầu của phash làm prefix

Ví dụ 2 ảnh gần giống:
```
phash A
10101010 11110000 01010101 ...

phash B
10101011 11110000 01010101 ...
```
Ta cho phép:

Hamming distance ≤ 5

Nhưng:
```
prefix A = 10101010 11110000
prefix B = 10101011 11110000
```
→ prefix khác nhau

Khi Query:
```sql
WHERE phash_prefix = $prefix
```
→ miss duplicate.

Đây là false negative rất phổ biến.

Ý tưởng của Multi-Prefix Search

Thay vì search 1 prefix, ta search nhiều prefix gần nhau.

Tức là:
```
prefix
prefix XOR mask1
prefix XOR mask2
prefix XOR mask3
...
```
Vì Hamming distance ≤ 5 nghĩa là:

có tối đa 5 bit khác nhau

Những bit khác nhau có thể nằm trong prefix 16 bit.

Ví dụ cụ thể

Prefix của ảnh mới: 10101010 11110000
Decimal: 43760

Giả sử ta flip 1 bit:
```
mask1 = 00000000 00000001
mask2 = 00000000 00000010
mask3 = 00000000 00000100
...
```

Các prefix cần search:
```
prefix
prefix XOR mask1
prefix XOR mask2
prefix XOR mask3
...
```
Ví dụ:
```
43760
43761
43762
43764
...
```

Đới với Postgres 9.5 thì cần tạo Function trước
```ruby

class AddPopcount64Function < ActiveRecord::Migration
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION popcount64(i bigint)
      RETURNS integer AS $$
        -- LANGUAGE sql giúp Postgres inline function vào hàm chính để tăng tốc độ.
        -- Dùng CASE để xử lý trường hợp i là NULL nếu cần,
        -- nhưng với IMMUTABLE và logic này thì SELECT là đủ.
        SELECT length(replace((i::bit(64))::text, '0', ''))::integer;
      $$ LANGUAGE sql IMMUTABLE STRICT;
    SQL
  end

  def down
    execute <<~SQL
      DROP FUNCTION IF EXISTS popcount64(bigint);
    SQL
  end
end
```

LANGUAGE SQL vs LANGUAGE PL/pgSQL

|Đặc điểm   |LANGUAGE SQL                         |LANGUAGE PL/pgSQL                           |
|-----------|-------------------------------------|--------------------------------------------|
|Cấu trúc   |Chỉ gồm các câu lệnh SQL             |Có DECLARE, BEGIN...END, IF, LOOP           |
|Tốc độ     |Nhanh hơn cho các phép toán nhỏ      |Chậm hơn một chút do chi phí vận hành       |
|Tối ưu hóa |Có thể Inlining (như copy-paste code)|Không thể Inlining                          |
|Phù hợp với|Chuyển đổi dữ liệu, toán học đơn giản|Logic nghiệp vụ, kiểm tra điều kiện phức tạp|

```ruby
class Image < ApplicationRecord
  # PREFIX_MASKS = [
  #   0,
  #   1 << 0,
  #   1 << 1,
  #   1 << 2,
  #   1 << 3,
  #   1 << 4,
  #   1 << 5,
  #   1 << 6
  # ].freeze

  # ta tối ưu hơn bằng cách tính trước kết quả, thay vì dịch bit lúc runtime
  PREFIX_MASKS = [
    0,
    1,
    2,
    4,
    8,
    16,
    32,
    64
  ].freeze

  HAMMING_THRESHOLD = 5

  def self.find_near_duplicates_robust(phash)
    prefix = phash >> 48
    prefixes = PREFIX_MASKS.map { |m| prefix ^ m }

    where(phash_prefix: prefixes)
      .where("popcount64(phash # ?) <= ?", phash, HAMMING_THRESHOLD)
      .order("popcount64(phash # #{phash}) ASC")
      .limit(100)
  end

  def s3_url
    "https://#{ENV['S3_BUCKET']}.s3.amazonaws.com/#{s3_key}"
  end
end
```

```sql
WHERE phash_prefix IN (...)
AND popcount64(phash, target) <= 5
```

Trade-off:
```
| prefix count | recall  | cost      |
| ------------ | ------- | --------- |
| 1            | thấp    | rất nhanh |
| 4            | khá     | nhanh     |
| 8            | tốt     | vẫn nhanh |
| 16           | rất tốt | hơi nặng  |
```
Production thường dùng: 8 – 16 prefixes

Ví dụ thực tế

Giả sử hệ thống có: 100M images

Prefix shard:
```
100M / 65536
≈ 1500 images per shard
```

Multi-prefix: search 8 shards → 1500 * 8 = 12k rows

So với full scan: 100M rows → nhanh hơn ~8000 lần.

## 14. LSH (optional)
Giải pháp này khá over engineering, sẽ không được viết doc lại, chỉ note lại để khi cần sẽ research lại.

## 15. Future Improvements

Có thể mở rộng sau:
```
vector embedding
cropped image detection
```

End of document.

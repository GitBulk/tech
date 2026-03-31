# 🚀 Roadmap: Hệ Thống Gợi Ý Sản Phẩm Nova AI
**Sự kết hợp giữa RDBMS truyền thống và Hệ sinh thái Vector AI**

Tài liệu này trình bày lộ trình nâng cấp tính năng "Sản phẩm liên quan", phân tách vai trò giữa Web App (Ruby on Rails) và AI Service Hub (Nova AI) nhằm tối ưu hiệu năng và chi phí.

---

## 🏗️ Kiến Trúc Tổng Quan
* **Web App (Rails):** Đóng vai trò Điều phối (Orchestrator), hiển thị UI và quản lý Transaction.
* **Nova AI (FastAPI):** Đóng vai trò Bộ não (Brain), xử lý tính toán nặng, Vector Search và Machine Learning.
* **Giao tiếp:** Gọi qua REST API (Gem `Faraday` hoặc `HTTParty`).

---

## Giai đoạn 1: Lớp Nền Tảng (RDBMS-Driven)
*Mục tiêu: Tận dụng dữ liệu cấu trúc sẵn có trong Postgres 9.5 để có kết quả ngay.*

### 1.1. Gợi ý theo thuộc tính (Metadata Filtering)
- **Cơ chế:** Dùng SQL để tìm sản phẩm cùng Category, Brand, hoặc Tags trong cùng phân khúc giá.
- **Công nghệ:** - **Rails:** Xử lý logic lọc qua `ActiveRecord Scopes`.
    - **Postgres:** Indexing `category_id`, `brand_id` để đảm bảo tốc độ truy vấn < 50ms.
- **Ưu điểm:** Chi phí $0, độ trễ cực thấp.

Sample products:

|id |name (Tên sản phẩm)           |price (Giá - VNĐ)|category_id|brand_id  |is_active|
|---|------------------------------|-----------------|-----------|----------|---------|
|1  |Giày chạy bộ Nike Air Zoom    |2,000,000        |10 (Giày)  |1 (Nike)  |true     |
|2  |Giày chạy bộ Nike React       |1,800,000        |10 (Giày)  |1 (Nike)  |true     |
|3  |Giày sneaker Adidas Ultraboost|2,200,000        |10 (Giày)  |2 (Adidas)|true     |
|4  |Giày đá bóng Puma Future      |1,200,000        |10 (Giày)  |3 (Puma)  |true     |
|5  |Áo thun thể thao Nike Dri-FIT |500,000          |20 (Áo)    |1 (Nike)  |true     |
|6  |Giày tập gym Reebok Nano      |1,900,000        |10 (Giày)  |4 (Reebok)|true     |

Table:
```sql
-- 1. Tạo bảng products
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    price DECIMAL(15, 2) DEFAULT 0.0,
    category_id INTEGER,
    brand_id INTEGER,
    is_active BOOLEAN DEFAULT true,
    image_url VARCHAR(500),
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL
);

-- 2. Index cho việc lọc Metadata (Giai đoạn 1.1)
-- Giúp tìm nhanh sản phẩm cùng Category và đang Active
CREATE INDEX index_products_on_category_id_and_is_active
ON products (category_id, is_active);

-- 3. Index cho việc lọc theo khoảng giá
-- Kết hợp với category_id để tối ưu các câu query "Related by Price"
CREATE INDEX index_products_on_price_and_category_id
ON products (price, category_id);

-- 4. Index hỗ trợ tìm kiếm theo tên (Trường hợp không dùng ES)
-- Sử dụng gin index với trgm (trigram) nếu bạn muốn search LIKE '%abc%' nhanh hơn
-- Lưu ý: Cần chạy lệnh 'CREATE EXTENSION IF NOT EXISTS pg_trgm;' trước
-- CREATE INDEX index_products_on_name_trgm ON products USING gin (name gin_trgm_ops);

-- 5. Index cho thời gian (Để Rake Task lấy hàng mới về hoặc hàng vừa cập nhật)
-- CREATE INDEX index_products_on_updated_at ON products (updated_at DESC);
```

Ruby code:
```ruby
class Product < ActiveRecord::Base
  # 1. Tìm cùng danh mục
  scope :same_category, ->(category_id) { where(category_id: category_id) }

  # 2. Tìm khoảng giá tương đồng (ví dụ: dao động +/- 20%)
  scope :similar_price, ->(current_price) {
    min_price = current_price * 0.8
    max_price = current_price * 1.2
    where(price: min_price..max_price)
  }

  # 3. Loại trừ chính sản phẩm đang xem
  scope :exclude_current, ->(current_id) { where.not(id: current_id) }

  scope :active, -> { where(is_active: true) } # Chỉ lấy SP đang bán

  def related_metadata_products(limit = 5)
    # Tạo Cache Key duy nhất cho sản phẩm này.
    # Có kèm "v1" để sau này đổi logic bạn chỉ cần đổi thành "v2" là cache tự reset.
    cache_key = "products/#{self.id}/related_metadata_v1"

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      Product.active.same_category(self.category_id)
             .similar_price(self.price)
             .exclude_current(self.id)
             .limit(limit)
             .to_a # Dùng .to_a để force ActiveRecord thực thi query và cache lại mảng Object
    end
  end
end

# app/controllers/products_controller.rb
class ProductsController < ApplicationController
  def show
    # Lấy sản phẩm hiện tại
    @product = Product.find(params[:id])

    # Gọi hàm lấy danh sách gợi ý (Mặc định lấy 4 sản phẩm)
    @related_products = @product.related_metadata_products(4)

    # ... các logic khác ...
  end
end
```

### 1.1.1 Dùng Elasticsearch để lưu trữ Products
Nếu Postgres chỉ biết lọc "cứng" (Đúng danh mục, Đúng khoảng giá), thì ES sử dụng thuật toán (BM25) để đếm tần suất từ khóa -> dùng filter more_like_this để tìm các sản phẩm có chữ trong name và description giống với sản phẩm hiện tại nhất.

Ruby + ES 2.4.6
```ruby
# app/models/concerns/product_indexable.rb
# frozen_string_literal: true

module ProductIndexable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model

    # Định nghĩa tên index (nên có prefix để tránh trùng lặp)
    index_name "jsh_products_#{Rails.env}"

    # Thiết lập Settings: Analyzer để xử lý tiếng Việt và xóa HTML
    settings index: {
      number_of_shards: 1,
      number_of_replicas: 0,
      analysis: {
        analyzer: {
          product_analyzer: {
            type: 'custom',
            tokenizer: 'standard',
            # Khi dùng more_like_this filter, ES sẽ lấy nội dung của sản phẩm A để đi tìm sản phẩm B. Nếu mô tả có nhiều mã HTML, ES 2.4 có thể hiểu lầm là các sản phẩm "giống nhau" vì chúng đều có nhiều thẻ <div>. Bộ lọc này sẽ xóa hết HTML trước khi "học" từ vựng.
            char_filter: ['html_strip'], # Quan trọng: Loại bỏ <p>, <br>... trước khi index

            # Giúp khớp các từ có dấu và không dấu (ví dụ: "giày" và "giay"). Điều này làm tăng cơ hội tìm thấy sản phẩm liên quan trong môi trường tiếng Việt.
            filter: ['lowercase', 'asciifolding'] # Chuyển về chữ thường, bỏ dấu cơ bản
          }
        }
      }
    } do
      # Định nghĩa Mappings cho ES 2.4.x
      mappings dynamic: 'false' do
        indexes :id,           type: 'integer'
        # Trường name và description dùng analyzer để MLT so sánh nội dung
        indexes :name,         type: 'string', analyzer: 'product_analyzer'
        indexes :description,  type: 'string', analyzer: 'product_analyzer'

        # Các trường dùng để Filter (không cần phân tích từ ngữ - not_analyzed)
        indexes :category_id,  type: 'integer'
        indexes :brand_id,     type: 'integer'
        indexes :price,        type: 'double'
        indexes :is_active,    type: 'boolean'
        indexes :created_at,   type: 'date'
      end
    end

    # Hàm định nghĩa dữ liệu sẽ đẩy lên ES
    def as_indexed_json(_options = {})
      {
        id: id,
        name: name,
        description: description,
        category_id: category_id,
        brand_id: brand_id,
        price: price.to_f,
        is_active: is_active,
        created_at: created_at
      }
    end
  end

  # Các method hỗ trợ quản lý index (Class methods)
  module ClassMethods
    def reindex!
      __elasticsearch__.create_index!(force: true)
      __elasticsearch__.refresh_index!
      import # Đẩy toàn bộ data hiện tại vào ES
    end
  end
end

# app/models/product.rb
class Product < ActiveRecord::Base
  include ProductIndexable

  # Các logic khác của bạn...
  # Usage: Product.reindex!

  # Giả định bạn đang dùng gem elasticsearch-model
  def related_es_products(limit = 4)
    cache_key = "products/#{self.id}/related_es_v1"

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      min_price = self.price * 0.8
      max_price = self.price * 1.2

      es_query = {
        query: {
          bool: {
            must: [
              {
                more_like_this: {
                  fields: ["name", "description"],
                  # ĐIỂM KHÁC BIỆT CỦA ES 2.4: Bắt buộc phải khai báo _type
                  like: [
                    {
                      _index: self.class.index_name,
                      _type: self.class.document_type, # Bắt buộc có ở bản 2.4
                      _id: self.id.to_s
                    }
                  ],
                  min_term_freq: 1,
                  min_doc_freq: 1
                }
              }
            ],
            filter: [
              { term: { category_id: self.category_id } },
              { range: { price: { gte: min_price, lte: max_price } } },
              { term: { is_active: true } }
            ],
            must_not: [
              { term: { _id: self.id.to_s } } # Ở bản 2.4, nên filter loại trừ theo _id chuẩn của ES
            ]
          }
        },
        size: limit
      }

      # Thực thi query và lấy mảng objects trả về
      self.class.search(es_query).records.to_a
    end
  end
end

# lib/tasks/elasticsearch.rake
# frozen_string_literal: true
namespace :es do
  desc "Reindex toàn bộ sản phẩm vào Elasticsearch"
  task reindex_products: :environment do
    puts "[#{Time.now}] Bắt đầu khởi tạo lại Index cho Product..."

    # Xóa index cũ và tạo mới với Mapping đã định nghĩa trong ProductIndexable
    Product.__elasticsearch__.create_index!(force: true)

    # Sử dụng find_in_batches để tránh ngốn RAM khi dữ liệu lớn
    batch_size = 500
    count = 0

    Product.find_in_batches(batch_size: batch_size) do |batch|
      # Import mảng sản phẩm vào ES
      Product.__elasticsearch__.client.bulk(
        index: Product.index_name,
        type:  Product.document_type,
        body:  batch.map { |p| { index: { _id: p.id, data: p.as_indexed_json } } }
      )
      count += batch.size
      puts "--- Đã sync: #{count} sản phẩm..."
    end

    Product.__elasticsearch__.refresh_index!
    puts "[#{Time.now}] Hoàn tất! Đã đồng bộ tổng cộng #{count} sản phẩm."
  end

  desc "Đồng bộ các sản phẩm mới cập nhật trong 24h qua"
  task sync_recent_products: :environment do
    puts "[#{Time.now}] Đang kiểm tra các sản phẩm thay đổi trong 24h qua..."

    recent_products = Product.where("updated_at >= ?", 24.hours.ago)

    if recent_products.any?
      recent_products.find_in_batches(batch_size: 100) do |batch|
        Product.__elasticsearch__.client.bulk(
          index: Product.index_name,
          type:  Product.document_type,
          body:  batch.map { |p| { index: { _id: p.id, data: p.as_indexed_json } } }
        )
      end
      puts "--- Đã cập nhật #{recent_products.count} sản phẩm."
    else
      puts "--- Không có sản phẩm nào thay đổi."
    end
  end
end
```

Dump data
```ruby
def dump_data
  puts "Bắt đầu tạo 10,000 sản phẩm với tên thực tế..."

  # Bộ từ điển mẫu
  adjectives = ["Cao cấp", "Chính hãng", "Thoáng khí", "Siêu nhẹ", "Bền bỉ", "Thời trang", "Chống nước"]
  categories_names = {1 => "Giày", 2 => "Áo", 3 => "Quần", 4 => "Phụ kiện", 5 => "Dụng cụ"}
  brands_names = {1 => "Nike", 2 => "Adidas", 3 => "Puma", 4 => "Reebok", 5 => "Mizuno"}

  products_data = []

  10_000.times do |i|
    cat_id = (1..5).to_a.sample
    brand_id = (1..5).to_a.sample

    # Tạo tên kiểu: "Giày Nike Cao cấp Chính hãng"
    name = "#{categories_names[cat_id]} #{brands_names[brand_id]} #{adjectives.sample} #{adjectives.sample} - #{i}"

    products_data << {
      name: name,
      description: "Mô tả cho #{name}. Sản phẩm phù hợp cho tập luyện cường độ cao, chất liệu vải mềm mại.",
      price: rand(200_000..3_000_000),
      category_id: cat_id,
      brand_id: brand_id,
      is_active: true,
      created_at: Time.now,
      updated_at: Time.now
    }

    if products_data.size >= 1000
      Product.insert_all(products_data)
      products_data = []
      print "."
    end
  end
end
```

Benchmark
```ruby
require 'benchmark'

# 1. Lấy một sản phẩm thực tế làm mẫu
# Ưu tiên lấy sản phẩm có đầy đủ category và giá để logic không bị sai
product = Product.active.where.not(category_id: nil).where("price > 0").order("RANDOM()").first

unless product
  puts "Lỗi: Không tìm thấy sản phẩm nào thỏa mãn điều kiện để benchmark!"
  return
end

limit = 4
iterations = 10 # Chạy mỗi hàm 10 lần để lấy kết quả trung bình

puts "=========================================================="
puts "BENCHMARKING PRODUCT ID: #{product.id} (#{product.name})"
puts "Cấu hình: ES 2.4.6 | Postgres 9.5 | Iterations: #{iterations}"
puts "=========================================================="

Benchmark.bm(30) do |x|
  # --- TEST POSTGRES (Giai đoạn 1.1) ---
  # Chúng ta gọi trực tiếp logic query, bỏ qua cache để đo nội lực DB
  x.report("Postgres (Metadata SQL):") do
    iterations.times do
      # Gọi các scope đã viết để đo tốc độ DB thực tế
      Product.active
             .same_category(product.category_id)
             .similar_price(product.price)
             .exclude_current(product.id)
             .limit(limit)
             .to_a
    end
  end

  # --- TEST ELASTICSEARCH (More Like This) ---
  x.report("Elasticsearch (MLT):") do
    iterations.times do
      # Gọi hàm ES bạn đã viết (giả định chưa có cache)
      # Lưu ý: Nếu hàm related_es_products của bạn có bọc Rails.cache,
      # hãy tạm thời comment nó hoặc xóa cache trước khi chạy.
      product.related_es_products(limit)
    end
  end

  # --- TEST REDIS (The Speed of Light) ---
  # Đảm bảo dữ liệu đã vào cache trước khi đo
  product.related_metadata_products(limit)

  x.report("Redis Cache (Hit):") do
    iterations.times do
      product.related_metadata_products(limit)
    end
  end
end
```

### 1.1.2 Alias trong ES
Trong ES, các thông số phần cứng cốt lõi như number_of_shards (số lượng phân mảnh) và analyzer (bộ phân tích ngôn ngữ) mang tính Bất biến (Immutable). Nghĩa là một khi Index đã được tạo ra, ta KHÔNG THỂ thay đổi số Shards của nó.

Với 20k sản phẩm: 1 Shard là hoàn hảo để tối ưu tốc độ và độ chính xác.
```
number_of_shards: 1,
number_of_replicas: 0
```

Nếu lên 1 triệu sản phẩm: 1 Shard sẽ trở thành nút thắt cổ chai (bottleneck) gây chậm hệ thống, bắt buộc phải tăng lên 3 hoặc 5 Shards.

**Giải pháp: Sử dụng Alias (Bí danh)**

Thay vì để code Rails kết nối trực tiếp vào tên thật của Index (ví dụ: nova_products_v1), chúng ta tạo một Alias tên là nova_products và trỏ nó vào Index thật. Code Rails chỉ giao tiếp với Alias này.

**Lợi ích sống còn của Alias đối với hệ thống của chúng ta:**

Nâng cấp hạ tầng Zero-Downtime (Không gián đoạn):
Khi cần tăng từ 1 Shard lên 5 Shards, chúng ta không cần sửa code Rails hay khởi động lại Web Server. Tiến trình diễn ra hoàn toàn ngầm bên dưới:
- Tạo Index mới nova_products_v2 (với 5 Shards).
- Copy dữ liệu từ v1 sang v2 (Reindex).
- Đảo hướng Alias từ v1 sang v2 trong nháy mắt (Atomic switch). User không hề hay biết sự thay đổi này.

**Decoupling (Tách biệt Code và Hạ tầng):**

Code của app (ProductIndexable) chỉ cần biết một cái tên duy nhất là nova_products. Việc hôm nay ES dùng bản v1, ngày mai dùng v5 hay v10 là chuyện của DevOps/Data Engineer, Developer không cần bận tâm.

An toàn tuyệt đối (Instant Rollback):
Giả sử chúng ta nâng cấp lên v2 nhưng phát hiện ra cấu hình analyzer bị lỗi khiến khách hàng không tìm thấy sản phẩm. Nếu không có Alias, chúng ta sẽ phải copy lại dữ liệu từ đầu rất lâu. Với Alias, ta chỉ cần 1 câu lệnh để trỏ ngược Alias về lại v1 ngay lập tức. Hệ thống được cứu sống trong vòng 1 giây.

Kết luận: Nên dùng Alias để xây dựng một Search Engine có khả năng mở rộng và chịu lỗi cao.

```ruby
module ProductIndexable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model

    # Định nghĩa tên index (có thể thêm env)
    # LUÔN TRỎ VÀO ALIAS
    index_name 'nova_products'
    ...
```

### 1.2. Thống kê hành vi (Co-occurrence Logic)
- **Cơ chế:** Thuật toán "Người mua A cũng mua B".
- **Giải pháp:** Chạy **Rake Task** hàng đêm để thống kê tần suất các cặp sản phẩm xuất hiện cùng nhau trong bảng `LineItems`. Lưu kết quả vào bảng trung gian `related_products_cache`.
- **Ưu điểm:** Không làm chậm DB chính khi khách hàng đang mua sắm.

## Giai đoạn 2: Tích Hợp AI (Vector-Based Search)
*Mục tiêu: Dùng Nova AI để xử lý dữ liệu phi cấu trúc (Ảnh/Mô tả) mà SQL không làm được.*

### 2.1. Tương đồng Ngữ nghĩa (Semantic Analysis)
- **Cơ chế:** Hiểu mô tả sản phẩm thông qua ngôn ngữ tự nhiên thay vì chỉ khớp từ khóa.
- **Công nghệ (Nova AI):**
    - **Model:** `paraphrase-multilingual-MiniLM-L12-v2` (Open Source - hỗ trợ tiếng Việt cực tốt).
    - **Vector DB:** **Qdrant** (Open Source - chạy Docker). Lưu trữ Vector để tìm kiếm lân cận (k-NN).
- **Ưu điểm:** Gợi ý được "Giày đá bóng" khi khách xem "Áo thi đấu" dù từ khóa không trùng nhau.

### 2.2. Tương đồng Thị giác (Visual Similarity)
- **Cơ chế:** Tìm sản phẩm có kiểu dáng, màu sắc tương đồng (Giải quyết bài toán sản phẩm mới chưa có lượt mua - Cold Start).
- **Công nghệ (Nova AI):**
    - **Model:** `CLIP` (Open Source từ OpenAI). Trích xuất Feature Vectors từ ảnh sản phẩm.

---

## Giai đoạn 3: Tối Ưu & Cá Nhân Hóa (Hybrid Layer)
*Mục tiêu: Tăng tỷ lệ chuyển đổi (CR) bằng cách xếp hạng lại kết quả.*

### 3.1. Hệ thống lai (Hybrid Scoring)
- **Cơ chế:** Kết hợp điểm số từ SQL (Hành vi đám đông) và Nova AI (Đặc tính sản phẩm).
- **Công nghệ:** Nova AI thực hiện tính toán trọng số:
  $$Score = (0.4 \times Visual) + (0.4 \times Semantic) + (0.2 \times Popularity)$$

### 3.2. Mô hình xếp hạng lại (Neural Re-ranking)
- **Cơ chế:** Dự đoán khả năng người dùng cụ thể sẽ click vào sản phẩm nào dựa trên lịch sử duyệt web (Clickstream).
- **Công nghệ:** Sử dụng thư viện **Implicit** hoặc **Surprise** (Open Source Python) để huấn luyện mô hình Collaborative Filtering.

---

## 💰 Bảng So Sánh Giải Pháp

| Thành phần | Giải pháp Open Source (Đề xuất) | Giải pháp Trả phí (SaaS) | Ghi chú |
| :--- | :--- | :--- | :--- |
| **AI Engine** | **FastAPI + PyTorch** | AWS SageMaker | Tự làm chủ công nghệ |
| **Vector DB** | **Qdrant (Self-hosted)** | Pinecone | Tiết kiệm phí hàng tháng |
| **Models** | **HuggingFace (Free)** | OpenAI API | Không tốn phí theo request |
| **Logic** | **Implicit / Scikit-learn** | Amazon Personalize | Tùy biến sâu theo ý muốn |

---

## ⚠️ Lưu Ý Triển Khai
1. **Caching:** Rails nên cache kết quả từ Nova AI vào **Redis** trong 24h để tránh gọi API liên tục.
2. **Fallback:** Nếu Nova AI không phản hồi (Timeout), Rails tự động chuyển sang hiển thị kết quả từ Giai đoạn 1 (SQL).
3. **Data Sync:** Sử dụng CSV Export/Import định kỳ để Nova AI cập nhật dữ liệu mà không cần kết nối trực tiếp vào DB của Rails.

---
*Ghi chú: Web Rails đóng vai trò là Orchestrator (Điều phối), Nova AI đóng vai trò là Brain (Trí tuệ).*
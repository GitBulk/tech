# 📚 Cấu trúc Database E-commerce: Mô hình Sản phẩm-Biến thể và Thuộc tính

Thiết kế này nhằm mục tiêu **Khả năng Mở rộng** (Scale) từ Sách sang Quần áo và các sản phẩm đa thuộc tính khác.
## 1. 🔑 Nguyên tắc Cốt lõi: Sản phẩm - Biến thể - Thuộc tính

Hệ thống được xây dựng dựa trên mối quan hệ phức tạp để đảm bảo mọi SKU (đơn vị tồn kho) đều có thể được mô tả chi tiết bằng nhiều thuộc tính khác nhau.

### 1.1. Quan hệ Thực thể (ERD)

| Bảng | Vai trò | Ví dụ |
| :--- | :--- | :--- |
| **`Products`** | Sản phẩm Gốc (Thông tin chung) | "Sách Sapiens", "Áo Thun Nam Basic" |
| **`Variants`** | Biến thể / SKU (Đơn vị có thể mua, có giá, có tồn kho) | ID của Sách Bìa cứng 2025, ID của Áo Trắng Size M |
| **`Attributes`** | Tên Thuộc tính | "Loại hình", "Màu sắc", "Kích thước" |
| **`VariantAttributeValues`** | Bảng liên kết **Nhiều-Nhiều** (Gán Giá trị thuộc tính cụ thể cho Biến thể) | Liên kết (Áo Trắng M) + (Màu sắc) + "**Trắng**" |

---

## 2. 📝 Mô hình Hóa Đơn (Snapshot - Ảnh chụp nhanh)

Để đảm bảo hóa đơn không bị ảnh hưởng khi giá hoặc tên sản phẩm thay đổi, chúng ta sử dụng cơ chế **Snapshot** trong bảng `OrderItems`.

### 2.1. Cấu trúc bảng `Order_Items`

| Tên Cột | Mô tả | Vai trò |
| :--- | :--- | :--- |
| **`variant_id`** | Mã ID biến thể đã mua | Liên kết cần thiết (FK) |
| **`unit_price_snapshot`** | Giá bán **tại thời điểm mua** | Dữ liệu Snapshot (bất biến) |
| **`product_description_snapshot`** | Mô tả chi tiết biến thể **tại thời điểm mua** | Dữ liệu Snapshot (bất biến) |

### 2.2. Code Rails: Mô hình và Phương thức tạo Snapshot

```ruby
# app/models/product.rb
class Product < ApplicationRecord
  has_many :variants
end

# app/models/variant.rb
class Variant < ApplicationRecord
  # Kết nối với các bảng chính
  belongs_to :product
  has_many :order_items
  has_many :variant_attribute_values
  
  # Phương thức tạo chuỗi mô tả biến thể (SÁCH & QUẦN ÁO)
  def full_description
    # Nếu là sách (giả sử có cột edition_year/type đơn giản)
    if product.category_id == 1 # Ví dụ: Category Sách
      return "#{product.name} (#{variant_type}, #{edition_year})"
    
    # Nếu là sản phẩm đa thuộc tính (Quần áo, Điện thoại...)
    else
      # Lấy tất cả thuộc tính/giá trị từ bảng trung gian
      details = variant_attribute_values.map do |vav|
        "#{vav.attribute.name}: #{vav.value}"
      end
      return "#{product.name} (#{details.join(', ')})"
    end
  end
end

# app/models/order.rb
class Order < ApplicationRecord
  has_many :order_items
  belongs_to :user
end

# app/models/order_item.rb
class OrderItem < ApplicationRecord
  # Bảng chi tiết hóa đơn, nơi lưu trữ Snapshot
  belongs_to :order
  belongs_to :variant # Liên kết để tham chiếu ban đầu
end

# app/models/attribute.rb
class Attribute < ApplicationRecord
  has_many :variant_attribute_values
end

# app/models/variant_attribute_value.rb
class VariantAttributeValue < ApplicationRecord
  belongs_to :variant
  belongs_to :attribute
end
```

# 3. 🛍️ Code Rails: Mô phỏng Giao dịch Mua hàng
Mô phỏng User A mua: 1 cuốn Sapiens Bìa cứng 2025 và 1 cuốn Sapiens Bìa mềm 2023.

```ruby
# 1. TÌM VÀ LẤY BIẾN THỂ (Variants)
# Giả sử đã tạo dữ liệu mẫu và các Variant IDs/SKUs đã tồn tại
variant_bc_2025 = Variant.find_by(sku: "SAP-BC-2025") # Sapiens Bìa cứng 2025
variant_bm_2023 = Variant.find_by(sku: "SAP-BM-2023") # Sapiens Bìa mềm 2023
user_a = User.find(1) # User A

# 2. TẠO ĐƠN HÀNG (Order)
order = Order.create!(user: user_a, status: 'pending')

# 3. TẠO CHI TIẾT ĐƠN HÀNG (Order_Items) VỚI SNAPSHOT

# --- Item 1: Bìa cứng 2025 ---
order.order_items.create!(
  variant: variant_bc_2025,
  quantity: 1,

  # LƯU SNAPSHOT MÔ TẢ
  product_description_snapshot: variant_bc_2025.full_description,
  
  # LƯU SNAPSHOT GIÁ
  unit_price_snapshot: variant_bc_2025.price
)

# -> product_description_snapshot: "Sapiens: Lược sử loài người (Bìa cứng, 2025)"

# --- Item 2: Bìa mềm 2023 ---
order.order_items.create!(
  variant: variant_bm_2023,
  quantity: 1,
  
  # LƯU SNAPSHOT MÔ TẢ
  product_description_snapshot: variant_bm_2023.full_description,
  
  # LƯU SNAPSHOT GIÁ
  unit_price_snapshot: variant_bm_2023.price 
)

# -> product_description_snapshot: "Sapiens: Lược sử loài người (Bìa mềm, 2023)"
```

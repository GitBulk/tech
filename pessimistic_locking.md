
# Pessimistic Locking (Khóa Chủ Động) trong Rails 4 + PostgreSQL  
### Kèm ví dụ thực tế: Rút quỹ (withdraw) chống race-condition

---

## 1. Khái niệm: Pessimistic Locking là gì?

**Pessimistic Locking** (Khóa chủ động) là kỹ thuật khóa **độc quyền (exclusive lock)** ngay khi đọc dữ liệu, đảm bảo:

- Chỉ **một** tiến trình (request) có quyền chỉnh sửa bản ghi tại một thời điểm.  
- Các tiến trình khác **bị block** — phải đợi cho đến khi tiến trình đang giữ khóa hoàn tất (commit hoặc rollback).  
- Tránh race-condition, dirty writes và dữ liệu sai lệch khi nhiều request chạy song song.

Trong Rails, nó được thực hiện qua:

```ruby
Model.lock
```

hoặc SQL:

```
SELECT ... FOR UPDATE
```

---

## 2. Khi nào dùng Pessimistic Locking?

Dùng khi:

### **✔️ Có khả năng xảy ra race-condition gây sai dữ liệu**
- Hai admin cùng cập nhật một record quan trọng  
- Hai người cùng click "Buy" một vật phẩm  
- Xử lý tài nguyên hiếm (slot, seat, lượt chơi…)

### **✔️ Cập nhật số dư, điểm, token — MUST USE**
- Trừ tiền  
- Cộng tiền  
- Cộng/trừ credit  
- Điểm thưởng / loyalty  

### **✔️ Khi optimistic locking không đủ**
(optimistic chỉ phù hợp khi xung đột rất hiếm)

### **❌ Không dùng khi:**
- Tải quá cao và không quan trọng sai số nhỏ  
- Hệ thống đọc nhiều, ghi ít → optimistic phù hợp hơn  
- Không cần strict consistency

---

## 3. Lợi ích

- An toàn tuyệt đối khi cập nhật dữ liệu quan trọng  
- Tránh hoàn toàn tình trạng:
  - đọc giá trị cũ  
  - ghi đè sai  
  - biến mất cập nhật (lost update)  
  - xử lý đồng thời dẫn tới âm tiền / double-spend  

---

## 4. Nhược điểm

- Các request phải **đợi nhau**, làm tăng độ trễ nếu traffic cao  
- Nếu code lock xong mà chạy lâu → block càng nặng  
- Cần thiết kế cẩn thận để tránh deadlock  

---

## 5. Kiến trúc hoạt động

1. Request A đọc account → **PostgreSQL khóa row**  
2. Request B đọc account → **bị block**  
3. A commit thay đổi  
4. B tiếp tục, nhưng đọc được dữ liệu mới đã được cập nhật  

→ Cực kỳ quan trọng: **đảm bảo tính tuần tự tuyệt đối trong update**.

---

## 6. Ví dụ chuẩn thực tế:  
# Rút quỹ (withdraw) — chống race-condition

### Bảng:

```ruby
# accounts
id | user_id | balance (integer)
```

Giả sử user có thể withdraw (rút tiền).

Hai request đến cùng lúc:

- A rút 300  
- B rút 600  
- Số dư ban đầu: 800  

Nếu **không có locking**, cả hai sẽ đọc balance = 800 → trừ tiền → dữ liệu sai hoặc âm tiền.

---

## 7. Giải pháp dùng Pessimistic Locking

### Code Rails 4 (hoạt động 100%)

```ruby
def withdraw(user_id, amount)
  Account.transaction do
    # Khóa row ngay khi SELECT
    account = Account.lock.find_by!(user_id: user_id)

    raise "Not enough balance" if account.balance < amount

    account.update!(balance: account.balance - amount)
  end
end
```

### PostgreSQL tự sinh:

```
SELECT "accounts".* FROM "accounts"
WHERE "accounts"."user_id" = ?
FOR UPDATE
```

### So sánh Optimistic Locking:

| Yếu tố                 | Pessimistic Locking               | Optimistic Locking                                |
| ---------------------- | --------------------------------- | ------------------------------------------------- |
| Nguy cơ race-condition | Không có                          | Có → cần retry                                    |
| Số bước code           | 1 transaction                     | transaction + rescue + retry                      |
| Hiệu năng              | Block request khác, nhưng ít → OK | Không block, nhưng nếu xung đột → retry nhiều lần |
| Dễ hiểu / maintain     | Rất dễ                            | Phải handle StaleObjectError                      |
| An toàn số dư          | 100%                              | Nếu không retry đúng → rủi ro                     |


---

## 8. Timeline hoạt động (rất quan trọng để hiểu)

**Balance ban đầu: 800**

### Request A:
- Lock row  
- Read 800  
- Trừ 300 → còn 500  
- Commit → thả khóa  

### Request B:
- Bị block cho đến khi A xong  
- Sau khi A commit → B tiếp tục  
- B đọc lại balance mới: **500**  
- Không đủ 600 → raise lỗi  

→ Không thể nào âm tiền.

---

## 9. Tại sao ví dụ này “đúng kiểu hệ thống thực tế”?

Vì nó tái hiện các bài toán trong:

- Ví điện tử  
- Credit consuming  
- Token spending  
- Payment gateway  
- In-app currency  
- Point system  
- Booking resource (ghế, slot, vé sự kiện)  

Hầu hết startup lớn đều cần case này.

---

## 10. Mở rộng nâng cấp

### ✦ Auto retry khi deadlock:
```ruby
module SidekiqHelper
  def self.with_db_retry(max: 3, sleep_time: 0.1)
    retries = 0
    begin
      yield
    rescue ActiveRecord::Deadlocked => e
      retries += 1
      if retries <= max
        sleep(sleep_time) if sleep_time > 0
        retry
      else
        Rails.logger.error("[DB Deadlock] Retry limit reached: #{e.message}")
        raise e
      end
    end
  end
end

class WithdrawJob
  include Sidekiq::Worker

  def perform(user_id, amount)
    SidekiqHelper.with_db_retry(max: 3, sleep_time: 0.2) do
      Account.transaction do
        account = Account.lock.find_by!(user_id: user_id)
        raise "Not enough balance" if account.balance < amount
        account.update!(balance: account.balance - amount)
      end
    end
  end
end

```

### ✦ Dùng `with_lock`:
```ruby
class WithdrawService
  def initialize(user_id, amount)
    @user_id = user_id
    @amount  = amount
  end

  def call
    with_retry(max: 3) do
      Account.transaction do
        # with_lock = SELECT ... FOR UPDATE
        account = Account.find_by!(user_id: @user_id)

        account.with_lock do
          raise "Not enough balance" if account.balance < @amount
          account.update!(balance: account.balance - @amount)
        end
      end
    end
  end

  private

  # retry deadlock
  def with_retry(max:)
    retries = 0
    begin
      yield
    rescue ActiveRecord::Deadlocked => e
      retries += 1
      if retries <= max
        sleep(0.1)
        retry
      else
        Rails.logger.error("[Deadlock] withdraw failed for user #{@user_id}: #{e.message}")
        raise
      end
    end
  end
end
```
#### So sánh với Class.lock.find ...

| Feature             | `Account.lock.find_by!`    | `account.with_lock`             |
| ------------------- | -------------------------- | ------------------------------- |
| Lock row            | Khi query                  | Khi block bắt đầu               |
| Transaction         | Cần tự wrap                | Có thể wrap hoặc dùng bên ngoài |
| Khi dùng object sẵn | Không tiện, phải query lại | Dễ dùng với object đã load      |
| Code style          | Dài hơn nếu đã có object   | Block syntax gọn, dễ đọc        |


#### Account.lock.find_by!(user_id: user_id)
```ruby
account = Account.lock.find_by!(user_id: user_id)
account.update!(balance: account.balance - amount)
Account.lock → Rails sẽ generate:
```

```sql
SELECT * FROM accounts WHERE user_id = ? FOR UPDATE
Lock ngay khi query
```
Bạn thao tác update ngoài transaction → phải wrap trong Account.transaction, thường dùng trong service object / job

#### account.with_lock do ... end
```ruby
account = Account.find_by!(user_id: user_id)
account.with_lock do
  account.update!(balance: account.balance - amount)
end
```
with_lock sẽ tạo transaction và lock row ngay trước khi chạy block.

Block code đảm bảo:
- Row đã bị lock
- Chỉ một session thao tác trên row đó

Hữu ích khi bạn đã có object account và muốn lock trước khi update


### ✦ Dùng advisory lock khi lock theo logic, không phải row
#### PostgreSQL cho phép bạn gọi pg_advisory_lock(key) để khóa một integer hoặc bigint key.
```ruby
class AdvisoryLockHelper
  # namespace: integer để phân loại resource
  # key: integer đại diện cho object
  def self.with_advisory_lock(namespace, key)
    # Lock
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{namespace}, #{key})")
    begin
      yield
    ensure
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{namespace}, #{key})")
    end
  end
end
```
```ruby
module AdvisoryLockNamespace
  ACCOUNTS   = 1
  INVENTORY  = 2
  ORDERS     = 3
  PAYOUTS    = 4
end
```
#### Withdraw
```ruby
AdvisoryLockHelper.with_advisory_lock(AdvisoryLockNamespace::ACCOUNTS, user_id) do
  Account.transaction do
    account = Account.find_by!(user_id: user_id)
    # logic withdraw
  end
end
```
#### Inventory update
```ruby
AdvisoryLockHelper.with_advisory_lock(AdvisoryLockNamespace::INVENTORY, product_id) do
  Product.transaction do
    product = Product.find(product_id)
    # logic update stock
  end
end
```
---

## 11. Kết luận

**Pessimistic Locking = vũ khí mạnh nhất để bảo vệ dữ liệu quan trọng khỏi race-condition.**  
Và ví dụ withdraw là kinh điển nhất, thực tế nhất, phù hợp cho mọi hệ thống thanh toán hoặc game.

---


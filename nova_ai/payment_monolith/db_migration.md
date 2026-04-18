

1\. Database Schema & Migration
-------------------

### 1.1 Design Principles

-   **Database là source of truth**
-   Mọi xử lý payment phải:
    -   idempotent
    -   atomic
-   **Unique constraint = lớp chặn cuối cùng**
-   Tách riêng:
    -   `orders` (business object)
    -   `payments` (transaction thực tế từ provider)
    -   `payment_events` (audit log / webhook history)

* * * * *

### 1.2 Tables Overview

| Table | Purpose |
| --- | --- |
| `orders` | Đơn hàng business |
| `payments` | Transaction từ payment provider |
| `payment_events` | Log toàn bộ webhook (debug + audit) |

* * * * *

### 1.3 Schema Definition

* * * * *

#### 1.3.1 `orders`

```sql
CREATE TABLE orders (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    amount BIGINT NOT NULL,
    currency VARCHAR(10) NOT NULL DEFAULT 'VND',
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    -- PENDING | PROCESSING (optional) | PAID | FAILED | EXPIRED
    idempotency_key VARCHAR(255),
    version INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);
```

**Index**
```sql
CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE UNIQUE INDEX uniq_orders_idempotency_key ON orders(idempotency_key) WHERE idempotency_key IS NOT NULL;
```
* * * * *

#### 1.3.2 `payments`
```sql
CREATE TABLE payments (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(id),
    provider VARCHAR(50) NOT NULL, -- momo | vnpay | stripe
    transaction_id VARCHAR(255) NOT NULL,
    amount BIGINT NOT NULL,
    currency VARCHAR(10) NOT NULL,
    status VARCHAR(20) NOT NULL,
    -- INIT | SUCCESS | FAILED
    raw_payload JSONB, -- dữ liệu gốc từ webhook
    created_at TIMESTAMP NOT NULL DEFAULT now()
);
```

**🔥 Critical Unique Constraint**
```sql
CREATE UNIQUE INDEX uniq_payments_transaction\
ON payments(provider, transaction_id);
```

👉 Đây là **idempotency guarantee ở DB level**

* * * * *

#### 1.3.3 `payment_events` (Audit / Debug)
```sql
CREATE TABLE payment_events (
    id BIGSERIAL PRIMARY KEY,
    provider VARCHAR(50) NOT NULL,
    transaction_id VARCHAR(255),
    event_type VARCHAR(50), -- webhook / retry / manual
    payload JSONB NOT NULL,
    received_at TIMESTAMP NOT NULL DEFAULT now()
);
```

**Index**

```sql
CREATE INDEX idx_payment_events_tx
ON payment_events(transaction_id);
```

* * * * *

### 1.4 Migration (Rails-style example)
```ruby
class CreatePaymentSystem < ActiveRecord::Migration[7.0]
  def change
    create_table :orders do |t|
      t.bigint :user_id, null: false
      t.bigint :amount, null: false
      t.string :currency, null: false, default: "VND"
      t.string :status, null: false, default: "PENDING"
      t.string :idempotency_key
      t.integer :version, null: false, default: 0

      t.timestamps
    end

    add_index :orders, :user_id
    add_index :orders, :status
    add_index :orders, :idempotency_key,
              unique: true,
              where: "idempotency_key IS NOT NULL",
              name: "uniq_orders_idempotency_key"

    create_table :payments do |t|
      t.references :order, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :transaction_id, null: false
      t.bigint :amount, null: false
      t.string :currency, null: false
      t.string :status, null: false
      t.jsonb :raw_payload

      t.timestamps
    end

    add_index :payments,
              [:provider, :transaction_id],
              unique: true,
              name: "uniq_payments_transaction"

    create_table :payment_events do |t|
      t.string :provider, null: false
      t.string :transaction_id
      t.string :event_type
      t.jsonb :payload, null: false

      t.timestamp :received_at, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :payment_events, :transaction_id
  end
end
```

* * * * *

### 1.5 Canonical Processing Flow (DB-level)

**Pseudocode Code**
```
BEGIN TRANSACTION

1. Insert payment (idempotency gate)\
   INSERT INTO payments(provider, transaction_id, ...)
   → nếu duplicate → STOP (already processed)

2. Update order
   UPDATE orders
   SET status = 'PAID'
   WHERE id = :order_id AND status = 'PENDING'

3. Commit

4. Trigger async jobs

END
```

* * * * *

### 1.6 Why This Works

**Case: Duplicate webhook**

-   Lần 1 → insert OK → xử lý
-   Lần 2 → unique constraint fail → ignore

* * * * *

**Case: Worker crash giữa chừng**

-   Insert thành công nhưng chưa update order
-   Retry → insert fail → system biết đã xử lý → cần reconcile (optional)

👉 Có thể improve bằng:

-   transaction wrapping
-   hoặc thêm `status` trong payments

* * * * *

### 1.7 Optional Enhancements

**1. Add payment status lifecycle**

status:\
INIT → SUCCESS → FAILED

* * * * *

**2. Add reconciliation support**

ALTER TABLE payments ADD COLUMN processed_at TIMESTAMP;

* * * * *

**3. Stronger consistency (advanced)**

-   Dùng **SELECT FOR UPDATE** khi update order
-   Hoặc combine:
```sql
UPDATE orders
SET status = 'PAID'
WHERE id = :id AND status = 'PENDING';
```

* * * * *

### 1.8 Anti-Patterns (Avoid)

❌ Không dùng:

-   Redis làm source of truth
-   Check "đã xử lý chưa" chỉ bằng SELECT
-   Không có unique constraint
-   Update order trước khi insert payment

2\. Final Takeaway (DB Layer)
--------------------------------------

-   **payments table + unique index = idempotency gate**
-   **orders table = business state machine**
-   **payment_events = audit/debug layer**

👉 Nếu implement đúng schema này:

> Có thể **tắt Redis vẫn không bị double charge**
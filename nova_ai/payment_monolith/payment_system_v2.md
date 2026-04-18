Payment Processing Architecture & Idempotency Guarantees
========================================================

**Status:** Draft\
**Author:** Backend Team\
**Last Updated:** 2026-04-18

* * * * *

1\. Summary
-----------

Tài liệu này đề xuất kiến trúc xử lý thanh toán nhằm đảm bảo:

-   **Data correctness (no double charge / no duplicate processing)**
-   **Idempotent processing under retries**
-   **Resilience trong môi trường distributed (multi-worker, network retry, webhook duplication)**

**Key decision:**

-   Không dựa vào Distributed Lock (Redis/Redlock) để đảm bảo correctness
-   Sử dụng **Database constraints + idempotency** làm cơ chế chính
-   Redis lock chỉ dùng như **performance optimization (optional)**

* * * * *

2\. Goals & Non-Goals
---------------------

### 2.1 Goals

-   Đảm bảo mỗi transaction được xử lý **exactly-once (effectively once)**
-   Chịu được:
    -   duplicate webhook
    -   retry từ partner
    -   retry từ client
    -   out-of-order events
-   Tách biệt rõ:
    -   UX flow (client)
    -   data integrity flow (server-to-server)

* * * * *

### 2.2 Non-Goals

-   Không giải quyết:
    -   Fraud detection
    -   Reconciliation với bank (batch settlement)
-   Không đảm bảo "exactly-once" ở level distributed system tuyệt đối\
    → Chỉ đảm bảo **idempotent outcome**

* * * * *

3\. High-Level Architecture
---------------------------

Hệ thống gồm 2 luồng độc lập:

### 3.1 Flow A: Client → Server (User Experience)

**Purpose:** tạo order và điều hướng user đi thanh toán

**Steps:**

1.  Client gửi request tạo thanh toán
2.  Server tạo `Order` với trạng thái `PENDING`
3.  Server gọi payment provider → lấy `payment_url`
4.  Client redirect user sang provider
5.  Sau khi thanh toán, user được redirect về `return_url`

**Important:**

-   Không cập nhật trạng thái `PAID` trong flow này
-   Chỉ hiển thị trạng thái "processing"

* * * * *

### 3.2 Flow B: Payment Provider → Server (Webhook/IPN)

**Purpose:** source of truth cho transaction

**Steps:**

1.  Provider gửi webhook (có thể retry nhiều lần)
2.  Server verify signature
3.  Server xử lý idempotent transaction
4.  Update DB
5.  Trigger async side effects

* * * * *

4\. Core Problem: Idempotency & Duplicate Processing
----------------------------------------------------

Trong thực tế, hệ thống phải xử lý các tình huống:

-   Webhook gửi nhiều lần (retry)
-   Multiple workers xử lý cùng lúc
-   Network delay / out-of-order events
-   Process pause (GC, crash)

👉 Vì vậy:

> **Payment processing = Idempotency problem, không phải locking problem**

* * * * *

5\. Proposed Design
-------------------

### 5.1 Idempotency Key

Mỗi transaction phải có một key duy nhất:

-   `transaction_id` từ payment provider\
    **hoặc**
-   `idempotency_key` do hệ thống generate

**Requirement:**

-   Cùng key -> cùng kết quả
-   Không xử lý lại transaction đã xử lý

* * * * *

### 5.2 Database-Level Guarantee (Primary Mechanism)

#### 5.2.1 Unique Constraint

Tạo bảng tracking:
```sql
CREATE TABLE payment_processed (
    id SERIAL PRIMARY KEY,
    transaction_id TEXT NOT NULL,
    order_id BIGINT NOT NULL,
    created_at TIMESTAMP DEFAULT now(),
    UNIQUE(transaction_id)
);
```

**Processing logic:**

1\. INSERT INTO payment_processed(transaction_id, order_id)\
2\. Nếu fail (duplicate) → STOP (already processed)\
3\. Nếu success → proceed update order

👉 Đây là **strongest guarantee (atomic + cheap)**

* * * * *

### 5.2.2 Order State Machine
```
PENDING → PAID
        → FAILED
        → EXPIRED
```
Optional:
```
PENDING → PROCESSING → PAID
```

**Constraint:**

-   Chỉ cho phép transition hợp lệ
-   Reject nếu state không match


**✅ Khi KHÔNG cần status `PROCESSING`**

Flow đơn giản:
```
PENDING → PAID / FAILED
```
Chỉ cần:

-   insert payment (idempotency gate)
-   update order trực tiếp

👉 Works tốt nếu:

-   logic xử lý nhanh
-   không có nhiều bước trung gian
-   side effects async (email, inventory...)

👉 Đây là case hiện tại → **OK, không cần PROCESSING**

* * * * *

**✅ Khi NÊN có `PROCESSING`**


Thêm state này khi:

### 1\. Có nhiều bước sync trong transaction

Ví dụ:

-   validate payment
-   check fraud
-   reserve inventory
-   call internal services

👉 Lúc này:
```
PENDING → PROCESSING → PAID
```
giúp:
-   tránh xử lý lại từ đầu nếu crash
-   debug dễ hơn ("kẹt ở bước nào?")

* * * * *

### 2\. Muốn tránh race condition phức tạp hơn

Ví dụ:
```
Worker A → set PROCESSING\
Worker B → thấy PROCESSING → skip
```

👉 Đây là **soft lock bằng DB state**

* * * * *

### 3\. Có SLA dài / external dependency

Ví dụ:

-   gọi API khác mất 2--5s
-   payment settle delayed

* * * * *

⚠️ Nhưng cũng có downside
-------------------------

-   Tăng complexity
-   Phải handle thêm state transition
-   Dễ bug nếu không enforce strict transition

* * * * *

👉 Kết luận (rất practical)
---------------------------

| Case | Dùng PROCESSING |
| --- | --- |
| Basic webhook payment | ❌ Không |
| Complex workflow | ✅ Có |
| Multi-step sync logic | ✅ Có |

👉 Với design hiện tại : **không cần**

* * * * *

### 5.2.3 Optimistic Locking (Optional)
```sql
UPDATE orders
SET status = 'PAID', version = version + 1
WHERE id = :id AND status = 'PENDING' AND version = :current_version;
```

* * * * *

6\. Redis Lock (Optional Optimization)
--------------------------------------

### 6.1 Usage

Redis lock có thể dùng để:

-   Giảm load DB
-   Giảm contention khi nhiều webhook đến cùng lúc

### 6.2 Limitation

Redis lock **KHÔNG đảm bảo strong correctness** do:

-   Async replication
-   Lock expiration
-   Process pause (GC)
-   Network partition

👉 Do đó:

> Redis lock chỉ là optimization layer, không phải safety layer

* * * * *

7\. Redlock Analysis
--------------------

### 7.1 Requirements (theoretical)

-   ≥ 5 independent Redis nodes
-   Quorum-based locking

### 7.2 Practical Issues

-   Clock drift giữa các node
-   Process pause → mất lock
-   Network delay → race condition

### 7.3 Conclusion

-   Redlock phù hợp cho:
    -   cache rebuild
    -   job coordination
-   Redlock **không phù hợp** cho:
    -   payment processing
    -   financial correctness

* * * * *

8\. Webhook Handling Requirements
---------------------------------

Hệ thống phải đảm bảo:

-   Idempotent processing
-   Safe under retry
-   Không phụ thuộc vào client redirect

**Rules:**

-   Webhook là **source of truth duy nhất**
-   Có thể nhận:
    -   duplicate events
    -   delayed events
    -   out-of-order events

* * * * *

9\. Side Effects Handling
-------------------------

Sau khi update DB:

-   Gửi event async (queue)
-   Các tác vụ:
    -   gửi email
    -   update inventory
    -   reward points

**Requirement:**

-   Side effects cũng phải idempotent

* * * * *

10\. Failure Scenarios
----------------------

| Scenario | Handling |
| --- | --- |
| Webhook duplicate | Block bởi unique constraint |
| Worker crash sau insert | Retry safe |
| GC pause | DB vẫn đảm bảo correctness |
| Redis lock mất | Không ảnh hưởng correctness |
| Out-of-order webhook | Check state trước update |

* * * * *

11\. Final Architecture Decision
--------------------------------

### 11.1 MUST HAVE

-   Idempotency key
-   Unique constraint tại DB
-   Order state machine
-   Webhook-driven processing

* * * * *

### 11.2 NICE TO HAVE

-   Redis lock (performance)
-   Optimistic locking
-   Retry queue

* * * * *

### 11.3 NOT RECOMMENDED

-   Dựa hoàn toàn vào Redis lock
-   Dùng Redlock cho payment correctness

* * * * *

12\. Key Takeaways
------------------

1.  Payment là bài toán **idempotency**, không phải locking
2.  Database là **source of truth duy nhất**
3.  Unique constraint là **final safety net**
4.  Webhook là **authoritative signal**
5.  System phải chịu được:
    -   duplicate
    -   retry
    -   delay
    -   out-of-order

* * * * *

13\. Appendix: Signature Verification Example
---------------------------------------------
Python:
```python
import hmac
import hashlib
import urllib.parse

def generate_signature(data, secret_key):
    sorted_data = sorted(data.items())
    raw_signature_str = urllib.parse.urlencode(sorted_data)

    return hmac.new(
        secret_key.encode('utf-8'),
        raw_signature_str.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()

```
Ruby
```ruby
require "openssl"
require "uri"

module Payments
  class SignatureVerifier
    def self.generate_signature(data, secret_key)
      # 1. sort keys
      sorted_data = data.sort.to_h

      # 2. build query string
      raw_string = URI.encode_www_form(sorted_data)

      # 3. HMAC SHA256
      OpenSSL::HMAC.hexdigest(
        "SHA256",
        secret_key,
        raw_string
      )
    end

    def self.valid_signature?(payload, received_signature, secret_key)
      calculated = generate_signature(payload, secret_key)

      secure_compare(calculated, received_signature)
    end

    def self.secure_compare(a, b)
      return false if a.blank? || b.blank?
      return false unless a.bytesize == b.bytesize

      ActiveSupport::SecurityUtils.secure_compare(a, b)
    end
  end
end
```

⚠️ 3 lỗi dev hay dính
1. ❌ Không sort params -> signature mismatch
2. ❌ Không dùng secure_compare -> timing attack
3. ❌ Encode sai format -> provider reject

* * * * *

14\. Open Questions
-------------------

### 14.1 Reconciliation job (daily)

Cron job chạy mỗi ngày — last safety net khi webhook miss hoặc fail.

**3 trường hợp cần xử lý:**

| Case | Nghĩa | Hành động |
| --- | --- | --- |
| Có trong provider, không có trong DB | Webhook miss hoàn toàn | Tạo payment + update order |
| Có trong cả 2, nhưng status lệch | Webhook đến nhưng xử lý lỗi | Fix status + alert |
| Có trong DB, không có trong provider | Data lạ / bug | Alert để điều tra |

```ruby
# app/jobs/payments/reconciliation_job.rb
module Payments
  class ReconciliationJob < ApplicationJob
    queue_as :low

    def perform(provider:, date: Date.yesterday)
      adapter = ProviderFactory.build(provider)

      # Lấy danh sách transactions từ provider trong ngày
      provider_txns = adapter.fetch_transactions(date: date)

      provider_txns.each do |txn|
        reconcile_transaction(provider, txn)
      end
    end

    private

    def reconcile_transaction(provider, txn)
      local = Payment.find_by(provider: provider, transaction_id: txn.transaction_id)

      if local.nil?
        # EXTERNAL: webhook miss — tạo lại từ provider data
        Rails.logger.warn("[Reconciliation] missing payment: #{txn.transaction_id}")
        reprocess(provider, txn)

      elsif local.status != txn.status
        Rails.logger.warn("[Reconciliation] status mismatch: #{txn.transaction_id} local=#{local.status} provider=#{txn.status}")
        fix_mismatch(local, txn)

      end
    end

    def reprocess(provider, txn)
      # Tái tạo NormalizedEvent từ provider data rồi chạy qua core processor
      event = Payments::NormalizedEvent.new(
        provider: provider,
        event_type: "reconciliation",
        transaction_id: txn.transaction_id,
        order_id: txn.order_id,
        amount: txn.amount,
        currency: txn.currency,
        status: txn.status,
        raw_payload: txn.raw
      )

      Payments::ProcessNormalizedEvent.new(event: event).call
    end

    def fix_mismatch(local, txn)
      return unless txn.status == "SUCCESS" && local.status != "SUCCESS"

      # Chỉ fix theo hướng SUCCESS — không downgrade từ SUCCESS xuống FAILED
      Payments::ProcessNormalizedEvent.new(
        event: Payments::NormalizedEvent.new(
          provider: local.provider,
          event_type: "reconciliation",
          transaction_id: local.transaction_id,
          order_id: local.order_id,
          amount: local.amount,
          currency: local.currency,
          status: "SUCCESS",
          raw_payload: local.raw_payload
        )
      ).call
    end
  end
end
```

**Schedule (cron):**
```ruby
# config/schedule.rb (whenever gem) hoặc Sidekiq-Cron
every 1.day, at: "2:00 am" do
  runner "Payments::ReconciliationJob.perform_later(provider: 'vnpay')"
  runner "Payments::ReconciliationJob.perform_later(provider: 'momo')"
end
```

**Lưu ý quan trọng:**
- `reprocess` và `fix_mismatch` đều đi qua `ProcessNormalizedEvent` — **idempotent by design**, chạy lại nhiều lần không bị double charge
- Chỉ fix theo hướng SUCCESS, không bao giờ downgrade từ PAID → FAILED qua reconciliation
- Adapter cần implement thêm `fetch_transactions(date:)` — mỗi provider có API riêng

👉 Đây là **last safety net**

* * * * *

### 14.2 Partial Payment / Refund

👉 Nếu có:

Schema cần thêm:
```sql
payments.type = 'charge' | 'refund'
```

hoặc:
```
refunds table
```

* * * * *

### Logic:
```
Order total: 100k
Payment: 100k
Refund: -50k
→ Net: 50k
```

👉 Order state lúc này không còn đơn giản `PAID` nữa

* * * * *

### 14.3 Webhook Retry SLA

👉 Bạn phải define:

-   Retry bao lâu? (VD: 24h)
-   Retry interval?

👉 Ảnh hưởng:

-   log retention
-   idempotency window

* * * * *

### 14.4 Audit Log

👉 Nếu "Có":

Bạn đã có `payment_events` table → OK rồi

* * * * *

Thêm:
```
index(transaction_id)
```
👉 để debug nhanh
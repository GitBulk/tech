Chaos Test Specification (production-grade) cho hệ thống payment. Tài liệu này dùng để:
- Validate các giả định trong RFC (idempotency, correctness)
- Phát hiện race condition, retry bug, consistency bug
- Chuẩn bị cho load / incident thực tế

Chaos Test Specification: Payment Processing System
===================================================

**Status:** Draft
**Owner:** Backend Team
**Scope:** Webhook processing + DB consistency + multi-worker execution

* * * * *

1\. Objectives
====================

## 1.1 Primary Goals

-   Đảm bảo hệ thống luôn đạt:
    -   **No double charge**
    -   **Exactly-once effect (idempotent outcome)**
    -   **Correct final order state**

* * * * *

## 1.2 Failure Conditions cần test

Hệ thống phải chịu được:

-   Duplicate webhook (high frequency)
-   Concurrent processing (multi-worker)
-   Process crash / restart
-   GC pause / thread freeze
-   Network delay / out-of-order events
-   DB contention / slow query

* * * * *

2\. Test Environment
====================

## 2.1 Setup

-   Postgres (production-like config)
-   Redis (optional, có thể tắt)
-   3--10 worker processes (Sidekiq / Puma / etc.)
-   Fake payment provider (mock webhook sender)

* * * * *

## 2.2 Test Data
```
Order:
- id: 1001
- amount: 500000
- status: PENDING

Transaction:
- transaction_id: TXN_ABC_123
```

* * * * *

3\. Chaos Scenarios
====================

* * * * *

## 3.1 Scenario A: Duplicate Webhook Storm


### Description

Provider gửi cùng một webhook **N lần cùng lúc**

### Injection

Send 50--200 identical webhook requests concurrently

* * * * *

### Expected Result

-   Chỉ **1 payment record được insert**
-   Order chỉ update **1 lần**
-   Các request còn lại:
    -   return duplicate
    -   không crash

* * * * *

### Assertions
```
COUNT(payments WHERE transaction_id=TXN_ABC_123) == 1

orders.status == "PAID"

No exception (except RecordNotUnique handled)
```

* * * * *

## 3.2 Scenario B: Concurrent Workers Race

### Description

N workers xử lý cùng transaction

* * * * *

### Injection

Spawn 10 workers:
→ all call ProcessWebhook(transaction_id=TXN_ABC_123)

* * * * *

### Expected Result

-   Chỉ 1 worker thắng
-   Không deadlock
-   Không inconsistent state

* * * * *

### Assertions
```
payments count == 1
orders.status == "PAID"
```
* * * * *

## 3.3 Scenario C: Process Crash Mid-Transaction

### Description

Worker crash sau khi insert payment nhưng trước khi update order

* * * * *

### Injection

1. Begin TX
2. Insert payment
3. Kill process (SIGKILL)

* * * * *

### Expected Result

-   Transaction rollback (nếu chưa commit)
    **hoặc**
-   Retry xử lý an toàn

* * * * *

### Assertions
```
System can reprocess webhook safely

Final:
payments count == 1
orders.status == "PAID"
```

* * * * *

## 3.4 Scenario D: GC Pause / Thread Freeze

### Description

Worker bị pause sau khi insert payment

* * * * *

### Injection

sleep(10) after INSERT payment
while another worker processes same webhook

* * * * *

### Expected Result

-   Worker thứ 2 fail do duplicate
-   Worker thứ 1 resume và complete

* * * * *

### Assertions
```
No double update
orders.status == "PAID"
```
* * * * *

## 3.5 Scenario E: Out-of-Order Events

### Description

Attempt đầu FAILED (tx_id mới), attempt sau SUCCESS (tx_id khác).
Mỗi attempt có `transaction_id` riêng — đúng với hành vi thực tế của VNPay/Momo.

> **Lưu ý:** Không dùng cùng `transaction_id` cho cả FAILED lẫn SUCCESS —
> unique constraint sẽ chặn attempt thứ 2, không phải out-of-order thật sự.

* * * * *

### Injection

Send:
1. FAILED webhook (`transaction_id = TXN_FAIL_xxx`)
2. SUCCESS webhook (`transaction_id = TXN_OK_yyy`, cùng `order_id`)

* * * * *

### Expected Result

-   Final state phải là:
    -   PAID (SUCCESS thắng, state machine guard bảo vệ không flip ngược lại)

* * * * *

### Assertions

```
orders.status == "PAID"
COUNT(payments WHERE order_id = 1001) == 2  -- 1 FAILED + 1 SUCCESS
```

* * * * *

## 3.6 Scenario F: Retry Storm (Exponential Backoff)

### Description

Provider retry liên tục trong 30--60s

* * * * *

### Injection

Send webhook every 100ms for 60 seconds

* * * * *

### Expected Result

-   Không tăng CPU bất thường
-   Không DB lock contention nặng
-   Không duplicate

* * * * *

### Metrics

Error rate < 1%
DB lock wait time stable

* * * * *

## 3.7 Scenario G: Redis Failure (If Used)

### Description

Redis down trong lúc xử lý

* * * * *

### Injection

Kill Redis container during webhook processing

* * * * *

### Expected Result

-   Hệ thống vẫn correct
-   Không phụ thuộc Redis để đảm bảo correctness

* * * * *

### Assertions
```
orders.status == "PAID"
No data corruption
```

* * * * *

## 3.8 Scenario H: DB Slow Query / Lock Contention

### Description

Simulate DB slow response

* * * * *

### Injection

pg_sleep(2) inside transaction

* * * * *

### Expected Result

-   Không deadlock
-   Retry vẫn OK

* * * * *


4\. Test Execution Strategy
===========================

## 4.1 Automated Chaos Runner

Pseudo-code:
```
threads = []

100.times do
  threads << Thread.new do
    Payments::ProcessWebhook.call(
      provider: "vnpay",
      payload: test_payload,
      headers: test_headers
    )
  end
end

threads.each(&:join)
```

* * * * *

## 4.2 Deterministic Replay

-   Log toàn bộ webhook payload
-   Replay lại scenario khi có bug

* * * * *

## 4.3 Fault Injection Hooks

Trong code:

def create_payment!
  Payment.create!(...)

  Chaos.inject!(:after_payment_insert)

end

* * * * *

5\. Metrics & Observability
===========================

## 5.1 Required Metrics

-   webhook throughput
-   duplicate rate
-   DB constraint violations
-   transaction latency

* * * * *

5.2 Logging
-----------

Log các event:
```json
{
  "transaction_id": "TXN_ABC_123",
  "status": "duplicate",
  "worker_id": "worker-3"
}
```

* * * * *

6\. Pass Criteria
=================

Hệ thống PASS nếu:

-   Không có duplicate payment
-   Order luôn đúng state cuối
-   Không crash hệ thống
-   Retry an toàn 100%


7\. Fail Signals (Red Flags)
============================

-   2 payment record cùng transaction_id ❌
-   Order bị flip state (PAID → FAILED) ❌
-   Deadlock ❌
-   Memory leak / CPU spike ❌

8\. Final Takeaway
==================

Chaos test này verify một điều:

> **Hệ thống đúng không phải khi mọi thứ "chạy mượt"
> mà khi mọi thứ "chạy sai" nó vẫn đúng**
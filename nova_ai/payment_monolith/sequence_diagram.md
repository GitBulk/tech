Dưới đây là **sequence diagram "multi-provider + race condition + retry"** . Có 3 scenario quan trọng nhất trong production:

* * * * *

1\. Happy Path (Single Webhook, No Race)
========================================
```
User        Client        Server        Provider        DB
 |            |              |              |            |
 | Click Pay  |              |              |            |
 |----------->|              |              |            |
 |            | Create Order |              |            |
 |            |------------->|              |            |
 |            |              | Insert PENDING order      |
 |            |              |-------------------------->|
 |            |              |              |            |
 |            |              | Create payment URL        |
 |            |              |------------->|            |
 |            |              |              |            |
 | Redirect   |              |              |            |
 |----------->|              |              |            |
 |            |              |              | User pays  |
 |            |              |              |----------->|
 |            |              |              |            |
 |            |              | Webhook      |            |
 |            |              |<-------------|            |
 |            |              | Verify sig                |
 |            |              |              |            |
 |            |              | INSERT payment            |
 |            |              |-------------------------->|
 |            |              | OK                        |
 |            |              |                           |
 |            |              | UPDATE order → PAID       |
 |            |              |-------------------------->|
 |            |              |                           |
 |            |              | Commit                    |
```

👉 Không có gì đặc biệt --- baseline

* * * * *

2\. Race Condition: Duplicate Webhook (Most Important)
======================================================

Scenario:
---------

-   Provider retry webhook 2 lần gần như cùng lúc
-   2 workers xử lý song song

* * * * *
```
Provider         Server A              Server B              DB
   |                |                     |                  |
   | Webhook #1     |                     |                  |
   |--------------->|                     |                  |
   | Webhook #2     |                     |                  |
   |--------------->|-------------------->|                  |
   |                |                     |                  |
   |                | BEGIN TX            | BEGIN TX         |
   |                |                     |                  |
   |                | INSERT payment      | INSERT payment   |
   |                |-------------------->|----------------->|
   |                | OK                  | ❌ UNIQUE FAIL   |
   |                |                     |                  |
   |                | SELECT ... FOR UPDATE (order)          |
   |                |-------------------->|                  |
   |                |                     |                  |
   |                | UPDATE order=PAID   |                  |
   |                |-------------------->|                  |
   |                | COMMIT              | ROLLBACK         |
   |                |                     |                  |
   |                | return OK           | return duplicate |
```
* * * * *

🔥 Key Insight
--------------

-   **DB unique constraint thắng**
-   Không cần Redis
-   Không cần lock phân tán

👉 Đây là "exactly-once effect"

* * * * *

3\. Race + Process Pause (GC / Crash Scenario)
==============================================

Scenario:
---------

-   Worker A lấy lock, nhưng bị pause (GC)
-   Worker B xử lý xong trước

* * * * *
```
Provider      Server A (slow)      Server B (fast)       DB
   |               |                     |                |
   | Webhook       |                     |                |
   |-------------->|                     |                |
   |               | BEGIN TX            |                |
   |               |                     |                |
   |               | INSERT payment      |                |
   |               |-------------------->|                |
   |               | OK                  |                |
   |               |                     |                |
   |               | --- PAUSED (GC) --- |                |
   |               |                     |                |
   |               |                     | Webhook retry  |
   |               |                     |<---------------|
   |               |                     | BEGIN TX       |
   |               |                     |                |
   |               |                     | INSERT payment |
   |               |                     |--------------->|
   |               |                     | ❌ DUPLICATE   |
   |               |                     |                |
   |               |                     | EXIT           |
   |               |                     |                |
   |               | RESUME              |                |
   |               | UPDATE order        |                |
   |               |-------------------->|                |
   |               | COMMIT              |                |
```
* * * * *

🔥 Key Insight
--------------

-   Redis lock **fail trong scenario này**
-   Nhưng DB constraint vẫn **correct**

* * * * *

4\. Out-of-Order Events
=======================

Scenario:
---------

-   FAILED webhook đến trước SUCCESS

* * * * *

```
Provider        Server              DB
   |               |                 |
   | FAILED        |                 |
   |-------------->|                 |
   |               | INSERT payment  |
   |               |---------------->|
   |               |                 |
   |               | UPDATE order=FAILED
   |               |---------------->|
   |               |                 |
   | SUCCESS       |                 |
   |-------------->|                 |
   |               | INSERT payment  |
   |               |---------------->|
   |               | OK              |
   |               |                 |
   |               | UPDATE order=PAID
   |               |---------------->|
```
* * * * *

⚠️ Problem
----------

Nếu không guard:

→ trạng thái có thể sai

* * * * *

✅ Fix (State Machine Guard)
---------------------------

return if order.status == "PAID"

* * * * *

5\. Multi-Provider Flow (Abstraction Layer)
===========================================
```
Provider A (VNPay)                     Provider B (Momo)
        |                                        |
        | Webhook                         Webhook|
        |------------------->|<------------------|
                             |
                      ProviderAdapter
                             |
                      Normalize Event
                             |
                   ProcessNormalizedEvent
                             |
                             DB
```
* * * * *

🔥 Insight
----------

-   Core system **không biết provider**
-   Tất cả đi qua:
    -   `NormalizedEvent`
    -   `ProcessNormalizedEvent`

* * * * *

6\. Failure Matrix (Important for Review)
=========================================

| Scenario | Result |
| --- | --- |
| Duplicate webhook | Block bởi unique constraint |
| Retry storm | Safe |
| Worker crash | Retry OK |
| GC pause | Safe |
| Redis down | Không ảnh hưởng |
| Out-of-order | Controlled by state machine |

* * * * *

7\. One Diagram to Rule Them All (Condensed)
============================================
```
Webhook -> Adapter -> Normalize -> TX BEGIN
        -> INSERT payment (unique)
            -> FAIL -> STOP
            -> OK ->
                  -> LOCK order
                  -> VALIDATE state
                  -> UPDATE order
        -> COMMIT
```
* * * * *

8\. What Senior Engineers Will Notice
=====================================

-   Có idempotency chưa? ✅
-   Có race condition chưa? ✅
-   Có retry-safe chưa? ✅
-   Có provider-agnostic chưa? ✅
-   Có DB constraint chưa? ✅

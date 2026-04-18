1\. Ledger (Double-entry) --- "Sự thật tài chính"
===============================================

1.1 Vấn đề nó giải quyết
------------------------

Bắt đầu với kiểu này:
```
orders.status = PAID
user.balance -= 100k
```

👉 Nghe ổn... cho đến khi:

-   race condition → trừ tiền 2 lần
-   bug → mất tiền mà không trace được
-   audit → không giải thích được "tiền đi đâu"

* * * * *

1.2 Ý tưởng cốt lõi
-------------------

> Mọi thay đổi tiền = **ghi lại một dòng log**\
> Không bao giờ sửa trực tiếp số dư

Và quan trọng hơn:

> Mỗi giao dịch luôn có **2 phía (double-entry)**

```
User Wallet     -100k
Platform Escrow +100k
```
👉 Tổng luôn = 0

* * * * *

1.3 Tại sao nó quan trọng
-------------------------

-   Không thể "tạo tiền từ không khí"
-   Có thể trace mọi dòng tiền
-   Audit được 100%

👉 Đây là **chuẩn kế toán toàn cầu**, không phải chỉ tech

* * * * *

1.4 Khi nào cần
---------------

| System | Có cần không |
| --- | --- |
| Ecommerce nhỏ | ❌ |
| Ví điện tử | ✅ |
| Payment system | ✅ bắt buộc |

* * * * *

1.5 Trade-off
-------------

| Lợi | Hại |
| --- | --- |
| Rất an toàn | Khó hiểu hơn CRUD |
| Audit mạnh | Query phức tạp |
| Debug dễ (về lâu dài) | Dev mới sẽ "ngợp" |

* * * * *

🔥 Insight quan trọng
---------------------

> Ledger không làm system "nhanh hơn"\
> → Nó làm system **không sai**

* * * * *


2\. Settlement + Reconciliation --- "Đối chiếu với thế giới thật"
===============================================================


2.1 Vấn đề
----------

System bạn nói:
```
User đã trả tiền ✔
```

Nhưng ngân hàng nói:
```
Tôi không thấy giao dịch này ❌
```

👉 Ai đúng?

* * * * *

2.2 Ý tưởng
-----------

Bạn có 2 nguồn sự thật:
```
Internal (ledger)
External (bank/provider)
```

👉 Reconciliation = so sánh 2 bên

* * * * *

2.3 Settlement là gì
--------------------

-   Tiền không chuyển ngay
-   Nó đi theo batch:
```
T (user pay) → T+1 (bank settle)
```

* * * * *

2.4 Flow đơn giản
-----------------
```
Webhook -> bạn ghi nhận payment

Ngày hôm sau:
Bank gửi file

→ So sánh:
  - thiếu
  - dư
  - lệch
```

* * * * *

2.5 Tại sao cần
---------------

-   Webhook có thể fail
-   Network có thể lỗi
-   Provider có thể bug

👉 Nếu không reconciliation:

> Bạn sẽ không bao giờ biết mình mất tiền

* * * * *

2.6 Trade-off
-------------

| Lợi | Hại |
| --- | --- |
| Detect sai lệch | Delay (T+1) |
| Fix được tiền sai | Phức tạp hơn |
| Audit mạnh | Phải build thêm system |

* * * * *

🔥 Insight
----------

> Payment system không kết thúc ở webhook\
> → Nó kết thúc ở reconciliation

* * * * *

3\. Kafka / Event Sourcing --- "Ghi lại mọi chuyện đã xảy ra"
===========================================================


3.1 Vấn đề
----------

Trong system bình thường:
```
orders.status = PAID
```

👉 Bạn chỉ thấy **state cuối cùng**

Bạn không biết:

-   trước đó là gì
-   ai thay đổi
-   tại sao

* * * * *

3.2 Ý tưởng
-----------

> Thay vì lưu state → lưu **event**
```
order_created
payment_received
order_paid
```

* * * * *

3.3 Kafka giúp gì
-----------------

Kafka = hệ thống lưu + stream event
```
Event → Kafka → nhiều service cùng đọc
```

* * * * *

3.4 Tại sao cần
---------------

-   Debug: replay lại toàn bộ lịch sử
-   Scale: nhiều consumer đọc cùng lúc
-   Decouple system

* * * * *

3.5 Khi nào cần
---------------

| System | Có cần không |
| --- | --- |
| CRUD app | ❌ |
| Payment / fintech | ✅ |
| Distributed system | ✅ |

* * * * *

3.6 Trade-off
-------------

| Lợi | Hại |
| --- | --- |
| Replay được | Complexity cao |
| Scale tốt | Khó debug nếu chưa quen |
| Decouple system | Phải quản lý schema event |

* * * * *

🔥 Insight
----------

> DB cho bạn "trạng thái hiện tại"\
> Event cho bạn "sự thật lịch sử"

* * * * *

4\. CQRS --- "Tách đọc và ghi"
============================

* * * * *

4.1 Vấn đề
----------

Bạn dùng 1 DB cho:

-   ghi (write)
-   đọc (read)

👉 Khi scale:

-   query chậm
-   lock
-   conflict

* * * * *

4.2 Ý tưởng
-----------

Write model ≠ Read model

* * * * *

4.3 Ví dụ
---------

Write:
```
ledger_entries (phức tạp, chuẩn)
```
Read:
```
account_balance (đã tính sẵn)
```

* * * * *

4.4 Flow
--------
```
Write → Event → Projection → Read DB
```

* * * * *

4.5 Tại sao cần
---------------

-   Read nhanh
-   Scale tốt
-   UI đơn giản

* * * * *

4.6 Trade-off
-------------

| Lợi | Hại |
| --- | --- |
| Query nhanh | Eventual consistency |
| Scale tốt | Data duplicated |
| Flexible | Phức tạp hơn |

* * * * *

🔥 Insight
----------
```
Write model = đúng
Read model = nhanh
```
* * * * *

5\. Ghép tất cả lại (bức tranh lớn)
===================================


Level 1 (basic)
---------------

orders + payments

👉 Dễ nhưng dễ sai

* * * * *

Level 2
-------

+ idempotency + DB constraint

👉 không double charge

* * * * *

Level 3
-------

+ Ledger

👉 không sai tiền

* * * * *

Level 4
-------

+ Reconciliation

👉 phát hiện sai

* * * * *

Level 5
-------

+ Event streaming (Kafka)

👉 realtime + scale

* * * * *

Level 6
-------

+ CQRS

👉 nhanh + tách biệt

* * * * *

6\. Câu hỏi quan trọng nhất
===========================

> Có cần build hết không?

👉 Không.

* * * * *

Thứ tự thực tế nên đi
---------------------

1.  ✅ Idempotency + DB constraint
2.  ✅ Ledger (khi có tiền thật)
3.  ✅ Reconciliation (khi scale)
4.  ⏳ Kafka (khi system lớn)
5.  ⏳ CQRS (khi read/write bottleneck)

* * * * *

7\. Kết luận (cái bạn thực sự cần nhớ)
======================================

-   Ledger → **để không sai tiền**
-   Reconciliation → **để phát hiện sai**
-   Event sourcing → **để biết chuyện gì đã xảy ra**
-   CQRS → **để scale**


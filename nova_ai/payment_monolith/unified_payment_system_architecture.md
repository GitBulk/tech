# 🧠 Unified Payment System Architecture (1-page)

---

## 🎯 Mục tiêu

Thiết kế một hệ thống thanh toán:

* Không double charge
* Không sai tiền
* Có thể audit
* Scale được khi lớn lên

---

## 🏗️ Toàn bộ hệ thống (End-to-End)

```
                         ┌──────────────────────┐
                         │   Payment Provider   │
                         │ (VNPay / Stripe...)  │
                         └──────────┬───────────┘
                                    │ Webhook
                                    ▼
                          ┌────────────────────┐
                          │  Payment Service   │
                          │ (Verify + Idempotency)
                          └──────────┬─────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    ▼                                 ▼
        ┌────────────────────┐             ┌────────────────────┐
        │   Orders (DB)      │             │   Payments (DB)    │
        │  (Business state)  │             │ (External signal)  │
        └─────────┬──────────┘             └─────────┬──────────┘
                  │                                  │
                  └──────────────┬───────────────────┘
                                 ▼
                      ┌────────────────────┐
                      │   Ledger System    │
                      │ (Double-entry)     │
                      │ Financial Truth    │
                      └─────────┬──────────┘
                                │
                                ▼
                      ┌────────────────────┐
                      │   Event Store      │
                      │ (Append-only log)  │
                      └─────────┬──────────┘
                                │
                                ▼
                      ┌────────────────────┐
                      │  Event Stream      │
                      │ (Kafka / Queue)    │
                      └─────────┬──────────┘
                                │
        ┌───────────────────────┼────────────────────────┐
        ▼                       ▼                        ▼
┌───────────────┐      ┌────────────────┐      ┌────────────────────┐
│ Read Models   │      │ Reconciliation │      │ Monitoring / Alert │
│ (CQRS)        │      │ Engine         │      │ (Metrics / Logs)   │
│ Fast queries  │      │ (Compare ext)  │      │                    │
└───────────────┘      └───────┬────────┘      └────────────────────┘
                               │
                               ▼
                    ┌────────────────────┐
                    │ External Reality   │
                    │ (Bank Settlement)  │
                    └────────────────────┘
```

---

## 🧩 Giải thích từng khối (ngắn gọn, đúng bản chất)

### 1. Payment Service

* Verify signature
* Enforce idempotency
* Không quyết định “tiền có đúng không”

👉 Chỉ là **entry point**

---

### 2. Orders (Business State)

* Trạng thái: PENDING / PAID
* Dùng cho UI / business logic

👉 Không phải financial truth

---

### 3. Payments (External Signal)

* Ghi nhận từ provider
* Có thể sai / duplicate

👉 Không đáng tin tuyệt đối

---

### 4. Ledger (Double-entry) ⭐

* Ghi nhận tiền theo debit / credit
* Tổng luôn = 0

👉 Đây là **nguồn sự thật tài chính duy nhất**

---

### 5. Event Store

* Lưu toàn bộ event (immutable)
* Có thể replay

👉 “Lịch sử không thể thay đổi”

---

### 6. Event Stream (Kafka)

* Phát event cho các hệ khác
* Async, scalable

---

### 7. CQRS Read Models

* DB riêng cho read
* Query nhanh

👉 UI không đọc ledger trực tiếp

---

### 8. Reconciliation Engine ⭐

* So sánh:

  * Internal (ledger)
  * External (bank)

👉 Phát hiện:

* Missing
* Duplicate
* Mismatch

---

### 9. External Reality (Bank)

* Settlement T+1
* Không realtime

👉 Đây mới là “tiền thật”

---

### 10. Monitoring / Alert

* Detect anomaly
* Alert mismatch

---

## 🔄 Flow đơn giản (1 transaction)

```text
User pay
 → Webhook
 → Payment Service (idempotent)
 → Payment record
 → Ledger transaction (double-entry)
 → Event emitted
 → Read model update
 → Reconciliation check (real-time + batch)
```

---

## 🧠 4 lớp bảo vệ hệ thống

| Layer                       | Mục tiêu            |
| --------------------------- | ------------------- |
| Idempotency + DB constraint | Không double charge |
| Ledger                      | Không sai tiền      |
| Reconciliation              | Phát hiện sai       |
| Event sourcing              | Audit + replay      |

---

## ⚖️ Trade-offs tổng thể

| Thành phần     | Lợi            | Hại                  |
| -------------- | -------------- | -------------------- |
| Ledger         | Correctness    | Phức tạp             |
| Reconciliation | Detect lỗi     | Delay                |
| Kafka/Event    | Scale + replay | Khó debug            |
| CQRS           | Fast read      | Eventual consistency |

---

## 🚀 Khi nào cần từng phần?

```text
Startup nhỏ:
→ Orders + Payments

Có tiền thật:
→ + Ledger

Scale lớn:
→ + Reconciliation

Distributed system:
→ + Kafka

High throughput:
→ + CQRS
```

---

## 🧠 Câu chốt (để explain cho team)

> Orders chỉ là trạng thái business
> Payments chỉ là tín hiệu bên ngoài
>
> 👉 Ledger mới là sự thật về tiền
> 👉 Reconciliation đảm bảo sự thật đó khớp với thế giới thực

---

## 🏁 Final Takeaway

> System tốt không phải là system “không bao giờ sai”
>
> 👉 Mà là system:
>
> * Không sai tiền
> * Nếu sai → phát hiện được
> * Và có thể sửa mà không phá lịch sử

---

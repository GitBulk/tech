# 📑 Tech Notes Index

Mục lục các note kỹ thuật trong `techblog/tech/`. Mỗi entry kèm 1 dòng tóm tắt + path. Một số file vẫn nằm ở `tech/` root (đang migrate dần sang `tech/docs/` — path tương đối `../` cho file chưa di chuyển).

---

## 🗄️ Database Design / Schema

| Note | Tóm tắt |
| :--- | :--- |
| [db_ecommerce.md](../db_ecommerce.md) | Mô hình Sản phẩm – Biến thể – Thuộc tính cho e-commerce; snapshot pattern cho OrderItems để hóa đơn không bị ảnh hưởng khi giá đổi |
| [db_survey_with_other.md](db_survey_with_other.md) | Schema khảo sát + option "Khác" (custom_text), reward grant atomic, identity strategy cho game không có account |

## 🔒 Concurrency / Locking

| Note | Tóm tắt |
| :--- | :--- |
| [optimistic_vs_pessimistic_locking.md](../optimistic_vs_pessimistic_locking.md) | **Comparison** — so sánh trade-off 2 mô hình; khi nào dùng cái nào |
| [pessimistic_locking.md](../pessimistic_locking.md) | **Implementation** — pessimistic locking trong Rails + PostgreSQL; ví dụ thực tế chống race condition khi rút quỹ |

## 🏗️ System Design

| Note | Tóm tắt |
| :--- | :--- |
| [feed_paging.md](../feed_paging.md) | Pagination cho feed (v1.1) |
| [like_system.md](../like_system.md) | Like/reaction system (v1.6); scope + architecture |
| [image_moderation.md](../image_moderation.md) | Image moderation system design (v1.0); roadmap |

## ⚡ Infrastructure / Performance

| Note | Tóm tắt |
| :--- | :--- |
| [big_data.md](../big_data.md) | PostgreSQL 18 high-performance lab — Phase 1 |

---

## 🤖 AI maintenance

File này được AI maintain semi-automatically. Quy trình:

**Khi thêm note mới:**
```
Đọc file mới trong tech/ và tech/docs/ chưa có trong _index.md.
Thêm vào nhóm phù hợp với 1 dòng tóm tắt (rút từ heading + 2-3 dòng đầu).
Không sửa các entry sẵn có.
```

**Lint định kỳ (chạy hàng tháng):**
```
Đọc tech/docs/_index.md và toàn bộ note trong tech/, tech/docs/.
Báo cáo:
- Note có trên disk nhưng thiếu trong _index.md
- Entry trong _index.md trỏ tới file không tồn tại (sau migrate)
- Cặp note nội dung overlap đáng kể (chú ý: comparison + implementation cùng chủ đề là intentional split, KHÔNG phải overlap)
- Các nhóm phình to >5 entries — đề xuất tách nhóm
```

**Nguyên tắc:** AI **không** chỉnh sửa nội dung note gốc — chỉ maintain index + báo cáo. Người vẫn là tác giả; AI là librarian.

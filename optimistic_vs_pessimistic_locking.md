# So sánh Optimistic vs Pessimistic Locking trong thực tế

## 1️⃣ Pessimistic Locking (Row-level lock)

**Nguyên tắc:** Khóa row ngay khi đọc (`SELECT … FOR UPDATE`) → các session khác phải chờ lock được release.

**Khi dùng thực tế:**

| Case thực tế | Tại sao Pessimistic phù hợp |
|-------------|----------------------------|
| Rút tiền / trừ số dư tài khoản (withdraw) | Nhiều request cùng user có thể đồng thời → tránh balance âm |
| Cập nhật inventory / stock khi order nhiều bước | Nhiều worker update cùng product → tránh oversell |
| Booking hệ thống (hotel, vé máy bay) | Cần lock seat/room → tránh double booking |
| Multi-step financial transaction | Nhiều bảng cùng update → tránh deadlock logic phức tạp |
| Job backend / batch xử lý cùng record | Worker nhiều thread → tránh race condition |

**Ưu điểm:**

- An toàn tuyệt đối, không cần retry logic phức tạp  
- Logic dễ hiểu, dễ debug  
- Row-level lock native trong PostgreSQL  

**Nhược điểm:**

- Block request khác → có thể ảnh hưởng performance nếu lock lâu  
- Không phù hợp hệ thống read-heavy  

---

## 2️⃣ Optimistic Locking (Lock Version)

**Nguyên tắc:** Không lock row, chỉ check `lock_version` khi update → nếu version khác → raise `StaleObjectError`.

**Khi dùng thực tế:**

| Case thực tế | Tại sao Optimistic phù hợp |
|-------------|----------------------------|
| Update profile user (email, address) | Xung đột update hiếm → block không cần thiết |
| Comment / blog post / article | Nhiều người đọc, ít người update cùng lúc |
| Voting / rating / likes | Rare conflicts → performance tốt |
| Cập nhật metadata / setting chung | Xung đột hiếm, không ảnh hưởng critical resource |
| Collaborative document nhưng cho phép retry / merge | Conflict xảy ra → retry hoặc merge dễ dàng |

**Ưu điểm:**

- Không block user khác → phù hợp read-heavy  
- Tối ưu performance khi xung đột hiếm  
- Dễ scale, không ảnh hưởng transaction khác  

**Nhược điểm:**

- Phải handle `StaleObjectError` → retry hoặc show lỗi  
- Không phù hợp **critical resource / số dư** → dễ gây data inconsistency  

---

## 3️⃣ TL;DR

| Loại Locking | Khi dùng | Risk nếu dùng sai |
|-------------|----------|-----------------|
| **Pessimistic** | Critical resource, multi-step transaction, backend job nhiều thread | Block người dùng, performance giảm nếu lock lâu |
| **Optimistic** | Read-heavy, conflict hiếm, metadata update | Data inconsistency nếu không retry đúng |

# 📋 Database Schema: Khảo sát có Option "Khác" (Other) + Gift Reward

Thiết kế cho hệ thống survey trong game (hoặc bất kỳ app nào): user trả lời → nhận quà. Yêu cầu chính: hỗ trợ option "Khác (vui lòng ghi)" cho phép user nhập text tự do, nhưng vẫn giữ schema gọn để query thống kê.

---

## 1. 🎯 Yêu cầu thiết kế

| Yêu cầu | Ý nghĩa |
| :--- | :--- |
| **Question types** | `single_choice` (radio), `multi_choice` (checkbox), `free_text` (textarea) |
| **Option "Khác"** | Một choice trong danh sách cho phép user nhập text tự do — không phải tách thành câu hỏi riêng |
| **One-shot reward** | Mỗi user chỉ được nhận quà **1 lần** per survey |
| **Atomic grant** | Tránh race condition khi 2 request submit cùng lúc → grant quà 2 lần |
| **Audit-able** | Query được "Có bao nhiêu user chọn 'Khác' và họ ghi gì?" |

---

## 2. 🗂️ Schema (Postgres)

### 2.1. `surveys` — Định nghĩa survey

| Cột | Kiểu | Vai trò |
| :--- | :--- | :--- |
| **`id`** | `SERIAL PK` | |
| `title` | `TEXT` | Tiêu đề khảo sát |
| `description` | `TEXT` | Mô tả ngắn |
| `reward_kind` | `TEXT` | Mã reward, vd `'gold:100'`, `'cosmetic:dragon_skin'`, `'xp:500'` |
| `is_active` | `BOOLEAN` | Có đang chạy không |
| `starts_at` | `TIMESTAMPTZ` | Thời gian bắt đầu |
| `ends_at` | `TIMESTAMPTZ` | Thời gian kết thúc |

### 2.2. `survey_questions` — Câu hỏi trong survey

| Cột | Kiểu | Vai trò |
| :--- | :--- | :--- |
| **`id`** | `SERIAL PK` | |
| `survey_id` | `FK → surveys` | |
| `position` | `INT` | Thứ tự hiển thị |
| `prompt` | `TEXT` | Nội dung câu hỏi |
| `question_type` | `TEXT` | `'single_choice'` \| `'multi_choice'` \| `'free_text'` |
| `is_required` | `BOOLEAN` | User bắt buộc trả lời |

### 2.3. `survey_choices` — Các đáp án có sẵn

| Cột | Kiểu | Vai trò |
| :--- | :--- | :--- |
| **`id`** | `SERIAL PK` | |
| `question_id` | `FK → survey_questions` | |
| `position` | `INT` | Thứ tự hiển thị |
| `label` | `TEXT` | Vd: `"Rất hài lòng"`, `"Khác (vui lòng ghi)"` |
| **`allows_custom_text`** | `BOOLEAN` | ⭐ Cờ "Other" — true nếu choice này yêu cầu text tự do |

> 💡 **Key insight:** Cờ `allows_custom_text` nằm trên *choice*, không phải trên *question*. Nghĩa là 1 question có thể có 4 choices có sẵn + 1 choice "Khác" (cờ true). User chọn "Khác" → UI hiện textarea → ghi vào `custom_text` của answer row.

### 2.4. `survey_submissions` — Phiếu trả lời (header)

| Cột | Kiểu | Vai trò |
| :--- | :--- | :--- |
| **`id`** | `SERIAL PK` | |
| `survey_id` | `FK → surveys` | |
| `user_id` | `FK → users` | |
| `submitted_at` | `TIMESTAMPTZ` | |
| `reward_granted` | `BOOLEAN` | Quà đã được phát chưa |
| `reward_granted_at` | `TIMESTAMPTZ NULL` | Thời điểm phát quà |
| | | **`UNIQUE (survey_id, user_id)`** ⭐ chống double-claim ở DB level |

### 2.5. `survey_answers` — Từng đáp án cụ thể

| Cột | Kiểu | Vai trò |
| :--- | :--- | :--- |
| **`id`** | `SERIAL PK` | |
| `submission_id` | `FK → survey_submissions` | |
| `question_id` | `FK → survey_questions` | |
| `choice_id` | `FK → survey_choices NULL` | NULL khi `question_type = 'free_text'` |
| **`custom_text`** | `TEXT NULL` | ⭐ Populated khi: (a) choice có `allows_custom_text=true`, hoặc (b) question là `free_text` |

> 💡 `multi_choice` → nhiều answer rows per (submission, question), mỗi row 1 choice_id.

---

## 3. 🛡️ 3 Invariants App-Layer phải enforce

Postgres không enforce được — phải validate ở backend trước khi insert:

### Invariant 1: `custom_text` chỉ được populate đúng chỗ
```
custom_text NOT NULL ⟹ EITHER
  (a) survey_choices[choice_id].allows_custom_text = true
  OR
  (b) survey_questions[question_id].question_type = 'free_text'
```
Nếu vi phạm: phía client đang gửi text vào choice không cho phép → reject.

### Invariant 2: Số lượng answer rows phù hợp question_type
| `question_type` | Số rows per question | `choice_id` | `custom_text` |
| :--- | :--- | :--- | :--- |
| `single_choice` | đúng 1 | NOT NULL | NULL hoặc text (nếu cờ Other) |
| `multi_choice` | ≥1 | NOT NULL each | NULL hoặc text per row |
| `free_text` | đúng 1 | NULL | NOT NULL |

### Invariant 3: Reward grant phải atomic
```sql
BEGIN;
  INSERT INTO survey_submissions (...) VALUES (...) RETURNING id;
  INSERT INTO survey_answers (...) VALUES (...), (...), ...;
  UPDATE survey_submissions SET reward_granted = true, reward_granted_at = NOW()
    WHERE id = $1;
  -- Gọi service phát quà (grant gold, cosmetic, etc.) trong cùng transaction
  -- nếu service idempotent thì có thể gọi ngoài transaction + retry
COMMIT;
```

`UNIQUE (survey_id, user_id)` ở table sẽ throw lỗi nếu có race condition → backend bắt lỗi `unique_violation` và return "đã làm rồi".

---

## 4. 🔍 Query patterns hữu ích

### 4.1. Đếm câu trả lời "Khác" và xem text user ghi
```sql
SELECT sa.custom_text, COUNT(*) AS occurrences
FROM survey_answers sa
JOIN survey_choices sc ON sa.choice_id = sc.id
WHERE sc.allows_custom_text = true
  AND sa.custom_text IS NOT NULL
  AND sa.question_id = $question_id
GROUP BY sa.custom_text
ORDER BY occurrences DESC;
```

### 4.2. Phân phối lựa chọn cho 1 câu hỏi
```sql
SELECT sc.label, COUNT(sa.id) AS picks
FROM survey_choices sc
LEFT JOIN survey_answers sa ON sa.choice_id = sc.id
WHERE sc.question_id = $question_id
GROUP BY sc.id, sc.label
ORDER BY sc.position;
```

### 4.3. List user chưa nhận quà sau khi submit (lỗi grant?)
```sql
SELECT user_id, submitted_at
FROM survey_submissions
WHERE survey_id = $survey_id
  AND reward_granted = false
  AND submitted_at < NOW() - INTERVAL '5 minutes';
```

---

## 5. 🔄 Alternatives đã cân nhắc

### 5.1. Tách "Khác" thành 1 question riêng (free_text follow-up)
- ✅ Schema đơn giản hơn, không cần `allows_custom_text` flag
- ❌ UI phải có logic conditional display ("nếu chọn X ở câu trên thì show câu này")
- ❌ Người trả lời nhìn thấy 2 câu thay vì 1 — UX không tự nhiên

### 5.2. Polymorphic response (1 bảng, type discriminator)
- ✅ Schema duy nhất cho mọi loại trả lời
- ❌ Query phức tạp (CASE/UNION nhiều); validation phía app dày
- 👉 Chỉ nên dùng nếu có thật nhiều loại response (rating sao, ranking, drag-and-drop)

### 5.3. Choice templates dùng chung giữa surveys
Vd: "Bạn ở khu vực nào?" dùng cùng list 63 tỉnh thành cho 5 surveys khác nhau.
- ✅ Tránh duplicate hàng trăm rows
- ❌ Overengineering nếu mỗi survey độc lập
- 👉 Chỉ thêm khi đã có thực tế reuse

---

## 6. 🎁 Lưu ý về Reward Delivery

Nếu reward là **in-game item** (gold, skin, multiplier):
- Service grant phải **idempotent** — gọi 2 lần với cùng `submission_id` chỉ phát 1 lần. Có thể dùng `submission_id` làm idempotency key.
- Nếu service grant **bên ngoài transaction submit**: dùng outbox pattern hoặc background reconcile job (query `reward_granted=false` cũ hơn N phút và retry).

Nếu reward là **mã giảm giá / coupon code** dùng 1 lần:
- Bảng `reward_codes` có cột `assigned_to_submission_id NULL UNIQUE` — atomic SELECT FOR UPDATE rồi UPDATE để claim 1 mã chưa được dùng.

---

## 7. 🏷️ Identity Strategy (lưu ý quan trọng cho game không có account)

`user_id` trong schema giả định **đã có user identity bền vững**. Game không có account login phải chọn 1 trong 3:

| Cấp độ | Identity | Trade-off |
| :--- | :--- | :--- |
| **Yếu** | Device ID (Android `ANDROID_ID`, iOS `identifierForVendor`) | User reset device hoặc đổi máy → claim được nhiều lần |
| **Trung** | Server-issued `user_id` lưu SharedPreferences/Keychain + secret token | Reinstall app = mất ID, vẫn fakeable |
| **Mạnh** | Account login (email / OAuth) | Chống mọi gian lận; nhưng dựng auth = scope lớn |

Cấp độ chọn ảnh hưởng trực tiếp **mức độ user có thể game-the-system để nhận quà nhiều lần**. Quà càng giá trị → identity phải càng chặt.

---

## 📌 Tóm tắt

- 5 bảng: `surveys` → `survey_questions` → `survey_choices` → `survey_submissions` → `survey_answers`
- Cờ **`allows_custom_text`** nằm trên *choice*, không phải *question*
- **`UNIQUE (survey_id, user_id)`** trên submissions = chống double-claim ở DB level
- 3 invariants enforce ở app layer (custom_text validity, answer count, atomic grant)
- Identity strategy là **gating concern** trước cả schema — chốt mức độ chặt trước khi code

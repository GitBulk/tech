Payment Integrity & Distributed Logic (v1.0)
============================================

**Tài liệu kế thừa và phát triển từ Cache Stampede v1.4**

1\. Tầm nhìn & Mục tiêu
-----------------------

Tài liệu này xác lập quy trình xử lý giao dịch tài chính (Payment/Bank Transfer/Inventory) dựa trên nguyên tắc **Tính đúng đắn tuyệt đối (Absolute Correctness)** thay vì chỉ ưu tiên hiệu năng.

|Thành phần         |Old Logic   |Nova AI Refactor (Final)        |Lý do                                                      |
|-------------------|-------------------------|--------------------------------|-----------------------------------------------------------|
|Idempotency Key    |UUID + Business Hash     |Giữ nguyên                      |Đây là bộ định danh chuẩn.                             |
|Concurrency Control|Global Redis Lock        |Local Coalescing + DB Constraint|Loại bỏ nguy cơ "Single Point of Failure" và Zombie Lock.  |
|Atomic Operation   |SQL Transaction đơn thuần|Transactional Outbox            |Đảm bảo tính nhất quán giữa Database và Message Bus.       |
|Race Condition     |Check-and-set            |Fencing Token (Monotonic)       |Chặn đứng hoàn toàn các xử lý "thây ma" (Zombie Processes).|
|Error Recovery     |Retry đơn thuần          |Saga + Inquiry Logic            |Tự động đối soát trạng thái mơ hồ với Ngân hàng.           |

Kiến trúc:
1. Lớp bảo vệ (L1): EphemeralCoalescer gộp request, chống Stampede trên Mac M3.
2. Lớp định danh: UUID + Business Hash để định danh chính xác ý đồ người dùng.
3. Lớp nguyên tử: Postgres Transactional Outbox đảm bảo dữ liệu không bao giờ thất lạc.
4. Lớp điều phối: Saga Pattern xử lý giao dịch phân tán.
5. Lớp bảo mật: Fencing Token chặn đứng các luồng xử lý "thây ma" (Zombie processes).
6. Lớp đối soát: Inquiry Logic giải quyết các trạng thái mơ hồ.


2\. Phản biện Global Redis Distributed Lock
-------------------------------------------

Dựa trên Cache Stampede v1.4, quyết định **loại bỏ** ý định sử dụng Redis Distributed Lock mức Global vì các lý do sau:

*   **Rủi ro Clock Drift:** Redis dựa trên TTL thời gian hệ thống, trong môi trường Global, sự lệch múi giờ/mili giây có thể dẫn đến release lock sớm.
    
*   **Vấn đề Zombie Lock:** Nếu Worker chiếm lock rồi bị treo (GC Pause), lock vẫn tồn tại nhưng không có xử lý thực tế, gây nghẽn hệ thống.
    
*   **Tính nhất quán yếu:** Redis là hệ thống AP (CAP Theorem). Trong trường hợp Failover, dữ liệu lock có thể bị mất, dẫn đến Double Spending.
    
*   **Bottleneck:** Lock global tạo ra điểm thắt nút cổ chai, làm mất đi ý nghĩa của kiến trúc phân tán Saga.
    

3\. Kiến trúc Đề xuất (The Shield of Integrity)
-----------------------------------------------

### A. Định danh (Identification)

Sử dụng tổ hợp Key để định danh duy nhất một ý đồ giao dịch:

*   **Client UUID:** Chống retry do lỗi mạng/UI.
    
*   **Business Hash:** vd: Hash(UserID + MerchantID + OrderID + Amount + Currency). Chống gian lận hoặc lỗi logic từ phía Client.
    

### B. Lớp bảo vệ (Protection)

*   **L1 - EphemeralCoalescer:** Gộp các request trùng lặp tại tầng RAM của Web Server (kỹ thuật từ v1.4).
    
*   **L2 - DB Unique Constraint:** Dùng Postgres làm "Source of Truth" cuối cùng thay cho Redis Lock.
    

### C. Cơ chế Fencing Token "Vượt biên" (External Side-effects) & Transactional Outbox

*   **Vấn đề:** Ngân hàng/Provider không biết Fencing Token là gì.
*   **Giải pháp:** Đính kèm Fencing Token vào Idempotency Key gửi đi.
*   **Công thức:** External_Idempotency_Key = {Saga_ID}_{Fencing_Token}.
*   **Kết quả:** Nếu một Zombie Worker gửi lệnh cũ, Ngân hàng nhận diện Key cũ và trả về kết quả đã xử lý (idempotent response) thay vì thực hiện giao dịch mới.
* Đảm bảo tính nguyên tử và chặn đứng các tiến trình "thây ma" (Zombie Processes).

### D. Cơ chế Hồi phục (Self-healing Inquiry)
- Không bao giờ để giao dịch ở trạng thái "Treo".
- Nếu gặp lỗi mạng (Ambiguous), chuyển sang pending_inquiry.
- Sử dụng InquiryWorker để chủ động hỏi trạng thái từ Provider thay vì đợi Client retry.

4\. Code Sample & SQL Schema
----------------------------

### 4.1 SQL Schema (PostgreSQL)

```sql
-- Bảng trạng thái Saga (State Machine)
CREATE TABLE saga_states (
    id UUID PRIMARY KEY,
    idempotency_key UUID NOT NULL,
    business_hash VARCHAR(64) NOT NULL,
    status VARCHAR(50) NOT NULL, -- 'started', 'step_completed', 'pending_inquiry', 'failed'
    current_fencing_token BIGINT DEFAULT 1,
    payload JSONB,
    response JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(idempotency_key, business_hash)
);

-- Bảng Transactional Outbox
CREATE TABLE outbox (
    id BIGSERIAL PRIMARY KEY,
    saga_id UUID REFERENCES saga_states(id),
    event_type VARCHAR(100),
    payload JSONB,
    fencing_token BIGINT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_outbox_fencing ON outbox(saga_id, fencing_token);
```

### 4.2 Logic xử lý chính (Saga Orchestrator + Fencing)
```ruby
def generate_business_hash(params)
  return Digest::SHA256.hexdigest(
    "#{payment_params[:user_id]}:#{payment_params[:order_id]}:#{payment_params[:amount]}"
  )
end

def process_payment_saga(client_uuid, params)
  # 1. Sinh Business Hash
  business_hash = generate_business_hash(params)
  composite_key = "#{client_uuid}:#{business_hash}"

  # 2. L1 Coalescing (từ v1.4)
  COALESCER.fetch(composite_key) do
    ActiveRecord::Base.transaction do
      # 3. DB Atomic Guard - Thay thế Global Lock
      saga = SagaState.find_or_create_by!(
        idempotency_key: client_uuid,
        business_hash: business_hash
      ) do |s|
        s.status = 'started'
        s.payload = params
      end

      return saga.response if saga.status == 'completed'

      # 4. Fencing Token - Tăng version mỗi lần retry/tiếp quản
      new_token = saga.current_fencing_token + 1
      
      # 5. Giao dịch & Outbox (Atomic)
      begin
        # Gọi sang bên thứ 3 hoặc trừ tiền
        # Lưu ý: Pass idempotency_key + token cho Provider nếu cần
        external_key = "#{saga.id}:#{new_token}"
        result = BankGateway.execute(params, idempotency_key: external_key)
        
        saga.update!(
          status: 'step_completed',
          current_fencing_token: new_token,
          response: result
        )

        # Ghi Outbox để trigger bước tiếp theo (Inventory...)
        Outbox.create!(
          saga_id: saga.id,
          event_type: 'PAYMENT_SUCCESS',
          payload: result,
          fencing_token: new_token
        )
      rescue Net::ReadTimeout, Net::OpenTimeout => e
        # Chuyển sang Inquiry Mode nếu trạng thái mờ hồ
        saga.update!(status: 'pending_inquiry', current_fencing_token: new_token)
        InquiryWorker.perform_async(saga.id)
        # "Ambiguous State: Inquiry Started"
        raise e
      end
    end
  end
end
```

### 4.3 Inquiry Logic (Hồi phục trạng thái)
```ruby
class InquiryWorker
  def perform(saga_id)
    saga = SagaState.find(saga_id)
    return if saga.status != 'pending_inquiry'

    # Tăng token để "Fence" các worker cũ
    inquiry_token = saga.current_fencing_token + 1

    # Hỏi trạng thái thực tế từ ngân hàng bằng chính idempotency key cũ
    external_status = BankGateway.inquire(saga.idempotency_key)

    ActiveRecord::Base.transaction do
      # Chỉ update nếu chưa có worker nào mới hơn can thiệp
      affected = SagaState.where(id: saga_id)
                          .where('current_fencing_token < ?', inquiry_token)
                          .update_all(
                            status: map_status(external_status),
                            current_fencing_token: inquiry_token
                          )

      if affected > 0 && external_status == 'success'
        create_outbox_event(saga, inquiry_token)
      end
    end
  end
end
```

Trong một hệ thống thực tế, InquiryWorker hoạt động như một "Lưới an toàn" (Safety Net) thông qua 2 cơ chế:

1. Cơ chế 1: Event-Driven (Trigger ngay khi có lỗi)
Khi luồng chính (Main Flow) gọi sang Ngân hàng và gặp lỗi Timeout hoặc Network Error, nó sẽ chuyển trạng thái sang pending_inquiry và bắn một message vào Queue (ví dụ: Sidekiq hoặc RabbitMQ) để Worker xử lý ngay lập tức.

2. Cơ chế 2: Scheduled Scan (Quét định kỳ - Chống lọt lưới)
Đây là cơ chế quan trọng nhất để xử lý các ca mà ngay cả Queue cũng bị sập. Một Cron Job sẽ chạy mỗi phút một lần để tìm các Saga bị kẹt.

Tại luồng xử lý chính (Main Flow):
```ruby
begin
  result = BankGateway.execute(params)
  # ... xử lý thành công ...
rescue Net::ReadTimeout, Net::OpenTimeout => e
  # KHI GẶP LỖI MẠNG: Không được báo Fail ngay, mà chuyển sang trạng thái chờ đối soát
  saga.update!(status: 'pending_inquiry')
  
  # Trigger InquiryWorker ngay lập tức để xử lý "nóng"
  InquiryWorker.perform_async(saga.id) 
end
```

Tại tầng Scheduler (Cron Job):
```ruby
# Chạy mỗi 1-5 phút một lần để quét các Saga bị "mồ côi"
class SagaRecoveryScheduler
  def perform
    SagaState.where(status: 'pending_inquiry')
             .where('updated_at < ?', 2.minutes.ago) # Tránh tranh chấp với worker đang chạy nóng
             .find_each do |saga|
      InquiryWorker.perform_async(saga.id)
    end
  end
end
```

5\. Kết luận & Quyết định
-------------------------

1.  **Reuse:** Sử dụng phương pháp sinh Idempotency Key của tác giả Tuấn Hiệp.
    
2.  **Remove:** Xóa bỏ toàn bộ Logic SETNX hoặc Redis Lock mức global cho tiền tệ.
    
3.  **Implement:**
    
    *   Sử dụng **Fencing Token** cho mọi bước ghi dữ liệu.
        
    *   Sử dụng **Transactional Outbox** để liên lạc giữa các microservices.
        
    *   Sử dụng **Inquiry Worker** để giải quyết trạng thái Ambiguous.
        
4.  **Next Step:** Phát triển **Adaptive Rate Limiting** tại Gateway để chặn Retry Storm dựa trên trạng thái của Saga.

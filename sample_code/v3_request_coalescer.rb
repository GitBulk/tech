
# Trong bản cập nhật V3, bổ sung thêm GRACE_PERIOD, Lý do:
# - Vấn đề: Nếu fetch_from_db chạy rất nhanh (ví dụ 10ms) nhưng request burst kéo dài 50ms. Request đầu tiên xong sẽ xóa in_flight[key]. Request thứ 2 đến ở ms thứ 15 sẽ lại tạo một Promise mới và chọc vào DB tiếp.
# - Giải pháp: Để tối ưu hơn, sau khi promise hoàn thành, ta có thể giữ entry đó trong in_flight thêm một khoảng thời gian cực ngắn (ví dụ 100-200ms) để các request đến sau "hút" nốt kết quả thay vì chọc DB lần nữa.

require "concurrent"

class V3::RequestCoalescer
  DEFAULT_TIMEOUT = 2
  # nếu promise chết hoặc thread crash, entry sẽ bị dọn
  DEFAULT_TTL = 5

  # Chống việc 10k keys miss cùng lúc → in_flight map phình to → memory leak
  DEFAULT_MAX_ENTRIES = 1000

  Entry = Struct.new(:promise, :created_at, :completed_at)

  def initialize(timeout: DEFAULT_TIMEOUT, ttl: DEFAULT_TTL, max_entries: DEFAULT_MAX_ENTRIES, grace_period: 0.2)
    @timeout = timeout
    @ttl = ttl
    @max_entries = max_entries
    @grace_period = grace_period
    @in_flight = {}
    @mutex = Mutex.new

    # Background Thread để dọn dẹp định kỳ, tách biệt hoàn toàn với luồng xử lý request của user.
    start_background_cleanup
  end

  def fetch(key, stale_data = nil)
    entry = nil

    @mutex.synchronize do
      # Không quét toàn bộ. Chỉ check key cụ thể hoặc dọn dẹp xác suất cực thấp.
      entry = @in_flight[key]

      # Kiểm tra xem entry cũ đã "thực sự" hết hạn chưa (bao gồm cả grace period)
      if entry && expired?(entry)
        @in_flight.delete(key)
        entry = nil
      end

      unless entry
        guard_capacity # Dọn dẹp cục bộ nếu quá tải

        promise = Concurrent::Promise.execute { yield }
        entry = Entry.new(promise, Time.now.to_f, nil)
        @in_flight[key] = entry
      end
    end

    begin
      # có timeout, tránh việc DB query bị treo → thread chờ vô hạn
      result = entry.promise.value(@timeout)

      # Đánh dấu thời điểm hoàn thành để tính grace period
      entry.completed_at = Time.now.to_f if entry.promise.fulfilled? && entry.completed_at.nil?

      # Xử lý lỗi từ Promise
      if entry.promise.rejected?
        raise entry.promise.reason
      end

      result
    rescue => e
      # Nếu có dữ liệu cũ (stale data), ưu tiên trả về để cứu hệ thống
      return stale_data if stale_data
      raise e
    end
  end

  private

  def expired?(entry)
    now = Time.now.to_f
    # Nếu chưa xong: check theo TTL gốc
    return (now - entry.created_at > @ttl) if entry.completed_at.nil?

    # Nếu đã xong: cho phép tồn tại thêm một khoảng grace_period
    now - entry.completed_at > @grace_period
  end

  def guard_capacity
    # ta xóa ngẫu nhiên hoặc xóa vài key đầu tiên
    # Trong Ruby, Hash duy trì thứ tự chèn, nên shift/first là key cũ nhất (O(1))
    # shift sẽ Xóa entry cũ nhất một cách nhanh chóng
    @in_flight.shift if @in_flight.size >= @max_entries
  end

  def start_background_cleanup
    # Thread này khởi tạo 1 lần duy nhất khi Coalescer được tạo ra
    Thread.new do
      loop do
        begin
          # Ngủ một khoảng thời gian bằng TTL để không chiếm dụng CPU
          sleep(@ttl)

          @mutex.synchronize do
            before_count = @in_flight.size
            # Dọn dẹp tất cả các entry đã quá hạn trong Hash của Ruby
            @in_flight.delete_if { |_, entry| expired?(entry) }

            # (Optional) Log để theo dõi trong môi trường development
            # puts "[Cleanup] Removed #{before_count - @in_flight.size} leaked entries."
          end
        rescue => e
          warn "[Coalescer Cleanup Error] #{e.message}"
        end
      end
    end.tap do |t|
      # ruby 2.5+ support report_on_exception, thế thread crash thì in stacktrace ra STDERR, nhưng process vẫn chạy.
      t.report_on_exception = true
      t.name = "coalescer-cleanup"
    end
  end
end

require 'concurrent'
require 'concurrent/map'

# EphemeralCoalescer: Cơ chế gộp request (Coalescing) với vòng đời tự hủy.
# Giúp bảo vệ Database khỏi tình trạng Cache Stampede và tối ưu hóa tài nguyên RAM.
class EphemeralCoalescer

  # Cửa sổ thời gian (giây) để reuse kết quả sau khi xong
  # đây là grace_period, vd: 1000 request đến ở giây thứ 1.0 (được gộp), và 1 request khác đến ở giây thứ 1.1 (ngay sau khi request trước vừa xong), thì request sau được hưởng ké grace_period
  WINDOW = 0.1

  # Entry mang tính chất tạm thời, tự quản lý thời điểm hết hạn
  Entry = Struct.new(:promise, :expires_at)

  def initialize(redis, redis_ttl, timeout = 2.0)
    @map = Concurrent::Map.new
    @redis = redis
    @timeout = timeout
    @redis_ttl = redis_ttl
  end

  def fetch(key, stale_data = nil)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    entry = @map[key]

    # --- FAST PATH: Reuse kết quả nếu còn trong cửa sổ WINDOW ---
    if entry && entry.expires_at > now
      return entry.promise.value(@timeout)
    end

    # --- SLOW PATH: Atomic Coalescing ---
    is_new = false
    entry = @map.compute(key) do |_, old|
      if old && old.expires_at > now
        old
      else
        is_new = true
        # Chỉ khởi tạo Promise thực thi yield khi chắc chắn cần tạo mới
        promise = Concurrent::Promise.execute { yield }
        Entry.new(promise, Float::INFINITY)
      end
    end

    # Nếu là thread "chiến thắng", thiết lập cơ chế tự hủy (Self-destruct)
    attach_cleanup(key, entry) if is_new

    # Đợi kết quả với chốt chặn Timeout
    result = entry.promise.value(@timeout)

    # Xử lý Timeout: result nil và promise vẫn đang pending
    if result.nil? && entry.promise.pending?
      # record_error, airbrake if needed
      return stale_data if stale_data
      raise "Request Timeout: Resource busy or Database slow."
    end

    # Xử lý lỗi bên trong logic nghiệp vụ (yield)
    if entry.promise.rejected?
      # record_error, airbrake if needed
      return stale_data if stale_data
      raise entry.promise.reason
    end
    result
  end

  private

  def attach_cleanup(key, entry)
    entry.promise.on_resolution do
      # Xong việc: Thiết lập thời điểm hết hạn thực tế
      entry.expires_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WINDOW

      # Hẹn giờ: Xóa entry khỏi Map sau đúng khoảng WINDOW
      Concurrent::ScheduledTask.execute(WINDOW) do
        @map.delete_pair(key, entry)
      end
    end
  end
end
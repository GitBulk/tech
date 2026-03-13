
# Mục tiêu:
# ```
# thread-safe
# không memory leak
# không in-flight explosion
# có timeout
# có cleanup TTL
# ```
# Thiết kế:
# ```
# RequestCoalescer
#  ├── in_flight map
#  ├── TTL cho entry
#  ├── max_entries guard
#  └── promise timeout
# ```

require "concurrent"

class V2::RequestCoalescer
  DEFAULT_TIMEOUT = 2
  # nếu promise chết hoặc thread crash, entry sẽ bị dọn
  DEFAULT_TTL = 5

  # Chống việc 10k keys miss cùng lúc → in_flight map phình to → memory leak
  DEFAULT_MAX_ENTRIES = 1000

  Entry = Struct.new(:promise, :created_at)

  def initialize(timeout: DEFAULT_TIMEOUT, ttl: DEFAULT_TTL, max_entries: DEFAULT_MAX_ENTRIES)
    @timeout = timeout
    @ttl = ttl
    @max_entries = max_entries

    @in_flight = {}
    @mutex = Mutex.new
  end

  def fetch(key)
    entry = nil

    @mutex.synchronize do
      cleanup_expired

      entry = @in_flight[key]

      unless entry
        guard_capacity

        promise = Concurrent::Promise.execute { yield }
        entry = Entry.new(promise, Time.now.to_f)

        @in_flight[key] = entry
      end
    end

    begin
      # có timeout, tránh việc DB query bị treo → thread chờ vô hạn
      entry.promise.value(@timeout)
    ensure
      cleanup_key(key, entry)
    end
  end

  private

  def cleanup_key(key, entry)
    @mutex.synchronize do
      if @in_flight[key] == entry
        @in_flight.delete(key)
      end
    end
  end

  def cleanup_expired
    now = Time.now.to_f

    @in_flight.delete_if do |_, entry|
      now - entry.created_at > @ttl
    end
  end

  def guard_capacity
    if @in_flight.size >= @max_entries
      # fallback strategy: xóa entry cũ nhất
      oldest = @in_flight.min_by { |_, e| e.created_at }
      @in_flight.delete(oldest[0]) if oldest
    end
  end
end

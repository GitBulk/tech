require "concurrent"

class RequestCoalescer
  def initialize
    @in_flight = {}
    @mutex = Mutex.new
  end

  def fetch(key)
    promise = nil

    @mutex.synchronize do
      promise = @in_flight[key]

      unless promise
        promise = Concurrent::Promise.execute do
          yield
        end

        @in_flight[key] = promise
      end
    end

    begin
      promise.value
      # or timeout 2s
      # promise.value(2)
    ensure
      cleanup(key, promise)
    end
  end

  private

  def cleanup(key, promise)
    @mutex.synchronize do
      # chỉ xóa nếu promise vẫn là cái đang lưu
      @in_flight.delete(key) if @in_flight[key] == promise
    end
  end
end

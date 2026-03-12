# Xử lý Cache Stampede -- v1.0

Cache Stampede không chỉ là cache miss, dẫn đến hoàng loạt request đổ thẳng vào DB, mà là sự kết hợp của: Key cực hot + Thời gian tính toán (recomputation) lâu + Nhiều request đồng thời (high concurrency)

## Roadmap:
- **v1.0:**  Init doc, TTL Jitter, distributed lock

## 1. TTL Jitter (Randomized Expiration)
Đây là kỹ thuật đơn giản nhất.

Thay vì TTL cố định như: TTL = 60s

Ta thêm random: TTL = 60 + rand(0..10)

Điều này giúp phân tán thời điểm expire.

Ruby example:
```ruby
def cache_write(key, value, base_ttl)
  jitter = rand(0..10)
  ttl = base_ttl + jitter

  $redis.set(key, value.to_json, ex: ttl)
end
```

Ưu điểm:
- cực đơn giản
- giảm expire đồng loạt

Nhược điểm:
- không bảo vệ DB hoàn toàn

## 2. Khóa phân tán (Distributed Locking)
Khi cache miss, chỉ cho phép một request rebuild cache. Các request khác chờ.

- **Ưu điểm:** Bảo vệ database tuyệt đối khỏi việc bị quá tải bởi các query trùng lặp.
- **Nhược điểm:** Tăng độ trễ (latency) cho những người dùng phải đứng đợi khóa được giải phóng.

Flow:
```
read cache, but cache miss
    ↓
acquire lock
    ↓
read cache again
    ↓
fetch DB
    ↓
update cache
    ↓
release lock
```

Ruby sample code (v1.0):
```ruby
def get_data_with_lock_refined(key)
  data = $redis.get(key)
  return JSON.parse(data) if data

  lock_key = "lock:#{key}"
  acquired = false

  begin
    # Bước 1: Thử lấy lock
    acquired = $redis.set(lock_key, "true", nx: true, ex: 5)

    if acquired
      puts "Lock acquired! Fetching from DB..."
      data = fetch_from_db() # Giả sử hàm này có thể văng Exception
      $redis.set(key, data.to_json, ex: 60)
      return data
    else
      # Bước 2: Không có lock thì đợi và thử lại
      sleep(0.1)
      return get_data_with_lock_refined(key)
    end
  rescue => e
    puts "Error occurred: #{e.message}"
    raise e # Re-raise để layer trên xử lý
  ensure
    # Bước 3: Chỉ giải phóng nếu chính mình là người giữ lock
    $redis.del(lock_key) if acquired
  end
end
```

Hàm get_data_with_lock_refined ở v1.0 có khuyết điểm:

`Vấn đề 1 — recursive retry`
```ruby
sleep(0.1)
return get_data_with_lock_refined(key)
```

Nếu traffic cao:
```
1000 request
↓
999 request retry
↓
recursive stack
```
=> nguy cơ stack overflow

Production nên:
```ruby
loop do
  data = redis.get(key)
  return data if data

  if acquire_lock
     break
  end

  sleep jitter
end
```

`Vấn đề 2 — lock release nguy hiểm`

```ruby
$redis.del(lock_key)
```

Distributed lock không bao giờ được delete lock trực tiếp.

Case nguy hiểm:
```
process A lấy lock
lock expire
process B lấy lock
process A finish -> del(lock)

=> A xóa lock của B
```

Giải pháp chuẩn: lock value phải là unique token
```
SET lock_key uuid NX PX 5000
```

release bằng Lua:
```lua
if redis.get(lock_key) == uuid
  redis.del(lock_key)
end
```

Đây là pattern chuẩn Redis distributed lock.

`Vấn đề 3 — busy wait`
```ruby
sleep(0.1)
```
Nếu 1000 request -> 1000 × polling

Production thường dùng: **exponential backoff + jitter**
```
sleep(rand * base * 2**retry)
```

Ruby sample code (v1.1):
```ruby
class RedisCacheStampede
  DEFAULT_CACHE_TTL = 60
  LOCK_TTL = 5

  def initialize(redis)
    @redis = redis
  end

  def fetch(key, max_retry: 5)
    # lock:{key}, {key}
    # Hash Tags {...} trong key name để đảm bảo các key liên quan nằm cùng một shard
    # tránh lỗi CROSSSLOT Keys in request don't hash to the same slot
    safe_key = "{#{key}}"
    lock_key = "lock:#{safe_key}"
    fencing_key = "fencing:#{safe_key}"

    cached = @redis.get(safe_key)
    return JSON.parse(cached) if cached

    base_sleep = 0.05

    max_retry.times do |attempt|
      token = @redis.incr(fencing_key)
      @redis.expire(fencing_key, 86400)

      if acquire_lock(lock_key, token)
        return handle_lock_owner(safe_key, lock_key, fencing_key, token)
      end

      cached = @redis.get(safe_key)
      return JSON.parse(cached) if cached

      sleep(base_sleep * (2**attempt) + rand(base_sleep))
    end

    fallback
  end

  private

  def acquire_lock(lock_key, token)
    @redis.set(lock_key, token, nx: true, ex: LOCK_TTL)
  end

  def handle_lock_owner(cache_key, lock_key, fencing_key, token)
    begin
      # Double check
      cached = @redis.get(cache_key)
      return JSON.parse(cached) if cached

      data = fetch_from_db

      write_cache_with_fencing(cache_key, lock_key, fencing_key, token, data)

      data
    ensure
      release_lock(lock_key, token)
    end
  end

  def write_cache_with_fencing(cache_key, lock_key, fencing_key, token, data)
  script = <<~LUA
    local lock_value = redis.call("get", KEYS[1])

    if lock_value ~= ARGV[1] then
      return 0
    end

    local last_token = redis.call("get", KEYS[3])

    if (not last_token) or tonumber(ARGV[2]) > tonumber(last_token) then
      redis.call("set", KEYS[2], ARGV[3], "ex", ARGV[4])
      redis.call("set", KEYS[3], ARGV[2])
      return 1
    end

    return 0
  LUA

  @redis.eval(
    script,
    keys: [lock_key, cache_key, fencing_key],
    argv: [token.to_s, token.to_s, data.to_json, DEFAULT_CACHE_TTL]
  )
end

  def release_lock(lock_key, token)
    script = <<~LUA
      if redis.call("get", KEYS[1]) == ARGV[1]
      then
        return redis.call("del", KEYS[1])
      else
        return 0
      end
    LUA

    @redis.eval(script, keys: [lock_key], argv: [token])
  end

  def fetch_from_db
    # user implement
    raise NotImplementedError
  end

  def fallback
    # graceful degradation
    nil
  end
end
```

`Note`

- Mặc dù distributed lock là một cách phổ biến để giảm hiện tượng cache stampede bằng cách đảm bảo chỉ một tiến trình chịu trách nhiệm tái tạo dữ liệu cache tại một thời điểm, cách tiếp cận này vẫn tồn tại nhiều hạn chế trong môi trường hệ thống phân tán.

- Việc sử dụng lock làm tăng độ phức tạp của hệ thống, tạo thêm độ trễ do lock contention và cơ chế retry, đồng thời vẫn không thể đảm bảo tính loại trừ tuyệt đối trong một số tình huống lỗi như GC pause, process crash, hoặc Redis failover.

- Trong thực tế vận hành ở quy mô lớn, những rủi ro và chi phí vận hành này khiến distributed lock trở thành một giải pháp không hoàn toàn lý tưởng. Vì vậy, nhiều hệ thống hiện đại đã chuyển sang các kỹ thuật lock-free như Probabilistic Early Expiration, cho phép giảm đáng kể nguy cơ cache stampede mà không cần dựa vào cơ chế distributed lock phức tạp.

- Chỉ nên dùng distributed lock với Redis cho trường hợp efficiency lock như: cache rebuild, cron dedup, background job, vì trong trường hợp xấu nhất chỉ là duplicate work. Còn đối với hệ thống cần correctness lock (KHÔNG nên dùng Redis) như: bank transfer, inventory deduction, distributed transaction thì nên dùng consensus system

`Các Gem nổi tiếng`
- redlock-rb (implement Redlock algorithm)
- redis_queued_locks
- Redis::Lock

## 3. Sớm cập nhật cache (Probabilistic Early Recomputation)
Thay vì đợi cache hết hạn rồi mới load lại, hệ thống sẽ tính toán khả năng cần làm mới cache dựa trên một thuật toán xác suất khi thời gian hết hạn (TTL) sắp đến.
- **Cách hoạt động:** Một request bất kỳ khi đọc cache sẽ thực hiện một phép tính ngẫu nhiên. Nếu "trúng thưởng", request đó sẽ chủ động đi cập nhật database sớm vài giây trước khi cache thực sự chết.
- **Công thức gợi ý:** $P(recompute) = e^{-\Delta \cdot \beta / (TTL - now)}$ (với $\Delta$ là thời gian tính toán, $\beta$ là hệ số điều chỉnh).

Ruby sample code:
```ruby
def get_data_probabilistic(key, ttl, beta = 1.0)
  cached_item = $redis.hgetall(key) # Giả sử lưu hash: { "data" => "...", "expiry" => "..." }

  now = Time.now.to_f
  data = JSON.parse(cached_item["data"])
  expiry = cached_item["expiry"].to_f # Thời điểm hết hạn thực tế

  # Công thức X-Fetch: ngẫu nhiên hóa việc fetch lại dựa trên thời gian còn lại
  # gap = thời gian thực thi (giả sử 50ms)
  gap = 0.05
  if now - (gap * beta * Math.log(rand)) >= expiry
    puts "Probabilistic hit! Refreshing early..."
    new_data = fetch_from_db()
    save_to_cache(key, new_data, ttl)
    return new_data
  end

  data
end
```

## 3. Gia hạn thời gian ảo (Soft Expiration)
Bạn lưu trữ dữ liệu trong cache kèm theo một mốc thời gian "hết hạn mềm".
- Quy trình: Khi một request thấy dữ liệu đã quá hạn mềm nhưng vẫn còn trong cache (chưa đến hạn cứng), nó sẽ trả về dữ liệu cũ ngay lập tức cho người dùng, đồng thời âm thầm (asynchronous) gửi một task đi cập nhật database.
- Kết quả: Người dùng luôn thấy dữ liệu nhanh (dù có thể hơi cũ một chút), và database không bao giờ bị dội bom.

Ruby sample code:
```ruby
def get_data_soft_expiry(key)
  cached = JSON.parse($redis.get(key))

  if Time.now.to_i > cached["soft_expiry"]
    # Đẩy vào Sidekiq/Resque để cập nhật ngầm
    puts "Soft expired! Triggering background update..."
    CacheUpdateWorker.perform_async(key)
  end

  # Luôn trả về dữ liệu ngay lập tức (có thể hơi cũ)
  cached["data"]
end
```

## 4. Background Refresh (Cron jobs)
Thay vì để request của người dùng kích hoạt việc cập nhật cache (Passive), bạn chủ động cập nhật cache theo định kỳ bằng một tiến trình chạy ngầm (Active).
- Áp dụng: Phù hợp với các dữ liệu biết trước là luôn nóng (ví dụ: bảng xếp hạng, tỷ giá, danh sách sản phẩm hot).

Ruby sample code:
```ruby
# config/schedule.rb (Whenever gem)
every 5.minutes do
  runner "CacheManager.refresh_hot_keys"
end

# app/models/cache_manager.rb
class CacheManager
  def self.refresh_hot_keys
    puts "Cron job: Refreshing hot data..."
    data = fetch_from_db()
    $redis.set("hot_price_list", data.to_json) # Không cần TTL vì luôn được làm mới
  end
end
```

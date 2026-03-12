# Xử lý Cache Stampede -- v1.2

Cache Stampede không chỉ là cache miss, dẫn đến hoàng loạt request đổ thẳng vào DB, mà là sự kết hợp của: Key cực hot + Thời gian tính toán (recomputation) lâu + Nhiều request đồng thời (high concurrency)

## Roadmap:
- **v1.0:**  Init doc, TTL Jitter, distributed lock
- **v1.1:**  Probabilistic Early Recomputation
- **v1.2:**  Probabilistic Recomputation + Request Coalescing

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
Một cách tiếp cận khác để giảm cache stampede là không chờ đến khi cache hết hạn rồi mới tái tạo dữ liệu. Thay vào đó, hệ thống cho phép một số request ngẫu nhiên chủ động làm mới cache trước thời điểm hết hạn. Kỹ thuật này được gọi là Probabilistic Early Recomputation (hoặc XFetch).

Ý tưởng chính là: mỗi lần đọc cache, hệ thống thực hiện một phép tính xác suất. Nếu điều kiện thỏa mãn, request đó sẽ thực hiện việc recompute và cập nhật cache sớm. Nhờ vậy, việc tái tạo cache được phân tán ngẫu nhiên giữa các request, tránh tình trạng nhiều request đồng thời truy cập database khi cache vừa hết hạn.

Cách hoạt động:
- Giả sử cache lưu thêm hai metadata:
    - expiry: thời điểm cache hết hạn
    - delta: thời gian cần để tái tạo dữ liệu (thời gian fetch từ database)


Khi đọc cache, hệ thống kiểm tra điều kiện:

$t_{now} + \Delta \cdot \beta \cdot (-\ln(U)) \ge t_{expiry}$

Trong đó:

- `t_now`: current time
- `t_expiry`: cache expiration time
- `Δ`: recomputation time
- `U`: random number in (0,1)
- `β`: tuning factor, là "nút vặn" duy nhất để điều chỉnh. $\beta = 0$ là tắt tính năng, $\beta$ càng lớn thì cache càng "tươi" nhưng DB load càng tăng.

Pseudo code:
```
now + delta * beta * (-log(rand)) >= expiry
```

Ruby sample code:
```ruby
def get_data_probabilistic(key, ttl, beta = 1.0)
  cached = $redis.hgetall(key) # Giả sử lưu hash: { "data" => "...", "expiry" => "..." }
  if cached.nil? || cached.empty?
    start = Time.now
    data = fetch_from_db
    delta = Time.now - start

    save_to_cache(key, data, ttl, delta)
    return data
  end

  now = Time.now.to_f
  expiry = cached["expiry"].to_f
  delta  = cached["delta"].to_f

  # Random number trong (0,1)
  u = rand
  u = 0.0000001 if u == 0

  # Probabilistic Early Recomputation (XFetch)
  if now + delta * beta * (-Math.log(u)) >= expiry
    start = Time.now
    new_data = fetch_from_db
    new_delta = Time.now - start

    save_to_cache(key, new_data, ttl, new_delta)
    return new_data
  end

  data = JSON.parse(cached["data"])
  data
end

def save_to_cache(key, data, ttl, delta)
  expiry = Time.now.to_f + ttl
  # có thể thêm Jitter
  # ttl = DEFAULT_TTL + rand(5)
  # expiry = Time.now.to_f + ttl

  $redis.hmset(
    key,
    "data", data.to_json,
    "expiry", expiry,
    "delta", delta
  )

  $redis.expire(key, ttl)
end
```

**Ưu điểm:**

So với distributed lock, kỹ thuật này:
- Không cần lock phân tán
- Không tạo lock contention
- Giảm đáng kể nguy cơ cache stampede
- Dễ triển khai và ít phụ thuộc vào hạ tầng

Nhờ những ưu điểm này, Probabilistic Early Recomputation thường được sử dụng trong các hệ thống cache quy mô lớn như CDN, proxy cache hoặc các dịch vụ có lượng truy cập cao.

## 4. Kết hợp Probabilistic Early Recomputation với Request Coalescing

Mặc dù Probabilistic Early Recomputation giúp phân tán việc làm mới cache theo thời gian, vẫn có khả năng nhiều request trên cùng một server cùng lúc quyết định recompute dữ liệu. Khi đó hệ thống có thể vẫn tạo ra nhiều truy vấn database không cần thiết.

Để giảm thêm tải cho database, có thể kết hợp kỹ thuật Request Coalescing.

Ý tưởng: khi một request đã bắt đầu tái tạo dữ liệu, các request khác trên cùng server sẽ không truy vấn database, mà chờ kết quả của request đang xử lý.

Nhờ vậy nhiều request đồng thời sẽ được gom lại thành một truy vấn database duy nhất.

Ví dụ: Giả sử cache sắp hết hạn và probabilistic recomputation được kích hoạt:
```
t = 54s   Request A → recompute → query DB
t = 54s   Request B → thấy A đang recompute → chờ
t = 55s   Request C → thấy A đang recompute → chờ
```

Kết quả:
```
3 requests
→ 1 DB query
```
Sau khi request A hoàn thành:
```
cache updated
A, B, C đều nhận cùng kết quả
```

**Triển khai trong môi trường nhiều web server**

Trong hệ thống có nhiều node (ví dụ 10 web servers phía sau load balancer), Request Coalescing thường chỉ thực hiện trong phạm vi một process. Điều này vẫn mang lại lợi ích lớn vì phần lớn request burst (một lượng lớn request đến gần như cùng lúc trong một khoảng thời gian rất ngắn) thường tập trung vào một số node nhất định.

Mỗi web server sẽ có một bảng in-flight requests trong memory để theo dõi các request đang recompute dữ liệu.

Ruby sample code:
```
Gem concurrent-ruby
```
Ví dụ triển khai đơn giản bằng Mutex để đảm bảo thread-safe:
```ruby
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
```

Cách dùng:
```ruby
coalescer = RequestCoalescer.new

data = coalescer.fetch("user:42") do
  fetch_from_db
end
```
Nếu 10 thread cùng lúc:
```
coalescer.fetch("user:42")
```
Timeline:
```
Thread A → chạy fetch_from_db
Thread B → chờ
Thread C → chờ
...
Thread J → chờ
```
Kết quả:
```
10 requests
→ 1 DB query
```

**Lợi ích của việc kết hợp hai kỹ thuật**

Ruby sample code:
```ruby
def get_data(key)
  cached = read_cache(key)

  return cached unless should_recompute?(cached)

  coalescer.fetch(key) do
    data = fetch_from_db
    write_cache(key, data)
    data
  end
end
```

Khi sử dụng đồng thời:
- Probabilistic Early Recomputation: phân tán việc tái tạo cache theo thời gian
- Request Coalescing: đảm bảo mỗi server chỉ thực hiện một truy vấn database

Kết quả:
```
N requests
→ 1 DB query / server
```

Điều này giúp giảm đáng kể áp lực lên database, đặc biệt trong các hệ thống có nhiều web server và lượng truy cập lớn.

So với giải pháp **distributed lock**, cách tiếp cận này đơn giản hơn, ít phụ thuộc vào hạ tầng hơn và tránh được các vấn đề lock contention hoặc lock failure trong môi trường phân tán.

**Cải tiến RequestCoalescer V2**

Ta nâng cấp lên RequestCoalescer v2 để an toàn hơn trong production.
Mục tiêu:
```
thread-safe
không memory leak
không in-flight explosion
có timeout
có cleanup TTL
```
Thiết kế:
```
RequestCoalescer
 ├── in_flight map
 ├── TTL cho entry
 ├── max_entries guard
 └── promise timeout
```

```ruby
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
```

Cách dùng:
```ruby
coalescer = V2::RequestCoalescer.new
coalescer.fetch("user:#{id}") do
  User.find(id)
end
```

**Thiết kế hệ thống:**

Nếu hệ thống có:
```
Nginx làm load balancer
10 web servers
Postgres (master + slave)
```
sau khi áp dụng:
```
Probabilistic recompute
+
Request coalescing
```
thì DB load sẽ chuyển từ:
```
burst = 5000 queries thành ≈ 10 queries (vì 1 query / server).
```

**Vì sao các hệ thống lớn thường tránh Distributed Lock cho cache**

Mặc dù distributed lock có thể ngăn cache stampede bằng cách đảm bảo chỉ một request tái tạo dữ liệu, nhiều hệ thống quy mô lớn lại tránh sử dụng kỹ thuật này khi đọc cache nóng (hot path).

Có ba lý do chính.

***1. Lock tạo thêm độ trễ cho mọi request***

Mỗi lần cache miss, hệ thống phải:
```
1. acquire lock
2. fetch database
3. release lock
```

Điều này khiến một thao tác đọc cache vốn dĩ rất nhanh trở thành một chuỗi thao tác mạng:
```
App → Redis (lock)
App → DB
App → Redis (unlock)
```

Trong các hệ thống có độ trễ thấp (low latency systems), việc thêm nhiều round-trip như vậy có thể làm tăng đáng kể p99 latency.

***2. Lock có thể trở thành điểm nghẽn (contention)***

Khi lưu lượng truy cập tăng đột biến, rất nhiều request sẽ tranh cùng một lock.

Ví dụ: 5000 requests → cùng chờ 1 lock

Khi đó hệ thống dễ gặp các vấn đề:
- lock contention
- queue buildup
- timeout
- retry storm

Trong nhiều trường hợp, bản thân hệ thống lock có thể trở thành bottleneck mới.

***3. Distributed lock không hoàn toàn đáng tin cậy***

Các hệ thống lock phân tán thường dựa trên cache system như Redis hoặc Memcached. Tuy nhiên những hệ thống này không phải là hệ thống consensus mạnh.

Do đó các vấn đề như sau có thể xảy ra:
- lock timeout
- clock drift
- process pause (GC)
- network jitter

Những hiện tượng này có thể khiến hai client cùng tin rằng mình đang giữ lock.

Vì lý do đó, nhiều hệ thống production coi distributed lock chỉ là best-effort coordination, không phải là cơ chế đồng bộ tuyệt đối.


***4. Cách tiếp cận phổ biến hơn***

Thay vì dựa vào lock, nhiều hệ thống lớn sử dụng kết hợp:
```
Probabilistic Early Recomputation
+
Request Coalescing
```
Hai kỹ thuật này giải quyết cache stampede theo cách không cần lock toàn cục:
- Probabilistic Early Recomputation phân tán việc tái tạo cache theo thời gian.
- Request Coalescing đảm bảo mỗi server chỉ thực hiện một truy vấn database cho mỗi key.

Kết quả là hệ thống vẫn tránh được cache stampede nhưng:
- không có lock contention (không có nhiều rquest cùng tranh 1 lock)
- không cần coordination giữa các node
- latency thấp hơn

Trong các hệ thống có nhiều web server phía sau load balancer, cách tiếp cận này thường đủ để giảm tải database xuống mức rất nhỏ mà không cần triển khai distributed locking phức tạp.

## 5. Gia hạn thời gian ảo (Soft Expiration) (REVIEWING)
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

# Xử lý Cache Stampede -- v1.4

Cache Stampede không chỉ là cache miss, dẫn đến hoàng loạt request đổ thẳng vào DB, mà là sự kết hợp của: Key cực hot + Thời gian tính toán (recomputation) lâu + Nhiều request đồng thời (high concurrency)

## Roadmap:
- **v1.0:**  Init doc, TTL Jitter, distributed lock
- **v1.1:**  Probabilistic Early Recomputation
- **v1.2:**  Probabilistic Recomputation + Request Coalescing
- **v1.3:**  define cache layers (L1, L2, ...)
- **v1.4:**  Add EphemeralCoalescer

## Quy ước
Việc lựa chọn chiến thuật nào phụ thuộc vào bản chất của dữ liệu (Data Nature). Không có một chiếc chìa khóa vạn năng cho mọi loại cache, kết hợp linh hoạt giữa các tầng bảo vệ để đạt hiệu quả cao.

**Các tầng Cache**

Việc phân tầng cache (Multi-level Caching) giống như việc đặt đồ ăn: cái gì hay dùng thì để trên bàn (L1), xa hơn tí thì để trong tủ lạnh (L2), xa nữa thì ra tiệm tạp hóa đầu ngõ (L3), và cuối cùng là vào siêu thị trung tâm (Database/Storage). Quy ước:

L1 Cache: In-memory (Local RAM)
- Vị trí: Trong RAM của Web Server (Puma/Unicorn).
- Tốc độ: Cực nhanh (nano giây).
- Đặc điểm: Chỉ tồn tại trong một tiến trình duy nhất. Nếu có 5 server, mỗi server sẽ có một L1 riêng.

L2 Cache: Distributed Cache (Redis/Memcached)
- Vị trí: Một server Redis dùng chung cho tất cả các node Web Server.
- Tốc độ: Rất nhanh (mili giây), tốn chi phí truyền tải qua mạng (Network I/O).
- Đặc điểm: Giúp các server chia sẻ dữ liệu với nhau. Nếu Server A đã tính toán xong, Server B có thể lấy dùng ngay.

L3 Cache: CDN hoặc Edge Cache (Cloudflare/CloudFront)
- Vị trí: Nằm ở các server gần người dùng nhất (Edge nodes).
- Tốc độ: Nhanh đối với người dùng cuối vì không cần phải đi sâu vào server ở Vietnam (nếu user đang ở Mỹ).
- Đặc điểm: Thường dùng cho các dữ liệu tĩnh hoặc kết quả API ít thay đổi. Đây là lớp bảo vệ giúp server "không thấy mặt" request luôn.

L4 Cache: Database Query Cache / Materialized Views
- Vị trí: Ngay bên trong Database (PostgreSQL/MySQL).
- Tốc độ: Chậm hơn Redis nhưng nhanh hơn việc query lại từ đầu.
- Đặc điểm: Database tự giữ lại kết quả của các câu query giống hệt nhau hoặc chủ động tạo các bảng tổng hợp sẵn (Materialized Views) cho các báo cáo lịch sử phức tạp.

L5 Cache: Client-side Cache (Browser/Mobile App)
- Vị trí: Ngay trên máy của người dùng.
- Tốc độ: Tức thời.
- Đặc điểm: Sử dụng Header Cache-Control (Etag, Last-Modified). Đây là lớp "tối thượng" vì nó triệt tiêu hoàn toàn request đến server.

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
Ví dụ triển khai RequestCoalescer bằng Mutex để đảm bảo thread-safe: xem file `sample_code/v3_request_coalescer.rb`

Cách dùng:
```ruby
coalescer = V3::RequestCoalescer.new

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
def get_data(key, ttl = 60)
  cached = $redis.hgetall(key) # Trả về hash: data, expires_at, delta/fetch_time

  if cached.empty? || should_recompute?(cached)

    # Dùng coalescer để đảm bảo nếu 1000 người cùng "trúng" xác suất refresh,
    # thì chỉ 1 người thực sự gọi vào DB.
    stale_data = cached.empty? ? nil : JSON.parse(cached['data'])

    new_data = @coalescer.fetch(key, stale_data: stale_data) do
      start_t = Time.now.to_f
      data = fetch_from_db(key) # Thực hiện query thực tế
      duration = Time.now.to_f - start_t

      # Lưu lại vào Redis
      # TTL: 60s, Dữ liệu này sẽ hết hạn sau 60 giây kể từ thời điểm hiện tại
      $redis.hmset(key, {
        data: data.to_json,
        expires_at: Time.now.to_f + ttl,
        detal: duration
      })

      # Phải set expire cho chính cái key để tránh việc tràn Redis.
      # nên để TTL của Redis lớn hơn TTL mà trong code một chút (Grace Period)
      $redis.expire(key, ttl * 2) # Redis sẽ xóa hẳn key này sau 120 giây

      # để tránh round trip hmset và expire thì ta có thể dùng lệnh multi hoặc LUA
      # update_cache_atomic(key, data, ttl, delta)
      data
    end

    return new_data
  end

  JSON.parse(cached['data'])
end

def update_cache_atomic(key, data, ttl, delta)
  lua_script = <<-LUA
    redis.call("HMSET", KEYS[1], "data", ARGV[1], "expires_at", ARGV[2], "delta", ARGV[3])
    redis.call("EXPIRE", KEYS[1], ARGV[4])
  LUA

  $redis.eval(lua_script,
    keys: [key],
    argv: [data.to_json, Time.now.to_f + ttl, delta, ttl * 2]
  )
end

# BETA (Hệ số nhạy cảm):
# BETA = 1.0: Giá trị mặc định, cân bằng giữa việc bảo vệ DB và tiết kiệm tài nguyên.
# BETA > 1.0: Hệ thống sẽ trở nên "lo lắng" hơn, refresh sớm hơn và thường xuyên hơn.
# BETA = 0: Thuật toán trở thành cache bình thường (chỉ refresh khi đã hết hạn hoàn toàn).
# Tăng BETA khi refresh cache sớm hơn để tránh miss burst.
# Giảm BETA khi không muốn refresh cache nhiều
BETA = 1.0

def should_recompute?(cached)
  return true if cached.nil?

  now = Time.now.to_f
  # lấy delta thực tế, nếu không thì mặc định 50ms
  expiry = cached[:expiry].to_f
  delta = cached[:delta]&.to_f || 0.05
  # rand không bao giờ nên bằng 0 để tránh lỗi Log(0) là undefined
  random_factor = Math.log(rand(0.0001..1.0))

  threshold = now - (delta * BETA * random_factor)

  threshold >= expiry
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

`Nâng cấp trong tương lai`

Hỗ trợ N sharded, thay vì chỉ có 1 mutex

`Break changes`

Bản V3 dùng background thread/cleanup logic, bản EphemeralCoalescer (tự hủy/atomic). Ý tưởng: entry tồn tại đúng bằng lifetime của promise, Promise resolve → delete entry ngay lập tức. Đây được xem là bảng tham khảo chính thức.

Khả năng mở rộng của EphemeralCoalescer nằm ở tính chất Event-driven. Thay vì cố gắng kiểm soát toàn bộ thế giới (Global Cleanup), nó trao quyền cho từng Entry tự sinh tự diệt. Chia nhỏ vấn đề để đạt được sự vô tận.

**Note**: Thiết kế hiện tại tập trung vào Request Coalescing và Micro-caching. Trong tương lai, có thể tích hợp thêm cơ chế Circuit Breaker để chủ động ngắt tải (fail-fast) khi tài nguyên hạ tầng (Database/External API) gặp sự cố kéo dài, giúp hệ thống tự phục hồi nhanh hơn.

|Chỉ số tải                       |V3: RequestCoalescer (Legacy)                                                                                          |EphemeralCoalescer (Modern)                                                                                               |
|---------------------------------|-----------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
|Lock Contention (Tranh chấp khóa)|Khi traffic tăng, xác suất nhiều thread đâm sầm vào cùng một Mutex Shard tăng cao. Gây hiện tượng nghẽn cổ chai cục bộ.|Lock-free/Atomic: Concurrent::Map sử dụng kỹ thuật phân tách cực nhỏ. Càng nhiều core CPU, hiệu năng càng tăng tuyến tính.|
|Memory Pressure (Áp lực RAM)     |Dễ bị tràn RAM nếu dọn dẹp không kịp hoặc guard_capacity quét quá chậm. RAM có thể bị "phồng" (bloat) bất thình lình.  |Self-Limiting: RAM tỷ lệ thuận với lượng request đang xử lý. Khi traffic giảm, RAM được giải phóng gần như ngay lập tức.  |
|CPU Overhead                     |Tốn CPU để chạy thread dọn dẹp và quản lý mảng Shards phức tạp.                                                        |Tối ưu CPU tối đa. Chỉ tốn tài nguyên khi thực sự có request. Không tốn "phí duy trì".                                    |
|Burst Handling (Xử lý bùng nổ)   |Có thể bị sập nếu số lượng key mới sinh ra vượt quá tốc độ dọn dẹp của thread ngầm.                                    |Vô địch: Nhờ sự kết hợp của L1 Window và X-Fetch, các đợt bùng nổ traffic được "san phẳng" ngay từ lớp vỏ.                |
|Distributed Scaling              |Khó đồng bộ hóa trạng thái giữa các server nếu muốn gộp request xuyên node.                                            |Dễ dàng mở rộng chiều ngang (Horizontal Scaling) nhờ sự phối hợp nhịp nhàng với lớp L2 (Redis).                           |
Độ phức tạp Code|Cao: Nhiều logic quản lý shard, xử lý tràn bộ nhớ, thread dọn dẹp ngầm.|Thấp: Code cực kỳ tinh gọn, logic dọn dẹp nằm gọn trong callback của chính Promise đó.
Độ chính xác dọn dẹp|Thấp: Dễ xóa nhầm key mới nếu chỉ dựa trên tên key (delete).|Tuyệt đối: Dùng delete_pair(key, entry) để đảm bảo chỉ xóa đúng phiên bản đã hết hạn.
Phạm vi bảo vệ|Chỉ gộp request (Request Coalescing)|Đa tầng: Kết hợp Coalescing (L1) + Redis (L2) + Xác suất X-Fetch + Stale Fallback.
Hiệu năng (Throughput)|Bị giới hạn bởi số lượng Shard và chi phí quản lý Cleanup.|Gần như không giới hạn: Hiệu năng tỷ lệ thuận với khả năng xử lý của Concurrent::Map.

Sample ruby code:
```ruby
require 'concurrent'
require 'concurrent/map'

# EphemeralCoalescer: Cơ chế gộp request (Coalescing) với vòng đời tự hủy.
# Giúp bảo vệ Database khỏi tình trạng Cache Stampede và tối ưu hóa tài nguyên RAM.
class V2::EphemeralCoalescer

  # Cửa sổ thời gian (giây) để reuse kết quả sau khi xong
  # đây là grace_period, vd: 1000 request đến ở giây thứ 1.0 (được gộp), và 1 request khác đến ở giây thứ 1.1 (ngay sau khi request trước vừa xong), thì request sau được hưởng ké grace_period
  WINDOW = 0.1

  # Entry mang tính chất tạm thời, tự quản lý thời điểm hết hạn
  Entry = Struct.new(:promise, :expires_at)

  # BETA (Hệ số nhạy cảm):
  # BETA = 1.0: Giá trị mặc định, cân bằng giữa việc bảo vệ DB và tiết kiệm tài nguyên.
  # BETA > 1.0: Hệ thống sẽ trở nên "lo lắng" hơn, refresh sớm hơn và thường xuyên hơn.
  # BETA = 0: Thuật toán trở thành cache bình thường (chỉ refresh khi đã hết hạn hoàn toàn).
  # Tăng BETA khi refresh cache sớm hơn để tránh miss burst.
  # Giảm BETA khi không muốn refresh cache nhiều
  BETA = 1.0

  def initialize(redis, ttl: 120, timeout: 2.0)
    @map = Concurrent::Map.new
    @redis = redis
    @ttl = ttl
    @timeout = timeout
  end

  def fetch(key)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # 1. L1 FAST PATH: Kiểm tra trong RAM trước. Reuse kết quả nếu còn trong cửa sổ WINDOW ---
    entry = @map[key]
    if entry && entry.expires_at > now
      return entry.promise.value(@timeout)
    end

    # 2. L1 SLOW PATH & ATOMIC COALESCING: Gộp các request đang bay
    is_new = false
    entry = @map.compute(key) do |_, old|
      if old && old.expires_at > now
        old
      else
        is_new = true
        # Chỉ khởi tạo Promise thực thi yield khi chắc chắn cần tạo mới
        # Entry.new(Concurrent::Promise.execute do
        #   execute_with_l2_logic(key, &block)
        # end, Float::INFINITY)
        Entry.new(Concurrent::Promise.execute { execute_with_l2_logic(key, &block) }, Float::INFINITY)
      end
    end

    # Nếu là thread "chiến thắng", thiết lập cơ chế tự hủy (Self-destruct)
    attach_cleanup(key, entry) if is_new

    # 3. ĐỢI KẾT QUẢ & XỬ LÝ TIMEOUT/ERROR
    result = entry.promise.value(@timeout)

    if result.nil? && entry.promise.pending?
      # Ở đây ta không có sẵn stale_data vì nó nằm bên trong scope của promise
      # Do đó logic cứu hộ stale data nên được ưu tiên xử lý bên trong execute_with_l2_logic
      raise "Request Timeout: Resource busy or Database slow."
    end

    # Xử lý lỗi bên trong logic nghiệp vụ (yield)
    raise entry.promise.reason if entry.promise.rejected?

    result
  end

  private

  def execute_with_l2_logic(key, &block)
    # Trả về json string: value, expires_at, delta/stay_time
    cached = @redis.get(key)
    data = parsing_cache(cached)

    if data.nil? || should_recompute?(data)
      begin
        # FETCH MỚI & LƯU L2 (Nếu Redis trống hoặc trúng xác suất tính sớm)
        start_t = Time.now.to_f
        fresh_data = block.call # Thực thi logic DB
        duration = Time.now.to_f - start_t

        payload = { value: fresh_data, expires_at: Time.now.to_f + @ttl, delta: duration }
        # Lưu dư 60s để tránh mất data khi vừa hết hạn
        @redis.setex(key, @ttl + 60, payload.to_json)
        return fresh_data
      rescue => e
        # STALE DATA FALLBACK: Trả về data cũ từ Redis nếu DB sập
        return data['value'] if data && data.key?('value')
        raise e
      end
    end

    data['value']
  end

  def parsing_cache(cache)
    return nil if cache.nil?

    JSON.parse(cache) rescue nil
  end

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

  def should_recompute?(data)
    return true if data.nil?

    now = Time.now.to_f
    # lấy delta thực tế, nếu không thì mặc định 50ms
    expiry = data['expires_at'].to_f
    delta = data['delta']&.to_f || 0.05
    # rand không bao giờ nên bằng 0 để tránh lỗi Log(0) là undefined
    random_factor = Math.log(rand(0.0001..1.0))

    threshold = now - (delta * BETA * random_factor)

    threshold >= expiry
  end
end
```

Cách dùng:
```
# Khởi tạo (Dùng chung một instance trong toàn app)
COALESCER = EphemeralCoalescer.new(Redis.new, ttl: 1.hour, timeout: 2.0)

# Sử dụng trong Controller hoặc Service
result = COALESCER.fetch("post_123") do
  # Logic query DB nặng nề ở đây
  Post.find(123).detailed_analysis
end
```

**Chiến lược về sau:**

Khi traffic cực lớn, ta có thể mở rộng như sau:
- Nấc 1 (Vertical Scaling): tăng RAM và CPU cho server hiện tại. Nhờ tính chất Atomic, code sẽ tự động tận dụng thêm sức mạnh của các Core CPU mới.
- Nấc 2 (Horizontal Scaling): Chạy nhiều instance Ruby (Puma/Unicorn). Lớp L1 (RAM) của mỗi instance sẽ bảo vệ instance đó, còn lớp L2 (Redis) sẽ đảm bảo các instance không làm việc trùng lặp.
- Nấc 3 (Cluster Scaling): Khi một server Redis không còn chịu nổi nhiệt, có thể chuyển sang Redis Cluster. Class của chúng ta chỉ cần đổi redis_client là xong, logic bên trong không thay đổi.

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

**Checklist khi implement coalescer**

Nên hỏi:
1. same key requests thường xảy ra không?
2. duplicate rate bao nhiêu?
3. compute/query cost bao nhiêu?
4. burst traffic có xảy ra không?

Nếu câu trả lời là: YES YES HIGH YES
→ coalescer rất đáng dùng.

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

## 6. Background Refresh (Cron jobs)
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

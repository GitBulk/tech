Dưới đây là **Chaos Test Runner hoàn chỉnh (Docker + script chạy thật)** để có thể spin up môi trường và bắn chaos test vào service webhook.

Thiết kế theo hướng:
-   Chạy độc lập (không phụ thuộc infra phức tạp)
-   Có thể gắn vào service Rails của bạn
-   Có fault injection + concurrent load

* * * * *

1\. Folder Structure
====================
```
chaos-runner/
├── docker-compose.yml
├── runner/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── chaos_runner.py
│   └── scenarios.py
```


2\. docker-compose.yml
======================
```yaml
version: "3.9"

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: chaos
      POSTGRES_PASSWORD: chaos
      POSTGRES_DB: chaos_db
    ports:
      - "5433:5432"

  redis:
    image: redis:7
    ports:
      - "6380:6379"

  runner:
    build: ./runner
    depends_on:
      - postgres
      - redis
    environment:
      TARGET_URL: "http://host.docker.internal:3000/webhooks/payments"
    volumes:
      - ./runner:/app
```


3\. Runner Dockerfile
=====================
```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

CMD ["python", "chaos_runner.py"]
```

4\. requirements.txt
====================
```
requests
faker
```

* * * * *

5\. scenarios.py (Chaos Scenarios)
==================================
```python
import threading
import time
import requests
import random
import uuid
import os

TARGET_URL = os.getenv("TARGET_URL")

HEADERS = {
    "Content-Type": "application/json",
    "X-Signature": "test-signature"
}

def generate_payload(transaction_id):
    return {
        "transaction_id": transaction_id,
        "order_id": 1001,
        "amount": 500000,
        "status": "success"
    }

# --- Scenario A: Duplicate Storm ---
def duplicate_storm(n=100):
    tx_id = f"TXN_{uuid.uuid4()}"

    def send():
        payload = generate_payload(tx_id)
        requests.post(TARGET_URL, json=payload, headers=HEADERS)

    threads = []
    for _ in range(n):
        t = threading.Thread(target=send)
        threads.append(t)
        t.start()

    for t in threads:
        t.join()

    print(f"[duplicate_storm] sent {n} requests for {tx_id}")

# --- Scenario B: Retry Storm ---
def retry_storm(duration=10):
    tx_id = f"TXN_{uuid.uuid4()}"

    start = time.time()

    while time.time() - start < duration:
        payload = generate_payload(tx_id)
        requests.post(TARGET_URL, json=payload, headers=HEADERS)
        time.sleep(0.05)

    print(f"[retry_storm] ran for {duration}s on {tx_id}")

# --- Scenario C: Out-of-order ---
def out_of_order():
    tx_id = f"TXN_{uuid.uuid4()}"

    failed_payload = generate_payload(tx_id)
    failed_payload["status"] = "failed"

    success_payload = generate_payload(tx_id)
    success_payload["status"] = "success"

    requests.post(TARGET_URL, json=failed_payload, headers=HEADERS)
    time.sleep(0.1)
    requests.post(TARGET_URL, json=success_payload, headers=HEADERS)

    print(f"[out_of_order] executed for {tx_id}")

# --- Scenario D: Mixed Chaos ---
def mixed_chaos():
    tx_id = f"TXN_{uuid.uuid4()}"

    def worker():
        payload = generate_payload(tx_id)

        # random delay
        time.sleep(random.uniform(0, 0.2))

        # random duplicate or fail
        if random.random() < 0.3:
            payload["status"] = "failed"

        requests.post(TARGET_URL, json=payload, headers=HEADERS)

    threads = []
    for _ in range(50):
        t = threading.Thread(target=worker)
        threads.append(t)
        t.start()

    for t in threads:
        t.join()

    print(f"[mixed_chaos] completed for {tx_id}")
```

6\. chaos_runner.py (Main Runner)
=================================
```python
import time
from scenarios import duplicate_storm, retry_storm, out_of_order, mixed_chaos

def run_all():
    print("Starting Chaos Tests...\n")

    # 1. Duplicate Storm
    duplicate_storm(100)
    time.sleep(2)

    # 2. Retry Storm
    retry_storm(duration=5)
    time.sleep(2)

    # 3. Out-of-order
    out_of_order()
    time.sleep(2)

    # 4. Mixed chaos
    mixed_chaos()

    print("nChaos Tests Completed.")

if __name__ == "__main__":
    run_all()
```


7\. Cách chạy
=============

### Bước 1: Start hệ thống của bạn (Rails server)
```
rails s -p 3000
```
* * * * *

### Bước 2: Run chaos runner
```
docker-compose up --build
```

8\. Bạn sẽ thấy gì
==================

Logs từ runner:

[duplicate_storm] sent 100 requests for TXN_123
[retry_storm] ran for 5s on TXN_456
[out_of_order] executed for TXN_789
[mixed_chaos] completed for TXN_ABC


9\. Cách verify kết quả (QUAN TRỌNG)
====================================

Trong DB:
```sql
-- Không được >1
SELECT transaction_id, COUNT(*)
FROM payments
GROUP BY transaction_id
HAVING COUNT(*) > 1;
```
👉 Phải trả về **0 rows**

* * * * *

```sql
-- Order phải đúng
SELECT id, status FROM orders WHERE id = 1001;
```

👉 Expected: `PAID`

* * * * *

10\. Nâng cấp (rất đáng làm)
============================

10.1 Thêm latency injection
---------------------------

Trong Rails:
```ruby
sleep(rand(0.1..0.5))
```


10.2 Thêm crash injection
-------------------------
```ruby
exit(1) if rand < 0.1
```

* * * * *

10.3 Add metrics
----------------

-   Prometheus
-   Log duplicate rate

* * * * *

11\. Real Talk
==============

Nếu hệ thống pass được bộ test này:
-   Redis lock gần như không còn quan trọng nữa
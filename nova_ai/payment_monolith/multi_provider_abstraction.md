Multi-provider abstraction “Stripe-level” cho hệ thống payment. Mục tiêu là:
- Tách business logic <-> provider integration
- Chuẩn hóa interface + event model
- Đảm bảo idempotency + consistency như RFC đã định
- Dễ thêm provider mới (Momo, VNPay, Stripe…) mà không sửa core flow

1\. Design Goals
================

-   **Single internal contract** cho mọi provider
-   **Normalized webhook event** (mọi provider → cùng format)
-   **Pluggable adapters** (mỗi provider = 1 adapter)
-   **Stateless service layer** (state nằm ở DB)
-   **Idempotent by design**

* * * * *

2\. High-Level Architecture
===========================
```
Client
  ↓
PaymentService (internal API)
  ↓
ProviderAdapter (Stripe/Momo/VNPay)
  ↓
External Payment Provider

Webhook
  ↓
WebhookController
  ↓
ProviderAdapter.parse_webhook
  ↓
NormalizedEvent
  ↓
ProcessTransaction (core logic)
```

* * * * *

3\. Core Abstractions
=====================

3.1 Provider Adapter Interface
------------------------------
```ruby
# app/services/payments/providers/base_adapter.rb
module Payments
  module Providers
    class BaseAdapter
      def initialize(config:)
        @config = config
      end

      # Create payment URL / intent
      def create_payment(order:)
        raise NotImplementedError
      end

      # Verify webhook signature
      def verify_webhook(payload:, headers:)
        raise NotImplementedError
      end

      # Normalize webhook → internal format
      def parse_webhook(payload:)
        raise NotImplementedError
      end

      # Fetch transactions từ provider API theo ngày — dùng cho reconciliation job
      # Returns: Array of Struct/OpenStruct với fields: transaction_id, order_id, amount, currency, status, raw
      def fetch_transactions(date:)
        raise NotImplementedError
      end
    end
  end
end
```

* * * * *

3.2 Normalized Event (Internal Contract)
----------------------------------------
```ruby
# app/models/payments/normalized_event.rb
module Payments
  NormalizedEvent = Struct.new(
    :provider,
    :event_type,       # payment.succeeded | payment.failed
    :transaction_id,
    :order_id,
    :amount,
    :currency,
    :status,           # SUCCESS | FAILED
    :raw_payload,
    keyword_init: true
  )
end
```

👉 Đây là **trái tim abstraction**
→ mọi provider phải map về format này

* * * * *

4\. Provider Implementations
============================

* * * * *

4.1 VNPay Adapter
-----------------
```ruby
# app/services/payments/providers/vnpay_adapter.rb
module Payments
  module Providers
    class VnpayAdapter < BaseAdapter
      def create_payment(order:)
        params = {
          amount: order.amount,
          order_id: order.id,
          return_url: @config[:return_url]
        }

        query = URI.encode_www_form(params)
        signature = sign(query)

        "#{@config[:endpoint]}?#{query}&signature=#{signature}"
      end

      def verify_webhook(payload:, headers:)
        received_sig = headers["X-Signature"]
        calculated = sign(URI.encode_www_form(payload.sort.to_h))

        secure_compare(received_sig, calculated)
      end

      def parse_webhook(payload:)
        Payments::NormalizedEvent.new(
          provider: "vnpay",
          event_type: map_event(payload),
          transaction_id: payload["transaction_id"],
          order_id: payload["order_id"].to_i,
          amount: payload["amount"].to_i,
          currency: "VND",
          status: payload["status"] == "success" ? "SUCCESS" : "FAILED",
          raw_payload: payload
        )
      end

      private

      def sign(data)
        OpenSSL::HMAC.hexdigest("SHA256", @config[:secret], data)
      end

      def secure_compare(a, b)
        ActiveSupport::SecurityUtils.secure_compare(a, b)
      end

      def map_event(payload)
        payload["status"] == "success" ? "payment.succeeded" : "payment.failed"
      end
    end
  end
end
```

* * * * *

4.2 Momo Adapter
----------------
```ruby
# app/services/payments/providers/momo_adapter.rb
module Payments
  module Providers
    class MomoAdapter < BaseAdapter
      def verify_webhook(payload:, headers:)
        signature = payload["signature"]
        raw = build_raw_string(payload)

        expected = OpenSSL::HMAC.hexdigest("SHA256", @config[:secret], raw)

        # SECURITY: dùng secure_compare để tránh timing attack
        ActiveSupport::SecurityUtils.secure_compare(signature, expected)
      end

      def parse_webhook(payload:)
        Payments::NormalizedEvent.new(
          provider: "momo",
          event_type: map_event(payload),
          transaction_id: payload["transId"],
          order_id: payload["orderId"].to_i,
          amount: payload["amount"].to_i,
          currency: "VND",
          status: payload["resultCode"] == 0 ? "SUCCESS" : "FAILED",
          raw_payload: payload
        )
      end

      private

      def map_event(payload)
        payload["resultCode"] == 0 ? "payment.succeeded" : "payment.failed"
      end
    end
  end
end
```

* * * * *

5\. Adapter Factory
===================
```ruby
# app/services/payments/provider_factory.rb
module Payments
  class ProviderFactory
    def self.build(provider)
      config = Rails.application.credentials.dig(:payments, provider.to_sym)

      case provider
      when "vnpay"
        Providers::VnpayAdapter.new(config: config)
      when "momo"
        Providers::MomoAdapter.new(config: config)
      else
        raise "Unsupported provider: #{provider}"
      end
    end
  end
end
```
* * * * *

6\. Unified Payment Service
===========================

6.1 Create Payment
------------------
```ruby
# app/services/payments/create_payment.rb
module Payments
  class CreatePayment
    def initialize(order:, provider:)
      @order = order
      @provider = provider
    end

    def call
      adapter = ProviderFactory.build(@provider)

      url = adapter.create_payment(order: @order)

      { payment_url: url }
    end
  end
end
```

* * * * *

6.2 Webhook Processing (Unified)
--------------------------------
```ruby
# app/services/payments/process_webhook_v2.rb
module Payments
  class ProcessWebhookV2
    def initialize(provider:, payload:, headers:)
      @provider = provider
      @payload = payload
      @headers = headers
    end

    def call
      adapter = ProviderFactory.build(@provider)

      verify!(adapter)

      record_event!

      event = adapter.parse_webhook(payload: @payload)

      Payments::ProcessNormalizedEvent.new(event: event).call
    end

    private

    def verify!(adapter)
      valid = adapter.verify_webhook(
        payload: @payload,
        headers: @headers
      )

      raise InvalidSignatureError unless valid
    end

    def record_event!
      PaymentEvent.create!(
        provider: @provider,
        transaction_id: @payload["transaction_id"] || @payload["transId"],
        event_type: "webhook",
        payload: @payload
      )
    end
  end
end
```

* * * * *

7\. Core Processor (Provider-agnostic)
======================================
```ruby
# app/services/payments/process_normalized_event.rb
module Payments
  class ProcessNormalizedEvent
    def initialize(event:)
      @event = event
    end

    def call
      payment, order = ActiveRecord::Base.transaction do
        payment = create_payment!

        order = Order.lock.find(@event.order_id)

        handle_event(order, payment)

        [payment, order]
      end

      # ORDER: emit sau khi transaction commit, tránh job chạy trước khi DB ghi xong
      emit_side_effects(payment, order) if @event.status == "SUCCESS"

      :ok
    rescue ActiveRecord::RecordNotUnique
      :duplicate
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error("[ProcessNormalizedEvent] order not found: order_id=#{@event.order_id}")
      :order_not_found
    end

    private

    def create_payment!
      Payment.create!(
        provider: @event.provider,
        transaction_id: @event.transaction_id,
        order_id: @event.order_id,
        amount: @event.amount,
        currency: @event.currency,
        status: "INIT",
        raw_payload: @event.raw_payload
      )
    end

    def handle_event(order, payment)
      case @event.status
      when "SUCCESS"
        mark_paid(order, payment)
      when "FAILED"
        mark_failed(order, payment)
      end
    end

    def mark_paid(order, payment)
      return if order.status == "PAID"

      order.update!(status: "PAID")
      payment.update!(status: "SUCCESS")
    end

    def mark_failed(order, payment)
      return if order.status != "PENDING"

      order.update!(status: "FAILED")
      payment.update!(status: "FAILED")
    end

    def emit_side_effects(payment, order)
      Payments::DispatchSideEffectsJob.perform_later(
        payment_id: payment.id,
        order_id: order.id
      )
    end
  end
end
```

* * * * *

8\. Why This Is "Stripe-level"
==============================

### ✅ Clean separation

-   Provider logic isolated

### ✅ Unified domain model

-   `NormalizedEvent` = single source of truth

### ✅ Easy to add provider

Chỉ cần:

class NewProviderAdapter < BaseAdapter

→ không sửa core system

* * * * *

### ✅ Strong correctness

-   Idempotency: DB constraint
-   Race-safe: transaction + row lock
-   Retry-safe: duplicate-safe

* * * * *

### ✅ Extensible

Có thể thêm:

-   Refund API
-   Subscription
-   Partial payment
-   Multi-currency

* * * * *

9\. Optional Advanced Extensions
================================

9.1 Event Bus (Kafka)
---------------------

Webhook → Normalize → Kafka → Consumers

* * * * *

9.2 Outbox Pattern
------------------

-   Ghi event vào DB
-   Worker publish → Kafka

* * * * *

9.3 Provider Capability Matrix
------------------------------

| Feature | VNPay | Momo | Stripe |
| --- | --- | --- | --- |
| Refund | ❌ | ⚠️ | ✅ |
| Subscription | ❌ | ❌ | ✅ |

* * * * *

10\. Final Takeaway
===================

Thiết kế này đạt:

> **"Swap provider mà không đụng core logic"**

và:

> **"Retry 100 lần vẫn không double charge"**
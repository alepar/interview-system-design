---
slug: stock-alert-fanout
archetype: fan-out
sources:
  programming_ai_substack: programmingappliedai.substack.com/p/design-a-system-to-notify-users-when
  dedup: sohilladhani.com/blog/post/2026-04-12-notification-deduplication/
  tradingview: tradingview.com/support/solutions/43000520149-introduction-to-tradingview-alerts/
  robinhood: robinhood.com/us/en/support/articles/price-alerts/
  apns_design: designgurus.substack.com/p/push-notification-architecture-apns
  fcm_scale: firebase.google.com/docs/cloud-messaging/scale-fcm
---

# Stock alert fan-out — per-symbol subscriber list indexed by (user_id, stock_symbol) composite key (avg 500 subscribers/symbol enables single-pass fan-out per tick) + ~10K updates/sec to ~1M active users + target 2-3s end-to-end + Redis SETNX dedup with 1h TTL + DB unique constraint for crash-recovery idempotency + APNs apns-collapse-id + FCM collapse_key for gateway-level collapse + TradingView Pine signal → server rule → webhook → broker 1.5-5s normal / 25s+ under news-event load + Robinhood default 5% and 10% movement alerts for held assets via mobile push + in-app + email + APNs ~2K req/sec/HTTP2-connection + FCM 1K concurrent fanouts/project / 600K msgs/min default

## Bar anchors
- **Mid-level (L4/E4):** Evaluates each rule per user against every tick (N×M).
- **Senior (L5/E5):** Names per-symbol indexing. May or may not articulate dedup layers, gateway-level collapse, or news-event backpressure.
- **Staff+ (L6/E6+):** Names (a) **per-symbol subscriber list** — composite index (user_id, stock_symbol); avg 500 subscribers/symbol; in-memory cache of alert thresholds grouped by symbol — single-pass fan-out per tick instead of N-rules scans; (b) **target latency** ≤2-3s; throughput ~10K updates/sec across ~1M active users; storage 259 GB/day raw / 778 GB with 3× Kafka replication; (c) **dedup at multiple layers**: Composite Redis key `{user_id:stock_symbol:alert_id:trigger_timestamp}` with SETNX + 1h TTL; DB unique constraint on notification log for crash-recovery idempotency; **gateway-level collapse** via APNs `apns-collapse-id` + FCM `collapse_key` — gateway replaces pending-undelivered with same collapse-id instead of queuing second; (d) **TradingView**: each watchlist alert evaluated independently per symbol on every bar close; Pine signal → server rule → webhook → broker pipeline = 1.5-5s normal load; **25s+ during high-impact news events** due to internal alert-queue backpressure; (e) **Robinhood**: 3 channels (mobile push, in-app, email); default 5% and 10% movement alerts for held assets unless user opts out — server-side default rules; (f) **APNs scale**: ~2K req/sec/HTTP2-connection; pool 5-10 connections for 9K+ notifs/sec total; opening/closing connections per message treated as DoS; (g) **FCM**: 1K concurrent fanouts/project hard cap; ~10K QPS typical sustained per project but divided across in-flight fanouts; single-recipient token sends preferred over topic for latency-sensitive alerts.

## Canonical decomposition

### Requirements
**Functional:**
- Per-user alert rules (price ≥ / ≤ / %-change)
- Push / in-app / email delivery channels
- Default rules (held assets, 5%/10%)
- Dedup so single trigger fires once even on retry

**Non-functional:**
- ~10K stock updates/sec; ~1M active users; avg 500 subscribers/symbol
- ≤2-3s end-to-end
- 259 GB/day raw / 778 GB with 3× Kafka replication
- APNs ~2K req/sec/connection; FCM 1K concurrent fanouts/project

### Core entities
- **Alert:** (user_id, stock_symbol, alert_id, threshold, op, channels[])
- **PerSymbolIndex:** in-memory `symbol → [(user, threshold, op, channels), ...]`
- **DedupKey:** `{user_id:symbol:alert_id:trigger_ts}` in Redis with 1h TTL
- **NotificationLog:** DB row with unique constraint (user_id, symbol, alert_id, trigger_ts)

### API
- `POST /alerts` body={symbol, threshold, op, channels[]}
- Tick stream: exchange feed → Kafka topic (per-symbol partitioned)

### HLD
Tick path: exchange feed → Kafka (per-symbol partition). Alert Evaluator subscribes; for each tick, looks up per-symbol subscriber list (in-memory cache rebuilt periodically + updated on alert CRUD). Evaluates threshold; produces matched (user, alert_id, trigger_ts) tuples.

Dedup: Redis SETNX on `{user_id:symbol:alert_id:trigger_ts}` with 1h TTL; first writer wins. DB unique constraint on notification log = crash-recovery idempotency.

Delivery: per-user channel selection → APNs / FCM / SES. APNs connection pool 5-10 × ~2K req/sec/conn. FCM single-recipient token for latency. Gateway collapse via apns-collapse-id / collapse_key replaces pending-undelivered with newer.

### Deep dives
1. **Per-symbol subscriber list + tick-to-fan-out single pass.** Composite index (user_id, stock_symbol); per-symbol subscriber list in-memory; single-pass per tick. Tick stream from exchange (~10K msg/sec aggregate) → fan-out rule eval → matched users → push.
2. **Multi-layer dedup (Redis SETNX + DB unique + gateway collapse).** Composite key {user_id:symbol:alert_id:trigger_ts} via SETNX + 1h TTL in Redis. DB unique constraint on notification log for crash-recovery idempotency. APNs apns-collapse-id + FCM collapse_key gateway replaces pending-undelivered with same collapse-id.
3. **Rate-limiting + multi-channel + per-symbol caching.** Per-user max 10 alerts/hour. Per-symbol alert dedup within N min. Web/mobile/email per user preference. APNs pool 5-10 × ~2K/sec = 9K+ notifs/sec. FCM 1K concurrent fanouts/project hard cap; single-token preferred over topic for latency.

## Known failure modes
1. *News-event backpressure* — TradingView pipeline 25s+ vs 1.5-5s normal. Production answer: priority queue for time-sensitive alerts; degrade non-essential during news.
2. *Push gateway saturation* — FCM 1K concurrent fanouts/project. Production answer: multi-project sharding; per-symbol topic vs per-token trade-off.
3. *Duplicate push on retry storm* — at-least-once semantics. Production answer: app-level dedup key + gateway collapse-id.

## Notes for the coach
- **Plausibly-asked at Robinhood, Coinbase, TradingView, E*TRADE, Schwab.** TradingView + Robinhood docs + APNs/FCM docs are public.
- **Cross-coverage** with messaging `push-notification` (gateway). With ML-in-loop `stripe-fraud` (per-symbol rule evaluation engine analog). With `sports-scores-fanout` (real-time fan-out twin).
- **The per-symbol subscriber-list with multi-layer dedup is the canonical Staff+ unlock.** Mid-senior candidates evaluate N rules per tick × M users; Staff+ candidates invert to per-symbol subscriber list + multi-layer dedup.
- **Adversarial probe: "Apple drops 5% on rumor. 500K users have AAPL alerts. How many duplicate pushes do users see?"** Strong answer: zero — Redis SETNX on composite key + DB unique constraint + APNs apns-collapse-id triple-layer dedup; only one notification per (user, symbol, alert, trigger_ts) regardless of retry storms or downstream worker restarts. Weak answer: "we'd just queue them" without naming the three dedup layers.

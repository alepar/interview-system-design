---
slug: stock-ticker
archetype: caching-read-heavy
sources:
  rt_stock_streaming: medium.com/@akhilvpsharma/system-design-real-time-stock-market-data-streaming-at-scale-2ee276619ba9
  kalshi_orderbook: docs.kalshi.com/websockets/orderbook-updates
  redis_pubsub_cache: hansajdeghun.medium.com/redis-pub-sub-local-memory-low-latency-high-consistency-caching-3740f66f0368
  opra_exegy: exegy.com/hidden-cost-options-market-data/
  delayed_quotes: sofi.com/learn/content/real-time-vs-delayed-stock-quotes/
---

# Stock Ticker (read fan-out of price data with freshness)

## Bar anchors
- **Mid-level (L4/E4):** Polls the DB for the latest price per request. Doesn't address fan-out to many readers, hot symbols, or acceptable staleness.
- **Senior (L5/E5):** Caches the latest price per symbol, pushes/streams updates to clients over WebSocket, partitions by symbol. Knows hot symbols are hot keys and some staleness is acceptable. May not articulate snapshot+delta, the consistency-vs-latency tradeoff, or push-update-to-cache with self-healing.
- **Staff+ (L6/E6+):** Drives proactively. Designs the **read fan-out**: ingest connectors normalize exchange feeds into **Kafka partitioned by symbol** (per-symbol ordering; each aggregator owns a symbol group), aggregators maintain the **latest quote per symbol in Redis (sub-ms)**, and **WebSocket gateways** subscribe and stream to clients (compute lives in aggregators, not gateways). Handles **hot symbols** (AAPL/TSLA) as hot keys via regional edge fan-out, batching, and a **symbol→gateway subscription map** (a gateway only consumes pub/sub for symbols its clients follow). Uses **snapshot + delta** (full snapshot first, then incremental updates with a per-symbol sequence number; gap → re-snapshot) and **push-update-to-cache + short TTL** (publish latest over Redis Pub/Sub for sub-ms fan-out, plus a 30–120s TTL so a missed message self-heals on the next read-through). Owns the **consistency-vs-latency tradeoff** (15-min delayed quotes are the standard free tier; day-traders need to-the-second). Notes extreme fan-out scale (OPRA peaked >187M msgs/sec in 2025; WebSocket clusters ~1.2M ticks/sec at sub-65ms).

## Canonical decomposition

### Requirements
**Functional:**
- Stream the latest price/quote per symbol to many concurrent readers with low latency
- Handle hot symbols (everyone watching the same few) without a single-node bottleneck
- Recover correctly from missed updates (gaps) on reconnect
- Bounded, well-defined staleness for the displayed price

**Non-functional (with numbers):**
- Hot symbols are hot keys; many readers per symbol; sub-second display latency
- Push fan-out via Redis Pub/Sub (sub-ms) + 30–120s TTL self-heal
- OPRA peak >187M msgs/sec (2025); WebSocket ~1.2M ticks/sec at sub-65ms
- Display staleness: 15-min delayed (free tier) vs to-the-second (traders)

### Core entities
- **Quote:** symbol → latest price (cached, hot key for popular symbols)
- **Snapshot + delta:** full state then incremental updates with a per-symbol sequence number
- **Aggregator:** owns a symbol group; maintains latest quote in Redis
- **WebSocket gateway:** subscribes to symbols its clients follow; streams to clients

### API
- client `subscribe(symbols)` over WebSocket → snapshot then deltas
- ingest → Kafka (partitioned by symbol) → aggregator → Redis latest-quote + Pub/Sub
- gateway: on price event for a subscribed symbol, push delta to clients
- reconnect: client sends last sequence per symbol → replay from retention or re-snapshot

### HLD
This is the **read/display fan-out** path (not the trading-engine matching). Exchange feeds are ingested by connectors that normalize them into **Kafka topics partitioned by symbol** — so all updates for a symbol are ordered and a given **aggregator** owns a group of symbols, maintaining each symbol's **latest quote in Redis** (sub-ms reads). **WebSocket gateways** sit in front of clients: a gateway maintains a **symbol→subscribers map**, consumes Pub/Sub only for the symbols its clients follow, and pushes updates out. Compute (aggregation, candle-building) lives in aggregators; gateways are thin fan-out. The client protocol is **snapshot + delta**: on subscribe, the client gets a full quote/order-book snapshot, then incremental **deltas** each carrying a **per-symbol sequence number**; if the client detects a sequence gap, its local view may be stale, so it **re-snapshots** (or, on reconnect, sends its last sequence per symbol to replay from Kafka retention, typically 5–30 min).

**Hot symbols** (AAPL/TSLA) are hot keys: regional edge fan-out, **batching/coalescing** of rapid updates, binary encoding (protobuf) and delta encoding cut per-message cost. For freshness, **push-update-to-cache** publishes the latest price over **Redis Pub/Sub** (sub-ms fan-out in publish order) *plus* a short **TTL (30–120s)** so any gateway/instance that missed a message self-corrects on the next read-through — a self-healing cache. The defining design choice is the **consistency-vs-latency tradeoff**: how stale may the *displayed* price be? A **15-minute delayed quote** is the standard free tier (fine for casual viewers since prices move little over short intervals); active traders need **to-the-second** data — and that tier choice cascades into how aggressively you cache vs push.

### Deep dives
1. **Read fan-out architecture (aggregator vs gateway split).** The scaling insight: separate **stateful aggregation** (own a symbol group, maintain latest quote, build candles — in aggregators) from **stateless fan-out** (push to subscribers — in WebSocket gateways). Kafka partitioned by symbol gives per-symbol ordering and clean aggregator ownership; gateways subscribe only to the symbols their clients follow (a symbol→gateway map) so a gateway isn't firehosed by all symbols. This keeps the hot path (one quote → many readers) cheap and lets gateways and aggregators scale independently. The Staff+ point: compute near the data (aggregators), fan-out near the clients (gateways).
2. **Snapshot + delta with sequence numbers + gap recovery.** Streaming only deltas is bandwidth-efficient but fragile: a missed delta corrupts the client's view silently. The standard market-data protocol sends a **full snapshot first**, then **deltas tagged with a per-symbol sequence number**; the client tracks the sequence and, on a gap, knows its local book is stale and triggers a **re-snapshot** (or replays from Kafka retention using its last-seen sequence on reconnect). This is the same "detect staleness via sequence, recover via snapshot" pattern as replication — applied to the read-display path. The framing: deltas for efficiency, sequence numbers for gap detection, snapshots for recovery.
3. **Push-to-cache + short TTL self-healing + the staleness tier.** Two complementary freshness mechanisms: **push** the latest price into caches/gateways via Pub/Sub (sub-ms, publish-ordered fan-out) for low latency, *and* a short **TTL (30–120s)** so an instance that missed a push self-corrects on the next read-through (push for speed, TTL for correctness). The product decision that frames everything is the **acceptable-staleness tier**: a 15-minute-delayed display tolerates aggressive caching and lazy refresh; a real-time trader tier demands push on every tick and tight gap recovery. The Staff+ candidate states the staleness SLO up front and derives the caching/push aggressiveness from it.

## Known failure modes
1. **Hot-symbol fan-out bottleneck.** One mega-watched symbol overloads a node/gateway. Production answer: regional edge fan-out, batching/coalescing rapid ticks, delta+binary encoding, replicate the hot symbol's quote across gateways.
2. **Silent stale view from a missed delta.** A dropped update corrupts the client's price/book with no error. Production answer: per-symbol sequence numbers to detect gaps → re-snapshot; replay from Kafka retention on reconnect; short cache TTL as a backstop self-heal.
3. **Over-fresh or under-fresh display.** Pushing every tick to casual viewers is wasteful; lazily caching for traders is wrong. Production answer: define the staleness tier (15-min delayed vs real-time) and match caching/push aggressiveness to it; serve different tiers from different paths.

## (Delineation note)
`stock-ticker` is the read-heavy price-display fan-out + freshness problem. The trading-engine matching/order placement is a concurrent-resource concern (not this); the WebSocket connection-management substrate is shared with messaging — reference, don't re-derive. Here it's caching the latest quote + push fan-out + snapshot/delta + staleness tiers.

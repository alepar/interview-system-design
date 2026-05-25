---
slug: flash-sale
archetype: concurrent-resource
sources:
  flash_sale_singhajit: singhajit.com/flash-sale-system-design/
  redis_dedup: redis.io/tutorials/data-deduplication-with-redis/
  alibaba_double11: infoq.com/news/2012/12/interview-taobao-tmall/
  seckill_lua: developer.aliyun.com/article/878247
  trip_flash_sale: medium.com/@trip-tech/how-trip-com-group-engineered-a-robust-flash-sale-system-scaling-to-millions-of-concurrent-users-031aead9b660
---

# Flash Sale / Seckill (extreme-contention limited-stock sale)

## Bar anchors
- **Mid-level (L4/E4):** `UPDATE stock SET qty = qty - 1 WHERE id = ?` per request. Doesn't see that 10M concurrent buyers for 1,000 units melt a single DB row, or how to prevent oversell.
- **Senior (L5/E5):** Pre-deduct stock in Redis with an atomic op, queue admitted orders to the DB asynchronously, rate-limit, reject sold-out fast. Knows the DB shouldn't see losers. May not articulate the atomic check-and-decrement correctness (negative-stock), the layered funnel quantitatively, the token-gate, or hot-key sharding.
- **Staff+ (L6/E6+):** Drives proactively. Makes inventory deduction **atomic in Redis** (a **Lua script**: check-dedup → check-stock → DECR → record-buyer, executed as one indivisible unit) so the DB never sees the ~99.8% of losing requests; prevents **oversell-to-negative** (plain DECR can go negative → either Lua GET+DECR, or detect DECR<0 and compensate with INCR+reject). Describes the **layered funnel** that sheds ~1 order of magnitude per tier (CDN/static page ~10s TTL: 10M→~1M; waiting room: →~100k/s; **token gate** clamped to inventory size; Redis DECR; MQ → DB sees ~1k steady writes/sec). Uses a **token-gate** (pre-mint exactly N tokens into a Redis list; atomic LPOP per buy ⇒ oversell mathematically impossible). Handles **hot-key contention** (shard one stock counter into N sub-keys, DECR a random shard), **idempotency/one-per-user** (SETNX + DB `UNIQUE(user,sku,sale)`), bot/rate-limiting, cache warm-up. Quotes scale (Alibaba 2012: 13k orders/sec, 40k QPS, 200ms; Xiaomi 10k units in 1.1s; Redis ~100k ops/sec).

## Canonical decomposition

### Requirements
**Functional:**
- Sell a tiny fixed stock (e.g. 1,000 units) to a huge concurrent crowd (millions) starting at T0
- Never oversell; one purchase per user; fair-ish admission
- Keep the site up (don't let the spike take down the DB/origin)

**Non-functional (with numbers):**
- 10M+ concurrent users, 1,000s of units; peak requests/sec orders of magnitude above inventory
- DB sees only the winners (~1k writes/sec), not the 99.8% losers
- Redis atomic ops ~100k ops/sec/instance; sub-ms stock gate
- Oversell tolerance: zero (atomic decrement / token gate)

### Core entities
- **Stock counter:** Redis integer (or N sharded sub-counters) — the gatekeeper
- **Token:** a pre-minted purchase right (Redis list, one per unit)
- **Order:** created async from an admitted request (via MQ → DB)
- **Dedup set:** users who already bought (SISMEMBER / SADD), enforcing one-per-user

### API
- `POST /buy {user, sku}` → edge rate-limit → Redis Lua (dedup+stock gate) → MQ → async order
- Redis Lua: `if SISMEMBER buyers user then reject; if GET stock <= 0 then sold_out; DECR stock; SADD buyers user`
- sold-out: serve a static page at the edge once stock hits 0
- DB `UNIQUE(user_id, sku_id, sale_id)` as the final oversell/one-per-user safety net

### HLD
The whole design is a **funnel that protects a single hot resource**. Requests first hit a **CDN** serving the static product/countdown page (~10s TTL) — turning a 10M spike into ~1M reaching origin. A **virtual waiting room** admits users at a controlled rate (~100k/s). Admitted buy requests hit the **Redis stock gate**: an atomic **Lua script** does dedup (SISMEMBER), stock check (GET), decrement (DECR), and buyer-record (SADD) as **one indivisible unit** — no interleaving, so no oversell. The key correctness subtlety: a bare `DECR` can drive stock negative under race, so either the Lua wraps GET+DECR, or the code treats a negative DECR return as oversold and compensates (`INCR` + reject). An even stricter variant is the **token gate**: before the sale, pre-mint exactly N tokens (one per unit) into a Redis list; each buy does an atomic **LPOP** — when the list is empty there are literally no tokens to hand out, so overselling is impossible.

Winners (those who got stock/a token) are placed on a **message queue**; a worker pool drains it and writes orders to the DB asynchronously, so the DB sees a **steady ~1k writes/sec** instead of the raw spike. Losers get a fast **sold-out** response (static page at the edge once stock = 0 — reject early, cheaply). Cross-cutting: **rate limiting + bot mitigation** (token bucket per user/IP/device — bots try to drain stock in the first 50ms), **idempotency/one-per-user** (the dedup set + a DB `UNIQUE(user, sku, sale)` constraint as the last line of defense), and **cache warm-up** (preload stock + product into Redis before T0). For a single hot stock key, **shard** it into N sub-counters (DECR a random shard) to spread write contention across the cluster.

### Deep dives
1. **Atomic stock deduction + oversell-to-negative.** The core correctness mechanism: the check-and-decrement must be atomic, or two requests both read stock=1 and both succeed (oversell). Redis Lua runs the whole check→DECR→record as one unit (no command interleaves), which is why it's the canonical seckill primitive. The trap is that a naked `DECR` on a counter at 0 returns −1 (oversold by one), so you either guard inside the Lua (`if GET <= 0 then reject`) or detect the negative return and compensate (`INCR` + sold-out). The **token gate** (LPOP from a list pre-sized to inventory) sidesteps the arithmetic entirely — you can't pop a token that doesn't exist. The Staff+ point: oversell prevention reduces to "make the gate atomic and bounded."
2. **The layered funnel + async order processing.** No single tier can absorb 10M concurrent buyers, so each tier sheds ~an order of magnitude: CDN (cache the static page, ~10s TTL) → waiting room (admit at a sustainable rate) → token/stock gate (clamp to inventory) → MQ → DB. The DB, the scarcest resource, ends up seeing only the ~1k winning orders/sec. The MQ decouples "admitted" from "persisted" so a burst doesn't hit the DB synchronously; compensation handles payment failures (release the stock/token). The framing: keep the authoritative scarce resource (stock counter) in fast memory as the gatekeeper, and make everything downstream async — the DB is for durability of winners, not for arbitrating the race.
3. **Hot-key contention, fairness, and bots.** Even Redis has a limit: all DECRs on one stock key hit one node. Shard the counter into N sub-keys (DECR a random shard, sum for display) to spread it. **Fairness** is a design choice: pure first-come rewards fast bots, so a waiting room with **random** queue ordering (random score in a Redis sorted set) gives humans equal odds; bots are the dominant adversary (rate-limit per user/IP/device-fingerprint, behavioral checks). **One-per-user** is enforced by the dedup set plus a DB unique constraint (so even a race that slips through Redis can't create two orders). These three — hot-key sharding, fairness/anti-bot, and idempotency — are what separate a toy "atomic DECR" answer from a production seckill.

## Known failure modes
1. **Oversell.** Non-atomic check-then-decrement lets two buyers claim the last unit. Production answer: atomic Lua (check+DECR+record as one unit) or a token gate (LPOP from an inventory-sized list); DB `UNIQUE` constraint as the backstop; compensate on negative DECR.
2. **DB meltdown from the spike.** Synchronous DB writes per request collapse under millions of concurrent buyers. Production answer: the layered funnel (CDN + waiting room + Redis gate) so the DB sees only winners; MQ + async order persistence; reject sold-out at the edge.
3. **Bots drain stock unfairly in the first milliseconds.** Scripts grab all units before humans can click. Production answer: per-user/IP/device rate limiting, a randomized waiting room (not pure FCFS), behavioral/bot detection, and per-user purchase caps (dedup set + unique constraint).

## (Delineation note)
`flash-sale` is the extreme-contention limited-stock variant of the concurrent-resource archetype. The seat-hold variant is `ticketmaster`; the bot-fairness variant is `sneaker-drop`; the steady-state checkout-inventory variant is `ecommerce-inventory`. Building Redis is infra-primitives; the payment engine is `stripe-payments` — reference, don't re-derive.

---
slug: view-counter
archetype: caching-read-heavy
sources:
  sd_one_counter: systemdesign.one/distributed-counter-system-design/
  netflix_counter: netflixtechblog.com/netflixs-distributed-counter-abstraction-8d0c45eb66b2
  redis_hll: redis.io/docs/latest/develop/data-types/probabilistic/hyperloglogs/
  educative_sharded_counter: educative.io/courses/system-design-interview-prep-crash-course/design-sharded-counters
  hi_topk: hellointerview.com/learn/system-design/problem-breakdowns/top-k
---

# View / Like Counter (hot-key counting at scale)

## Bar anchors
- **Mid-level (L4/E4):** `UPDATE posts SET views = views + 1` per view. Doesn't see that a viral item's counter is a single hot row, or that exact synchronous counting doesn't scale.
- **Senior (L5/E5):** Increments a counter in Redis and flushes to the DB periodically; knows a viral item is a hot key and counts can be eventually consistent. May not articulate the sharded-counter pattern, approximate unique counting (HyperLogLog), idempotent dedup, or the flush-interval freshness tradeoff.
- **Staff+ (L6/E6+):** Drives proactively. Names the **hot-key problem** (a viral video's counter is one hot key — BTS "Butter" took 108M views/24h ≈ 1,250/sec average, far higher at peak) and the **sharded-counter fix** (split one counter into N sub-counters keyed by bucket; increment a random shard, **sum all N on read** — read cost rises linearly with N, so N trades write-contention vs read-overhead). Uses **write batching + periodic flush** (increment in cache, aggregate deltas by id every 1–10s via a stream processor like Flink, flush to DB) and accepts **eventual consistency** for display. Uses **HyperLogLog** for unique-view cardinality (12KB, 0.81% error, ~400,000× smaller than a Set of 100M IDs). Makes counting **idempotent** (dedup via an idempotency key with `SET NX EX`, or a Bloom filter on the event stream). Cites Netflix's Distributed Counter (75K req/s, single-digit-ms, Best-Effort vs Eventually-Consistent modes with immutable event log + background rollup).

## Canonical decomposition

### Requirements
**Functional:**
- Increment a count (view/like) per event; read the current count
- Survive viral hot items without a single-row write bottleneck
- Count unique viewers (dedup) without storing every viewer id
- Display counts can be slightly stale (eventual consistency)

**Non-functional (with numbers):**
- Viral hot key: 100M+ views/day on one item (peak ≫ 1,250/sec average)
- Flush interval 1–10s (freshness vs DB-write load tradeoff)
- HyperLogLog: 12KB, 0.81% std error for unique cardinality
- Netflix Distributed Counter: 75K req/sec, single-digit-ms latency

### Core entities
- **Counter:** id → total (logically; physically N sharded sub-counters)
- **Sub-counter:** (id, bucket_id) → partial count (summed on read)
- **HyperLogLog:** per-id sketch for unique-viewer cardinality
- **Idempotency key:** per-event token to dedup double-counts

### API
- `increment(id)` → bump a (random) sub-counter shard, or log an immutable event
- `get(id) → count` → sum the N sub-counters (or read the rolled-up aggregate)
- `unique(id) → estimate` → PFCOUNT on the HyperLogLog
- dedup: `SET idemp:<event_id> 1 NX EX <ttl>` before counting

### HLD
A naive `UPDATE … views = views+1` serializes all writes for one item onto a single row/key — fatal for a viral item. The **sharded-counter** pattern splits each logical counter into **N physical sub-counters** keyed by `(id, bucket_id)`; an increment bumps a randomly chosen shard (spreading write contention across N keys/nodes), and a **read sums all N shards**. N is a tradeoff: too few ⇒ write contention; too many ⇒ read-aggregation overhead. On top, writes are **batched**: increments accumulate in a cache/stream and a processor (e.g. Flink) **aggregates deltas by id every 1–10s** and flushes to the durable store — turning 100 like-events into one UPDATE. The display count is **eventually consistent** (the flush interval is the freshness-vs-load knob). For **unique** views (distinct viewers), a **HyperLogLog** estimates cardinality in 12KB at 0.81% error instead of storing 100M viewer ids (~5GB Set) — a ~400,000× memory win. Counting is made **idempotent** (a retried event must not double-count) via an idempotency key (`SET NX EX` with a TTL) or a Bloom filter over the event stream.

Netflix's Distributed Counter Abstraction is the production reference: it offers **Best-Effort** (near-immediate, slightly approximate) and **Eventually-Consistent** (each count logged as an immutable event with an idempotency key, aggregated by a background time-windowed rollup) modes, sustaining 75K req/sec at single-digit-ms latency.

### Deep dives
1. **The sharded-counter hot-key fix.** A single counter is a single hot key; in any keyed store all its increments land on one node. Splitting into N sub-counters (`counter:video:{0..N-1}`) and incrementing a random shard spreads writes across N nodes; reads sum the N partials. The dial: small N = write contention persists; large N = every read pays N lookups. A static N can still hotspot the very hottest items, so adaptive shard counts (more shards for hotter counters) are the refinement. This is the canonical answer to "how do you count a viral item" and the Staff+ candidate names the read-overhead cost explicitly.
2. **Approximate + idempotent counting.** Two probabilistic/structural techniques: **HyperLogLog** for *unique* counts (12KB, 0.81% error vs ~5GB for 100M exact ids — accept the error for a 400,000× memory win), and **idempotent dedup** so retries/duplicate events don't inflate counts (an idempotency key with `SET NX EX <ttl>` gives exactly-once within the TTL window; Bloom filters give cheap probabilistic dedup over a Kafka stream). The framing: at viral scale, *exact* counting is neither necessary (display) nor affordable (unique), so trade bounded error for memory and dedup for correctness-under-retry.
3. **Batching, flush interval, and consistency modes.** Per-event DB writes don't scale, so increments aggregate in cache/stream and flush periodically; the **flush interval (1–10s)** trades display freshness against DB write load. Netflix formalizes this as two modes: **Best-Effort** (fast, approximate — fine for a like count) and **Eventually-Consistent** (durable: each event is an immutable log entry with an idempotency key, rolled up by a background time-windowed job — used when the count must reconcile exactly over time). The Staff+ point: choose the consistency mode per use case (a display like-count vs a billing-relevant count), and make the flush interval an explicit SLA parameter.

## Known failure modes
1. **Viral hot key write bottleneck.** One item's counter saturates a single node. Production answer: sharded counter (N sub-counters, random-shard increment, sum-on-read), adaptive N for the hottest items, write batching/aggregation upstream.
2. **Double counting under retries / at-least-once delivery.** A retried view or duplicated stream event inflates the count. Production answer: idempotency key (`SET NX EX`) for exactly-once within a window, or Bloom-filter dedup on the stream; immutable event log + idempotent rollup (Netflix) for durable exactness.
3. **Unique-count memory blowup.** Storing every viewer id to dedup uniques costs gigabytes per hot item. Production answer: HyperLogLog (12KB, 0.81% error) for cardinality; accept the bounded error rather than an exact Set.

## (Delineation note)
`view-counter` is the hot-key counting + approximate-structures problem. Building the KV store is infra-primitives; the trending-list variant is `top-k-trending`; the leaderboard (ranked) variant is `leaderboard`. Here it's distributed counting under write hotspots + eventual consistency.

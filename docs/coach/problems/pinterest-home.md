---
slug: pinterest-home
archetype: fan-out
sources:
  smartfeed: medium.com/pinterest-engineering/building-a-smarter-home-feed-ad1918fdfbe3
  smartfeed_scalable: medium.com/pinterest-engineering/building-a-scalable-and-available-home-feed-6a343766bb6
  pixie: cs.stanford.edu/people/jure/pubs/pixie-www18.pdf
  singer_kafka: medium.com/pinterest-engineering/how-pinterest-runs-kafka-at-scale-ff9c6f735be
  hbase_deprecation: medium.com/pinterest-engineering/hbase-deprecation-at-pinterest-8a99e6c8e6b7
---

# Pinterest home — SmartFeed Worker multi-source priority queue + dual HBase cluster (Pools writes + Materialized reads) + Pixie graph candidate generator + Zen abstraction + Singer/Kafka 120B+ msgs/day

## Bar anchors
- **Mid-level (L4/E4):** Produces chronological per-user inbox. No multi-source ranking at fan-out time.
- **Senior (L5/E5):** Names push-with-ranking. May or may not articulate the dual-cluster split, Pixie graph, or Zen abstraction.
- **Staff+ (L6/E6+):** Names (a) **SmartFeed Worker ingesting 3 push sources** (repins from followed users, related-pins recommendations, pins from followed interests) into per-user HBase priority queue with quality score at write time; (b) **dual HBase cluster**: Pools (high-write, all candidates) + Materialized (read-optimized, shown pins) — scales independently; after read, SmartFeed Service moves shown pins pools→materialized; (c) **HBase key = user|score|pin_id** for priority-queue semantics — newly-added triples insert at appropriate location to maintain score order; (d) **Pixie graph** as candidate generator: bipartite pin-board graph (175B+ pins, ~100B edges pruned to ~20B/150GB RAM); biased random walks; 60ms p99, 1K QPS/server, >60% of Pinterest engagement, >10B recommendations/day; (e) **Zen abstraction layer** over HBase — graph data model hides region/partition operations; (f) **Singer+Kafka 120B+ msgs/day** — same backbone powers fan-out source streams and downstream ML feature pipelines; (g) **speculative execution** to hot standby in different EC2 AZ at 99.9th percentile latency → four nines availability; (h) **historical note**: Pinterest deprecated HBase entirely (50 clusters, 9K EC2 instances, 6+ PB) in favor of TiDB/KVStore/Druid/Goku.

## Canonical decomposition

### Requirements
**Functional:**
- Pin an image to a board
- Repin (save pin to own board)
- Follow user/interest
- View home feed (multi-source ranked)

**Non-functional:**
- Hundreds of TB; millions of HBase ops/sec; ms read latency
- Write latency tolerates seconds/minutes (PinLater decouples)
- Pixie: 175B+ pins, ~100B edges, 60ms p99, 1K QPS/server
- Singer+Kafka: 120B+ msgs/day, thousands of hosts

### Core entities
- **Pin:** pin_id, image_url, board_id, author_id, quality_score
- **Board:** board_id, owner_id
- **InboxEntry:** user|score|pin_id (HBase priority queue)
- **PixieGraphNode:** pin_id ↔ board_id edges

### API
- `POST /pins` → {pin_id}
- `POST /pins/:id/repin` body={board_id}
- `GET /feed?cursor=<>` → {pins[], next_cursor}
- `POST /follows` body={target_type, target_id}

### HLD
Source streams: (a) Repins from followed users → Singer/Kafka; (b) Pixie graph recommendations (biased random walks on pin-board bipartite graph; bot-tuned biases discount low-signal walks); (c) Pins from followed interests/topics.

Write path: SmartFeed Worker consumes from all 3 sources; assigns quality score per candidate; writes via PinLater into Pools cluster (HBase priority queue keyed by user|score|pin_id). Decoupled: writes tolerate seconds/minutes.

Read path: SmartFeed Service reads top-N from Pools cluster; merges with cached shown pins from Materialized cluster; returns to client. After read, moves shown pins Pools→Materialized + deletes from Pools.

Pixie: bipartite pin-board graph (~20B edges in 150GB RAM); biased random walk personalized PageRank; serves >10B recs/day to SmartFeed.

Speculative execution: hot standby in different EC2 AZ syncing within hundreds of ms; cuts off at 99.9th percentile latency; achieves four nines.

### Deep dives
1. **SmartFeed Worker + 3 push sources + per-user priority queue.** Sources: repins, Pixie recs, interest-follows. SmartFeed Worker scores each at write time + writes via PinLater into HBase priority queue. Decouples write rate (seconds/minutes) from read rate (ms p99). Inbox is multi-source + pre-ranked at fan-out time rather than chronological.
2. **Dual HBase cluster (Pools + Materialized) + Zen abstraction.** Pools: high write QPS, all candidates per user. Materialized: read-optimized, cached shown. After read: move shown pools→materialized + delete from pools. Zen: graph data model on HBase, hides region/partition ops; lets feed code treat HBase as graph DB.
3. **Pixie + speculative execution + Singer/Kafka backbone.** Pixie powers >60% of Pinterest engagement, >10B recs/day. Hot standby in different EC2 AZ; speculative cuts at 99.9th percentile → four nines. Source streams through Singer+Kafka (120B+ msgs/day) shared with downstream ML pipelines.

## Known failure modes
1. *Pools cluster hot writes on viral pin* — millions of priority-queue writes simultaneously. Production answer: PinLater absorbs spike async; SmartFeed Worker batches.
2. *Speculative execution doubles cost in steady state* — 99.9th-percentile means ~0.1% requests fire to standby. Production answer: explicit cost budget; tune threshold; only hot-path queries.
3. *HBase technical-debt motivates entire stack migration* — Pinterest's HBase deprecation reflects 5-yr-behind-upstream issues, lack of distributed txns, 6-replica primary-standby cost. Production answer: phased migration to TiDB / KVStore / Druid / Goku per workload.

## Notes for the coach
- **Asked-confirmed at Pinterest.** SmartFeed blog + Pixie paper are canon.
- **Cross-coverage** with ML-in-loop `pinterest-pixie` (Pixie graph is in both archetypes — fan-out source vs ML candidate generator).
- **The SmartFeed multi-source priority-queue at write time is the canonical Staff+ unlock.** Most candidates draw chronological inbox; Pinterest scores at fan-out time and stores in HBase priority-queue order.
- **Adversarial probe: "Pinterest just announced HBase deprecation. How do you migrate the SmartFeed stack?"** Strong answer: phased per-workload migration — feed serving to TiDB (for distributed transactions); recs serving to KVStore (RocksDB+Rocksplicator for low-latency reads); analytics to Druid/StarRocks; counters to Goku. Migrate one cluster at a time; shadow-traffic validation. Weak answer: "rewrite everything in TiDB" without naming the workload-mismatch dimensions.

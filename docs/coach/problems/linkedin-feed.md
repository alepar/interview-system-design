---
slug: linkedin-feed
archetype: fan-out
sources:
  followfeed: linkedin.com/blog/engineering/feed/followfeed-linkedin-s-feed-made-faster-and-smarter
  concourse: linkedin.com/blog/engineering/messaging-notifications/concourse-generating-personalized-content-notifications-in-near
  next_gen_feed: linkedin.com/blog/engineering/feed/engineering-the-next-generation-of-linkedins-feed
---

# LinkedIn feed — pure pull (fan-out-on-read) via FollowFeed RocksDB outboxes + 720-partition broker with hedged duplicate requests + Concourse Samza/Kafka recipient-side re-partitioning

## Bar anchors
- **Mid-level (L4/E4):** Defaults to push to all followers. Doesn't recognize that LinkedIn's reciprocal-graph + low-posting-frequency workload inverts the storage economics.
- **Senior (L5/E5):** Names pull-vs-push trade. May or may not articulate the 62× storage saving, 720-partition broker, hedged duplicate requests, or Concourse recipient-side re-partitioning.
- **Staff+ (L6/E6+):** Names (a) **architectural justification for pull**: LinkedIn's connection graph is mostly bidirectional/reciprocal, low posting frequency, no Bieber-class superstars — push storage amplification unfavorable; per FollowFeed verbatim "Data size with this model [push] was 62 times greater than pull-based architecture"; (b) **FollowFeed RocksDB per-author outbox** keyed by (entity_id, content_type, position); linked-list-of-blobs storage; (c) **720-partition over-partitioning** (chosen because 720 has many divisors: 40/45/60/80/360 → flexible cluster resizing); (d) **broker hedged-duplicate requests** at 1/2/3 replicas with staggered timeouts — mobile p99 ~140ms, 5× faster than Sensei predecessor; (e) **Concourse**: Kafka partitioned by actor pre-fanout and **re-partitioned by recipient post-fanout** so all candidates for one recipient land on same scoring host — distributes load and handles super-actors without bottlenecks; (f) scale: ~500K QPS scoring at peak, RocksDB tens-of-µs reads vs ms-to-hundreds-ms remote calls; local-DC Kafka ~4× capacity vs global.

## Canonical decomposition

### Requirements
**Functional:**
- Post update (text + media + article)
- View feed (chronological + relevance-ranked)
- Connect/follow; mute; hide
- React/comment/share

**Non-functional:**
- 1.3B members; mobile feed p99 ~140ms; relevance computation ~50µs p99 per record
- FollowFeed: 20× more data than predecessor Sensei; 50% capex reduction; 150ms p90 improvement
- Concourse: 500K QPS scoring; millions of candidates/sec; feature store hundreds of billions of records / several TB

### Core entities
- **Member:** member_id, connections[], follows[]
- **Activity:** entity_id, author_id, content_type, position, created_at
- **OutboxEntry:** (entity_id, content_type, position) → activity blob in RocksDB linked-list
- **FeatureRecord:** {actor, item, recipient, edge} features in RocksDB feature cache

### API
- `POST /activities` → {entity_id}
- `GET /feed?cursor=<>&limit=20` → {activities[], next_cursor}
- `POST /connections` (mutual-acknowledge gated)

### HLD
Write path: Activity Service writes to Activity Store. Publishes to Kafka actor-partitioned topic. FollowFeed indexer writes per-author outbox entry to local RocksDB on index node (sharded by author_id mod 720). Author outbox = linked-list of blobs keyed by (entity_id, content_type, position).

Read path: Broker receives feed request; fans out queries to N index nodes holding partitions for author IDs in member's follow set. Per partition, **hedged duplicate requests** to 1/2/3 replica index nodes with staggered timeouts; master-master replicas all serve real-time reads. Aggregator merges + ranks via GLMix scorer; returns top-N.

Notification path (Concourse): activity event lands on actor-partitioned Kafka topic; Samza fanout job emits (candidate, recipient) tuples for each follower; **re-partitioned by recipient_id** onto downstream Kafka topic. Recipient-partitioned Samza scoring task consumes; loads 4 feature categories (Actor/Item/Recipient/Edge) from local RocksDB cache (tens of µs) and computes click probability + notification-disable rate; **message consolidation** when recipient reachable via multiple edges (picks most-relevant path).

### Deep dives
1. **Pull-only justification + RocksDB per-author outbox.** Reciprocal-mostly graph; M_following typically 500-1000; compute cost bounded. Storage = O(authors × posts) instead of O(users × posts × followers) → 62× saving. RocksDB linked-list blobs; read-update-write split when blob exceeds size limit.
2. **720-partition broker + hedged requests.** 720 chosen for divisor flexibility (40, 45, 60, 80, 360). Broker fans out to N index nodes; **hedged duplicate requests** to 1/2/3 replica nodes with staggered timeouts compress tail latency without dedicated stand-by tier. Master-master replicas all serve reads.
3. **Concourse Kafka re-partitioning + RocksDB feature cache.** Per-actor pre-fanout (producer load distribution) → recipient-partitioned post-fanout (all candidates for recipient on same scoring host) → Samza scoring with local RocksDB feature cache (µs vs ms-to-hundreds-ms remote). Local-DC consumption gives ~4× capacity vs global aggregates.

## Known failure modes
1. *Slow author / large follow set drives p99* — broker hedged duplicate requests mitigate but a 5K-author follow-set is worst-case slow. Production answer: per-author timeout + partial-result rendering.
2. *Re-partitioning by recipient creates hot recipients* — 100M-follower user makes one scoring host hot. Production answer: per-recipient rate-limit + sharded scoring across N partitions for super-actors.
3. *Real-time backpressure from Samza* — slow RocksDB → task lag → Kafka topic backlog. Production answer: dead-letter queue for repeatedly-failing scoring; surface affected-recipient counts to ops.

## Notes for the coach
- **Asked-confirmed at LinkedIn.** Plausibly Microsoft (Teams/Outlook feed-style features) given parent ownership.
- **Architectural opposite** of `instagram-feed` (hybrid) and `twitter-timeline` (push-default). Pair to teach the pull-vs-push trifecta.
- **The 62× storage justification is the canonical Staff+ unlock.** Mid-senior candidates default to push; Staff+ candidates quote the storage math that justifies pull for LinkedIn's graph topology.
- **Adversarial probe: "Your CEO mandates push because reads are slow. What do you tell them?"** Strong answer: 62× storage = ~62× compute & TCO bill; LinkedIn graph has no Bieber celebrities to mitigate; reads bounded by typical M_following; current p99 140ms is fine; counter-proposal = precompute top-N rather than full inbox. Weak answer: "push is bad" without the storage math.

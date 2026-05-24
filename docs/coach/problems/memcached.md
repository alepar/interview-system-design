---
slug: memcached
archetype: infra-primitives
sources:
  facebook_nsdi: usenix.org/system/files/conference/nsdi13/nsdi13-final170_update.pdf
  netflix_evcache: infoq.com/articles/netflix-global-cache/
  tao_paper: usenix.org/system/files/conference/atc13/atc13-bronson.pdf
  redis_cluster_spec: redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/
  caffeine_tinylfu: arxiv.org/abs/1512.00727
---

# Memcached / Redis Cluster / EVCache / TAO (distributed in-memory cache)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic distributed cache: hash the key, route to a node, store in memory. Names LRU eviction. Discusses cache-aside / lookaside pattern. Doesn't address stale-set races, thundering herds, regional invalidation, or fault-tolerance patterns unprompted.
- **Senior (L5/E5):** Names consistent hashing for shard membership; discusses Redis Cluster's 16384 slots or Memcached's client-side hashing. Articulates lookaside vs write-through; identifies cache-coherence problem on writes (invalidate, write-through, or write-back). Knows about LRU vs LFU at category level. Identifies cross-region replication as a separate concern.
- **Staff+ (L6/E6+):** Drives proactively. Quantifies scale anchors: Facebook Memcached (NSDI 2013) — billions of reads/sec, trillions of items, "over a billion users"; Netflix EVCache 400M ops/sec, 14.3 PB, 22K instances; TAO 1B+ reads/sec, 96.4% cache hit rate, 3s p99 slave replication lag. Names Facebook's three production patterns: (a) **leases** — 64-bit token issued on miss; only the lease holder may set the key; concurrent misses wait or get stale; eliminates both thundering-herd and stale-set races in one mechanism; (b) **gutter pool** — ~1% of capacity reserved as fallback when primary shard fails; bounds blast radius; (c) **mcsqueal + mcrouter** — MySQL commit-log tailer batches deletes into packets routed by mcrouter, amortizing per-key invalidation at billion-QPS scale. Names Redis Cluster specifics: 16384 hash slots (CRC16 mod 16384), bitmap fits in 2KB heartbeat; MOVED (permanent slot relocation) vs ASK (transient during migration) redirects; gossip-based membership with PFAIL/FAIL flags. Discusses W-TinyLFU (Caffeine) as the in-process admission-policy frontier — beats LRU by 10-30% hit rate via Count-Min sketch frequency comparison; ~2 bytes/entry overhead. Identifies the lookaside-vs-write-through architectural fork: Memcached/EVCache are lookaside; TAO is write-through (Facebook social graph cache, leader-follower per shard). Stretch (Sr Staff bar): articulates Netflix EVCache's WAL-based cross-region replication (Kafka + SQS, P90 cross-region replication latency <2s); discusses Moneta SSD-tier with L1 get p95=153μs / p99=191μs.

## Canonical decomposition

### Requirements
**Functional:**
- In-memory KV cache with sub-millisecond get/set latency
- Lookaside semantics: client reads cache, falls back to DB on miss, writes back to cache after DB load
- TTL-based expiry + LRU/LFU eviction when memory is full
- Multi-region replication with bounded staleness (where required)
- Thundering-herd protection: prevent N concurrent clients from all hitting the DB on a hot-key miss
- Sharding with consistent-hash routing; client-side discovery of shard ownership

**Non-functional (with numbers):**
- Sub-ms p99 latency for cache hits within a region
- Billions of reads/sec aggregate (Facebook NSDI 2013: "billions of requests per second" across the cluster)
- Trillions of items capacity (Facebook), 14.3 PB capacity (Netflix EVCache)
- 95-99% hit rate target (TAO published: 96.4%; lower = DB overload risk)
- Cross-region replication lag <2s p90 (Netflix EVCache WAL-based)
- Single-node throughput: 100K-500K ops/sec depending on op type + data size
- Failure tolerance: single shard down absorbs into gutter pool (~1% capacity reserved); regional outage absorbs via cross-region read

### Core entities
- **Cache node:** holds key-value pairs in memory; LRU/LFU eviction queue; configurable max memory; per-key TTL
- **Hash slot (Redis Cluster) / consistent-hash ring position (Memcached):** assignment of keys to nodes; clients route directly without proxy
- **Lease (Facebook Memcached):** 64-bit token issued on miss; binds a specific writer to subsequent SET; rejects concurrent SETs from non-lease-holders
- **Gutter shard:** small pool (~1% of capacity) of fallback nodes; populated by clients on primary-shard failure
- **mcrouter / proxy:** stateless client-side proxy; handles consistent hashing, retries, failover, lease tracking, batched invalidation
- **Regional cluster:** independent cache fleet per region; replicated invalidations via Kafka/SQS or mcsqueal

### API
- `get(key)` → value or null; sub-ms p99
- `set(key, value, ttl)` → unconditional write (or with lease token: rejected if lease doesn't match)
- `delete(key)` → invalidation; often batched at the proxy layer
- `cas(key, value, version)` → compare-and-swap for write-with-version
- Lease-aware get: `get(key) → (value | (null, lease_token))`; client uses lease_token in subsequent set to prevent stale-set race
- Cluster topology API: `CLUSTER NODES` (Redis), shard map config (Memcached client library)

### HLD
Application servers are stateless; each holds a client library (mcrouter for Memcached, Redis Cluster client, Hazelcast/Caffeine for in-process). On request: (1) compute `slot = hash(key) mod 16384` (Redis Cluster) or consistent-hash position (Memcached), (2) route to the owning cache node, (3) on cache hit, return; on miss, fall back to the DB (lookaside) or compute (TAO write-through writes both DB and cache via the leader). On write to the source-of-truth DB, invalidate the cache: either explicit delete (mcrouter pattern) or via a tailed commit log (Facebook's mcsqueal pattern: MySQL commit-log tailer → mcrouter → fanout to all regions' Memcached fleets).

**Thundering-herd defense** on a hot-key invalidation: 10K clients miss simultaneously, all hit DB → DB collapses. Facebook's **lease pattern**: cache server issues a 64-bit lease token on the first miss; subsequent misses for the same key are told to "wait or get stale"; only the lease holder may set the key, and a concurrent invalidation invalidates the lease (preventing stale-set). Alternative patterns: **single-flight** (only one client per key goes to DB, others wait on a per-key future), **probabilistic early expiration** (refresh slightly before TTL with probability scaled by remaining lifetime).

**Sharding architecture choice.** Redis Cluster uses **16384 fixed hash slots** (CRC16(key) mod 16384); the slot count is tuned so the slot bitmap fits in a 2KB cluster heartbeat. Clients maintain a slot→node map and refresh on **MOVED** redirects (permanent slot relocation after rebalance) or **ASK** redirects (transient during ongoing migration; the client must send `ASKING` prefix on the next single command). Membership and slot ownership propagate via **gossip** with **PFAIL/FAIL** flags; majority of masters required to mark a node FAIL. Memcached's classical model uses client-side consistent hashing without any server-side cluster awareness; mcrouter centralizes that logic.

**Multi-region replication.** Netflix EVCache uses **async WAL-based cross-region replication** (Kafka + SQS) — writes/deletes mirrored via per-cluster Write-Ahead Log to other regions; P90 cross-region replication latency <2s; replication failure never blocks local reads. Facebook's mcsqueal pattern is similar: MySQL commit-log tailer in the master region batches invalidations into packets routed by mcrouter to all regions. TAO uses leader-follower per shard (writes go to the leader region's leader for the shard; reads from any nearby follower) with explicit per-object eventual consistency.

**Lookaside vs write-through.** Memcached is **lookaside**: cache and DB are independent; cache is populated by clients on miss; consistency on DB writes requires explicit invalidation. TAO is **write-through**: the cache is the gateway; writes go through the cache to the underlying DB (MySQL) — gives stronger consistency at the cost of cache-tier coupling to the DB. Lookaside is simpler operationally; write-through is simpler semantically.

### Deep dives
1. **Facebook's lease pattern: thundering-herd + stale-set in one mechanism.** Stale-set race: writer A reads DB at t0, writer B updates DB and invalidates cache at t1, writer A writes its now-stale value to cache at t2 → cache holds stale data indefinitely (or until next invalidation/expiry). Thundering herd: hot key invalidates → 10K clients miss → all hit DB → DB collapses. Lease pattern solves both: on cache miss, the cache server issues a 64-bit lease token (cheap, in-memory); subsequent misses for the same key within a short window are told to "wait or get a stale value" (single-flight); only the lease-holder may SET the key (others rejected). If an invalidation arrives between the miss and the holder's SET, the invalidation invalidates the lease → the holder's SET is rejected → no stale write. Cost: per-cache-server lease state (small); throughput cost ~negligible. Staff+ commit: lease TTL choice (short enough that abandoned leases don't block forever; long enough to cover DB-read p99), what happens on lease expiry without SET (next miss gets a new lease), throttling on hot keys to prevent lease-acquire-rate from being the bottleneck.

2. **Sharding and the Redis Cluster MOVED/ASK protocol.** Redis Cluster's 16384 slots: each master owns some slots; client computes `hash(key) mod 16384 → slot → node` via local slot map. On a slot migration (rebalance after adding/removing a node), the slot moves from source to target. During the migration window, a request for a key in the migrating slot may hit the source (key still there) or the target (key already moved). The protocol: source returns **ASK** (with target address) if the specific key has moved but the slot officially still belongs to source; client retries against target with `ASKING` prefix. Once migration completes, slot ownership flips → source returns **MOVED** (permanent redirect) → client updates its slot map. Why 16384 slots specifically: the bitmap of slot ownership fits in a 2KB cluster gossip heartbeat. Hash tags `{...}` co-locate related keys: `user:{1234}:profile` and `user:{1234}:friends` hash on `1234` only, landing on the same slot for multi-key operations (MGET, transactions, Lua scripts). Staff+ commit: slot-count rationale, ASK vs MOVED semantics, hash-tag pattern for multi-key ops, what happens during ongoing migration (degraded for migrating slots, normal for others).

3. **Multi-region replication and the staleness budget.** Three production patterns: (a) **Netflix EVCache async WAL** — per-cluster WAL captures writes/deletes; Kafka topic per replication pair; downstream applies on receipt; P90 lag <2s; failure of cross-region path never blocks local writes; (b) **Facebook mcsqueal** — MySQL commit log tailed in master region; deletes batched into packets routed via mcrouter to slave regions' Memcached fleets; per-key invalidation amortized across batches; (c) **TAO leader-follower** — one shard leader per object; writes through leader region; reads from any nearby follower; explicit per-object replication lag SLO. All three accept eventual consistency for cross-region reads. The staleness budget = replication lag + clock skew + processing delay. For read-after-write within a session, use session affinity (clients pin to write-region for read-after-write window) or version-token reads (client knows the version it just wrote; rejects cache reads with older version). Staff+ commit: pick a pattern, address what happens during regional failover (stale reads visible for the replication window; document SLA), session-affinity policy for read-after-write.

## Known failure modes
1. **Cache cluster down → DB overload.** Even brief cache outage means all traffic hits the DB, which is sized assuming ~99% cache hit rate; DB collapses under 100× normal load. Production answer: per-region failure isolation (one region's cache down doesn't affect others — Netflix EVCache pattern); rapid cache restart via warm-up from persistent SSD-backed L2 (Redis with `--persistence`, or Netflix Moneta SSD tier); admission-control on the DB to shed load during cache recovery; per-key request coalescing at the application layer to bound DB queries-per-cold-start.

2. **Cache key cardinality explosion.** Application generates unique cache keys per request (e.g., includes timestamp or request ID); cache fills with one-shot entries that never get reused; effective hit rate collapses to ~0. Production answer: key-normalization layer (truncate timestamps to minute, strip query parameters not relevant to caching); per-tenant cache budget caps preventing one tenant's cardinality from evicting another's hot keys; observability on per-prefix hit rate to catch the issue early.

3. **Cross-region replication lag visible to clients (stale read after write).** User writes in region A, then reads from region B before invalidation propagated → sees stale value. Production answer: session affinity (clients pin to write-region for a read-after-write window — typically the replication lag + safety margin); read-your-writes via version tokens (client knows the version it just wrote; cache reads include version; reads with older version are treated as misses); document the stale-read SLO for cross-region failover scenarios.

## Notes for the coach
- **This is the canonical distributed-cache interview prompt.** Asked-confirmed via Hello Interview's "Distributed Cache System" tag (Microsoft / Google / Meta); on every infra interview-prep list (ByteByteGo Vol 2; Educative Grokking; IGotAnOffer). Facebook's NSDI 2013 paper is the implicit model answer.
- **The lease pattern is the L6+ unlock.** Most candidates know about LRU and TTL; the Staff+ candidate names the lease pattern as the unified solution for both thundering herd and stale set. If the candidate proposes single-flight separately from stale-set defense, redirect: "is there one mechanism that solves both?"
- **Redis Cluster covers as the alternate framing.** When the candidate proposes Redis Cluster (16384 slots, MOVED/ASK, gossip), the coach pivots into that variant. Both Memcached-Facebook and Redis Cluster are reference architectures with similar but distinct operational stories; the candidate's call on which to anchor on signals their production background.
- **The 96.4% TAO hit rate + 1B reads/sec is the headline scale anchor.** Citing it grounds the design pressure quantitatively; Netflix EVCache's 400M ops/sec / 14.3 PB is the modern complement.
- **W-TinyLFU / Caffeine is the in-process admission-policy literacy signal.** Most candidates default to LRU; the Sr Staff candidate mentions W-TinyLFU (Count-Min sketch frequency comparison) as outperforming LRU by 10-30% hit rate on skewed real workloads, achieving within 99% of Belady-optimal.
- **Cross-coverage with AI-infra `prompt-cache-infrastructure`:** the AI version uses similar substrate but adds prefix-aware KV-cache lookup (RadixAttention pattern), GPU-VRAM vs DRAM tier, per-tenant cache_salt. Coach should announce "no AI-specific framing" up front for this primitive version.
- **Don't allow drift to "design Redis" full implementation.** Redis-the-product has hundreds of data structures (sorted sets, hyperloglog, streams, etc); this problem stays focused on cache primitive (KV with eviction). If the candidate proposes data structures beyond KV, redirect: "let's stay on the cache shape; complex data structures are a separate problem."

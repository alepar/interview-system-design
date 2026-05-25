---
slug: leaderboard
archetype: caching-read-heavy
sources:
  redis_zset: redis.io/docs/latest/develop/data-types/sorted-sets/
  bytebytego_leaderboard: bytebytego.com/courses/system-design-interview/real-time-gaming-leaderboard
  leaderboard_sd_one: systemdesign.one/leaderboard-system-design/
  redis_cluster_spec: redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/
  hello_interview_leaderboard: hellointerview.com/community/questions/cm4t0qbr9004988ilmum8jm06
---

# Leaderboard (real-time ranking, Redis Sorted Sets)

## Bar anchors
- **Mid-level (L4/E4):** Stores scores in a SQL table and runs `ORDER BY score LIMIT 10` for the top list and a `COUNT(*) WHERE score > x` for a player's rank. Doesn't recognize that rank queries over millions of rows are slow, or reach for a sorted data structure.
- **Senior (L5/E5):** Uses **Redis Sorted Sets** (ZADD/ZRANGE/ZREVRANK) for O(log N) updates and O(log N + M) range reads; knows ranks recompute cheaply vs SQL. Handles time-windowed boards via dated keys. May not articulate sharding a global board + top-K merge, the hot-key write bottleneck, or approximate rank at scale.
- **Staff+ (L6/E6+):** Drives proactively. Picks **Redis Sorted Sets** (skiplist + hashtable; ZADD O(log N), ZRANGE O(log N + M), ZREVRANK O(log N)) as the canonical structure and contrasts with SQL (a rank query over 10M rows can take ~seconds even indexed). Sizes it: ByteByteGo's 5M-DAU board (~500 score-update QPS, ~26 bytes/entry) fits one Redis instance, but a **global board of ~300M entries must shard** (Redis is single-threaded; CPU on rank calc is the bottleneck). Shards **by score range** (supports top-K *and* surrounding-rank queries) or region, with a **k-way merge** of per-shard local top-K into a small, highly-replicated **Top-M ZSET** (e.g. Top 1,000 fits in CPU cache). Names the **hot-key write bottleneck** (all ZADDs for one board key land on one cluster shard regardless of cluster size) and **time-windowed boards** (dated ZSETs + TTL + atomic RENAME on reset). Accepts **eventual consistency** for exact global rank (recompute periodically), exact only for top-K. Quotes read-dominance (~35K writes vs 200K+ reads/sec; top-100 requested far more than it changes ⇒ two-tier cache serves ~99.9% of reads).

## Canonical decomposition

### Requirements
**Functional:**
- Update a player's score; read the top-K; read a specific player's rank + neighbors
- Time-windowed boards (daily/weekly/all-time)
- Reads (view board / my rank) vastly outnumber writes (score updates)

**Non-functional (with numbers):**
- 5M DAU reference: ~500 score-update QPS; ~26 bytes/entry; one Redis instance suffices
- Global board ~300M entries ⇒ must shard (single-threaded Redis CPU-bound on rank)
- Top-K read latency sub-ms (Redis ~0.45ms p99 GET); read:write heavily read-skewed
- Redis Cluster: 16,384 hash slots; ~100K–1M ops/sec/instance

### Core entities
- **ZSET (leaderboard:scope):** member=player_id, score=points; sorted by score
- **Top-M ZSET:** small replicated set holding the global top-K (e.g. 1,000), updated by a merger
- **Time-windowed keys:** leaderboard:daily:2026-05-24, leaderboard:weekly:2026-W21 (+TTL)

### API
- `ZADD leaderboard:<scope> <score> <player>` → update (O(log N))
- `ZREVRANGE leaderboard:<scope> 0 K-1 WITHSCORES` → top-K
- `ZREVRANK leaderboard:<scope> <player>` → player's rank; `ZRANGE` for neighbors
- merger: per-shard local top-K → aggregator min-heap of size K → Top-M ZSET

### HLD
The core is a **Redis Sorted Set** per board scope: `ZADD` updates a player's score in O(log N), `ZREVRANGE 0 K-1` reads the top-K in O(log N + K), and `ZREVRANK` gives a player's exact rank in O(log N) — all far cheaper than SQL, where computing a rank over millions of rows scans/sorts and can take seconds. Sorting happens at **write time** (the ZSET stays ordered), which is ideal because reads (view board, check my rank) vastly outnumber writes. A modest board (ByteByteGo's 5M DAU ⇒ ~500 update QPS, ~26 bytes/entry) fits a **single Redis instance** for both storage and throughput.

At **global scale** (~300M ranked entries) a single instance can't hold it efficiently and Redis's single-threaded rank computation becomes the CPU bottleneck, so the board is **sharded** — by **score range** (which uniquely supports both "global top-K" and "players near rank X") or by region. **Top-K across shards** is a k-way merge: each shard returns its local top-K to an aggregator that merges them in a size-K min-heap; the result is published to a small, **highly-replicated Top-M ZSET** (e.g. Top 1,000) that everyone reads (so the hot read is a tiny in-cache list). **Exact global rank of an arbitrary player** across shards is expensive, so it's computed periodically / approximated (bucketed percentile) — **eventual consistency** is accepted for arbitrary rank, exactness reserved for top-K. **Time-windowed** boards use dated keys (`leaderboard:daily:2026-05-24`) with per-window TTL and an **atomic RENAME** on reset so no writes are lost. A two-tier cache (Redis primary + durable fallback) serves ~99.9% of reads without touching disk.

### Deep dives
1. **Why Redis Sorted Sets, and the memory/encoding model.** A ZSET stores each member twice (hashtable for O(1) score-by-member, skiplist for O(log N) ordered range), ~100–150 bytes/entry in skiplist encoding (small sets use a compact listpack ≤128 members / ≤64-byte members). The win is moving sort cost to write time: ZADD keeps the set ordered, so top-K and rank are logarithmic reads, vs SQL's `ORDER BY`/`COUNT` that recompute per query (~seconds at 10M rows). The Staff+ framing: a leaderboard is a write-time-sorted index optimized for the read-heavy "show me the ranking" access pattern.
2. **Sharding a global board + top-K merge + approximate rank.** One instance caps at ~hundreds of millions of entries and is CPU-bound on rank calc (single-threaded), so shard by score range or region. Top-K is a clean k-way merge (each shard's local top-K → aggregator min-heap → a small replicated Top-M ZSET that absorbs the hot read). The genuinely hard query is **exact rank of an arbitrary mid-pack player across shards** — it requires counting members above them in every shard. Production answer: don't do it synchronously; bucket scores into ranges with maintained counts to return an approximate/percentile rank, and recompute exact ranks periodically. Insisting on immediate exact global rank blows the latency/throughput budget; accept eventual consistency except for top-K.
3. **The hot-key write bottleneck + time windows.** In Redis Cluster the *key* picks the shard, so **all** score updates for one board key land on a **single** shard no matter how big the cluster — a write hotspot. Mitigations: shard the board into sub-keys (by score range / region) so writes spread, then merge for reads; or accept the single-shard write ceiling if update QPS is modest. Time-windowed boards multiply keys (daily/weekly/all-time as separate ZSETs) with per-window TTL; resetting a window uses atomic RENAME so concurrent writes during the swap aren't lost. Updating multiple windows on each score event is the write-amplification cost.

## Known failure modes
1. **Write hotspot on the board key.** All ZADDs for one leaderboard hit one cluster shard, capping write throughput. Production answer: split into range/region sub-shards (writes spread, reads merge) or a write-aggregation layer; don't assume cluster size raises single-key write capacity.
2. **Exact-global-rank query melts latency.** Computing an arbitrary player's exact rank across shards is O(all shards). Production answer: bucketed/approximate rank for arbitrary players, exact only for top-K, periodic exact recompute; accept eventual consistency for mid-pack ranks.
3. **Lost writes on window reset.** Naively clearing a daily board drops in-flight score updates at the boundary. Production answer: atomic RENAME to a new key (or write to the new window key from a precise cutover time) so no update lands in a gap; TTL old windows for cleanup.

## (Delineation note)
`leaderboard` is the read-heavy ranked-reads + hot-key problem. Building Redis itself is infra-primitives `memcached`-class; the top-K-over-a-stream variant (trending) is `top-k-trending`; deep ranking models are ml-in-loop. Here it's the sorted-set index + sharding + approximate rank.

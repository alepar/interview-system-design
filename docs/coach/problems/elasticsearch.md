---
slug: elasticsearch
archetype: search-indexing
sources:
  lucene_index_pkg: lucene.apache.org/core/9_8_0/core/org/apache/lucene/index/package-summary.html
  es_translog: elastic.co/docs/reference/elasticsearch/index-settings/translog
  es_size_shards: elastic.co/docs/deploy-manage/production-guidance/optimize-performance/size-shards
  es_from_the_top_down: elastic.co/blog/found-elasticsearch-top-down
  es_column_store: elastic.co/blog/elasticsearch-as-a-column-store
  yelp_nrtsearch: engineeringblog.yelp.com/2021/09/nrtsearch-yelps-fast-scalable-and-cost-effective-search-engine.html
---

# Elasticsearch (distributed full-text search primitive)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic design: documents indexed into an inverted index, queries match terms and return ranked results. Knows an index is split into shards and shards have replicas. Names "scale by adding nodes." Doesn't articulate the segment lifecycle, near-real-time refresh semantics, or the two-phase query-then-fetch unprompted.
- **Senior (L5/E5):** Names Lucene as the per-shard engine and immutable segments as the write unit. Explains near-real-time search (refresh makes new docs searchable, default ~1s) and that durability comes from the translog, distinct from segment flush. Describes primary/replica write path and that a search broadcasts to one copy of every shard. Picks a shard count up front and knows over-sharding is a problem. May not name BKD trees, doc-values, or the FST term index, and may conflate refresh with flush/commit.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the full segment lifecycle: in-memory buffer → refresh (new in-memory segment, searchable, not durable) → flush (fsync, new translog generation) → committed segment → background `TieredMergePolicy` merge. Names translog durability levers: `request` (fsync per op on primary + every allocated replica — the default) vs `async` (fsync every `sync_interval`, default 5s, risks losing pre-crash ops). Quantifies shard sizing: **10–50 GB/shard, <200M docs/shard, soft limit ~1,000 shards/node** (notes the "20 shards/GB heap" guideline was deprecated in 8.3). Explains query-then-fetch as a two-round-trip: phase 1 each shard returns local top-K (id+score), coordinator merges to global top-K; phase 2 multi-GET stored fields for **only the final K** (avoids fetching N×shards docs). Names the FST term index (`.tip`) over the BlockTree terms dictionary (`.tim`), postings compressed via Frame-of-Reference + PFOR-Delta, BKD trees for numeric/geo (points at leaves, per-cell min/max for range pruning), and doc-values (columnar, off-heap) for sort/aggregations. Cites the operational reality that **Yelp migrated >90% of Elasticsearch traffic to Nrtsearch** because per-replica indexing CPU bottlenecked (every replica re-does indexing work). Treats this as the *primitive* most other search problems specialize.

## Canonical decomposition

### Requirements
**Functional:**
- Index JSON documents into a named index; full-text search returns ranked matches
- Near-real-time: a newly indexed doc is searchable within seconds
- Filter + sort + aggregate (facets) over structured fields
- Durable: an acknowledged write survives a node crash
- Horizontally scalable read and write via sharding + replication

**Non-functional (with numbers):**
- NRT refresh default 1s (tunable to 30s, or `-1` during bulk load)
- Shard size 10–50 GB, <200M docs/shard, ~1,000 shards/node soft limit
- Translog `request` durability: fsync per op on primary + every replica before ack
- Filesystem cache should get ≥50% of system RAM (postings/doc-values are mmap'd)
- Well-tuned 30+ node clusters: 100K+ docs/sec ingest, 10K+ QPS search
- 99.9%+ availability with replica factor ≥1 across nodes/AZs

### Core entities
- **Index:** logical namespace; maps to N primary shards × (1+R) replicas
- **Shard:** one Lucene index; the unit of scale and recovery
- **Segment:** immutable Lucene file set (term dict + postings + doc-values + points); write-once
- **Document:** JSON; routed to a shard by `hash(routing_key) % num_primaries`
- **Translog:** per-shard write-ahead log; replayed on recovery after the last commit

### API
- `PUT /index/_doc/:id` body={json} → indexes/overwrites a doc (routed by id or routing key)
- `POST /index/_bulk` → batched index/update/delete (the throughput path)
- `GET /index/_search` body={query, aggs, sort, from, size} → query-then-fetch, ranked hits + facets
- `POST /index/_refresh` → force new segment (make recent docs searchable now)
- `GET /index/_search?scroll=` or `search_after` → deep pagination without `from+size` blowup

### HLD
A write hits a coordinating node, which routes the doc to its primary shard by `hash(routing) % num_primary_shards`. The primary appends the op to its in-memory buffer **and** the translog, then replicates the op to each in-sync replica; with `translog.durability: request` (default) the primary acks the client only after the translog is fsynced on the primary and every allocated replica. The in-memory buffer is not yet searchable. Every `refresh_interval` (default 1s) the buffer is written to a new **in-memory** Lucene segment that *is* searchable but not yet durable — this is the near-real-time property. Periodically a **flush** fsyncs in-memory segments to disk as committed segments and rolls a new translog generation. Background `TieredMergePolicy` merges roughly-equal-sized small segments into larger ones (and can merge non-adjacent segments), reclaiming space from deleted/updated docs (deletes are tombstones until merge).

A search hits a coordinating node and runs in two phases. **Query phase:** broadcast to one copy (primary or replica) of every shard; each shard executes locally against its segments and returns a priority queue of `(doc_id, score)` for its local top-`from+size`. The coordinator merges these into the global top-K. **Fetch phase:** the coordinator issues a multi-GET to the shards that own the final K docs to retrieve stored fields/`_source` — fetching only K, not K×shards. Aggregations and sorts read **doc-values** (columnar, on-disk, off-heap) rather than the inverted index. Numeric/date/geo range predicates use **BKD trees**; full-text predicates walk **postings** found via the in-RAM **FST term index** pointing into the on-disk BlockTree terms dictionary.

Replicas exist for both availability and read throughput. On primary failure a replica is promoted; sequence numbers + the global checkpoint (6.x+) let a recovering replica reseed only the ops it missed rather than copying whole segments.

### Deep dives
1. **Segment lifecycle and the refresh/flush/merge distinction** — Refresh (default 1s) creates a searchable in-memory segment; it does **not** make data durable. Flush fsyncs segments and rolls the translog; durability between flushes comes entirely from the translog. Merge consolidates segments and is where deletes/updates are physically reclaimed. The three are commonly conflated; the Staff+ signal is keeping them separate and reasoning about their independent cost. Bulk-load tuning: set `refresh_interval: -1` and replicas to 0 during initial load, restore afterward — refreshing every 1s during a bulk import creates a storm of tiny segments and wasteful merges.
2. **Why query-then-fetch is two round-trips** — If each shard returned full `_source` for its local top-K, the coordinator would receive K×num_shards full documents and discard most. Instead phase 1 returns only `(id, score)` (cheap), the coordinator computes the true global top-K, and phase 2 fetches `_source` for only those K. The cost is a second round-trip; the win is bandwidth and heap. This also explains why deep pagination (`from: 100000, size: 10`) is expensive — every shard must build a priority queue of `from+size` and ship it — and why `search_after`/`scroll`/PIT exist.
3. **The indexing-CPU-per-replica bottleneck (Yelp → Nrtsearch)** — In Elasticsearch, every replica independently re-indexes each document (document-based replication), so indexing CPU scales with replica count, not just primaries. For a write-heavy, high-replica workload this caps throughput. Yelp's Nrtsearch (Lucene-based, gRPC/protobuf) uses **near-real-time segment replication**: the primary indexes once and replicas pull pre-built segments from S3, so replicas pay IO not CPU. Yelp migrated >90% of ES traffic to it, improving p50/p95/p99 by 30–50% and cutting cost up to 40%. The Staff+ point: replication strategy (document vs segment) is a first-order throughput lever, not a footnote.

## Known failure modes
1. **Merge storms degrade ingest and search latency** — Heavy indexing (especially with frequent refreshes) produces many small segments; background merges then compete for IO and CPU, spiking latency. Mitigation: raise the refresh interval (or `-1`) during bulk loads, tune merge throttling and the merge scheduler thread count, size shards so per-shard segment counts stay bounded, and force-merge read-only (e.g. time-based) indices down to 1 segment after they stop receiving writes. The deeper fix for write-heavy clusters is segment replication (Nrtsearch / OpenSearch segrep) so replicas don't re-merge.
2. **Hot shard from skewed routing** — Default routing is `hash(_id) % num_primaries`, but a custom routing key chosen for query locality (e.g. `customer_id`) can concentrate documents on one shard if the key is skewed (one giant customer). That shard becomes a CPU/IO/storage hotspot and caps the whole index. Mitigation: composite/partitioned routing (`routing_partition_size`) to spread a hot key across several shards, or a virtual-shard layer; monitor per-shard doc counts and reject the assumption that hash routing is automatically balanced.
3. **Translog growth and slow recovery** — If flush is slow (large `flush_threshold_size`, default 512MB) or a node was offline, the translog grows and recovery must replay a long log, extending restart time and risking disk pressure. With `translog.durability: async`, a crash can lose all ops since the last `sync_interval` (default 5s) — a silent data-loss window many teams don't realize they opted into. Mitigation: keep `request` durability for anything that must not lose acked writes, monitor translog size and flush age, and size `flush_threshold_size` against acceptable recovery time. On failover, rely on sequence-numbers + global checkpoint so replicas reseed deltas rather than full segments.

---
slug: log-search
archetype: search-indexing
sources:
  loki_architecture: grafana.com/docs/loki/latest/get-started/architecture/
  loki_cardinality: grafana.com/docs/loki/latest/get-started/labels/cardinality/
  quickwit_101: quickwit.io/blog/quickwit-101
  quickwit_08: quickwit.io/blog/quickwit-0.8
  splunk_buckets: thinkcloudly.com/blog/hot-warm-cold-bucket-lifecycle/
  splunk_index_vs_search_time: docs.splunk.com/Documentation/Splunk/9.4.1/Indexer/Indextimeversussearchtime
---

# Log / Observability Search (TB/day ingest, object-storage-backed)

## Bar anchors
- **Mid-level (L4/E4):** Proposes putting logs in Elasticsearch and searching them. Knows logs are time-ordered and high-volume. Doesn't address the index-everything cost, time-partitioning, retention tiers, or the metadata-only-vs-full-text tradeoff unprompted.
- **Senior (L5/E5):** Recognizes logs are write-heavy, low-QPS, append-only, and time-partitioned. Proposes time-based indices, retention tiering (hot/warm/cold), and acknowledges that indexing every field is expensive at TB/day. Knows object storage is the cheap durable tier. May not articulate the Loki (metadata-only) vs Quickwit/Splunk (full-text) design choice, schema-on-read, or object-storage-native search mechanics.
- **Staff+ (L6/E6+):** Drives proactively. Frames the central decision as an **indexing-strategy tradeoff**: **Loki indexes only labels/metadata** (≤~15 labels; ~0.5–1× raw storage vs Elasticsearch's ~2–3×; up to ~90% cost reduction) trading away arbitrary full-text query for cost; **Quickwit/Tantivy** does full-text **natively on object storage** (decoupled compute/storage, stateless searchers, a metastore of split metadata, sub-second cold queries); **Splunk** runs **schema-on-read** (parse/extract fields at search time, not index time) with **hot→warm→cold→frozen** bucket lifecycle. Quantifies: Quickwit's largest user **>1 PB/day (13.4 GiB/s, ~14M docs/s) on 200 pods**, single indexer ~7.5 MB/s/core, S3 ~30ms first-byte but ~1.6 GB/s parallelized, ~$8.4/ingested-TB/month at 2.75× compression; Loki chunk target ~1.5MB compressed. Names **cardinality explosion** as Loki's failure mode and **per-tenant rate-limit + cost attribution** for multi-tenant ingest. Trades these architectures explicitly rather than defaulting to "just use Elasticsearch."

## Canonical decomposition

### Requirements
**Functional:**
- Ingest TB/day of log lines from many sources, durably, with minimal loss
- Query by time range + structured labels; full-text grep within matched streams
- Retain data with tiered cost (recent fast, old cheap) and configurable retention
- Multi-tenant: isolate ingest, query, and cost per tenant

**Non-functional (with numbers):**
- Ingest 10s of TB/day per cluster (Quickwit largest user >1 PB/day on 200 pods)
- Storage: metadata-only ~0.5–1× raw (Loki) vs full-text ~2–3× (Elasticsearch)
- Object storage: S3 ~30ms first-byte, ~80 MB/s/stream, ~1.6 GB/s parallelized
- Query QPS low (humans/alerts), but scans large time ranges
- Retention tiers: hot (SSD) → warm → cold (S3) → frozen (archive/delete)

### Core entities
- **LogStream:** identified by a label set `{app, env, host, level, …}` (the index key in Loki)
- **Chunk / Split:** compressed batch of log lines in object storage (Loki chunk ~1.5MB; Quickwit split = a mini-index file)
- **Index/Metastore:** label index (Loki) or split metadata (Quickwit) — small relative to data
- **Bucket:** Splunk lifecycle unit (hot/warm/cold/frozen); aged per-bucket, not per-event
- **Tenant:** isolation + rate-limit + cost-attribution boundary

### API
- `POST /push` (or agent: Promtail/Vector/Fluent Bit) → ship log lines tagged with labels
- `GET /query?{labels}|=pattern&start&end` → label-filtered streams + grep within them (LogQL-style)
- Internal: indexers chop the stream into chunks/splits, compress, upload to object storage, register metadata
- Internal: stateless searchers fetch only the splits a query's time+label filter selects

### HLD
Agents (Promtail/Vector/Fluent Bit) ship log lines tagged with a **label set** to a write path. **Indexers** batch lines per stream, compress them into **chunks** (Loki) or per-batch mini-index **splits** (Quickwit/Tantivy), and upload to **object storage** (S3/GCS), registering lightweight metadata (label index, or split time-range + field stats) in a small **index/metastore**. The defining architectural choice is *how much to index*:

- **Loki** indexes **only the labels** — never the log content. A query is "filter streams by labels (index hit) → fetch those streams' chunks from object storage → grep the lines inside (brute force over a small candidate set)." This makes the index tiny and storage ~0.5–1× raw, but arbitrary full-text query over *all* logs is impossible — you must label well.
- **Quickwit** indexes **full text on object storage**: each split is a complete mini Lucene-like index (term dict + postings) uploaded to S3; stateless **searchers** download only the splits a query selects (pruned by time + tags) and exploit S3's parallel throughput (~1.6 GB/s) plus a **hotcache** to open splits in tens of ms. Compute and storage scale independently; indexers (write) and searchers (read) are separate fleets sharing the metastore.
- **Splunk** uses **schema-on-read**: it indexes raw events but defers field parsing/extraction to *search time*, giving flexibility (any field, late-defined) at the cost of search-time CPU. Data ages through **hot** (writable SSD) → **warm** (read-only SSD) → **cold** (cheap disk / S3 via SmartStore) → **frozen** (archived or deleted) **buckets**, rolled by size and age — and aging is per-bucket, not per-event.

Retention is tiered to match the access pattern (recent data queried often → fast tier; old data rarely → object storage/archive). Multi-tenancy applies per-tenant rate limits, per-tenant indices/streams, and cost attribution so one noisy tenant can't starve others.

### Deep dives
1. **Metadata-only vs full-text indexing (the cost lever)** — The single biggest decision. Indexing every token (Elasticsearch) makes any query fast but costs ~2–3× raw storage plus heavy indexing CPU. Indexing only labels (Loki) costs ~0.5–1× raw and almost no indexing CPU, but pushes work to query time (grep within label-selected chunks) and *requires* good labeling — you can only fast-filter on what you labeled. Quickwit splits the difference: full text, but on cheap object storage with stateless searchers, so you pay full-text query power at object-storage cost. The Staff+ answer names the workload: high-cardinality, ad-hoc-query observability → full-text (Quickwit/ES); known-label, cost-sensitive, mostly-grep → Loki. There is no universally right choice; the candidate must trade it against the query mix and budget.
2. **Object-storage-native search (compute/storage decoupling)** — Traditional search couples index storage to the search node's local disk, so scaling read throughput means replicating the whole index. Quickwit instead keeps splits in S3 and runs **stateless** searchers that download only the splits a query needs. This works because S3's per-stream latency (~30ms first byte) is hidden by massive parallelism (~1.6 GB/s aggregate) and a hotcache that opens splits in <60ms. Indexers and searchers scale independently; adding query capacity is just adding stateless searchers (no rebalancing, no data movement). The metastore (Postgres or JSON-on-S3) is the shared source of truth for which splits exist and what they cover, enabling time/tag pruning so a query touches a tiny fraction of splits.
3. **Cardinality, schema-on-read, and the cost of flexibility** — Loki's Achilles heel is **label cardinality**: each unique label-set is a distinct stream, so a high-cardinality label (request_id, user_id) explodes the number of streams, bloats the index, and flushes thousands of tiny chunks — degrading both ingest and query. The fix is keeping labels low-cardinality and pushing high-cardinality fields to a structured-metadata path rather than labels. Splunk's schema-on-read is the dual tradeoff: by parsing fields at search time it never has to re-index when you define a new field, but every search pays parsing CPU, so heavy index-time field extraction is discouraged. Both illustrate the theme: in log search you are constantly trading index cost (write/storage) against query cost (CPU/latency), and the right point depends on how often each field is queried.

## Known failure modes
1. **Loki label-cardinality explosion** — Putting a high-cardinality value (request_id, full URL, user_id) in a label creates a near-unique stream per event: the index balloons, chunks become tiny and numerous, and both ingest and query slow to a crawl or fail. Mitigation: keep labels bounded and low-cardinality (app/env/host/level), move high-cardinality fields to structured metadata or rely on grep within streams, and alert on stream-count growth.
2. **Hot-tier saturation on an ingest burst** — A deploy gone wrong or a debug-logging flood spikes ingest, filling Splunk hot buckets or Quickwit indexer capacity, causing back-pressure or drops. Mitigation: per-tenant ingest rate limits with informative back-pressure, earlier bucket roll / more hot buckets, autoscaling the (stateless) indexer/searcher fleets, and a dead-letter/sampling path so a single tenant's flood degrades gracefully rather than taking down ingest globally.
3. **Slow cold-tier queries** — Querying old data in object storage (or a cold/frozen Splunk bucket) can be far slower than hot-tier queries, surprising users debugging an incident from last week. Mitigation: Quickwit hotcache warmup + aggressive split tagging so time/tag pruning skips irrelevant splits; Splunk SmartStore cache management; set user expectations via tier-aware query UIs; and keep the retention/tiering policy aligned with realistic query-recency patterns so "the data I need" is usually in a fast tier.

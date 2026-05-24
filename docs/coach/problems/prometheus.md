---
slug: prometheus
archetype: infra-primitives
sources:
  gorilla_paper: vldb.org/pvldb/vol8/p1816-teller.pdf
  prometheus_tsdb: prometheus.io/docs/prometheus/latest/storage/
  m3db_uber: uber.com/blog/m3/
  victoriametrics: docs.victoriametrics.com/faq/
---

# Prometheus / Gorilla / M3DB / Datadog (time-series database)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic time-series store: (metric_name, labels, timestamp, value); discusses LSM-tree storage. May know about downsampling at category level. Doesn't address cardinality explosion, Gorilla compression, or label-posting-list inverted index unprompted.
- **Senior (L5/E5):** Names the (metric_name + labels) → time-series mapping; identifies cardinality as a real concern. Discusses push (StatsD, OpenTelemetry) vs pull (Prometheus scrape) ingestion. Knows about retention windows and downsampling at category level. May or may not articulate Gorilla compression or the inverted-index query path.
- **Staff+ (L6/E6+):** Drives proactively. Cites the **Gorilla compression** (Pelkonen et al., VLDB 2015) explicitly: delta-of-delta encoding for timestamps + XOR encoding for float values; **1.37 bytes/sample average** on real Facebook workloads (down from 16 bytes for naive (timestamp, value) tuples). Articulates **cardinality explosion as THE dominant failure mode**: each unique combination of (metric_name, label_set) creates a new time-series; adding a high-cardinality label (user_id, request_id, full URL) blows up series count by orders of magnitude. Each active series ~3-4 KB in Prometheus head block; 10M series → 30-40 GB RAM, OOM follows; OOM-kill mid-write can corrupt the WAL. Names **inverted index on label posting lists**: similar substrate to Elasticsearch; a PromQL `rate(http_requests_total{method="GET",status="500"}[5m])` becomes label posting-list AND + sample iteration. Identifies the **head block + 2h chunked storage** architecture: active series in memory (head); closed blocks flushed to disk as immutable 2-hour chunks with Gorilla-style XOR compression and string interning. Discusses **downsampling tiers**: raw 1s data for 24h, 1-min aggregates for 30d, 1-hour aggregates for years (Thanos/Cortex/Mimir patterns). Quantifies M3DB scale (Uber): 6.6B time series, 12B series stored, peaks at 1B writes/s and 2B reads/s aggregated, 500M metrics/s aggregated, 20M metrics/s persisted. Stretch (Sr Staff bar): articulates the **percentile-aggregation gotcha** (averaging percentiles is wrong; you need pre-aggregated sketches like t-digest); names **VictoriaMetrics** as the Go-based ClickHouse-inspired alternative with better high-cardinality behavior.

## Canonical decomposition

### Requirements
**Functional:**
- Ingest time-series samples at high throughput; each sample is (metric_name, labels_set, timestamp, value)
- Query language (PromQL or equivalent) for range queries, aggregations (sum, rate, percentile), label filtering
- Configurable retention with tiered downsampling (raw recent data, aggregated older data)
- Alerting rules evaluated against the query engine
- Multi-tenant: per-tenant cardinality budget + retention policy

**Non-functional (with numbers):**
- 1M samples/sec ingest target (single Prometheus instance scale)
- M3DB at Uber: 1B writes/sec + 2B reads/sec aggregate (cluster scale)
- 1.37 bytes/sample compressed (Gorilla)
- Prometheus head series: typical ceiling ~10M active series before single-instance memory issues
- ~3-4 KB per active series in head block → 10M series ≈ 30-40 GB RAM
- p99 query latency: 1s for 24h-range typical query
- Retention tiers: 24h raw / 30d at 1-min / 1y at 1-hour typical
- Cardinality budget: 10K series per metric typical limit

### Core entities
- **Metric:** named entity (e.g., `http_requests_total`)
- **Label set:** key-value pairs that distinguish series within a metric (e.g., `{method="GET", status="200"}`)
- **Series:** unique (metric_name + label_set) tuple → time-ordered sequence of (timestamp, value) samples
- **Sample:** (timestamp, value) pair appended to a series
- **Head block:** in-memory write buffer holding the most recent ~2h of samples for all active series
- **Block (2h chunk):** immutable on-disk segment with Gorilla-compressed samples + per-block inverted-label-index
- **Inverted index entry:** label_value → posting list (sorted list of series_ids matching that label_value)

### API
- Ingestion: **push** model — clients (StatsD, OpenTelemetry collectors) POST samples; or **pull** model — Prometheus server scrapes target HTTP endpoints exposing `/metrics` in text format
- Query: PromQL `instant_vector(query, time)` and `range_vector(query, start, end, step)` over the HTTP API
- Aggregation operators: `rate()`, `sum`, `avg`, `histogram_quantile()`, label-matchers (`{label="value"}`, `{label=~"regex"}`)
- Admin: cardinality status, compaction status, block metadata

### HLD
The architecture has three primary components: **ingestion path, storage, and query engine**.

**Ingestion path**: each sample is `(metric_name, labels_set, timestamp, value)`. The server identifies the series by hashing the (metric_name, labels) tuple; appends the sample to the series's WAL + head-block buffer. The head block holds the most recent ~2 hours of samples for all active series in memory + WAL on disk for durability. New series (new label combinations) are created on first-write; this is where cardinality explosion happens — an unbounded label like `user_id` creates a new series per unique value, blowing up active series count.

**Storage**: every 2 hours, the head block is flushed to disk as an immutable **2-hour chunk** with Gorilla compression (delta-of-delta timestamps, XOR floats — 1.37 bytes/sample average). The chunk also includes an **inverted-label-index** mapping each label_value to the series-IDs containing that value (sorted posting list, similar to Elasticsearch). Blocks accumulate; periodically, blocks are **compacted** — adjacent 2-hour blocks merge into larger blocks (e.g., 24-hour blocks); downsampled aggregates (5-min averages) may also be materialized at this stage (Thanos/Cortex pattern).

**Query engine**: PromQL queries decompose into label-matcher filtering + sample iteration. For `rate(http_requests_total{method="GET",status="500"}[5m])`:
1. **Label filter**: read posting lists for `method=GET` and `status=500`, intersect → series-IDs matching both labels.
2. **Sample iteration**: for each matching series, read samples within the query time range (5m window) from head block + relevant disk blocks.
3. **Aggregation**: compute rate (per-series derivative) and return.

The **inverted-label-index** is the key data structure — same as Elasticsearch for full-text search, but for label-value matching. Query cost = O(posting-list intersection) + O(sample iteration within matched series).

**Downsampling tiers**: raw 1-second data is the most storage-expensive; pre-aggregated 5-minute / 1-hour rollups are cheaper but lossy on percentile queries (averaging percentiles is wrong — you need t-digest or HDR-histogram sketches that compose correctly). Query planner picks the appropriate tier based on query time range (long range → downsampled; short range → raw).

**Push vs pull ingestion**: Prometheus uses **pull** (server scrapes target endpoints periodically) — good for well-known infrastructure (Kubernetes pods, ECS services with service discovery); push targets are short-lived (Lambda, batch jobs) and don't have stable endpoints to scrape. StatsD / OpenTelemetry are push-based; pull-based Prometheus uses Pushgateway as a bridge for short-lived push sources. Push gives the broker more control over ingestion rate; pull gives the broker more control over discovery and scrape interval consistency.

### Deep dives
1. **Gorilla compression: delta-of-delta timestamps + XOR floats.** Gorilla (Pelkonen et al., VLDB 2015) is the canonical TSDB compression scheme. Two-axis encoding: (a) **delta-of-delta for timestamps**: regular sampling (e.g., every 10 seconds) means consecutive timestamps differ by a constant; the second derivative (delta-of-delta) is zero → encodes to a single control bit ("same as previous delta"). When sampling rate varies, the delta-of-delta encodes the change in bits proportional to the magnitude of variation; typical compression to ~few bits per timestamp. (b) **XOR for float values**: consecutive doubles in a time series tend to share most high bits (small relative changes); XOR yields small differences that can be encoded with leading-zero-count + meaningful-bits. On Facebook ODS workloads: 16 bytes/sample (raw timestamp + double) → **1.37 bytes/sample average** = 12× compression. 26 hours of all Facebook ODS data in 1.3 TB RAM across 20 machines. Compression engine: >1.5M datapoints/sec/machine. Adopted by Prometheus TSDB, M3DB, VictoriaMetrics. Staff+ commit: name delta-of-delta + XOR explicitly, articulate why regular sampling enables the second-derivative-is-zero compression, address the failure mode (irregular sampling reduces compression ratio).

2. **Cardinality explosion as THE central failure mode.** Each unique (metric_name, label_set) combination is a new series. A metric `http_requests_total{method="GET", status="200", endpoint="/api/users"}` is one series; adding `user_id` as a label creates one series per unique user_id — at 10M users, 10M series for that metric alone. Each active series consumes ~3-4 KB in Prometheus head block (label set storage + chunk buffer + index entry); 10M series → 30-40 GB RAM. OOM-kill follows; mid-write OOM-kill can corrupt the WAL → data loss on restart. Production answer: **cardinality budget per metric** (admission-control reject series creation if metric exceeds 10K-100K threshold); **per-tenant cardinality budget** (multi-tenant cluster prevents one tenant's bad config from breaking the cluster); **drop-high-cardinality-labels at ingest** (relabel rules in Prometheus); **alerting on cardinality growth rate** before OOM. Anti-patterns: using request_id, trace_id, full URL, IPv4 address as labels — anything with cardinality > a few thousand. Staff+ commit: name cardinality explicitly as the central failure mode, articulate per-metric budget enforcement, address the OOM-corrupting-WAL recovery scenario.

3. **Tiered storage + downsampling + the percentile gotcha.** Long retention is expensive: 1 second resolution × 1 year × 10M series ≈ petabytes. Tiered downsampling: raw 1s data retained for 24h-7d; pre-aggregated 1-minute averages retained for 30d; pre-aggregated 1-hour averages retained for years. Query planner picks the appropriate tier based on query time range (a "last hour" query reads raw; a "last year" query reads 1-hour aggregates). **The percentile gotcha**: averaging pre-aggregated percentiles is mathematically wrong. If you compute p99 over each 1-minute window and store those, you can't take the average of N p99 values to get the over-N-minutes p99 — the actual over-N-minutes p99 is different. Solution: store percentile-aggregation-friendly sketches (t-digest, HDR-histogram, KLL sketch) instead of point percentiles; these sketches compose correctly under merge. Histogram_quantile in PromQL uses bucket histograms (similar property — buckets compose under sum, percentiles derived at query time from merged buckets). Staff+ commit: name the tier policy + retention boundaries; name the percentile-storage gotcha + the sketch-based fix; address what happens when a query spans tiers (e.g., 26-hour range hits both 1s and 1m tiers — query planner stitches them).

## Known failure modes
1. **Cardinality explosion from misconfigured label.** Engineer adds `request_id` as a label "for debugging"; series count grows by 1M/min; head block memory consumption hits limit; OOM-kill; WAL corruption on restart. Production answer: cardinality admission control (per-metric, per-tenant); pre-flight cardinality dashboards; ban-list of dangerous labels (`request_id`, `user_id`, `trace_id`, `pod_name`, `IP_address` at fine grain); aggregate at the source instead of per-event (StatsD counter increments aggregate before sending, not per-request).

2. **Late-arriving data causes alert flap.** Alert fires on apparent low data, then resolves when late data arrives 30s later — false positive followed by false negative. Production answer: wait for completeness window before alerting (delay alert evaluation by 1-2 sampling intervals); alert on rate-of-change (e.g., "request rate dropped 50%") not absolute thresholds when possible; for irregular ingestion sources, use larger evaluation windows (5min instead of 1min).

3. **Query on long time range = full-table scan equivalent.** "Last year of CPU utilization at 1s resolution" reads trillions of points across years of raw data. Production answer: query planner forces downsampled tier for long ranges; per-query cardinality limit (reject queries that would touch >N series); UI guidance to pick appropriate resolution (e.g., Grafana's "max data points" parameter); per-tenant query timeout (e.g., 30s default); query result caching for repeated dashboard queries.

## Notes for the coach
- **This is asked-confirmed at Datadog** per Hello Interview tag ("Design a Metrics Monitoring Platform like Datadog"); plausibly-asked at Google, Amazon, Meta, Netflix, Cloudflare, Uber per SystemDesignHandbook. ByteByteGo Vol 2 dedicates a chapter.
- **The Gorilla 1.37 bytes/sample number is the headline anchor.** Citing the VLDB 2015 paper is the literacy signal.
- **The cardinality-as-central-failure-mode framing is the Staff+ unlock.** Most candidates anchor on storage cost or compression; the Staff+ candidate identifies cardinality first because it's the one that breaks the cluster fastest. If the candidate proposes adding `request_id` as a label, redirect: "what happens when you have 1M unique request_ids per hour?"
- **The percentile gotcha is the L7 differentiation flex.** Most senior candidates store p99 values directly and compose by averaging; the Sr Staff candidate names this as wrong and proposes t-digest sketches or histogram_quantile patterns.
- **M3DB at Uber's scale numbers (12B series stored, 1B writes/sec) are the modern complement to Gorilla's Facebook anchor.**
- **No direct AI-infra counterpart** — TSDB is generic observability; the AI-infra `eval-pipeline-at-scale` problem has overlapping concerns (high-cardinality eval traces) but the substrate is different.
- **Cross-coverage:** below most other primitives in the catalog (every system in this catalog needs metrics monitoring), uses `s3` for long-term storage offload (Thanos/Cortex pattern). When other problems mention "observability" or "alerting on SLI," this is the substrate.
- **Don't allow drift into "design Datadog full product."** Stay on the TSDB primitive shape; tracing (Jaeger), logging (Elasticsearch), APM (separate problem) are out of scope.

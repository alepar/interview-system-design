---
slug: yelp-search
archetype: geo-proximity
sources:
  yelp_es: engineeringblog.yelp.com/2017/06/moving-yelps-core-business-search-to-elasticsearch.html
  nrtsearch: engineeringblog.yelp.com/2021/09/nrtsearch-yelps-fast-scalable-and-cost-effective-search-engine.html
  fast_order: engineeringblog.yelp.com/2018/06/fast-order-search.html
  data_pipeline: engineeringblog.yelp.com/2016/07/billions-of-messages-a-day-yelps-real-time-data-pipeline.html
  ltr: engineeringblog.yelp.com/2014/12/learning-to-rank-for-business-matching.html
  elastic_completion: elastic.co/search-labs/blog/elasticsearch-autocomplete-search
  elastic_geo: elastic.co/guide/en/elasticsearch/reference/current/query-dsl-geo-distance-query.html
  hi_yelp: hellointerview.com/learn/system-design/problem-breakdowns/yelp
---

# Yelp search — Apollo proxy fronting Elasticsearch (and now Nrtsearch on Lucene 8) + migration from custom Lucene → Elasticsearch → Nrtsearch (90%+ traffic, 30-50% p50/p95/p99 latency, ~40% infra cost reduction) + MySQLStreamer → Kafka → Flink (Elasticpipe) → Nrtsearch NRT indexing + LTR pointwise regression rescores ES recall (F1 91% → 95% business matching) + Elasticsearch Completion Suggester in-memory FST per Lucene segment for <100ms autosuggest + geo_distance + bounding-box pre-filter + geosharding by geohash prefix with adaptive split/merge + category in routing key to diffuse hot queries

## Bar anchors
- **Mid-level (L4/E4):** Postgres full-text search; no geo index; no autosuggest.
- **Senior (L5/E5):** Names Elasticsearch + geosharding. May or may not articulate Apollo, Nrtsearch migration lineage, LTR rescoring, or NRT indexing pipeline.
- **Staff+ (L6/E6+):** Names (a) **migration lineage**: custom Lucene → Elasticsearch → Nrtsearch; Nrtsearch built on Lucene 8 replaced ES with 30-50% latency improvement + ~40% infra cost reduction; (b) **Apollo proxy** decouples client code from underlying engine — engine swap only required Apollo route changes; (c) **Nrtsearch architecture**: NRT segment replication (primary indexes, replicas pull immutable segments); concurrent segment search across cores; gRPC/protobuf; grpc-gateway for REST backward compat; phased rollout 1% dark-launch + dual-running; (d) **NRT indexing pipeline**: MySQLStreamer (CDC from MySQL binlog) → Kafka → Flink (Elasticpipe) → Elasticsearch/Nrtsearch; idempotent replay via Kafka-message-key as doc ID; nightly audit O(log N) queries for consistency; (e) **Schematizer-governed Kafka pipeline** handling billions of messages/day; (f) **LTR pointwise regression rescores ES recall**: F1 91% → 95% business matching; features TF-IDF name match + address text + geo-distance + phone match; (g) **ranking signals**: review recency, count, reviewer credibility, profile completeness, owner responsiveness, language specificity; (h) **autosuggest <100ms via Elasticsearch Completion Suggester** using in-memory FST per Lucene segment; (i) **geo_distance + bounding-box pre-filter** for "nearby" search; (j) **geosharding by geohash prefix** with adaptive split/merge + category in routing key to diffuse hot queries.

## Canonical decomposition

### Requirements
**Functional:**
- Search businesses by query + location + category + filters
- Autosuggest as user types
- Multi-language reviews + business names
- Closed-business handling

**Non-functional:**
- 8.4M active businesses, 330M reviews
- Autosuggest <100ms p95
- Nrtsearch 30-50% latency improvement + 40% cost reduction
- Schematizer Kafka billions of messages/day

### Core entities
- **Business:** business_id, name, address, location (geo_point), categories, ratings_aggregate
- **Review:** review_id, business_id, user_id, rating, content, created_at
- **SearchQuery:** {q, lat, lon, radius, categories[]}
- **AutosuggestEntry:** prefix → top-K business completions

### API
- `GET /search?q=&lat=&lon=&radius=&category=`
- `GET /autosuggest?q=` → suggestions[]
- Internal: write events → MySQLStreamer → Kafka

### HLD
Write path: Business + Review writes to MySQL primary. MySQLStreamer (CDC binlog reader) emits to Kafka. Schematizer validates schema. Flink (Elasticpipe) consumes from Kafka + writes to ES/Nrtsearch. Idempotent replay via Kafka-message-key as doc ID. Nightly audit job runs O(log N) queries to verify upstream-vs-index consistency.

Read path: Search request → Apollo proxy → Nrtsearch (or legacy ES). Nrtsearch: NRT segment replication (primary indexes, replicas pull immutable segments); concurrent segment search across cores. Query plan: geo bounding-box pre-filter (cheap) → geo_distance filter (refines) → text query → top-N candidates. Candidates rescored by LTR pointwise regression. Returned to client.

Autosuggest path: Elasticsearch Completion Suggester via in-memory FST (Finite State Transducer) per Lucene segment — sub-100ms. Per (geohash-prefix, category) shard.

Geosharding: by geohash prefix with adaptive split/merge; category in routing key to diffuse hot queries (e.g., "restaurants" wouldn't all hit one shard).

### Deep dives
1. **Apollo proxy + Nrtsearch migration.** Custom Lucene → ES → Nrtsearch on Lucene 8. Apollo decouples clients from engine. Nrtsearch NRT segment replication + concurrent segment search + gRPC/protobuf + grpc-gateway. Phased rollout 1% dark-launch + dual-running.
2. **NRT indexing pipeline + LTR rescoring.** MySQLStreamer → Kafka → Flink (Elasticpipe) → Nrtsearch. Idempotent replay via Kafka-key=doc-id. Nightly audit. ES as recall + ML re-ranker (LTR pointwise regression). F1 91% → 95% business matching.
3. **Autosuggest + geosharding + geo_distance.** Autosuggest <100ms via Completion Suggester (in-memory FST per Lucene segment). Geo_distance + bounding-box pre-filter. Geosharding by geohash prefix with adaptive split/merge + category in routing key.

## Known failure modes
1. *Stale closed-business detection* — pages with no recent reviews/photos rank lower; explicitly closed drop from general but persist in targeted search.
2. *Hot-spot geosharding* — naive geo partitions hot-spot in city centers. Production answer: adaptive split/merge + category in routing key.
3. *Multi-hour deploys* in legacy custom Lucene. Production answer: ES migration → Nrtsearch with segment replication.

## Notes for the coach
- **Asked-confirmed at Yelp.** engineeringblog.yelp.com posts are canon. Hello Interview "Design Yelp" canonical.
- **Cross-coverage** with `google-places` + `foursquare-checkin` (this archetype; competing place-search platforms). With search #7 `geo-place-search` (foundational place-search).
- **The Apollo + Nrtsearch migration with 30-50% latency + 40% cost wins is the canonical Staff+ unlock.** Mid-senior candidates name ES; Staff+ candidates name the proxy-decoupling + migration story with the specific wins.
- **Adversarial probe: "Restaurants in San Francisco" returns 5K results — how do you rank top 20?"** Strong answer: ES returns ~5K candidates via geo_distance + category filter (cheap recall); LTR pointwise regression rescores top-K with features (rating × log review count × proximity × profile completeness × owner-responsiveness × open-now); top 20 returned. **Why two-stage**: ES scoring (BM25) doesn't know about Yelp-specific ranking signals; LTR is per-Yelp learned model. Production: per-query category + per-user personalization features. Weak answer: "sort by rating" without the two-stage architecture.

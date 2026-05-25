---
slug: feature-store
archetype: ml-in-loop
sources:
  tecton_pit: docs.databricks.com/aws/en/machine-learning/feature-store/time-series
  hopsworks_pit: hopsworks.ai/dictionary/point-in-time-correct-joins
  michelangelo_blog: uber.com/blog/michelangelo-machine-learning-platform/
  feast_docs: docs.feast.dev/reference/offline-stores
  tecton_retrieval: tecton.ai/product/platform/retrieval-system/
  chip_huyen_book: Chip Huyen "Designing Machine Learning Systems" feature-store chapter
---

# Real-time feature store — point-in-time-correct joins + offline-online consistency + dual-store + streaming aggregations

## Bar anchors
- **Mid-level (L4/E4):** "Database of features." No point-in-time correctness; no offline-online consistency.
- **Senior (L5/E5):** Names online + offline stores + feature definitions. May or may not articulate point-in-time joins, streaming-vs-batch transformations, or backfill semantics.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **point-in-time correctness** as primary architectural concern: training rows must retrieve feature values where `feature_timestamp ≤ label_event_timestamp`, not current values. Per published guides: "without it, future information leaks into training, inflating offline AUC by 5 to 20 percent while online performance collapses." Names **training-serving skew elimination** as #1 use case — same feature-definition code executes both offline (training-set generation) and online (serving). Names **dual-store architecture**: offline on Parquet over S3/HDFS or warehouse (BigQuery/Snowflake) for training; online on KV (Redis, DynamoDB, Cassandra, RonDB) for inference. Cites **three transformation types (Tecton model)**: batch (offline materialized — e.g., 30-day avg spending), stream (Kafka/Kinesis windowed materialized — e.g., last-5-min count), **on-demand/realtime** (computed at request time, never materialized — for inputs only known at inference like `distance(user_loc, merchant_loc)`). Cites Uber Palette: >1M predictions/sec with P95 <5ms (no Cassandra) / <10ms (with). Cites DoorDash >20M reads/sec. Names **feature registry + lineage**: central system of record with owner, schema, lineage, version. Stretch (Sr Staff bar): articulates **backfill mandatory on new feature definition** — historical values regenerated using same transformation logic; backfill must use same code as streaming (framework auto-generates).

## Canonical decomposition

### Requirements
**Functional:**
- Define features once (consumed by both offline training pipelines + online serving)
- Point-in-time-correct joins for training set generation
- Streaming aggregations from Kafka with <200ms latency to online store
- On-demand transformations for inputs known only at inference
- Backfill historical values on new feature definition
- Feature registry with lineage + versioning

**Non-functional (with numbers):**
- Tecton: >100K QPS, <5ms median latency
- Uber Palette: >1M predictions/sec, P95 <5ms (no Cassandra) / <10ms (with); ~10K features × 1K models
- DoorDash: >20M reads/sec (store-ranking alone makes >1M predictions/sec with dozens of features each)
- Redis 2026 benchmarks: 0.12ms p50, 0.45ms p99 GET
- Lyft Feature Serving: thousands of features, millions of requests/min, single-digit-ms latency
- Backfill jobs: hundreds of TB to PB scans for multi-year windows

### Core entities
- **Feature definition:** name, owner, type, transformation_code, sources, version
- **Entity:** (entity_type, entity_id) — e.g., (user, user_id), (merchant, merchant_id)
- **Feature value:** (entity_id, feature_name, value, feature_timestamp)
- **Offline store:** Parquet/Hudi/Iceberg on S3 partitioned by (entity_type, feature_event_date)
- **Online store:** KV (Redis/DynamoDB/Cassandra/RonDB) keyed by entity_id → latest feature values
- **Registry:** central catalog with feature definitions + lineage + versions

### API
- Define: `FeatureView(name='user_30d_spend', source=spend_table, agg=sum, window=30d, entity=user)`
- Train: `feature_store.get_training_set(label_table, features=[...], event_timestamp_col='ts')` → point-in-time correct join
- Serve: `feature_store.get_online(entity_id=X, feature_names=[...])` → latest values <10ms
- Backfill: `feature_store.backfill(feature_view, from_date, to_date)`

### HLD
**Feature registry** is the central system of record — declares feature definitions (name, entity, source, transformation, type) + owner + lineage + version. **Offline path**: same transformation code runs as Spark / Flink batch job over historical data; writes to Hudi/Iceberg/Parquet on S3 partitioned by `(entity_type, feature_event_date)` with primary key on `(entity_id, feature_timestamp)`. **Online path**: same transformation code runs as Kafka → Flink/Samza streaming job; writes to KV store (Redis / DynamoDB / Cassandra / RonDB) keyed by `entity_id` → latest values. **Point-in-time-correct join API** for training: take label table with `(entity_id, label, event_timestamp)`; for each row, fetch feature values where `feature_timestamp ≤ event_timestamp`; partition-pruning on event date for efficiency. **On-demand transformation API** for inference: features computed at request time (never materialized) for inputs only known at inference (`distance(user_loc, merchant_loc)`). **Backfill pipeline** runs same transformation code over historical data on new feature definition. **Monitoring**: feature freshness SLOs per-feature; distribution-drift monitors comparing serving distributions to training distributions; alerting on null-rate spikes.

### Deep dives
1. **Point-in-time correctness + training-serving skew elimination.** **PIT join**: for each training row at time `t_event`, fetch feature values where `feature_timestamp ≤ t_event` (latest before event). Naive `feature_table.join(label_table)` on key uses **current** values → leaks future information → inflated offline metrics that don't replicate online. Production implementation: Hudi / Iceberg time-travel queries; Hopsworks ACID upserts on copy-on-write tables. **Training-serving skew**: same feature-definition code executes both paths. Naive: SQL aggregation in training pipeline + separately-coded streaming aggregation in serving — they drift. Feature store: declare feature once; framework generates both pipelines.

2. **Three transformation types (Tecton model).** **Batch**: offline materialized (30-day avg spending; computed nightly; written to offline + online stores). **Stream**: Kafka/Kinesis windowed aggregation (last-5-min purchase count; computed continuously; materialized to online store with <200ms latency). **On-demand/Realtime**: computed at request time (`distance(user_loc, merchant_loc)` — both values only known at request); never materialized; pure inference-time compute. Each type has different consistency guarantees + operational profile. Tecton's published example: "Realtime Feature Views cannot be materialized since they are calculated only at request-time. This is ideal for scenarios requiring up-to-the-moment data like fraud detection or dynamic pricing."

3. **Streaming feature pipeline + online store choice + scale anchors.** Uber's published stack: Kafka brokers aggregating logs → Samza streaming compute → managed Cassandra clusters for online store. Velocity counters (`count(events) WHERE event_time > now() - 5min`) updated <200ms from event to feature-store read. **Hopsworks** uses Apache Hudi copy-on-write tables on HopsFS/S3 for offline (ACID upserts + time-travel) + RonDB (in-memory 2PC) for online. **Online store choice**: Redis (sub-ms, expensive at scale) vs DynamoDB (slightly higher latency, cheaper, easier to scale) vs Aerospike (HMA blends DRAM + flash for sub-ms at scale). **LinkedIn Feathr + Airbnb Bighead (Deep Thought + Zipline/Chronon on Spark) + LinkedIn Pro-ML (Quasar engine + central feature marketplace)** as production examples.

## Known failure modes
1. **PIT-join violation in training.** Forget to filter `feature_timestamp ≤ event_timestamp`; train on leaked future features; offline metrics great, production terrible. Production answer: feature-store framework enforces PIT semantics by default; CI test that flags any non-PIT join.

2. **Online-offline drift on backfill.** New feature defined; backfill regenerates historical values; backfill uses different transformation than streaming → historical training data inconsistent with online serving. Production answer: backfill must use same transformation code as streaming; framework auto-generates backfill from same definition.

3. **Feature staleness vs freshness trade.** Hot features need <200ms freshness (fraud, surge); warm features can be hours stale (segment, lifetime value). Production answer: tiered freshness budgets per-feature; online store optimized for hot features; batch updates for warm.

4. **Online-store hot keys.** Viral entities (celebrity user, popular product) saturate one shard. Production answer: consistent-hash sharding + per-shard replication; per-entity TTL'd in-memory cache.

5. **Feature TTL evictions during traffic spikes.** Feature appears as null online but not in training (training has historical value). Production answer: fallback default for null; sentinel value vs true missing distinction; backfill on demand from offline if TTL expired.

6. **Schema-evolution breakage** when feature's type changes but consumers aren't notified. Production answer: feature-version pinning per-model; deprecation cycle with overlap; CI test on schema diffs.

## Notes for the coach
- **Asked-confirmed at multiple ML-platform interviews (Uber, Pinterest, Airbnb, DoorDash, Lyft, Tecton/Feast users).** Tecton docs, Feast documentation, Uber Michelangelo blog series, Chip Huyen's book, Hopsworks blog — all explicit interview-prep canon.
- **Point-in-time-correct joins are the canonical Staff+ unlock.** Candidates who name PIT correctness as a feature-store requirement demonstrate the right mental model; candidates who suggest naive `feature_table.join(label_table)` miss the data-leakage failure mode entirely.
- **The three transformation types (Tecton model) is the architectural depth probe.** Candidates who articulate batch vs stream vs on-demand demonstrate operational understanding of when each is appropriate.
- **Adversarial probe: "you added a new feature definition — what breaks at training time?"** Strong answer: backfill must regenerate historical values using same transformation code; framework auto-generates backfill from definition; PIT join enforced; CI test flags any feature consumed without backfill complete. Weak answer: "we wait for data to accumulate" — but that loses historical training data.

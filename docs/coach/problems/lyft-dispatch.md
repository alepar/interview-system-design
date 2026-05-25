---
slug: lyft-dispatch
archetype: geo-proximity
sources:
  lyft_dispatch: eng.lyft.com/solving-dispatch-in-a-ridesharing-problem-space-821d9606c3ff
  lyft_redis_15m: slideshare.net/slideshow/geospatial-indexing-at-scale-the-15-million-qps-redis-architecture-powering-lyft/76662828
  lyft_rl: arxiv.org/pdf/2310.13810
  lyft_mmv: eng.lyft.com/quantifying-efficiency-in-ridesharing-marketplaces-affd53043db2
  lyft_mapmatch: eng.lyft.com/a-new-real-time-map-matching-algorithm-at-lyft-da593ab7b006
  lyft_feature_store: slideshare.net/slideshow/taming-p99-latencies-at-lyft-tuning-low-latency-online-feature-stores/269858965
---

# Lyft dispatch — Google S2 (not Uber H3) + geohash-level-5 cells (~1 km²) + Redis cluster sharded by S2 cell ID + sorted-sets w/ 30s stale-beacon expiration (15M QPS sustained) + bipartite matching via ILP/LP relaxation + ~30s batched window for Lyft Line + online RL agent considering long-horizon driver-income state + Marketplace Marginal Values (MMV) dual-variable debiasing + Kalman-filter real-time map-matching

## Bar anchors
- **Mid-level (L4/E4):** Greedy nearest-driver per request; no spatial index discussion; per-request linear scan over driver table.
- **Senior (L5/E5):** Names spatial index + Redis cache. May or may not articulate Lyft's S2 choice (vs Uber's H3), 15M QPS architecture, RL transition, or MMV debiasing.
- **Staff+ (L6/E6+):** Names (a) **S2 + geohash level 5 default** (~1 km² per cell, chosen because region-based sharding caused hot-shard in big cities — level-5 cells limit each shard to bounded drivers); (b) **Redis cluster sharded by S2 cell ID**, sorted-sets keyed by cell with 30s expiration of stale driver beacons; **15M QPS sustained** per RedisConf17 talk; (c) **bipartite matching as ILP/LP relaxation** with ~30s batched window (especially Lyft Line shared rides); trade longer window = better global match vs longer rider no-dispatch anxiety; (d) **modern RL transition**: Lyft moved from optimization-only to online RL; agent considers long-horizon driver-income and supply-demand state; (e) **Marketplace Marginal Values (MMV)**: dual variables (shadow prices) from dispatch LP debias A/B experiments against marketplace interference (treatment + control compete for same drivers); (f) **real-time map-matching via Kalman filter**: translates raw GPS to road network; consumes streaming road-closure events; (g) **Lyft Feature Store online GET p50 8ms / p95 20ms / p99 40ms**; (h) **Apache Beam ML feature pipelines** at geohash+minute granularity (ClickHouse + SageMaker + Airflow stack); (i) **route-swapping for Lyft Line** reassigns riders between in-progress shared routes before pickup to improve density.

## Canonical decomposition

### Requirements
**Functional:**
- Request ride (pickup + dropoff)
- Driver receives + accepts/rejects
- Lyft Line shared-ride matching (route compatibility constraint)
- Real-time ETA

**Non-functional:**
- 15M QPS sustained Redis geospatial layer
- Feature Store p50 8ms / p95 20ms / p99 40ms
- Bipartite matching ~30s batched window (Lyft Line)
- Dispatch latency budget seconds-scale

### Core entities
- **Driver:** driver_id, current_location, S2 cell, status
- **Ride request:** rider_id, pickup, dropoff, created_at
- **Match:** driver_id × rider_id (or multi-rider for Lyft Line)
- **MMV:** shadow prices from dispatch LP dual variables

### API
- `POST /rides` body={pickup, dropoff, type ∈ {standard, line}}
- Driver app: WebSocket location-ping every N seconds → S2 cell update
- `POST /matches/:id/accept` body={driver_id}

### HLD
Location ingest: drivers ping location to Driver Tracking Service over WebSocket; service computes S2 cell ID (level 5 default ~1 km²); writes to Redis cluster sharded by cell ID using ZADD on sorted-set keyed by cell_id with score=timestamp; 30s TTL on entries discards stale beacons.

Dispatch path: rider request → Dispatch Service. Identify pickup's S2 cell + neighboring cells (k-ring expansion). Range-query Redis for driver pool (ZRANGEBYSCORE on cell sorted-sets). Compose bipartite matching problem (driver, rider) within batch window (~30s, especially Lyft Line); solve via ILP/LP relaxation (Gurobi or similar); for RL-augmented matching, agent computes long-horizon driver-income reward.

Dispatch + ETA: ETA Service uses Kalman-filter map-matching to translate raw GPS → road network; consumes road-closure event stream. Feature Store provides per-(driver, geohash, minute) features (Apache Beam pipelines + ClickHouse + SageMaker).

A/B + marketplace experiments: MMV dual variables from dispatch LP debias treatment-vs-control bias (both compete for same drivers).

### Deep dives
1. **S2 + Redis 15M QPS architecture.** Lyft chose Google S2 over Uber's H3. Geohash level 5 ~1 km² per cell. Sharded Redis cluster keyed by S2 cell ID. Sorted-sets per cell with 30s expiration of stale driver beacons. **15M QPS sustained.** Region-based sharding caused hot-shard problem in big cities; level-5 cells limit shard load. **Why level 5 specifically**: square-km cells balance shard load (~few cars per shard in big cities) vs spatial-query cost (k-ring of 6 neighbors covers ~7 km²).
2. **Bipartite matching + LP relaxation + 30s batching.** Dispatch as bipartite (driver, rider). Solved via ILP/LP relaxation. ~30s batched window — longer window = better global match (more rider/driver options) but longer rider no-dispatch anxiety. Lyft Line requires longer window because route-compatibility is part of the matching objective. Route-swapping reassigns riders between in-progress shared routes before pickup to improve density.
3. **MMV + RL + Marketplace experiments.** Marketplace Marginal Values: dual variables (shadow prices) from dispatch LP debias A/B experiments against marketplace interference. Modern RL agent considers long-horizon driver-income state (multi-step reward over future rides, not just current match). Switchback experimentation (time-region randomization) for marketplace A/B without interference bias.

## Known failure modes
1. *Hot shard problem in big cities* — naive region-based sharding overloads one Redis node. Production answer: level-5 cells (~1 km²) limit shard load.
2. *Stale driver beacon* causing assignment to offline driver. Production answer: 30s expiration on sorted-set entries + driver heartbeat refresh.
3. *Marketplace A/B interference bias* — treatment + control compete for same drivers. Production answer: MMV dual-variable debiasing; switchback experimentation.

## Notes for the coach
- **Asked-confirmed at Lyft.** RedisConf17 talk by Daniel Hochman is foundational; eng.lyft.com posts are interview-prep canon.
- **Architectural opposite** of `uber` (H3 hex vs S2 cube). Drill both for the H3-vs-S2 trade.
- **Cross-coverage** with `h3-s2-spatial-index` (this archetype; foundational primitive). With ML-in-loop `uber-surge` (pricing layer on top of dispatch).
- **The S2 + 15M-QPS architecture is the canonical Staff+ unlock.** Mid-senior candidates default to H3 (Uber's choice); Staff+ candidates name Lyft's S2 choice with the hot-shard justification.
- **Adversarial probe: "Why didn't Lyft use H3 like Uber?"** Strong answer: S2's strict-quadtree hierarchy enables single-cover-with-mixed-levels for shaped service areas (Lyft Line zones); H3's hex non-perfect-nesting (1/7 area per resolution) makes hierarchical roll-ups trickier; S2 + Hilbert curve allows B-tree range queries on existing Redis sorted-sets without bespoke spatial code. Also: chronologically S2 was production-ready when Lyft built its first dispatch system; H3 open-sourced later. Weak answer: "we use Redis sorted sets" without the spatial-index justification.

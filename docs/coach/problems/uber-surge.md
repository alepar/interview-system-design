---
slug: uber-surge
archetype: ml-in-loop
sources:
  uber_h3_blog: uber.com/us/en/blog/h3/
  uber_kafka_paper: arxiv.org/abs/2104.00087 (Fu et al. "Real-time Data Infrastructure at Uber")
  michelangelo_blog: uber.com/blog/michelangelo-machine-learning-platform/
  uber_gairos_blog: uber.com/us/en/blog/gairos-scalability/
---

# Uber surge pricing — H3 hex grid + streaming Kafka/Flink + decomposed forecast + price-elasticity controller + active-active failover

## Bar anchors
- **Mid-level (L4/E4):** "Increase price when demand > supply." No geospatial primitive; no oscillation control; no feedback loop.
- **Senior (L5/E5):** Names H3 + streaming features + multiplier function. May or may not address active-active failover, decomposed-vs-end-to-end modeling, anti-flicker engineering, or counterfactual evaluation.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **soft-real-time geo-bucketed ML** with regulatory + adversarial constraints. Names **H3 hex grid as geospatial primitive** (resolution 8 ≈ 0.74 km², ~460m edge; 16 resolutions; hexes for uniform 6-equidistant-neighbor aggregation without anisotropic bias). Names **streaming feature pipeline** (Kafka → Flink/Samza → per-cell aggregations over sliding windows ~60s). Articulates **decomposed modeling** (NOT end-to-end): demand-forecast GBM (DeepETT-class, 5-min cadence, 3-hour horizon, R²~0.92) feeds price-elasticity controller (multiplier ∈ [1×, ~5×] bounded by regulatory caps). Names **demand definition** = open requests + recent app opens + abandoned sessions (the last is critical — without it, surge collapses as riders give up). Cites **active-active multi-region failover** per Uber Kafka blog: "When disaster strikes the primary region, the active-active service assigns another region to be the primary, and the surge pricing calculation fails over to another region." Names **anti-flicker engineering**: smoothing + rate-limiting + hysteresis prevent single-driver cell-boundary crossings from swinging multiplier 1.0 → 1.6. Cites **Michelangelo** serving 10M predictions/sec at P95 <10ms (with Cassandra feature store) / <5ms (without). Stretch (Sr Staff bar): articulates **push (not poll) delivery** to clients over long-lived connection partitioned by H3 cell; rider's price-on-screen consistent within ~1s of recompute.

## Canonical decomposition

### Requirements
**Functional:**
- Per-H3-cell surge multiplier recomputed every 1-2 min (30-60s in volatile cells)
- Sub-100ms multiplier lookup latency
- Active-active multi-region (failover during region drop)
- Anti-flicker: no oscillation across cell boundaries
- Regulatory cap compliance per city

**Non-functional (with numbers):**
- Per Fu et al. arXiv 2104.00087: Kafka processes ~trillion messages/day, >10M msg/s peak at Uber
- Per Michelangelo: 5K+ models in production serving 10M real-time predictions/sec at peak
- Michelangelo P95: <5ms (no Cassandra) / <10ms (with Cassandra)
- H3 resolution 8 ≈ 0.74 km² ≈ block or two
- DeepETT re-forecasts every 5 min over 3-hour horizon across ~100M road segments
- GPS pings ~4s; driver heatmaps update ~10 min
- Multipliers historically 1.0× to ~5× with city-specific regulatory caps
- Gairos (real-time geospatial platform): 4× throughput post re-architecture; outages 1/month → 0/month

### Core entities
- **H3 cell:** cell_id (64-bit), resolution, geometry, supply/demand aggregates
- **Supply state:** active drivers in cell + adjacent ring
- **Demand state:** open requests + recent app opens + abandoned sessions
- **Forecast:** per-cell demand prediction over 3-hour horizon (5-min cadence)
- **Multiplier:** per-cell ∈ [1.0, regulatory_cap]; smoothed across neighbor hexes

### API
- `GET /surge?lat=X&lng=Y` → multiplier within <100ms (key-value lookup against precomputed table)
- Internal: aggregator.update(cell, supply, demand) → per-cell state; forecaster.predict(cell, horizon) → demand; controller.compute_multiplier(cell, forecast, current) → multiplier (smoothed)
- Push: cell_pubsub.broadcast(cell_id, multiplier) → all subscribed clients

### HLD
**Streaming pipeline**: Kafka topics partitioned by H3 cell ingest GPS pings + ride-request events + app-open events at ~10M msg/s peak; Samza/Flink stateful aggregation produces per-cell sliding-window aggregates (1-min, 5-min windows). **Active-active replicated topics** per Uber Kafka blog; regional aggregate clusters for global view. **Forecasting** runs DeepETT-class GBM every 5 min over 3-hour horizon. **Controller** combines forecast + current supply/demand → multiplier ∈ [1.0, regulatory_cap]; **smoothing** across ring-1 / ring-2 neighbor hexes prevents pricing cliffs; **rate-limiting** + **hysteresis** prevent oscillation. **Multiplier precomputed** per H3 cell at 1-2 min cadence; online surge lookup is essentially **key-value lookup** against precomputed table (<100ms). **Michelangelo** serves broader prediction surface (ETA, fraud, dispatch) at 10M predictions/sec; P95 <5ms (no Cassandra) / <10ms (with). **Palette feature store** bridges streaming/batch features for both real-time supply/demand + slowly-changing baselines (mean trips/hour, weather climatology). **Push to clients**: long-lived connection partitioned by H3 cell; rider's price-on-screen consistent with multiplier within ~1s of recompute.

### Deep dives
1. **H3 hex grid + supply-demand definitions.** H3 (Uber, open-source) tiles Earth in hexagons; 16 resolutions; 64-bit cell IDs. **Resolution 8** ≈ 0.74 km² ≈ block or two — matches rider "where I'm standing" granularity. **Hexagons over squares** because every cell has 6 equidistant neighbors → uniform neighbor distance math, important for spillover aggregation from adjacent cells without anisotropic bias. **Supply**: active drivers in cell + adjacent cells. **Demand**: open requests + recent app opens + **abandoned sessions** (the last is critical — without it, surge collapses as riders give up). **Ratio** = demand / max(supply, 1); multiplier = monotonic function of ratio.

2. **Decomposed modeling (forecast + elasticity controller).** **Not end-to-end**: separate demand-forecast model + price-elasticity controller. **Demand-forecast GBM** (DeepETT-class): regression on (cell × time → expected demand); R²~0.92 in published replications; 5-min cadence; 3-hour horizon. **Controller** maps (supply, predicted demand) → multiplier via parameterized monotonic function with smoothing. **Why decomposed**: easier to reason about, debug, tune; demand forecast reusable for other downstream models (ETA, ad placement); controller is marketplace-decision lever needing human-interpretable tuning. **No clean per-prediction label**: counterfactual / simulation evaluation needed (can't observe "what would have happened with 1.3× vs 1.5× on same trip"). Per Uber empirical finding: both supply and demand curves highly elastic — surging immediately drops open-to-order ratio + pulls more drivers online; this is the feedback loop multiplier is designed to close.

3. **Sub-100ms serving + active-active failover + anti-flicker.** **Multiplier precomputed** per H3 cell at 1-2 min cadence; online lookup is essentially KV lookup against precomputed table (<100ms). **Michelangelo** serves at 10M predictions/sec; P95 <10ms with Cassandra / <5ms without. **Palette feature store** for both real-time supply/demand (last-5-min) + slowly-changing baselines (mean trips per hour, weather climatology). **Active-active multi-region**: Kafka replicated topics across regions; primary recompute; on region failure, surge calc fails over to next region. **Anti-flicker**: smoothing (rolling avg across recomputes), rate-limiting (max multiplier change per tick), hysteresis (cool-down before multiplier changes direction). Display doesn't flicker even on cell-boundary single-driver crossings. **Push to clients** over long-lived connection partitioned by H3 cell.

## Known failure modes
1. **Oscillation** when controller gain too high → multipliers ping-pong across neighbor hexes. Production answer: tuned controller gains; explicit damping; ring-neighbor smoothing.

2. **Data-pipeline lag.** Kafka backs up; surge decisions stale; system over-prices. Production answer: per-pipeline freshness SLOs; alert on stale-feature degradation; backup with slower-but-fresher cell-level aggregate.

3. **Cold-start hexes** with low historical volume produce noisy demand estimates. Production answer: shrinkage estimator (pull toward city-mean demand); aggregate at coarser H3 resolution for low-volume cells.

4. **Cross-region drift** when active-active replicas drift slightly. Production answer: vector-clock 'persisted-up-to' positions per replica; alert on drift > threshold.

5. **Geographic non-transferability** — SF model doesn't generalize to Lagos (different supply elasticity, currency sensitivity, weather coupling). Production answer: per-city models with shared embedding/feature plumbing.

6. **Regulatory cap breakage** in newly entered cities. Production answer: per-city cap rule with default-deny (no rule → no surge allowed); legal-review gate before each new city launch.

## Notes for the coach
- **Asked-confirmed at Uber, Lyft, DoorDash.** Uber H3 blog, Real-time Data Infrastructure paper, Michelangelo blog series, Gairos blog — all explicit interview-prep canon. Hello Interview "Uber" is canonical.
- **The decomposed (forecast + elasticity controller) vs end-to-end framing is the Staff+ architectural unlock.** Candidates who default to "one neural network predicts multiplier" miss the operational reality.
- **The "demand includes abandoned sessions" is the deep-cut.** Without it, surge oscillates (riders give up → demand drops → surge drops → riders return → demand spikes → repeat).
- **Adversarial probe: "drivers cluster to chase surge — what counteracts this?"** Strong answer: demand definition includes abandoned sessions (drivers chasing fake-demand isn't matched by real riders → multiplier returns to normal quickly); reputation system for drivers gaming surge; explicit anti-collusion detection. Weak answer: "we trust the data" without acknowledging adversarial market participants.

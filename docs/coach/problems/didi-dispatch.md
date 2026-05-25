---
slug: didi-dispatch
archetype: geo-proximity
sources:
  didi_scale: greencarcongress.com/2018/01/20180112-didi.html
  didi_gaia: outreach.didichuxing.com/SimulationS/data.html
  didi_informs: dl.acm.org/doi/10.1287/inte.2020.1047
  didi_rl_wild: arxiv.org/pdf/2202.05118
  didi_hierarchical: arxiv.org/pdf/2009.02080
  didi_multiagent_rl: arxiv.org/abs/1910.02591
  didi_dima: arxiv.org/pdf/2503.04768
---

# DiDi dispatch — billion-trip scale (25M+ orders/day, 70TB/day new route data, 4500TB/day processed) + hexagonal/grid 200m × 200m cells for spatial discretization + bounded-depth spatial filtering keeps RL dispatch tractable + semi-Markov decision process (SMDP) + deep RL matching tens of millions of trips/day + multi-agent RL with KL-divergence-based order-vehicle distribution matching + hierarchical spatio-temporal adaptive dispatching + GAIA Open Dataset Initiative releases anonymized trip data + 2025 DiMA LLM conversational assistant

## Bar anchors
- **Mid-level (L4/E4):** Bipartite matching with no scale consideration; no spatial filtering.
- **Senior (L5/E5):** Names RL + spatial discretization. May or may not articulate hierarchical spatio-temporal dispatching, multi-agent RL KL-divergence matching, or DiMA.
- **Staff+ (L6/E6+):** Names (a) **scale**: 25M+ orders/day; 70TB/day new route data; 4500TB/day processed; (b) **GAIA**: anonymized trip data (origin/destination/route) from DiDi Express + Premier, public for transportation AI research starting 2017; (c) **dispatch evolution**: combinatorial optimization (Hungarian-style bipartite) → SMDP + deep RL; matches tens of millions of trips/day; (d) **spatial discretization**: 200m × 200m hexagonal/grid cells; **spatial filtering limits dispatch evaluation to cells within bounded depth** → near-identical service quality with lower latency; without bounded-depth filtering, naive global optimization over millions of orders intractable; (e) **hierarchical spatio-temporal adaptive dispatching**: cluster geographic areas with shared dispatch intervals, then choose dispatch time instants per cluster online; (f) **multi-agent RL** with KL-divergence-based order-vehicle distribution matching; hybrid online/offline system deployed in production; (g) **A/B impact**: +1.3% driver income; +5.3% on key metrics after full rollout in one major international market; (h) **DiMA (2025)**: LLM-powered conversational ride-hailing assistant layered on dispatch stack to handle complex multi-turn requests.

## Canonical decomposition

### Requirements
**Functional:**
- Request ride (Express / Premier / Carpool tiers)
- Driver dispatch under regulatory China constraints
- Multi-turn ride request via LLM assistant
- Anonymized data export for research (GAIA)

**Non-functional:**
- 25M+ orders/day; tens of millions of matched trips/day
- 70TB/day new route data; 4500TB/day processed
- 200m × 200m hex/grid cells
- A/B +1.3% driver income / +5.3% key metrics

### Core entities
- **Order:** order_id, pickup, dropoff, tier, created_at
- **Driver:** driver_id, location, cell, status
- **Cell:** 200m × 200m hex/grid cell
- **DispatchPolicy:** SMDP + deep RL state-action-reward per (cell, time-window)

### API
- `POST /orders` body={pickup, dropoff, tier}
- Driver app: location stream → cell update
- DiMA: conversational interface → structured order intent

### HLD
Spatial discretization: 200m × 200m hex/grid cells. Driver locations indexed by cell. Order requests bucket into pickup cell.

Dispatch: Hierarchical spatio-temporal adaptive — cluster geographic areas with shared dispatch intervals; per-cluster online time-instant selection. Per-cell bounded-depth spatial filtering limits RL evaluation. Multi-agent RL with KL-divergence-based order-vehicle distribution matching: each agent (cell) maintains policy; KL-divergence between desired (order) distribution and actual (vehicle) distribution drives reward.

Carpooling: route-compatibility within batched window.

DiMA (2025): LLM-powered conversational assistant for multi-turn ride requests (e.g., "Pick me up at the entrance closest to the food court, drop me off near the hospital's outpatient building, no extra stops").

### Deep dives
1. **Massive scale + GAIA + dispatch evolution.** 25M+ orders/day. GAIA dataset for transportation AI research. Dispatch evolution: Hungarian → SMDP + deep RL. Hierarchical spatio-temporal adaptive dispatching: cluster + online time-instant selection.
2. **200m hex cells + spatial filtering.** Bounded-depth filtering limits RL evaluation. Without it, global optimization over millions of orders intractable. Trade: near-identical service quality with lower latency.
3. **Multi-agent RL + KL-divergence + DiMA LLM assistant.** Multi-agent RL: per-cell policy, KL-divergence reward signal. Hybrid online/offline. A/B impact +1.3% driver income / +5.3% key metrics. DiMA LLM layer for complex multi-turn requests.

## Known failure modes
1. *Dispatch latency / matching quality trade-off* — naive global optimization intractable at DiDi scale. Production answer: spatial filtering + temporal batching.
2. *Carpooling regulatory complexity in China* — production answer: regulated separate "Express" and "Premier" service tiers.
3. *Cold-start in new cities* — limited historical data for RL warm-start. Production answer: transfer learning from similar-density cities.

## Notes for the coach
- **Plausibly-asked at DiDi, ByteDance, Meituan.** English-language sources limited — arXiv papers + INFORMS Interfaces + DiDi outreach site are the corpus.
- **Cross-coverage** with `uber` + `lyft-dispatch` (this archetype; competing dispatch designs). With ML-in-loop (RL deployment).
- **The 200m-cell + bounded-depth spatial filtering is the canonical Staff+ unlock at this scale.** Mid-senior candidates assume Hungarian-on-bipartite scales; Staff+ candidates name the explicit spatial-filtering tractability argument.
- **Adversarial probe: "Why hexagonal/grid 200m cells specifically? Why not H3 res-9?"** Strong answer: 200m × 200m chosen for the spatial-filtering bounded-depth tractability; specific size matches Chinese urban density (most Chinese cities have higher density than US so cells smaller); H3 res-9 ~0.11 km² (~330m × 380m equivalent) too coarse for dense urban + has 12 pentagon edge cases; DiDi chose custom hex grid for control over edge cases. Production: spatial-filter to bounded-depth (e.g., 3-cell radius) for RL action space tractability. Weak answer: "200m felt right" without the spatial-filtering argument.

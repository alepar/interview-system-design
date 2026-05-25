---
slug: doordash-dispatch
archetype: geo-proximity
sources:
  deepred: careersatdoordash.com/blog/using-ml-and-optimization-to-solve-doordashs-dispatch-problem/
  deepred_mip: careersatdoordash.com/blog/next-generation-optimization-for-dasher-dispatch-at-doordash/
  sibyl: careersatdoordash.com/blog/doordashs-new-prediction-service/
  ruin_recreate: careersatdoordash.com/blog/scaling-a-routing-algorithm-using-multithreading-and-ruin-and-recreate/
  service_mesh: careersatdoordash.com/blog/inside-doordashs-service-mesh-journey-part-1-migration-at-scale/
  switchback: careersatdoordash.com/blog/optimizing-real-time-algorithms-experimentation/
  dispatch_evolution: ilyazinkovich.github.io/2020/06/16/delivery-dispatching-evolution.html
---

# DoorDash dispatch — DeepRed three-sided marketplace (consumer + Dasher + merchant) + Hungarian on bipartite → MIP with Gurobi (10× faster, supports multi-stop routes) + Sibyl prediction service >100K predictions/sec (dispatch + ETA + prep-time + fraud) + Sibyl predicts Dasher travel/parking time + restaurant prep time + corrections to merchant prep quotes + ruin-and-recreate metaheuristic with multithreading for large neighborhood search + strategic dispatch delay + batching cascade risk + switchback experimentation (time-region randomization) + Level 0/1/2/X architectural evolution

## Bar anchors
- **Mid-level (L4/E4):** Greedy nearest courier per order; no batching; no prep-time consideration.
- **Senior (L5/E5):** Names courier ≠ rider, prep-time uncertainty. May or may not articulate Hungarian-to-MIP evolution, Sibyl service, ruin-and-recreate, or strategic delay.
- **Staff+ (L6/E6+):** Names (a) **DeepRed** as DoorDash's named last-mile dispatch — three-sided marketplace optimizer; (b) **algorithm evolution**: Hungarian on bipartite (one delivery per route) → MIP with Gurobi (10× faster on large instances + supports multi-stop routes); (c) **Sibyl prediction service**: handles ALL real-time ML predictions for "hundreds of thousands of predictions per second"; supports batched predictions over many feature sets to amortize gRPC overhead; (d) **Sibyl predicts** Dasher travel time to restaurant + restaurant food-prep time + corrections to merchant-quoted prep times — all fed into MIP dispatch; (e) **Routing solver**: ruin-and-recreate (LNS) metaheuristic with multithreading; penalty term scales with route complexity to discourage high-variance offers; (f) **batching cascade risk**: one slow restaurant prep delays all batched deliveries; batching constrained to orders completable within promise window; (g) **strategic dispatch delay**: DeepRed intentionally delays an offer rather than dispatch a sub-optimal Dasher (balances courier idle time vs food temperature); (h) **DoorDash traffic platform 80M+ requests/sec at peak**; (i) **switchback experimentation** (time-region randomization) because marketplace A/B has interference bias; (j) **architecture evolution**: Level 0 (greedy nearest) → Level 1 (Hungarian batched + prep-time) → Level 2 (multi-order pooling) → Level X (full VRP).

## Canonical decomposition

### Requirements
**Functional:**
- Order placed → Dasher dispatched → restaurant prep → pickup → drop-off
- Batching multiple orders to single Dasher when SLA-compatible
- Strategic dispatch delay when better Dasher imminent
- Food temperature constraint

**Non-functional:**
- DoorDash traffic platform 80M+ requests/sec at peak
- Sibyl >100K predictions/sec
- DeepRed MIP 10× faster than prior Hungarian

### Core entities
- **Order:** order_id, restaurant_id, customer_id, promise_time, status
- **Dasher:** dasher_id, current_location, vehicle_type, active_batch
- **Batch:** dasher_id, ordered_stops[], total_time_estimate
- **PredictionRequest:** {features[], model_id} → Sibyl

### API
- `POST /orders` (consumer)
- Dasher app: location-stream + accept/reject offer
- Internal: Sibyl `predict(model_id, batch_features[])` → predictions[]

### HLD
Order placement: order → routes to Dispatch Service. Dispatch Service queries Sibyl for predictions (Dasher travel time to restaurant for nearby Dashers, food-prep time correction for this restaurant, Dasher acceptance probability). Predictions feed into MIP solver (Gurobi).

MIP solver: variables = (dasher_id, batch_set, order_id) assignments. Objective = weighted sum of food temperature + Dasher idle time + customer SLA + per-route complexity penalty. Constraints: each order assigned exactly once; batches completable within promise window; capacity constraints per vehicle. Solver runs per-batch with wall-clock budget; ruin-and-recreate metaheuristic with multithreading for large neighborhoods.

Strategic delay: DeepRed evaluates whether waiting N seconds for a better Dasher yields net benefit (vs immediate sub-optimal). If yes, delay; if no, dispatch immediately.

Switchback experimentation: per-(region, time-window) treatment assignment; ablates marketplace interference bias.

### Deep dives
1. **Hungarian → MIP-with-Gurobi + multi-stop batching.** Original Hungarian on bipartite — one delivery per route. MIP with Gurobi 10× faster + multi-stop. Batching constrained to promise-window-completable orders. Strategic dispatch delay when better Dasher imminent.
2. **Sibyl prediction service.** All real-time ML predictions (>100K/sec). Predicts Dasher travel, restaurant prep, prep-time corrections. Batched predictions over many feature sets amortize gRPC overhead. Makes per-dispatch ML feasible at marketplace cadence.
3. **Ruin-and-recreate routing + switchback experiments + architecture evolution.** Routing: ruin-and-recreate (LNS) metaheuristic with multithreading. Switchback (time-region randomization) for marketplace A/B without interference bias. Architecture evolution: Level 0 greedy → Level 1 Hungarian-with-prep-time → Level 2 multi-order pooling → Level X full VRP.

## Known failure modes
1. *Batching cascade* — one slow restaurant prep delays all batched deliveries. Production answer: batching constrained to promise-window-completable orders + per-batch SLA monitoring.
2. *Sibyl prediction stale* on cold-start restaurant. Production answer: fallback to merchant-quoted prep time + active-learning data collection.
3. *Strategic-delay user frustration* — user sees "looking for Dasher" longer than necessary. Production answer: SLO on max delay; surface "Dasher being assigned, ETA X" to mask the delay.

## Notes for the coach
- **Asked-confirmed at DoorDash.** DeepRed + Sibyl + ruin-and-recreate engineering blogs are canon.
- **Cross-coverage** with `last-mile-routing` (this archetype; VRP variant). With `instacart-batching` (this archetype; similar batching but indoor pick-path adds dimension). With `uber` + `lyft-dispatch` (geo #6; rider-dispatch comparison).
- **The three-sided marketplace (consumer + Dasher + merchant) with prep-time uncertainty is the canonical Staff+ unlock distinguishing food delivery from rides.** Mid-senior candidates pattern-match to Uber rides; Staff+ candidates name the third side (merchant) + prep-time uncertainty as unique inputs.
- **Adversarial probe: "Super Bowl Sunday, demand spikes 5×, what breaks first?"** Strong answer: Sibyl >100K predictions/sec saturates → batched predictions buy capacity but eventually queue lag; MIP solver per-batch time-bound exceeded → fall back to greedy with strategic delay; restaurant prep-time estimates drift (kitchens overloaded) → switch to recent-history-weighted predictions; per-Dasher acceptance probability shifts (Dashers reject due to wait) → re-tune incentive model + surface "high demand" in app. Weak answer: "scale horizontally" without naming the specific bottlenecks.

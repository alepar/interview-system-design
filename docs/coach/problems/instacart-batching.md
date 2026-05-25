---
slug: instacart-batching
archetype: geo-proximity
sources:
  fulfillment: tech.instacart.com/space-time-and-groceries-a315925acf3a
  quantile: tech.instacart.com/how-instacart-delivers-on-time-using-quantile-regression-2383e2e03edb
  mixpanel: mixpanel.com/blog/instacart-data-science-routing-batching-staffing-monte-carlo/
  fulfillment_docs: docs.instacart.com/connect/fulfillment/
  ieee: spectrum.ieee.org/the-algorithms-that-make-instacart-roll
  jit: instacart.com/company/tech-innovation/building-an-on-demand-fulfillment-engine-is-hard
---

# Instacart batching — CVRPTW (Capacitated VRP with Time Windows) decomposed into clustering + shopper-assignment + up to 5 deliveries per shopper batch + replan every minute + quantile regression q=0.9 predicts upper-bound delivery time (schedule against p90 so on-time 90%) + cumulative-risk failure (one over-time pick cascades into lateness for remaining 4) + greedy nearest-shopper baseline added ~10min per delivery in dense urban (halved by cluster-then-assign-then-heuristic in SF) + indoor pick-path routing as first-class cost component + out-of-stock replacement ML + in-app chat + just-in-time dispatching

## Bar anchors
- **Mid-level (L4/E4):** Single shopper per order; no batching; no quantile-bound scheduling.
- **Senior (L5/E5):** Names CVRPTW + batching. May or may not articulate quantile regression, cumulative-risk failure, indoor pick-path, or out-of-stock replacement chat.
- **Staff+ (L6/E6+):** Names (a) **fulfillment engine** generates trips with up to 5 deliveries per shopper; decomposes CVRPTW into clustering + shopper-assignment sub-problems; replans every minute; (b) **quantile regression model at q=0.9** predicts upper-bound delivery time → schedule against p90 so on-time 90% despite weather/store congestion; (c) **cumulative-risk failure mode**: in 5-delivery batch, one over-time pick cascades into lateness for remaining 4; quantile-based planning bounds this; (d) **greedy nearest-shopper baseline added ~10 min per delivery** in dense urban; Instacart moved to cluster-then-assign-then-heuristic and **halved per-delivery minutes in SF**; (e) **out-of-stock handling**: ML model recommends replacements based on shopping data; shopper can enter free-form items via Shopper app; replacement chat with customer in-app; (f) **routing must encode store-floor traversal** (not just driving) — Instacart cited as one of few logistics ML systems where indoor "pick path" is a first-class cost component; (g) **just-in-time dispatching**: forecasts demand, recomputes batch plans every minute, defers dispatch decisions until last-responsible-moment to meet SLA.

## Canonical decomposition

### Requirements
**Functional:**
- Customer places multi-store order
- Shopper picks at store, optionally batched with other orders
- Out-of-stock → ML recommends replacement OR shopper enters free-form OR in-app chat with customer
- Delivery to customer

**Non-functional:**
- Up to 5 deliveries per shopper batch
- Quantile regression q=0.9 for p90 on-time
- Replan every minute
- Halved per-delivery minutes in SF vs greedy

### Core entities
- **Order:** order_id, customer_id, store_id, item_list, promise_time
- **Shopper:** shopper_id, current_location, active_batch, vehicle_type
- **Batch:** shopper_id, store_id, order_ids[], total_pick_path_estimate
- **PredictionRequest:** {features} → quantile regression q=0.9

### API
- `POST /orders`
- Shopper app: pick-progress + replacement-chat + delivery-confirm
- Internal: just-in-time dispatch every minute → recompute batches

### HLD
Order placement: orders queued by store. Fulfillment Engine (every minute) runs CVRPTW solver:
1. **Cluster** orders by store (and nearby stores reachable in single shopper trip).
2. **Assign** clusters to shoppers via capacity-constrained assignment.
3. **Heuristic refine** within each cluster.

Quantile regression q=0.9 predicts upper-bound per-pick time + per-stop drive time. Solver schedules against p90 → 90% on-time despite weather/store congestion.

Shopper picks at store. Indoor pick-path computed (store-floor traversal as cost component). Out-of-stock: ML model recommends replacement; shopper enters free-form OR in-app chat with customer.

Delivery: shopper drives to customers in batch in optimized order.

### Deep dives
1. **CVRPTW + clustering + just-in-time dispatch.** CVRPTW decomposed into clustering + shopper-assignment + heuristic refinement. Up to 5 deliveries per batch. Replans every minute. Just-in-time: defers dispatch until last-responsible-moment to meet SLA.
2. **Quantile regression q=0.9 + cumulative-risk failure mode.** Q=0.9 predicts upper-bound delivery time. Schedule against p90 → 90% on-time. Cumulative risk: in 5-delivery batch, one over-time pick cascades into lateness for remaining 4. Quantile-based planning bounds the cascade.
3. **Indoor pick-path + out-of-stock replacement.** Routing encodes store-floor traversal (not just driving). Indoor pick path as first-class cost component. Out-of-stock: ML recommends replacements; shopper enters free-form via app; replacement chat with customer in-app.

## Known failure modes
1. *Cumulative-risk cascade* in 5-delivery batch. Production answer: q=0.9 quantile regression bounds the cascade.
2. *Greedy nearest-shopper baseline* adds ~10min per delivery in dense urban. Production answer: cluster-then-assign-then-heuristic.
3. *Out-of-stock without good replacement* — shopper picks bad alternative, customer rates poorly. Production answer: ML recommendation + in-app chat for confirmation.

## Notes for the coach
- **Asked-confirmed at Instacart.** Tech.instacart.com publishes quantile-regression + CVRPTW posts; IEEE Spectrum profile is staple.
- **Cross-coverage** with `doordash-dispatch` (this archetype; competing dispatch design). With `last-mile-routing` (this archetype; VRP variant). With ML-in-loop (quantile regression model).
- **The quantile-regression-bounding-cumulative-risk is the canonical Staff+ unlock.** Mid-senior candidates compute mean delivery time; Staff+ candidates name q=0.9 as the explicit bound on cascade failure.
- **Adversarial probe: "Big snowstorm in Chicago, all your batch plans are wrong. How does the system recover?"** Strong answer: just-in-time dispatching recomputes every minute → naturally absorbs distribution shift; quantile model retrained on recent weather-context data; per-store congestion features updated in feature store; surface "high demand" in app to manage customer expectations; shopper-supply adjustment via surge incentives. If quantile distribution shifts beyond model training distribution, fall back to conservative defaults + manual ops dashboard. Weak answer: "wait for the storm to pass" without naming the just-in-time loop.

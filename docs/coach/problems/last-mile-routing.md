---
slug: last-mile-routing
archetype: geo-proximity
sources:
  or_tools: developers.google.com/optimization/routing/vrptw
  deepred: careersatdoordash.com/blog/using-ml-and-optimization-to-solve-doordashs-dispatch-problem/
  ruin_recreate: careersatdoordash.com/blog/scaling-a-routing-algorithm-using-multithreading-and-ruin-and-recreate/
  sibyl: careersatdoordash.com/blog/doordashs-new-prediction-service/
  amazon_dataset: amazon.science/publications/2021-amazon-last-mile-routing-research-challenge-data-set
  amazon_driver: amazon.science/blog/amazon-mit-team-up-to-add-driver-know-how-to-delivery-routing-models
  orion: informs.org/Impact/O.R.-Analytics-Success-Stories/Optimizing-Delivery-Routes
  orion_dynamic: supplychaindive.com/news/ups-orion-route-planning-analytics-data-logistics/601673/
  bi_objective: arxiv.org/pdf/2405.16051
  vrptw_guide: mbrenndoerfer.com/writing/vehicle-routing-problem-time-windows-vrptw-optimization-guide
---

# Last-mile routing — CVRPTW (Capacitated VRP with Time Windows) NP-hard TSP generalization + metaheuristics (LNS / ruin-and-recreate, guided local search, tabu) + Google OR-Tools as open-source baseline + DoorDash DeepRed two-layer (ML predicts travel/parking/pickup/Dasher acceptance + OR scores/ranks/batches/strategic-delay) + Sibyl >100K predictions/sec batched feature sets amortize gRPC + UPS ORION (35K drivers 2015, saves 100M miles + 10M gal fuel/yr + $300-400M/yr opex, $250M project cost, 160 stops/day avg, dynamic mid-route reopt saves 2-4 more miles per driver) + Amazon Last Mile Routing Research Challenge ($175K prize, 9,184 routes from 5 metros) + driver-knowledge gap (mathematically-optimal routes rejected by drivers) + bi-objective formulation trades cost vs driver-preference similarity

## Bar anchors
- **Mid-level (L4/E4):** Single TSP per truck; no time windows; no capacity constraint.
- **Senior (L5/E5):** Names CVRPTW + OR-Tools. May or may not articulate ruin-and-recreate, DeepRed two-layer, driver-knowledge gap, or bi-objective formulation.
- **Staff+ (L6/E6+):** Names (a) **CVRPTW**: NP-hard TSP generalization; metaheuristics (LNS = ruin-and-recreate, guided local search, tabu); Google OR-Tools canonical open-source; (b) **DoorDash DeepRed** two-layer: ML estimates per-order travel + parking + pickup + Dasher acceptance probability; OR scores/ranks + batches + strategically delays; (c) **Ruin-and-recreate (LNS) with multithreading** for COVID-era demand spikes; penalty term scales with route complexity; (d) **Sibyl >100K predictions/sec**; batched predictions over many feature sets amortize gRPC overhead; (e) **Amazon Last Mile Routing Research Challenge** (2021, with MIT CTL): 9,184 historical driver routes from 5 US metros for ML teams to predict experienced-driver stop sequences; 1,000 held-out; prize pool $100K/$50K/$25K; (f) **Driver-knowledge gap** (Amazon's explicit motivation): "Drivers possess insights about road navigability, parking, stop clustering opportunities, operational factors that existing optimization models don't capture" — goal: imitate experienced drivers, not pure OR; (g) **UPS ORION** (Dec 2015): 35K of 55K US drivers using; saves ~100M miles + 10M gal fuel/yr; CO2 reduction 100K metric tons/yr; projected $300-400M/yr opex; $250M project cost; (h) **ORION on Package Flow Technology** (PFT, 2003); avg driver ~160 stops/day; deterministic OR + ML analytics on traffic/weather/historical; later dynamic mid-route reopt saves 2-4 more miles per driver; (i) **Bi-objective formulation**: trade cost against driver-preference similarity — pure OR optimum rejected on the ground; active research area; (j) **VRPTW solver capacity**: hundreds of customers per route reliably; thousands push into near-optimal-in-seconds territory.

## Canonical decomposition

### Requirements
**Functional:**
- Capacitated VRP with time windows per vehicle
- ML-predicted travel/parking/pickup time
- Multi-stop batching
- Mid-route dynamic reoptimization

**Non-functional:**
- UPS ORION 35K drivers / 160 stops/day / $300-400M/yr opex savings
- DoorDash Sibyl >100K predictions/sec
- DoorDash MIP 10× faster than Hungarian for multi-stop
- Modern solver: hundreds of stops per route reliably

### Core entities
- **Vehicle:** vehicle_id, capacity, start_location, time_window
- **Stop:** stop_id, location, demand, time_window
- **Route:** vehicle_id, ordered_stops[], total_time, total_cost
- **PredictionRequest:** {stop_features[]} → travel/parking/pickup time

### API
- Internal: per-batch `optimize_routes(vehicles[], stops[])` → routes[]
- Internal: `predict(model_id, features[])` → batched predictions
- Driver app: real-time stop progress + dynamic-reopt-request

### HLD
Offline batch: per-region per-day routing run. Vehicles + stops + time windows + capacities → CVRPTW formulation. Constructive heuristic (savings / insertion) for initial feasible solution. Metaheuristic refinement (ruin-and-recreate LNS with multithreading; OR guided local search; tabu) under wall-clock budget. Penalty term scales with route complexity to discourage high-variance offers.

Per-stop ML predictions: Sibyl-style prediction service. Predicts travel time (function of distance + traffic + time-of-day), parking time (function of urban-vs-suburban density), pickup time (function of restaurant prep / package handoff complexity), Dasher acceptance probability. Batched predictions over many feature sets amortize gRPC overhead.

Dynamic mid-route reopt: driver app reports stop progress; ORION-style system recomputes remaining route every N stops; saves 2-4 additional miles per driver.

Driver-knowledge gap mitigation: bi-objective formulation balances cost against driver-preference similarity (trained on historical driver trajectories); OR-only solutions rejected on the ground.

### Deep dives
1. **CVRPTW + metaheuristics + OR-Tools.** NP-hard. Metaheuristics: LNS (ruin-and-recreate), guided local search, tabu. OR-Tools open-source baseline. Two-phase production: heuristic construction + metaheuristic refinement under wall-clock budget. Modern solvers handle hundreds of customers per route reliably.
2. **DoorDash DeepRed + Sibyl + ruin-and-recreate.** ML predicts travel/parking/pickup/acceptance. OR scores/ranks/batches/strategic-delay. Sibyl >100K predictions/sec batched feature sets. Routing ruin-and-recreate multithreading + penalty on route complexity.
3. **UPS ORION + Amazon driver-knowledge gap + bi-objective.** ORION on PFT foundation; deterministic OR + ML analytics; dynamic mid-route reopt. Amazon's explicit motivation: driver tacit knowledge missing from pure OR. Bi-objective formulation trades cost against driver-preference similarity. Saves 2-4 more miles per driver via dynamic mid-route reopt.

## Known failure modes
1. *Batching cascade* — multiple orders to one driver reduces miles but increases per-order variance (cold food). Production answer: DeepRed penalty term on route complexity.
2. *Mathematically-optimal route rejected by driver* — driver-knowledge gap. Production answer: bi-objective formulation OR ML-imitating models on experienced-driver trajectories.
3. *Sibyl prediction stale on cold-start* new restaurant/neighborhood. Production answer: fallback to defaults + active-learning collection.

## Notes for the coach
- **Asked-confirmed at DoorDash, Amazon (Last Mile Science).** Plausibly at UPS, FedEx, Instacart, Postmates. DoorDash engineering blog + Amazon Science + INFORMS ORION case study are canon.
- **Cross-coverage** with `doordash-dispatch` (this archetype; coupler problem). With `instacart-batching` (this archetype; VRP variant with indoor pick-path). With `google-maps-routing` (this archetype; road-network preprocessing).
- **The driver-knowledge gap (math-optimal routes rejected by drivers) is the canonical Staff+ unlock distinguishing real last-mile from textbook VRP.** Mid-senior candidates focus on OR; Staff+ candidates name the Amazon Last Mile Challenge + bi-objective formulation.
- **Adversarial probe: "Your VRP solver returns optimal route but driver always goes a different way. Why don't you ignore the driver?"** Strong answer: driver knowledge encodes constraints OR can't observe — parking availability, road navigability for delivery vehicle (low-hanging branches), stop-clustering opportunities (same building accepts deliveries through one back door), customer-preference tacit info (signature-required times); pure OR optimum penalizes drivers' time AND fuel (they avoid the route in practice anyway); Amazon Last Mile Challenge dataset codifies this as bi-objective trading cost against driver-similarity; ML-imitating models trained on experienced-driver trajectories outperform pure OR by 5-15% on real fleet metrics. Weak answer: "drivers are wrong" without naming the unobservable constraints.

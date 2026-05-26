# Combinatorial Optimization

Source: `staff-engineer-study-guide.md`.

## Bipartite Matching and the Hungarian Algorithm

**Definition.** Bipartite matching assigns N workers to M tasks minimizing total cost over a cost matrix; the Hungarian algorithm solves the offline assignment problem in O(n³) by finding a minimum-cost perfect matching via augmenting paths in the equality subgraph.

**Canonical use.** DoorDash's original DeepRed dispatcher solved one-delivery-per-route assignments as a Hungarian bipartite match (Dasher × order), and Lyft formulates per-batch ride dispatch as a bipartite (driver, rider) matching solved via ILP/LP relaxation.

**Production systems.** DoorDash DeepRed (Hungarian → MIP migration), Lyft dispatch (bipartite + LP relaxation), Uber dispatch (similar bipartite framing).

**Alternatives.** Min-cost max-flow as a generalization when capacities and side constraints appear (e.g., one driver can take multiple orders); greedy nearest-neighbor for fast online assignment when O(n³) is too slow at marketplace cadence.

## Vehicle Routing Problem (VRP) and CVRPTW

**Definition.** VRP generalizes TSP to a fleet of vehicles serving customers from a depot; VRPTW adds delivery time windows per stop; CVRPTW adds per-vehicle capacity constraints — all NP-hard, so production solvers use construction heuristics plus metaheuristic refinement under a wall-clock budget.

**Canonical use.** Instacart formulates per-minute shopper batching as CVRPTW decomposed into clustering → shopper-assignment → heuristic refinement with up to 5 deliveries per shopper; UPS ORION solves CVRPTW-class instances for 35K drivers averaging 160 stops/day.

**Production systems.** UPS ORION (deterministic OR + ML analytics, saves ~100M miles/yr), Instacart fulfillment engine (CVRPTW every minute), DoorDash DeepRed (multi-stop batching), Amazon Last Mile Routing.

**Alternatives.** Pure TSP per vehicle when there's no time-window or capacity constraint (simpler but ignores SLA); cluster-first-route-second as a structured heuristic when geographic locality dominates.

## Ruin-and-Recreate / Large Neighborhood Search (LNS)

**Definition.** LNS destroys a chunk of the current solution (e.g., remove K random stops from their routes) and re-optimizes by re-inserting them via a constructive heuristic; ruin-and-recreate is the Schrimpf/Pisinger formulation that alternates destruction and repair to escape local minima.

**Canonical use.** DoorDash's routing solver uses ruin-and-recreate (LNS) with multithreading and a penalty term that scales with route complexity, enabling COVID-era demand spikes to be absorbed without degrading per-delivery quality.

**Production systems.** DoorDash DeepRed (multithreaded ruin-and-recreate), Google OR-Tools (LNS as a built-in metaheuristic), most commercial VRP solvers (Solomon and Pisinger insertion heuristics).

**Alternatives.** Guided local search (penalize features of bad solutions to escape local minima); tabu search (forbid recent moves to drive exploration); simulated annealing (probabilistic uphill moves with cooling schedule).

## Linear Programming and Integer LP (ILP / LP Relaxation)

**Definition.** LP optimizes a linear objective subject to linear constraints over continuous variables — solvable in polynomial time via simplex (combinatorial) or interior-point (polynomial worst-case); ILP restricts variables to integers and is NP-hard, but LP relaxation (drop integrality) gives a dual bound used inside branch-and-bound to prune the integer search tree.

**Canonical use.** DoorDash's DeepRed moved from Hungarian bipartite to a MIP (mixed-integer program) with Gurobi — 10× faster on large instances and supports multi-stop routes; Lyft solves per-batch dispatch as ILP/LP relaxation within a ~30s window.

**Production systems.** Gurobi and CPLEX (commercial, used by DoorDash, Lyft, FedEx for large MIPs), HiGHS and GLPK (open-source LP/MIP solvers), Google OR-Tools (wraps multiple backends).

**Alternatives.** Constraint programming when constraints don't naturally express as linear inequalities (scheduling with precedence); Lagrangian relaxation when a few hard constraints can be priced into the objective.

## Constraint Programming and CP-SAT

**Definition.** Constraint programming models problems as variables, domains, and constraints (alldifferent, cumulative, no-overlap) rather than as linear equations, then uses propagation + backtracking search to find feasible/optimal assignments; CP-SAT combines CP propagation with SAT-style conflict-driven clause learning for hybrid solving.

**Canonical use.** Google OR-Tools CP-SAT is the canonical open-source CP solver and is used heavily at Uber, Lyft, and DoorDash for batching, employee shift scheduling, and routing variants where natural-language constraints map cleanly to CP primitives but awkwardly to ILP.

**Production systems.** Google OR-Tools CP-SAT (won the MiniZinc Challenge multiple times), IBM CP Optimizer (commercial), Choco (Java CP library).

**Alternatives.** MIP via Gurobi/CPLEX when the problem is naturally linear and large (CP-SAT struggles with continuous variables); custom backtracking when the constraint structure is too narrow to benefit from a general solver.

## Dominant Resource Fairness (DRF)

**Definition.** DRF (Ghodsi et al., NSDI 2011) is a multi-resource fair-share algorithm: each tenant's dominant share is the maximum over resource types of their allocated fraction (CPU, memory, GPU); the algorithm allocates incrementally to the tenant with the smallest current dominant share — provably strategy-proof, envy-free, Pareto-efficient, and sharing-incentivizing.

**Canonical use.** Kubernetes (via KAI Scheduler / Volcano), YARN, and Mesos all use DRF for hierarchical multi-tenant fair-share when jobs have different resource profiles (a CPU-bound job and a GPU-bound job shouldn't fight over the same axis).

**Production systems.** Apache Mesos (original DRF reference implementation), Hadoop YARN Fair Scheduler, KAI Scheduler on Kubernetes, Run:ai (commercial DRF for GPU clusters).

**Alternatives.** Weighted fair-share on a single resource (simple but ignores multi-dim trade-offs); proportional sharing (vulnerable to strategic over-claiming, which DRF provably prevents).

## Gang Scheduling

**Definition.** Gang scheduling requires all N tasks of a tightly coupled job (MPI ranks, Spark executors, distributed training workers) to be scheduled simultaneously or none — partial admission deadlocks because already-running tasks hold capacity while waiting for peers that NCCL/MPI collectives can never reach.

**Canonical use.** GPU cluster schedulers gang-schedule distributed training jobs (e.g., a TP=8 job needs all 8 GPUs on one NVLink-connected node atomically); Kubernetes adds gang scheduling via KAI Scheduler, Volcano, or Kueue because the default scheduler places pods one at a time and causes deadlock at fleet scale.

**Production systems.** KAI Scheduler (Run:ai, gang scheduling on K8s), Volcano (CNCF gang scheduler), Kueue (K8s-native queueing with gang semantics), SLURM (HPC-style gang scheduling).

**Alternatives.** Best-effort placement with checkpoint-resume (cheaper for loosely coupled jobs but useless for synchronous collectives); reservation-based scheduling where capacity is pre-allocated to specific job classes (avoids gang complexity at the cost of utilization).

## Bin Packing and Best-Fit-Decreasing

**Definition.** Bin packing assigns items of various sizes to bins minimizing total bin count — NP-hard but with strong approximation heuristics: first-fit-decreasing (FFD) sorts items largest-first and places each in the first bin that fits, best-fit-decreasing (BFD) places each in the tightest-fitting bin; multi-dimensional bin packing (CPU × memory × GPU × network) is the production variant.

**Canonical use.** Kubernetes and Borg score node placements using bin-packing heuristics (most-allocated / least-allocated / balanced-resource-allocation) to consolidate workloads onto fewer nodes; the Tetris paper (SIGCOMM 2014) reports ~30% makespan improvement on production traces using multi-dim bin-packing as the scheduler scoring function.

**Production systems.** Borg/Kubernetes scoring plugins (most-allocated bin-packing), Tetris (research, multi-dim), Aladdin (constraint-solver bin-packing, up to 71% cost savings under SLO constraints).

**Alternatives.** Round-robin placement (simple, ignores consolidation — leaves fragmentation everywhere); load-aware spreading when failure-isolation matters more than utilization (anti-affinity across racks).

## Online vs Offline Algorithms

**Definition.** Offline algorithms see the full input at planning time and optimize globally (e.g., overnight route planning at UPS); online algorithms must commit to each decision as the request arrives without seeing future requests, measured by competitive ratio (worst-case online cost / offline optimum cost).

**Canonical use.** Lyft and DoorDash trade online vs offline by batching: ~30s dispatch windows convert an online stream of ride/order requests into small offline batches solved via ILP/LP relaxation, balancing global match quality against per-request latency anxiety; Instacart's "just-in-time dispatching" defers commitment to the last responsible moment so the per-minute solve sees as much demand as possible.

**Production systems.** UPS ORION (offline next-day planning + online mid-route reopt saves 2-4 more miles/driver), Lyft dispatch (~30s batched window), Instacart (per-minute replan), DoorDash strategic delay (intentionally wait for a better Dasher).

**Alternatives.** Pure greedy online (one-shot decision per request — simple, no batching infrastructure, but Instacart found this adds ~10 min/delivery in dense urban); deferred-decision online with bounded delay (Ferguson-style threshold rules from online algorithms theory).

## Anytime Algorithms

**Definition.** Anytime algorithms produce a valid (possibly suboptimal) solution quickly, then iteratively improve it as more compute time is granted — critical when the application has a hard wall-clock budget but the underlying problem is NP-hard.

**Canonical use.** DoorDash's MIP solver runs per-batch with a wall-clock budget and uses ruin-and-recreate to keep improving the incumbent until the timer fires, then returns the best feasible solution found — never gambling on optimal-or-nothing because dispatch latency is the binding SLO.

**Production systems.** Gurobi and CPLEX (incumbent-tracking with MIP gap reporting), OR-Tools metaheuristics (LNS, guided local search, tabu — all anytime by construction), Monte Carlo Tree Search (anytime planning under stochastic dynamics).

**Alternatives.** Exact branch-and-bound run to completion (correct but unusable when the budget is sub-second); precomputed lookup tables (instant response but inflexible to live state changes).

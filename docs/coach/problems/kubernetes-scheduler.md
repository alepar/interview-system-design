---
slug: kubernetes-scheduler
archetype: infra-primitives
sources:
  borg_paper: research.google.com/pubs/archive/43438.pdf
  mesos_paper: cs.berkeley.edu/~alig/papers/mesos.pdf
  omega_paper: cs.brown.edu/people/malte/pub/papers/2013-eurosys-omega.pdf
  sparrow_paper: sigops.org/s/conferences/sosp/2013/papers/p69-ousterhout.pdf
  drf_paper: people.eecs.berkeley.edu/~matei/papers/2011/nsdi_drf.pdf
---

# Borg / Mesos / Kubernetes scheduler (workload-agnostic cluster scheduling)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic K8s default scheduler design: pods request resources, scheduler watches for unscheduled pods, picks a node via filter + score. Names bin-packing. Discusses node affinity / anti-affinity at category level. Doesn't address gang scheduling, fair-share quotas, scheduler architecture comparison, or fragmentation defragmentation unprompted.
- **Senior (L5/E5):** Names monolithic (K8s default) vs two-level (Mesos) scheduling at category level; articulates the resource-offer model. Identifies gang scheduling as needed for distributed batch (MPI, Spark) — all-N-tasks-at-once or none. Discusses preemption + priority bands at category level. Knows about DRF (Dominant Resource Fairness) as a multi-dimensional fairness algorithm. May or may not surface shared-state OCC (Omega) or decentralized (Sparrow) alternatives.
- **Staff+ (L6/E6+):** Drives proactively. Names the four canonical scheduler architectures with criteria: **monolithic** (Borg, K8s default — global view, scheduler bottlenecks at high churn), **two-level resource-offer** (Mesos — frameworks own their per-task scheduling, central master allocates resource offers; loses global optimality), **shared-state optimistic** (Omega — every scheduler has a read-only replica of cell state, submits placement transactions optimistically with conflict detection; precursor to Kubernetes's design), **decentralized** (Sparrow — stateless schedulers, batch-sampling probes, late binding; ms-scale decisions for sub-second tasks). Quantifies Borg scale: median cell ~10K machines, Borgmaster 5 replicas with Paxos-replicated state; tens of thousands of jobs from thousands of applications; production cells reach 5% best-effort task preemption rate. Quantifies K8s scale: default scheduler ~100 pods/sec end-to-end; scheduler-only bench ~1000 pods/sec; **GKE demonstrated 65,000 nodes in Kubernetes v1.31 with control plane migrated from etcd to Spanner** (up from 15K nodes prior limit). Articulates **gang scheduling** (Sparrow's "batch sampling" / Omega's "scheduling round" / dedicated gang-scheduler plugins like Kueue) — all-or-nothing for tightly-coupled jobs; fragmentation risk; consolidation/preemption to free contiguous capacity. Names **DRF (Dominant Resource Fairness)** explicitly: each user's dominant share = max(allocated_fraction) across resource types; algorithm maximizes the minimum dominant share; provably strategy-proof, envy-free, Pareto-efficient. Names **alloc primitive** (Borg) — reserved resource bundle on a machine persisting across task restarts; supports co-scheduled tasks sharing the same alloc (main + sidecar). Stretch (Sr Staff bar): names **Tetris** (SIGCOMM 2014, multi-dim bin-packing, ~30% makespan improvement); articulates **priority bands with no intra-production preemption** (Borg's design — high-priority preempts lower, production-band tasks never preempt each other to avoid cascades); addresses **fragmentation defragmentation** via consolidation phase that relocates running workloads.

## Canonical decomposition

### Requirements
**Functional:**
- Accept job submissions (services, batch jobs, cron jobs, distributed batch with gang semantics) — no GPU-specific framing
- Allocate resources subject to fairness, capacity, and node-constraint policies (affinity, anti-affinity, taints, gang)
- Bin-pack at the node level to maximize utilization while respecting fault-domain constraints (rack/AZ diversity)
- Preempt lower-priority jobs to admit higher-priority work; cooperative graceful eviction
- Per-tenant fairness with budget caps; hierarchical quota across teams
- Surface scheduling decisions for observability + cost attribution

**Non-functional (with numbers):**
- 10K-65K nodes per cluster (Borg median 10K; GKE 65K with Spanner control plane)
- 100-1000 scheduling decisions/sec sustained
- p99 scheduling latency <1s for typical pods
- 70-85% sustained cluster utilization (higher hurts tail latency due to fragmentation)
- Gang-scheduled jobs: all-K-tasks-allocated within 60s of submission for typical sizes
- Preemption: graceful eviction within 30s of preempt signal (configurable per workload class)
- Fault-domain awareness: rack / AZ / DC diversity per workload's reliability requirement

### Core entities
- **Cluster / Cell:** the set of nodes under one scheduler's control; median ~10K machines (Borg)
- **Node / Machine:** physical or VM resource unit with CPU/memory/disk/other-resource vectors; runs an agent process (Borglet / kubelet)
- **Workload:** Job (set of tasks; Borg) or Deployment/Pod (K8s); declares resource request, priority, fault-domain constraints, gang requirements
- **Scheduler:** the placement decision component; one master replica with backups (Borg/K8s) or N schedulers with shared state (Omega) or distributed stateless (Sparrow)
- **Alloc (Borg):** reserved resource bundle on a machine persisting across task restarts; supports co-scheduled tasks (main + sidecars)
- **Quota:** per-team/per-priority resource limit; admission control rejects over-quota submissions
- **Priority band:** band of priorities within which preemption is allowed (Borg pattern: production preempts batch but not other production)

### API
- `submit(job_spec)` → job_id; spec includes resource_request, priority, gang_size, affinity_constraints, deadline
- `get(job_id)` → status (queued | scheduled | running | preempted | completed | failed)
- `cancel(job_id)` → graceful shutdown, release resources
- `preempt(job_id)` → eviction signal (used by scheduler for higher-priority admission)
- `set_quota(team_id, resource_vector)` → admin update of team-level resource budget
- `cluster_state()` → real-time node inventory, queued jobs, fragmentation metrics

### HLD
The scheduler is the placement decision engine. **Borg's monolithic design**: single Borgmaster (5 replicas, Paxos-replicated state) maintains the global cluster view; one Borglet per machine reports state; Borgmaster picks placements via filter + score (filter = nodes that match resource + constraints; score = bin-packing heuristic + topology + workload-specific scoring). Pros: global view enables optimal placement; cons: scheduler is the bottleneck at high job-submission rates.

**Mesos two-level scheduling**: Mesos master maintains the resource view and offers slices of the cluster to per-framework schedulers (Spark, Hadoop, MPI); each framework decides accept/reject and what to run on the offer. Pros: frameworks can be application-specific; cons: convergence is slow when frameworks are picky (resource offers churn); no global optimality.

**Omega shared-state OCC**: every scheduler has a read-only replica of cell state; submits placement transactions optimistically; conflicts detected on commit; loser retries. Pros: scales to many concurrent schedulers; cons: contention under hot resources; complex to reason about.

**Sparrow decentralized**: stateless schedulers; for each m-task job, probe d×m random workers (batch sampling); task assigned at the moment the worker becomes ready (late binding). Pros: ms-scale decisions, fault-tolerant by construction; cons: limited global view; works best for sub-second tasks where global optimality matters less than fast placement.

**Kubernetes default scheduler**: monolithic-but-pluggable. Filter phase: predicates evaluated per node (resource fit, taints, affinity, anti-affinity, gang group readiness). Score phase: priorities weighted 0-100 (most-allocated / least-allocated / balanced-resource-allocation / pod-topology-spread). Pluggable via scheduler framework — KAI Scheduler / Volcano / Kueue add gang scheduling + hierarchical queues + priority preemption as plugins. Default throughput ~100 pods/s end-to-end; ~1000 pods/s scheduler-only bench. GKE at 65K nodes required moving the control-plane store from etcd to a Spanner-backed store (etcd's 8 GB DB limit was hit by metadata at that scale).

**Gang scheduling**: distributed batch jobs (Spark, MPI, PyTorch DDP) require all N tasks scheduled simultaneously or none. Naive K8s scheduling places pods one at a time → partial admission → deadlock (running pods can't make progress without their peers, scheduled pods consume capacity others need). KAI Scheduler / Volcano / Kueue implement gang scheduling: reserve all N pods atomically; either all start or all stay queued; preemption evicts the whole gang together. **Fragmentation defragmentation**: an 8-pod gang needs 8 contiguous resource units; if free capacity is 7+1+0 across three nodes, the gang can't run despite 8 free units total. Production answer: consolidation phase that preempts cheapest-to-evict job to free contiguous capacity; Tetris-class multi-dim bin-packing as the placement heuristic.

**Fair-share via DRF**: each tenant's dominant share = max over resources of their allocated fraction (e.g., tenant using 30% of CPU + 10% of memory has dominant share 30%); DRF algorithm allocates incrementally to the tenant with the smallest current dominant share. Provably strategy-proof (no incentive to lie about resource needs), envy-free (no tenant prefers another's allocation), Pareto-efficient (no allocation improves one tenant without hurting another), sharing-incentivizing (no tenant gets less than they would alone). Reduces to max-min fairness in single-resource case.

### Deep dives
1. **Gang scheduling, fragmentation, and defragmentation.** A distributed batch job requires N pods scheduled simultaneously; if scheduled one at a time, partial admission causes the already-scheduled pods to consume capacity while waiting for their peers, blocking progress. NCCL/MPI collectives hang waiting for missing ranks. Gang scheduling protocol: client submits a "scheduling group" with N pods + atomic-or-nothing semantics; scheduler reserves N units atomically (filter phase succeeds for all N or fails); on success, all start together; on failure, all stay queued. Fragmentation: even with N total free units, they may not be contiguous (8-pod gang needs 8 on one node, or 4+4 on two nodes, depending on the gang's communication topology). Production answer: **consolidation phase** — periodically (every few minutes) the scheduler considers preempting + relocating running workloads to defragment; cheapest-to-evict (most recently started, lowest priority, smallest resource footprint) is evicted to free contiguous capacity. **Tetris** (Grandl et al., SIGCOMM 2014) is the published multi-dim bin-packing heuristic; ~30% makespan improvement on production traces. KAI Scheduler / Volcano are the K8s-native implementations. Staff+ commit: gang-scheduling primitive, fragmentation measurement, defragmentation trigger criteria.

2. **Preemption, priority bands, and the "no intra-band preemption" rule.** Higher-priority work can preempt lower-priority; lower-priority workloads must be designed to checkpoint and resume. Naive priority preemption causes cascades: A preempts B; B's restart preempts C; C's restart preempts D — unbounded chain destabilizing the cluster. **Borg's published rule**: priority **bands** (production / batch / best-effort), preemption only across bands. Production-band tasks never preempt each other — within band, scheduling is best-effort waiting for resources. Cross-band: production tasks preempt batch; batch preempts best-effort. Borg's published preemption rate: ~5% of MapReduce tasks preempted under best-effort. Cost of preemption is the workload's responsibility: preempted task's state-checkpoint frequency × preemption rate = expected wasted work; choose checkpoint cadence accordingly. Staff+ commit: priority-band design, preemption rate budget, cooperative graceful eviction protocol (preempt signal → workload checkpoints + exits → spare slot freed).

3. **DRF (Dominant Resource Fairness) for multi-dim fair-share.** Single-resource fair-share is well-defined: max-min fairness. Multi-resource (CPU + memory + GPU + network) requires choosing a fairness metric. DRF (Ghodsi et al., NSDI 2011): each user's **dominant share** = max over resources of (user's allocation / total available); the algorithm allocates incrementally to the user with the smallest current dominant share. Properties: **strategy-proof** (no incentive to over-claim — over-claiming raises your dominant share, reducing your priority for next allocation); **envy-free** (no user prefers another's allocation since the smallest-dominant-share user always gets the next allocation); **Pareto-efficient** (no allocation improves one user without reducing another); **sharing-incentivizing** (combining two users' resources never gives them less than they'd get separately). Used in Mesos, YARN, KAI Scheduler. Reduces to max-min in single-resource case. Staff+ commit: name DRF explicitly, articulate its strategy-proof property (the headline reason DRF wins over naive proportional sharing), address hierarchical DRF (team-level → user-within-team) for organizational fairness.

## Known failure modes
1. **Scheduling latency spike under churn.** High-churn workload (many short-lived pods) overwhelms the scheduler; pending queue grows; p99 scheduling latency goes from sub-second to minutes. Production answer: batched scheduling cycles (decide for 1000 pending pods in one optimization pass, not 1000 separate decisions); scheduler partitioning (multiple scheduler instances each handling a subset of pods); sharded admission queues per workload class. GKE's 65K-node cluster moved the control plane from etcd to Spanner to handle the metadata write rate alone.

2. **Quota starvation under priority preemption.** High-priority team's quota grows; their workloads preempt lower-priority teams; lower-priority teams are starved despite holding quota. Production answer: **reservation guarantees** (per-team min-guaranteed capacity that can't be preempted away) layered on top of priority preemption; over-quota burst capacity is the additional resources available beyond reservation; gang-aware preemption that respects priorities + reservations together.

3. **Stale node-state in scheduler cache.** Scheduler's cached view of node state is N seconds behind reality; scheduler places a pod on a node that's actually failed or out of capacity → pod fails → scheduler retries. Production answer: short cache TTL (sub-second for hot decisions) + reconciliation (kubelet reports back; scheduler corrects state); for K8s, this is the leader-elected scheduler + informer cache architecture.

## Notes for the coach
- **This is asked-confirmed at OpenAI** per Exponent OpenAI guide (phone-screen variant: "Implement a GPU credit calculator" as a coding warm-up that anticipates the system-design follow-up); confirmed at Hello Interview tagged "Apache Airflow + multiple companies." Plausibly-asked at Google (Borg-adjacent teams), Meta (Twine/Tupperware historical), and most large-infra companies.
- **Distinguished sharply from `gpu-cluster-scheduler` (AI-infra catalog) by the workload mix.** Coach announces up front: "no GPU specifics — this is the generic primitive that handles services + batch + cron uniformly." If the candidate drifts into GPU scheduling, redirect: "that's the GPU scheduler problem; let's stay on the workload-agnostic primitive shape."
- **The four-architecture taxonomy (monolithic / two-level / shared-state / decentralized) is the Staff+ unlock.** A candidate who only knows the K8s default is at Senior; the Staff+ candidate can name and compare all four with criteria.
- **GKE 15K → 65K nodes via etcd → Spanner migration is the 2024 modern-scale anchor.** Citing it grounds the scaling-ceiling discussion concretely.
- **DRF is the multi-resource fairness signal.** Most candidates default to "round-robin" or "weighted fair-share"; the Staff+ candidate names DRF explicitly with the strategy-proof property.
- **Tetris + bin-packing math is the L7 differentiation flex.** A candidate who articulates multi-dim bin-packing with the ~30% makespan improvement number demonstrates literacy with the SIGCOMM 2014 paper.
- **Cross-coverage with AI-infra `gpu-cluster-scheduler`:** the AI version adds gang scheduling × topology awareness (NVLink/IB) × heterogeneous GPU types × MIG slicing × checkpoint-aware preemption. Run the generic primitive first; AI version is the depth-cut after.

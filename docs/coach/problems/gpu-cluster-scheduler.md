---
slug: gpu-cluster-scheduler
archetype: ai-infrastructure
sources:
  igotanoffer_openai: igotanoffer.com (OpenAI prompt: "Design a GPU scheduling system to allocate compute resources across competing workloads at scale"; phone-screen variant: "Implement a GPU credit calculator")
  heteroscale: arxiv.org/abs/2508.19559
  kai_scheduler_runai: docs.ray.io/en/latest/cluster/kubernetes/k8s-ecosystem/kai-scheduler.html
  lyra_eurosys: https://dl.acm.org/doi/10.1145/3552326.3587445
---

# GPU cluster scheduler (heterogeneous fleet, training + inference)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic K8s + nvidia-device-plugin design: pods request `nvidia.com/gpu: 1`, default-scheduler bin-packs across nodes, autoscaler adds nodes when pending pods accumulate. Recognizes that training and inference are different workloads but doesn't articulate why a single scheduler must handle both. Doesn't name gang scheduling, topology awareness, or preemption unprompted.
- **Senior (L5/E5):** Names gang scheduling as the requirement for distributed training ("all 8 GPUs at once or none"); articulates topology awareness (NVLink within node, InfiniBand / RoCE across); identifies preemption as the lever for training↔inference borrowing. Discusses heterogeneous fleet (H100, A100, H20, L40S) and the bin-packing implications (an 8-GPU job might fit only on specific node types). Names KAI Scheduler / Run:ai / Volcano / Kueue as off-the-shelf options or SLURM for HPC-style. Handles autoscaling signals (queue depth, TTFT, batch fill rate) at fleet level.
- **Staff+ (L6/E6+):** Drives the session proactively. Quantifies the fleet: tens of thousands of GPUs (xAI Colossus 100K→200K H100s; HeteroScale tens of thousands), GPU-hours as the primary cost unit. Names the four-axis design: gang scheduling × topology awareness × preemption × heterogeneous bin-packing. Articulates per-tenant fairness (DRF weighted by GPU class, not raw count) and per-tier service classes (training jobs preemptible by online inference; batch inference preemptible by interactive). Names Lyra-style elastic borrowing (online inference borrows idle training GPUs, releases within ~5 min on demand spike). Surfaces fragmentation as a first-class concern (8-GPU job can't pack into 7+1+0 free GPUs across hosts; defrag-via-preemption is the answer with explicit cost-of-eviction math). Discusses fractional-GPU allocation (MIG partitions on H100, time-slicing on older GPUs) for low-utilization workloads. Stretch (Sr Staff bar): mentions GPU credit accounting per tenant with reservation vs spot economics; reservation system for hot-swap to new model launches; cost-aware scheduling under publisher-price (spot reclaim) constraints.

## Canonical decomposition

### Requirements
**Functional:**
- Accept job submissions (training, fine-tuning, batch inference, online inference)
- Per-job declaration of GPU count, GPU class (H100/A100/etc), topology constraints (NVLink/IB), gang-scheduling requirement, priority, optional deadline
- Allocate GPUs subject to fairness, capacity, and topology constraints
- Preempt lower-priority jobs to admit higher-priority work
- Surface GPU usage per tenant for cost attribution
- Support elastic scaling (online inference fleet shrinks/grows continuously)

**Non-functional (with numbers):**
- 10K-200K GPUs total fleet (xAI Colossus: 100K H100s online Sep 2024, 200K by Feb 2025)
- Heterogeneous: 5-10 GPU classes (H100 SXM/PCIe, A100, H20, L40S, V100 legacy)
- Gang scheduling latency: <60s from job submission to all-K-GPUs allocated for typical jobs
- Preemption latency: <5 min from preempt signal to preempted job's GPUs released (Lyra-class)
- Utilization target: 70-85% sustained GPU-utilization across fleet (HeteroScale reports 26.6pp utilization improvement)
- Per-job placement constraints: TP shards on NVLink; PP shards within rack; DP shards within DC
- Per-tenant fairness with budget caps; spot/reserved/on-demand tier economics

### Core entities
- **Job:** job_id, tenant_id, job_class (train | finetune | inference_online | inference_batch), gpu_count, gpu_class_pref, topology_constraint, priority, deadline, preemptible (bool)
- **Allocation:** allocation_id, job_id, node_set (host_id, gpu_local_id, mig_partition?), start_ts, expected_duration
- **Node:** node_id, gpu_class, gpu_count, mig_capability, rack_id, switch_id, current_allocations
- **Tenant:** tenant_id, gpu_hour_budget, reserved_capacity (per gpu_class), spot_eligible (bool), priority_tier
- **Topology:** rack→switch→DC hierarchy; intra-node NVLink bandwidth; inter-node IB/RoCE bandwidth

### API
- `POST /v1/jobs` body={tenant, gpu_count, gpu_class_pref, topology_constraint, priority, gang, preemptible} → {job_id, status: queued | scheduled | running}
- `GET /v1/jobs/:id` → {status, allocation, predicted_start_ts}
- `POST /v1/jobs/:id/preempt` → eviction signal (used by higher-priority admission path)
- `DELETE /v1/jobs/:id` → cancel, release GPUs
- `GET /v1/tenants/:id/usage` → GPU-hours consumed by class, budget remaining
- `GET /v1/fleet` → real-time inventory (free GPUs by class, queued jobs, fragmentation %)

### HLD
The scheduler is a stateful **controller** running consensus (Raft / etcd) for high availability. Job submissions enter an **admission queue** (per-priority-tier subqueue with weighted fair share). The **scheduling loop** runs every few hundred ms: for each pending job, the scheduler evaluates candidate placements by filtering nodes (gpu_class match, free slot count, topology constraint) and scoring (bin-pack to consolidate fragmentation, prefer same-rack for IB-sensitive jobs). For gang-scheduled jobs, the scheduler requires all-K-GPUs simultaneously available; if not, it can either wait or trigger preemption of lower-priority jobs to free the needed capacity. Topology-aware placement uses a **topology service** that maintains the rack/switch/DC graph and bandwidth metadata, exposed to the scheduler as a constraint solver input. The **preemption engine** sends graceful-preempt signals (workloads checkpoint and release) with a hard timeout for non-cooperative jobs. The **autoscaler** monitors queue depth + per-class GPU shortage and triggers cloud-provider scale-out for spot/on-demand capacity. The **accounting service** consumes the allocation event stream (Kafka) and writes per-tenant GPU-hour usage to a metering store with sub-minute precision for billing. The **fleet observer** continuously tracks GPU health (DCGM metrics), straggler detection (GPU >2× slower than peers on the same job), and ejects bad nodes from the schedulable pool.

### Deep dives
1. **Gang scheduling + topology-aware placement.** A distributed training job requires all-N-GPUs simultaneously — partial allocation is useless (NCCL collectives hang waiting for missing ranks). The scheduler must reserve all N atomically: either succeed and start, or release the reservation and wait. Default Kubernetes scheduler doesn't do this — partial admission leads to deadlock when multiple gang jobs compete. KAI Scheduler (Run:ai), Volcano, and Kueue add gang scheduling primitives. Topology awareness goes further: a TP=8 job wants all 8 GPUs on one node (NVLink, ~600 GB/s); a PP=16 job is fine with 2 nodes (IB, ~400 Gbps); a DP=128 job spans racks but is bandwidth-tolerant. The scheduler must filter nodes by topology fit AND bin-pack to consolidate. MegaScale's rail-optimized Clos fabric (8× 200G NICs per server, Broadcom Tomahawk 4 switches) is the target topology — the scheduler must understand which physical NICs connect to which switches and avoid placements that polarize the ECMP hash. Staff+ commit: topology graph representation, placement-scoring function, gang-admission protocol (two-phase: reserve all → confirm all → start, with rollback on partial failure).

2. **Preemption + elastic borrowing (training↔inference).** Online inference demand is bursty and time-varying; training demand is steady. Lyra (EuroSys 2023) demonstrated that online inference can borrow idle training GPUs and release them within ~5 minutes on demand spike, recovering most utilization slack without violating training SLOs. The design: training jobs declare `preemptible=true` with a checkpoint cadence (e.g., every 10 min); inference autoscaler can request "borrow N GPUs from training" → scheduler sends preempt signals to the lowest-priority/most-recently-checkpointed training jobs → they checkpoint and release within the SLO window → inference admission succeeds. When inference demand subsides, training jobs are re-admitted and resume from their checkpoint. Cost model: training pays "preemption insurance" (priority lower than inference); inference pays "burst-capacity premium" (vs holding dedicated capacity). HeteroScale (ByteDance) reports 26.6pp utilization gain on tens of thousands of GPUs via coordinated single-metric autoscaling. Staff+ commit: preemption SLO budget, checkpoint cadence to bound rework cost, priority hierarchy, anti-thrashing logic (don't preempt-then-restore on a 30s spike).

3. **Fragmentation defragmentation under heterogeneous fleet.** An 8-GPU TP=8 job needs all 8 on one node. If the cluster has 7+1+0 free across three nodes, the job can't run despite having 8 total free GPUs. This is the fragmentation problem at scale, made worse by heterogeneous classes (an H100 slot can't be filled by an A100 job, etc). Two production answers: (a) **defrag preemption** — find the cheapest-to-evict job whose eviction would free a single-node 8-GPU slot (e.g., move a 4-GPU PP=4 job to a different node, freeing the original 4 GPUs to combine with the existing 4 free); (b) **bin-packing optimizer** — periodically run a global optimization (Aladdin paper reports up to 71% cost savings via constraint-solver bin-packing under SLO constraints). Trade-off: defrag preemption is fast but disruptive; global re-bin is comprehensive but expensive (and itself a preemption event for all moved jobs). For fractional-GPU workloads (online inference at <100% per-GPU utilization), MIG partitions on H100 split one physical GPU into multiple isolated slices, reducing fragmentation at the cost of inter-slice isolation overhead. Staff+ commit: fragmentation metric (cluster-wide, per-class), threshold to trigger defrag, eviction-cost function, MIG vs time-slicing decision per workload class.

## Known failure modes
1. **Cascading preemption storm under high contention.** A high-priority job arrives, preempts a medium-priority job; the medium job, on restart, gets re-admitted but preempts a low-priority job, which on restart preempts another low-priority job. Production answer: per-job preemption budget (job can't be preempted more than N times in M minutes), preemption-cost-aware admission (consider total work-loss across the chain, not just the immediate eviction), priority-banded scheduling (jobs at the same priority don't preempt each other). Anti-pattern: unbounded preemption with no backoff — leads to no-job-makes-progress storms during cluster pressure.

2. **Straggler GPU silently slowing entire 10K-GPU training job.** A single bad GPU running at 50% throughput stalls the whole NCCL collective at every step; the rest of the cluster waits. Production answer: continuous straggler detection at fleet observer (per-GPU iteration time vs same-job p50; >2× slower triggers quarantine), automatic ejection from the schedulable pool, hot-spare swap from a pre-warmed pool. MegaScale's published number: 0.5% of GPUs at any time exhibit substantially slower performance (~60 stragglers in a 12K-GPU job). Without ejection, those 60 silently set the pace for the other 12,228.

3. **Scheduler control-plane saturation at 100K+ GPUs.** The default K8s scheduler can handle ~5K pods/sec; at 100K-GPU scale with frequent reschedules (preemption + autoscale + training stage transitions), the scheduler itself becomes the bottleneck. Production answer: hierarchical scheduling (global scheduler dispatches to per-cell schedulers each handling ~10K GPUs), sharded admission queues per tenant or per workload class, batched scheduling decisions (decide for 1000 pending jobs in one optimization pass, not 1000 separate decisions). xAI Colossus at 200K GPUs almost certainly runs sharded scheduling — no single Kubernetes control plane scales that far.

## Notes for the coach
- **This is the confirmed OpenAI Staff system-design prompt** per IGotAnOffer: "Design a GPU scheduling system to allocate compute resources across competing workloads at scale." The phone-screen variant — "Implement a GPU credit calculator" — is a coding warm-up that anticipates the system-design follow-up. Anthropic likely asks variants too (frequently cited as a "GPU cluster" category in prep guides).
- **The four-axis framing (gang × topology × preemption × heterogeneous) is the Staff+ unlock.** A candidate who hits all four in HLD without prompting is at Staff bar; one who needs to be walked into each axis is at Senior. Don't volunteer the framing — let the candidate surface what they remember.
- **Training-inference convergence is the modern story.** In 2024-2025, training and inference were separate clusters at most labs; in 2026, the integrated cluster with elastic borrowing (Lyra-class) is the cost-optimal design. A candidate who proposes "just have two clusters" is missing the 2026 trend.
- **Scale numbers matter.** xAI Colossus (100K → 200K H100s), Anthropic's >1M Trainium2 + 1M TPU commitments, OpenAI's published training-stack details — these anchor what "frontier scale" means. A candidate sizing the design for 1K GPUs is solving a different problem.
- **Cost reasoning is the safety bar.** GPU-hours at frontier scale = hundreds of millions of dollars per year. A design that doesn't surface per-tenant cost attribution + reservation vs spot economics is missing the production-grade architecture pressure. Surface as a category-level gap if not addressed.

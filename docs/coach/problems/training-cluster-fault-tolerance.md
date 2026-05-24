---
slug: training-cluster-fault-tolerance
archetype: ai-infrastructure
sources:
  llama_3_paper: ar5iv.labs.arxiv.org/html/2407.21783
  megascale_paper: arxiv.org/abs/2402.15627
  pytorch_async_ckpt: pytorch.org/blog/reducing-checkpointing-times/
  sdc_paper: arxiv.org/abs/2502.12340
---

# Training cluster fault tolerance (10K+ GPU operations platform)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic checkpoint-and-restart design: every N minutes, all ranks dump state to a shared filesystem; on failure, restart the entire job from the latest checkpoint. Recognizes that GPUs fail. Doesn't size the failure budget, doesn't articulate NCCL-specific failure modes or async checkpointing.
- **Senior (L5/E5):** Names asynchronous checkpointing (decouple write latency from training-step time) and explains why synchronous checkpoint at 10K-GPU scale is operationally untenable. Articulates NCCL/RoCE-specific failure modes (collectives hang, watchdog timeout on the wrong rank). Discusses straggler detection (one slow GPU stalls the whole pipeline). Identifies hot-spare provisioning for fast restart. Knows about gang scheduling for restart.
- **Staff+ (L6/E6+):** Drives the session proactively. Sizes the failure budget from Llama 3 numbers (419 unexpected interruptions in 54 days on 16,384 H100s = ~1 every 3 hours; per-failure recovery budget = total downtime budget / failure count) and shows the math reverse-engineering required checkpoint cadence. Names MegaScale's two-stage async checkpoint (GPU → host memory blocking ~seconds, then host → distributed FS asynchronously) and PyTorch async DCP (148.8s → 6.3s blocking time, 23.6× faster). Quantifies straggler prevalence (~0.5% of GPUs at any time, ~60 stragglers in a 12K-GPU job per MegaScale; the rest of the cluster waits for them). Names silent data corruption (Google reports SDC every "week or two", Meta saw 6 in 54 days of Llama 3 training) and the defense (deterministic replay + cross-replica gradient compare + per-host canary computations). Network topology: rail-optimized Clos, RoCE with Enhanced-ECMP, NCCL Flight Recorder for hang diagnosis. Stretch (Sr Staff bar): cross-fabric portability (training stack runs on H100 + TPU + Trainium without rewrite — Anthropic's multi-fabric reality forces this).

## Canonical decomposition

### Requirements
**Functional:**
- Run a frontier-class training job on 10K+ GPU cluster for 50-60 days
- Detect and recover from hardware failures, network failures, software bugs, silent data corruption
- Maintain >90% effective training time despite ~1 failure every 3 hours
- Automated recovery without manual intervention (Llama 3: only 3 manual interventions in 54 days)
- Per-rank observability for diagnostics (gradient norms, throughput, NCCL state)
- Cross-fabric compatibility (H100 + TPU + Trainium — Anthropic + Google + AWS partnerships)

**Non-functional (with numbers):**
- 16,384 GPUs (Llama 3 baseline) up to 100K+ (xAI Colossus); ByteDance MegaScale at 12,288 GPUs reports 55.2% MFU
- Failure rate: 419 unexpected interruptions / 54 days = ~1 every 3 hours
- Failure breakdown (Llama 3): 58.7% GPU-related, 17.2% HBM3 memory, 12.9% software, 8.4% network
- Fault detection latency <10 min (MegaScale target); recovery to latest checkpoint within 15 min
- Effective training time >90% (Llama 3 achieved); manual intervention <1% of incidents
- Async checkpoint blocking time: <10 seconds per checkpoint (PyTorch DCP: 6.3s on a 7B model)
- Straggler detection: >1s lag vs job median triggers quarantine (~0.5% of GPUs at any time)
- SDC defense: cross-replica gradient verification at configurable cadence

### Core entities
- **Job:** job_id, model_arch, parallelism (TP/PP/DP/CP degrees), gpu_count, expected_duration
- **Rank:** rank_id, gpu_id, host_id, role (data | tensor | pipeline | context), health_status
- **Checkpoint:** ckpt_id, job_id, iteration, sharded_files (per-rank), parent_ckpt, ts, integrity_hash
- **FailureEvent:** event_id, job_id, failed_rank_id, failure_type (gpu_hw | hbm | software | network | sdc), detection_latency_ms, recovery_action
- **HotSpare:** spare_id, gpu_class, host_id, status (idle | warming | swapping)

### API (operations control plane)
- `POST /v1/jobs` body={parallelism, gpu_count, gpu_class, ckpt_cadence_min} → {job_id}
- `GET /v1/jobs/:id` → {status, current_iteration, effective_training_time_pct, recent_failures}
- `POST /v1/jobs/:id/ckpt` → manual checkpoint trigger
- `POST /v1/jobs/:id/replay` body={from_ckpt, ranks} → deterministic replay for SDC investigation
- `GET /v1/fleet/health` → real-time per-rank health (NCCL state, throughput, gradient norms, anomalies)

### HLD
The job orchestrator is a stateful controller running gang-scheduled training jobs (see `gpu-cluster-scheduler`). The **fault detection layer** runs continuously per rank: per-rank health pings to a centralized **fleet observer** (PyTorch NCCL Flight Recorder captures collective metadata + stack traces, MegaScale full-stack observability tracks throughput vs job median to identify stragglers). The **NCCL watchdog** fires at 180s default but on the *wrong* rank (the one that didn't enter the collective, not the stalled rank); diagnostic tooling correlates with the fleet observer's per-rank trace to identify the actual culprit. **Async checkpointing** (MegaScale two-stage): GPU dumps state to host memory in ~seconds (blocking the training step), then a background process flushes host → distributed FS asynchronously without blocking. PyTorch async DCP cuts the blocking time 23.6× (148.8s → 6.3s on a 7B model). Checkpoints are sharded per-rank for fast restore; topology-agnostic format supports restart at different parallelism degrees. **Hot-spare pool** (~5% of fleet) is pre-warmed; on failure detection, the **recovery controller** quarantines the bad node, swaps in a hot spare via gang re-schedule, restores from latest checkpoint. **SDC defense**: periodic deterministic replay on canary workloads detects bit-divergence across nodes; gradient-norm anomaly detection flags suspicious values; cross-replica gradient comparison validates correctness. **Cross-fabric layer** (Anthropic context): training stack uses JAX/XLA + sharding annotations (GSPMD-class) so the same model runs on H100, TPU, Trainium without per-fabric rewrite.

### Deep dives
1. **Async two-stage checkpointing.** Synchronous checkpoint at 10K-GPU scale: each rank writes ~hundreds of GB to distributed FS, simultaneously, blocking all training. Storage system saturates, training pauses for minutes per checkpoint. MegaScale's two-stage pattern: stage 1 — GPU writes to host memory (RAM, ~seconds, blocking the training step but only briefly); stage 2 — background process asynchronously transfers host → distributed FS without blocking. PyTorch async DCP implements this: blocking time drops from 148.8s to 6.3s on a 7B model (23.6× faster). Result: you can checkpoint more often without paying the throughput hit, which reduces work-loss-per-failure. Trade-off: host RAM is the in-flight buffer (must size accordingly); brief vulnerability window between stage 1 and stage 2 (if host crashes between, lose the checkpoint). Staff+ commit: checkpoint cadence (math: cadence × failure_rate = expected work-loss; target work-loss as % of total runtime), shard layout (per-rank vs consolidated), topology-agnostic format for restart-at-different-parallelism, blob-store throughput math (10K ranks × hundreds of GB / async window).

2. **Fault detection and root-cause attribution under NCCL hangs.** NCCL watchdog timeout (180s default) fires on the rank that didn't enter the collective, not the actually-stalled rank — debugging takes hours without proper tooling. Production stack: PyTorch NCCL Flight Recorder captures collective metadata + stack traces on every rank continuously; on hang detection, the recorder dumps to centralized storage and the diagnostic correlator identifies which rank actually stalled (and why — slow GPU, network flap, OOM, etc). Optical link flaps last several seconds — long enough to trigger NCCL timeouts but short enough to evade most monitoring (MegaScale's named failure mode). Automated remediation: known patterns (slow GPU >2× lag, NCCL deadlock signature, link flap) trigger node quarantine + hot-spare swap without human intervention. Llama 3 published 3 manual interventions in 54 days — that's the bar. Staff+ commit: per-rank tracing cadence, hang-detection signature library, quarantine criteria, manual-intervention threshold.

3. **Silent data corruption (SDC) defense.** Bad hardware produces silently wrong outputs without crashing — gradients are mathematically valid but contaminated, training slowly diverges over many steps. Google reports SDC every "week or two" across their fleet; Meta reported 6 SDCs in one 54-day Llama 3 run. Defenses: (a) **deterministic replay** — re-run a recent step on a different rank and compare outputs bit-for-bit (Google's published approach); (b) **cross-replica gradient comparison** — DP replicas should produce identical gradients on identical batches; divergence beyond floating-point tolerance signals SDC; (c) **per-host canary computations** — periodic small known-answer computation on every GPU, output compared to a reference (catches HBM degradation early); (d) **ATTNChecker (arXiv 2410.11720)** — ABFT (algorithm-based fault tolerance) for attention with ~7% overhead, catches all extreme errors. Loss-curve anomaly detection is the last-resort signal (detects SDC after it's already polluted gradients). Staff+ commit: which defense at which cadence, false-positive vs false-negative trade-off, rollback procedure when SDC detected (which checkpoint to restore from).

## Known failure modes
1. **Cascading NCCL hang on a slow rank.** One rank running at 50% throughput stalls the collective at every step; default 180s watchdog fires on a different (innocent) rank; debugging takes hours. Production answer: continuous per-rank throughput tracking with median-relative threshold (>1s lag triggers quarantine attention), NCCL Flight Recorder dumps for forensic correlation, automated slow-rank ejection within minutes. MegaScale's published 0.5% straggler rate means ~50 ranks at any time in a 10K-GPU job are slow — without ejection, those 50 silently set the pace.

2. **Checkpoint write storm saturating network/storage.** 10K ranks writing simultaneously to a shared filesystem saturates network and storage tiers; checkpoint takes minutes instead of seconds. Production answer: staged checkpoint (host memory buffer + asynchronous background flush), hierarchical filesystem with per-rack aggregation tier, throttled upload rate per rack, dedicated checkpoint storage class (separate from training-data-read storage to avoid contention). MegaScale reports 100+ recovery events in a multi-week run while sustaining >90% effective training time — only possible with non-blocking checkpoint design.

3. **SDC poisoning gradients silently for hours.** Bad GPU produces wrong gradients that DP-aggregation accepts because they're within statistical noise of true gradients. Loss diverges 10+ hours later, by which point many checkpoints contain polluted weights. Production answer: cross-replica gradient comparison at every step or periodic step (cheap if same-batch DP replicas already exist), bit-exact deterministic training (carefully controlled randomness), rollback procedure to the last checkpoint that passed verification (which may be hours ago — accepting that cost is the SDC-defense price). Per-host canary computations catch the bad hardware before it corrupts anything; eject the host on canary mismatch.

## Notes for the coach
- **This is plausibly-asked at Anthropic** (the "GPU cluster" question framing); the Llama 3 paper + MegaScale paper + Anthropic's public Trainium2 / TPU commitments are the primary-source anchors. A candidate who cites the Llama 3 numbers (419 failures / 54 days / 16K H100s) demonstrates frontier-scale literacy.
- **The failure-budget math is the Sr Staff unlock.** Most candidates pick a checkpoint cadence arbitrarily ("every hour"). The Sr Staff candidate works backward: failure rate × per-failure-lost-time = total work-loss; pick cadence to bound work-loss to a target %. This is back-of-envelope work that demonstrates the candidate has actually thought about operational economics.
- **SDC is the depth probe that most candidates miss.** Generic distributed-systems intuition ("we have replicas") doesn't handle SDC — replicas produce wrong-but-internally-consistent gradients. The candidate who names SDC unprompted and reaches for deterministic replay or cross-replica comparison is at L6+ bar.
- **Cross-fabric portability is the Anthropic-specific Sr Staff differentiator.** Anthropic publicly committed to >1M Trainium2 + 1M TPU + GPU partnerships — running the same training stack across all three requires JAX/XLA + sharding annotations (GSPMD/Pathways) not framework-specific code. Mention this if the candidate is targeting Anthropic specifically.

---
slug: multi-tenant-lora-serving
archetype: ai-infrastructure
sources:
  s_lora: arxiv.org/abs/2311.03285
  punica: arxiv.org/abs/2310.18547
  vllm_lora_docs: docs.vllm.ai/en/latest/features/lora/
  dlora_osdi24: usenix.org/system/files/osdi24-wu.pdf
---

# Multi-tenant LoRA serving (thousands of adapters on shared base model)

## Bar anchors
- **Mid-level (L4/E4):** Per-tenant dedicated pod (one model + one LoRA per pod). Doesn't recognize that adapters are small enough to share GPU memory with the base model.
- **Senior (L5/E5):** Names LoRA adapters as small per-tenant deltas (MBs not GBs) that can share a base model. Discusses adapter loading on demand. May know about SGMV-class batched kernels at category level.
- **Staff+ (L6/E6+):** Drives proactively. Names S-LoRA Unified Paging (base + adapter weights + KV cache in one memory pool) and Punica SGMV kernel (12× throughput, +2ms latency per token via batched-with-different-adapters CUDA kernel). Cites S-LoRA benchmark: 2000+ concurrent adapters at ~7 req/s constant throughput vs vLLM packed which OOMs above a few. Articulates adapter storage hierarchy: GPU HBM (hot) → CPU DRAM (warm) → object storage (cold). Discusses dLoRA (OSDI 2024) and MixLoRA for rank-grouped batching. Cold-start mitigation via adapter prefetch on tenant traffic prediction. Per-tenant pinned budget + LRU above the budget to prevent hot tenant's adapter eviction by cold-tenant burst. Stretch (Sr Staff bar): security around dynamic adapter loading (vLLM warns: untrusted adapter weights are a real risk in multi-tenant settings); per-adapter content-hash verification at load; per-adapter eval canary to detect quality regression from corrupted adapter blob.

## Canonical decomposition

### Requirements
**Functional:**
- Serve thousands of per-tenant LoRA-fine-tuned variants of a shared base model
- Per-tenant adapter upload, activation, deactivation
- Mixed-rank serving (different tenants train at different LoRA ranks: r=8, r=16, r=64)
- Per-tenant isolation (one tenant's adapter cannot affect another's inference)
- Cold-start tolerance: first request to a never-seen adapter pays load cost; subsequent requests are warm

**Non-functional (with numbers):**
- 1000-10,000+ adapters per cluster (S-LoRA target)
- Per-adapter size: 10-100 MB (vs base model 14-140 GB at FP16)
- Throughput: ~7 req/s at constant throughput with 2000+ concurrent (S-LoRA on 16× L40S)
- TTFT reduction: up to 86% vs naive serverless LLM inference (S-LoRA published)
- GPU utilization: 40% → 75% under bursty load (S-LoRA)
- Cold-load latency: 100-500ms for first-time adapter load from object storage to GPU

### Core entities
- **Adapter:** adapter_id, tenant_id, base_model_id, rank, content_hash, storage_uri, status (active | idle | cold)
- **AdapterCache:** per-pod GPU HBM cache of active adapters; per-pod CPU DRAM warm tier; shared object-storage cold tier
- **BatchSlot:** request_id, adapter_id, base_model_segment, kv_blocks
- **MemoryPool:** unified paging across base_weights + adapter_weights + kv_cache (S-LoRA pattern)

### API
- `POST /v1/adapters` body={tenant_id, base_model, rank, weights_url} → {adapter_id, status: uploading}
- `POST /v1/adapters/:id/activate` → load to warm tier, ready for inference
- `DELETE /v1/adapters/:id` → remove from cache + storage
- `POST /v1/completions` body={model: "base@adapter_id", ...} → standard completions API with adapter selected

### HLD
The serving pool runs the **base model** loaded once per pod (e.g., Llama-3-70B at 140GB FP16 across 8 GPUs with TP=8). The **Unified Paging memory manager** (S-LoRA pattern) treats GPU HBM as a single pool shared by base model weights (mostly static, but mutable for swap if needed), active LoRA adapter weights (10-100 MB each, hot tier), and KV cache (per-request, varies with sequence length). Block-level allocation eliminates fragmentation across the three categories. The **batched-with-different-adapters kernel** is SGMV (Segmented Gather Matrix-Vector) — the named primitive that lets one GPU invocation process a batch of requests targeting different adapters in a single kernel launch (Punica reports 12× throughput with +2ms per token). Without SGMV (or equivalent), adapter swaps serialize and you lose continuous batching. The **adapter storage tier**: hot (GPU HBM, ms access), warm (CPU DRAM, ~10ms), cold (object storage, ~100-500ms first load). LRU eviction across tiers; per-tenant pinned budget guarantees minimum capacity (e.g., 1 hot slot reserved per premium tenant). **Adapter loading pipeline**: tenant uploads via `/v1/adapters` → content-hash verification → security scan → write to object storage → optional pre-warm to CPU DRAM. On first inference request, adapter is fetched from cold → CPU → GPU; subsequent requests are warm. **Mixed-rank batching** (dLoRA / MixLoRA pattern): adapters at different LoRA ranks (r=8, r=16, r=64) batched together via rank-grouped CUDA streams or via per-rank-batch grouping in the scheduler.

### Deep dives
1. **Unified Paging for base + adapter + KV cache.** Naive: separate memory regions for base weights (mostly static), adapter weights (dynamic, per-request), KV cache (per-request). Result: 60-80% fragmentation when adapter and KV allocations don't align with fixed-size regions. S-LoRA's Unified Paging: single GPU memory pool, block-based allocation (PagedAttention-style), all three categories allocate from the same pool. Result: eliminates fragmentation, enables serving 2000+ concurrent adapters at near-constant throughput. Trade-off: more bookkeeping per allocation, slightly higher CPU overhead. Staff+ commit: block size, eviction policy across the three tiers (base weights pinned, adapters LRU within tenant budget, KV pre-empted under pressure).

2. **SGMV / batched-with-different-adapters kernel.** Each request in a batch targets a different adapter. Without specialized kernel: serialize the adapter swaps, losing batching benefit. SGMV (Segmented Gather Matrix-Vector, Punica's named kernel): batches requests targeting different adapters into one GPU kernel launch by gathering the right adapter weights per request and computing the LoRA contribution in parallel. Punica's measured cost: +2ms latency per token, 12× throughput vs baseline. dLoRA and MixLoRA propose alternative approaches (rank-grouped batching, MixLoRA CUDA streams). Staff+ commit: name the kernel pattern, explain the gather-and-batch mechanism, discuss the per-token overhead, what happens when adapters have heterogeneous ranks (group by rank, or pad to max rank).

3. **Adapter storage hierarchy with cold-start mitigation.** Tier 1 (GPU HBM): active adapters, sub-ms access; capacity ~ tens to hundreds depending on rank and base model size. Tier 2 (CPU DRAM): warm adapters, ~10ms to load to GPU; capacity ~ thousands. Tier 3 (object storage S3/GCS): cold adapters, ~100-500ms first-load; unbounded capacity. LRU eviction across tiers with per-tenant pinned budget (premium tenants always have ≥1 hot slot). Cold-start mitigation: traffic-prediction-based prefetch (if a tenant typically requests at 9am, prefetch their adapter at 8:55am); adapter prefetch on session start (if user logs in, prefetch their tenant's adapter); request queue stalls cold requests up to a budget while waiting for adapter load. Staff+ commit: per-tier capacity sizing, eviction policy with tenant pinning, prefetch heuristics, what happens to a request that hits a cold adapter (wait? reject? serve with base only and note the degradation?).

## Known failure modes
1. **Hot tenant's adapter evicted by cold-tenant burst.** A burst of requests from many cold tenants pushes the LRU cache to evict the previously-hot tenant's adapter; next request from the hot tenant pays cold-load latency. Production answer: per-tenant pinned budget (e.g., 1 hot slot guaranteed per premium tenant) + LRU above the budget; per-tenant cache hit rate tracked as an SLI with alerting on regression.

2. **Adapter blob corruption causes silent quality regression.** Adapter weights corrupted on disk or during transfer; LoRA computation still works (no crash) but output quality is degraded. Production answer: content-hash verification at every load (compare to stored hash from upload); per-adapter eval canary (run a known-input → known-output check on activation; alert if quality below baseline); automatic rollback to previous adapter version on canary failure.

3. **Cross-tenant interference at the batch level when ranks mismatch.** Batching adapters of mismatched ranks together inefficiently uses GPU compute (must pad to max rank, wasting cycles for low-rank adapters). Production answer: rank-grouped batching (MixLoRA pattern) — schedule batches with similar ranks together; multi-stream execution to overlap rank-groups; or accept padding cost for simplicity if rank distribution is narrow.

## Notes for the coach
- **This is plausibly-asked.** S-LoRA and Punica are MLSys 2024 papers; multi-tenant fine-tuning is a public feature of OpenAI, Anthropic (via Bedrock), and Azure OpenAI; "Design Claude Custom" or "Design a multi-tenant fine-tune serving platform" is the natural Staff+ depth probe at any frontier lab.
- **The 12× throughput / +2ms / 2000+ concurrent numbers are the anchors.** Citing them grounds the Staff+ argument concretely.
- **The security boundary on dynamic adapter loading is a non-obvious gap.** vLLM's docs explicitly warn that runtime LoRA loading "carries security risks ... not for production unless ... isolated, fully trusted environment." A candidate who surfaces this and proposes content-hash + sandbox validation is at L6+ bar.
- **The cold-start economics differ from generic multi-tenant problems.** Generic patterns assume cold-start is fast (10s of ms); LoRA cold-start is 100-500ms because the adapter must move from object storage → CPU → GPU. Pretraining prefetch heuristics on traffic prediction is the production answer.

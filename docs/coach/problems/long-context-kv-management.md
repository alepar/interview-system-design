---
slug: long-context-kv-management
archetype: ai-infrastructure
sources:
  gemini_1_5: arxiv.org/abs/2403.05530
  paged_attention: arxiv.org/abs/2309.06180
  headinfer: openreview.net/pdf/eb649173c927a6eca428c65646c5191417c197e6.pdf
  deepseek_mla: arxiv.org/abs/2412.19437
---

# Long-context KV management (1M+ token serving on a GPU fleet)

## Bar anchors
- **Mid-level (L4/E4):** Single-GPU mental model. Doesn't recognize that 1M-token KV cache may not fit in HBM on a single GPU.
- **Senior (L5/E5):** Names PagedAttention. Knows GQA reduces KV cache vs MHA. Articulates per-user KV-cache memory cost at 128K context. May propose paged offload at category level.
- **Staff+ (L6/E6+):** Drives proactively. Quantifies KV-cache math: Llama-3 70B with GQA at 128K context = ~40 GB per user; 1M context = ~310 GB without compression. Names MLA (Multi-head Latent Attention, DeepSeek-V3) as the compression beyond GQA. Names sequence parallelism / Ring Attention for cross-GPU long-context attention. Names HEADINFER for fine-grained head-wise KV offloading (enables 4M token inference on single GPU). Names chunked prefill as the answer to long-prefill HOL blocking. Discusses paged offload to host RAM and NVMe with bandwidth budgets. Sticky session routing — once a session lives on N GPUs, it must stay there. Stretch (Sr Staff bar): TAKE (task-aware chunked KV eviction) or self-attention-guided eviction for retaining only important tokens; PNM/CXL-enabled KV management beyond GPU HBM (2025-2026 frontier).

## Canonical decomposition

### Requirements
**Functional:**
- Serve LLM inference for context up to 1M+ tokens (Gemini 1.5 anchor: 1M GA, 10M experimental)
- Support session resume — user returns after minutes-to-hours, KV state recovered or rebuilt
- Concurrent multi-user serving without one long-context user blowing out aggregate KV memory
- Cost-aware: 1M-token request costs $1+ in compute alone; users should know

**Non-functional (with numbers):**
- Per-user KV cache: 40 GB at 128K context (Llama-3 70B GQA); 310 GB at 1M context without compression
- Prefill latency for 1M tokens: seconds-to-tens-of-seconds even on H100
- Concurrent long-context users per node: bounded by HBM (8× H100 = 640 GB total)
- Session TTL: 5 min default, 1 hour extended (Anthropic precedent)
- HEADINFER: enables 4M token inference on single GPU via head-wise offload

### Core entities
- **Session:** session_id, user_id, model_id, kv_cache_blocks (across GPUs/tiers), context_length, last_access_ts
- **KVBlock:** block_id (16 tokens), tier (HBM | DRAM | NVMe | S3), gpu_id?, refcount
- **Pod:** pod_id, gpu_set, current_sessions, kv_capacity_total, kv_capacity_used
- **OffloadPlan:** session_id, blocks_on_hbm, blocks_on_dram, blocks_on_nvme, fetch_latency_budget

### API
- `POST /v1/completions` with sticky-session header → sends to pod hosting the session's KV
- `POST /v1/sessions/:id/checkpoint` → durably persist session KV state for resume after TTL
- `POST /v1/sessions/:id/resume` → restore from durable storage; pay cold-fetch cost

### HLD
For long-context serving, sessions are stateful (KV cache is per-session). The **session router** uses sticky-hash on session_id to keep all requests for a session on the same pod set (or migrate the session if rebalance is needed; rare event with high cost). The **KV memory manager** owns the tiered storage: HBM (active context, ms access), CPU DRAM (warm spill, ~10ms fetch), NVMe (cold spill, ~100ms), S3 (very cold, seconds — for paused sessions awaiting resume). Block-level allocation across tiers via PagedAttention pages; eviction policy can be LRU at block level or attention-guided (TAKE pattern — evict blocks with low attention weight; preserves "important" tokens). **Sequence parallelism / Ring Attention** distributes the attention computation across multiple GPUs for very long contexts (1M+ tokens) where even with offload, a single GPU can't hold enough HBM for active attention. **Chunked prefill** handles long-prompt admission: split the 1M-token prefill into 10K-token chunks, interleave with decode steps of other in-flight requests; no single request blocks the entire pipeline. **MLA (Multi-head Latent Attention)**: at the model architecture level, MLA stores a low-rank latent projection of K/V (reconstructed at attention time) — gives aggressive KV-cache shrinkage at higher expressive power than GQA. Reduces per-user KV memory by 4-8× without quality loss. **Session checkpoint/resume**: after TTL or on user idle, KV state is serialized to S3-tier; on resume, fetched back (pay cold latency) and rehydrated. For prompt-cache reuse, the prefix portion of the resumed KV may already be in the warm prompt cache, only the user-specific suffix needs cold-fetch.

### Deep dives
1. **KV-cache memory math and architectural compression.** Formula: `batch × seqlen × 2 × num_layers × num_kv_heads × head_dim × bytes_per_param`. Llama-3 70B at 128K context BF16 with GQA (8 KV heads vs 64 attention heads): ~40 GB per user. Same model at 1M context: ~310 GB. Without GQA (MHA): 8× larger. MLA (DeepSeek-V3) further compresses via low-rank latent projection: superior performance vs MHA with significantly reduced KV during inference. Trade-off: GQA requires model retraining; MLA requires both retraining + architectural change. For a candidate without model-architecture control, GQA is the practical answer; for a candidate building from scratch (or fine-tuning the architecture), MLA is the 2024+ frontier. Staff+ commit: pick GQA vs MLA based on whether you control model training, justify with the math.

2. **Chunked prefill + sequence parallelism for long inputs.** A 1M-token prefill on a 70B model takes seconds-to-tens-of-seconds on H100, dominated by O(N²) attention compute. Without chunking, this single request stalls the batch for all concurrent users. Chunked prefill (SARATHI pattern): split into 10-50K-token chunks, interleave each chunk with decode steps of other in-flight requests. The long request makes incremental progress without blocking others. For prefill compute that exceeds a single GPU's capacity, sequence parallelism distributes the attention computation across multiple GPUs (Ring Attention rotates K/V around the ring). Trade-off: more bookkeeping per chunk, slight per-chunk overhead. Staff+ commit: chunk size, sequence parallelism degree, topology-aware placement (Ring Attention bandwidth-sensitive — keep ranks on NVLink within node).

3. **Tier-2 KV storage and offload bandwidth.** GPU HBM is fast (3-5 TB/s) but small (80GB-141GB per H100); CPU DRAM is slower (~500 GB/s) but larger (TBs); NVMe is slower still (~7 GB/s) but vast. Tiered offload: active context blocks in HBM, recently-used blocks in DRAM, cold blocks on NVMe. PagedAttention block abstraction extends naturally to multi-tier. NVIDIA Dynamo's multi-tier KV memory (GPU/CPU/SSD/object) is the production pattern. HEADINFER goes further: fine-grained head-wise offloading — different attention heads' KV stored at different tiers based on attention pattern (some heads attend to everything, kept in HBM; some attend sparsely, can be offloaded). Enables 4M token inference on a single GPU. 2025-2026 frontier: PNM (Processing-Near-Memory) with CXL pushes the boundary further — offload to CXL memory with near-memory compute for token-page selection. Staff+ commit: tier capacities, eviction-to-next-tier policy, bandwidth budget for hot-path tier hops, fallback when NVMe saturated.

## Known failure modes
1. **A user resumes a 1M-token chat after 10 minutes — KV is gone.** TTL expired during the gap. Production answer: checkpoint-to-CPU/SSD before TTL eviction with async restore on resume; prompt-cache reuse if the prefix is shared (most of the 1M tokens are document context, only small recent suffix is user-specific) — that prefix may already be cached; only the user-specific suffix needs cold rebuild. UX: graceful degradation with a few-second "restoring conversation" delay rather than silent failure.

2. **Multiple long-context users on the same node OOM the host RAM.** 8 users each spilled 50 GB of KV to CPU DRAM = 400 GB. Production answer: admission control on aggregate KV bytes across HBM + DRAM + NVMe per node; reject session admission if no capacity guaranteed for the session lifetime; or migrate sessions to less-loaded nodes (high cost — full KV migration over network).

3. **Sequence-parallel collectives stall on slow links.** Ring Attention rotates K/V across N ranks at every attention step; slow inter-node IB link → entire collective waits. Production answer: topology-aware placement (Ring Attention ranks on NVLink within node, separate sessions on separate nodes); fallback to non-parallel attention with offload if topology not available.

## Notes for the coach
- **This is plausibly-asked.** Long-context is a public commitment of Anthropic, Google (Gemini 1.5), and OpenAI (GPT-4 Turbo 128K); the serving infrastructure is a natural Staff+ probe at any frontier lab. IGotAnOffer lists "Design a system that enables a large language model to handle multiple questions in a single thread" as a candidate Anthropic prompt — close variant.
- **The KV-cache memory math is the depth-fluency anchor.** A candidate who can derive 40 GB for Llama-3 70B at 128K from the formula demonstrates Staff+ math fluency.
- **MLA is the 2024+ frontier signal.** DeepSeek-V3 popularized it; candidates who name it unprompted are tracking the current literature. Generic answers stop at "use GQA."
- **HEADINFER + PNM/CXL are the 2025-2026 frontier signals.** Stretch topics for L7 differentiation.

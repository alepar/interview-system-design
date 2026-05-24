---
slug: prefill-decode-disaggregation
archetype: ai-infrastructure
sources:
  distserve_osdi24: usenix.org/system/files/osdi24-zhong-yinmin.pdf
  splitwise_isca24: arxiv.org/abs/2311.18677
  mooncake: arxiv.org/abs/2407.00079
  nvidia_dynamo: developer.nvidia.com/blog/introducing-nvidia-dynamo-a-low-latency-distributed-inference-framework-for-scaling-reasoning-ai-models/
---

# Disaggregated prefill/decode inference serving

## Bar anchors
- **Mid-level (L4/E4):** Produces a co-located design: each GPU runs both prefill and decode for whatever request it gets. May not identify the prefill/decode duality at all. Doesn't articulate why this is suboptimal.
- **Senior (L5/E5):** Names the prefill/decode duality (prefill compute-bound, decode memory-bandwidth-bound) and explains why co-location forces a compromise. Knows about chunked prefill (SARATHI) as one mitigation. Identifies KV-cache transfer as the joint bottleneck if you split pools. May propose disaggregation at category level but doesn't size the pools or address KV transport.
- **Staff+ (L6/E6+):** Drives proactively. Quantifies the prefill/decode duality numerically — prefill O(N²) on input length, decode O(N) per token. Names DistServe (OSDI 2024) — 7.4× goodput and 12.6× tighter SLO via disaggregation — and Splitwise (ISCA 2024) — 1.4× throughput at 20% lower cost via heterogeneous hardware (H100 for prefill, A100/L40S for decode). Names KV-cache transfer primitives: NIXL (NVIDIA Inference tranXfer Library), LMCache, MoonCake's KVCache-centric architecture. Sizes the two pools independently from input-length distribution: prefill cost dominated by p99 prompt length, decode cost dominated by p99 output length. Mentions that "almost every production-grade LLM serving framework as of 2025 implements disaggregation" — NVIDIA Dynamo claims up to 30× request capacity on DeepSeek-R1 on Blackwell. Stretch (Sr Staff bar): KV-cache-aware routing on the disaggregation boundary (when a request arrives, route to the decode pod that already has the cached prefix); chunked prefill as the simpler-ops alternative when disaggregation overhead isn't justified.

## Canonical decomposition

### Requirements
**Functional:**
- Accept LLM inference requests; stream tokens back
- Meet distinct TTFT (time to first token) and TPOT (time per output token) SLOs
- Handle wide input length distribution (1K to 1M tokens) and wide output length distribution (10 to 10K tokens)
- Scale prefill capacity and decode capacity independently with load
- KV cache transfer between pools must not become the bottleneck

**Non-functional (with numbers):**
- TTFT p99 <500ms for inputs ≤32K tokens
- TPOT p99 <30ms sustained
- Goodput improvement vs co-located: 2-7× per DistServe published; up to 30× per NVIDIA Dynamo on Blackwell
- KV transfer bandwidth: NVLink within rack (~600 GB/s aggregate), RDMA across (~400 Gbps), S3 fallback for cold-tier KV (seconds)
- Per-pool autoscaling response: <2 min from load spike to capacity-online
- Prefill:decode pool ratio: depends on length distribution; production examples 1:2 to 1:4 (decode is steady-state, prefill is bursty)

### Core entities
- **Request:** request_id, tenant_id, prompt, max_tokens, current_phase (prefill | decode | done)
- **PrefillPool:** pool_id, gpu_class (H100 typical), parallelism (TP=8 typical), current_load
- **DecodePool:** pool_id, gpu_class (A100/L40S typical), parallelism (smaller TP), current_load
- **KVCacheBlob:** request_id, layer_idx, kv_bytes, source_pod, target_pod, transfer_ms
- **Router:** maintains KV-cache-affinity hints (which decode pod has which prefixes cached)

### API (internal)
- `POST /prefill` body={request_id, prompt} → KVCacheBlob handle + first-token
- `POST /decode` body={request_id, kv_handle} → SSE stream of subsequent tokens
- KV transfer is a separate plane: source pod publishes blob, target pod fetches via NIXL/LMCache

### HLD
The user-facing **gateway** authenticates and routes requests to the **smart router** (Dynamo pattern). The router decides which prefill pool to use (cache-locality aware — if any pod has the prefix already cached, route there) and admits the request. The **prefill pool** runs on prefill-optimized GPUs (H100 SXM with high FLOPS) at moderate TP=8 for parallelism within a node; each prefill node runs continuous batching at the *prefill* iteration level (prefill chunks, not decode tokens). When prefill completes, the resulting **KV cache** (typically 1-40 GB depending on prompt length and model) must be transferred to a decode pod. The **KV transfer plane** uses NIXL (NVLink within rack, RDMA across; up to ~400 Gbps), LMCache (S3-tier for cold), or MoonCake's KVCache-centric store. The router pairs the request with a **decode pool** pod (KV-locality preferred; if the decode pod already has the prefix cached from a prior similar request, the transfer is a no-op). The decode pool runs on decode-optimized GPUs (A100/L40S — cheaper per memory-bandwidth) at smaller TP, with continuous batching at the *decode* token level. Each pool autoscales independently based on its own load signal (prefill queue depth → prefill scale; TPOT degradation → decode scale). The **smart router** also handles overflow: if KV transfer would saturate the inter-rack bandwidth, fall back to co-located prefill+decode on a "general" pool for that request.

### Deep dives
1. **KV transfer plane and the joint bottleneck.** Once you disaggregate, the KV state must move from prefill pod to decode pod on every request. For a 70B model with 128K context using GQA, that's ~40 GB per request; at 10K RPS, that's 400 TB/s of aggregate transfer — far exceeding any practical interconnect. The production answer is tiered transport: NVLink intra-rack (fastest, ~600 GB/s aggregate), RDMA / RoCE inter-rack (~400 Gbps), S3-class fallback (seconds, used only for cold-tier KV cache). NIXL is NVIDIA's named primitive for this transport; LMCache and MoonCake's KVCache store are alternatives. KV-cache-aware routing reduces transfer volume: route the request to a decode pod that already has the prefix cached from a prior request — the transfer becomes a no-op for the shared prefix. Staff+ commit: transport tier policy, cache-locality routing algorithm (consistent-hash on prefix-prefix? sticky-routing by tenant?), what happens when bandwidth saturates (overflow to co-located pool, reject, queue).

2. **Sizing the two pools independently from length distribution.** Given input-length distribution (e.g., median 4K, p99 64K) and output-length distribution (e.g., median 200, p99 2000) and target throughput, derive the prefill:decode GPU ratio. Math: prefill cost per request ~ O(N²) on input length (attention prefill is quadratic); decode cost ~ O(N_out) tokens × per-token cost. A workload with long prompts and short outputs (e.g., document Q&A: 100K input, 200 output) is prefill-heavy → prefill:decode ratio 4:1. A workload with short prompts and long outputs (e.g., creative writing: 200 input, 5K output) is decode-heavy → ratio 1:8. Heterogeneous workloads (real frontier-lab traffic) mix both → start at 1:2 to 1:4 and auto-tune. Staff+ commit: the math, the ratio derivation, the autoscaling signal per pool, what happens when a workload shift inverts the ratio.

3. **When NOT to disaggregate: chunked prefill alternative.** Disaggregation adds operational complexity (two pools, KV transport, smart router). SARATHI-Serve (OSDI 2024) showed that chunked prefill (split long prefill into chunks interleaved with decode steps of other in-flight requests) achieves 10× decode throughput improvement and 1.33× end-to-end throughput on LLaMA-13B *without* splitting pools. The disaggregation win is when SLO decoupling matters (very tight TTFT for short prompts + very tight TPOT for long generations); the chunked-prefill win is when ops simplicity matters more than peak goodput. Production reality (2025-2026): most frontier-lab serving runs disaggregation; smaller-scale or simpler workloads use chunked prefill. Staff+ commit: which architecture for which workload, the chunk size knob, when to switch from chunked-prefill to full disaggregation.

## Known failure modes
1. **KV transfer saturation under novel-prefix traffic.** When most requests have unique prefixes (no prompt-cache reuse), KV transfer volume is at maximum (every request's full KV moves from prefill to decode). At 10K RPS × 40 GB = 400 TB/s, this exceeds even Dynamo-class fabric. Production answer: tier the transport (NVLink intra-rack mandatory for hot path, RDMA inter-rack with bandwidth budget per request), cap the disaggregation ratio (overflow to co-located prefill+decode on a "general" pool when KV bandwidth approaches saturation), incentivize prompt caching at the application layer to reduce per-request KV size.

2. **Decode pool underflow when inputs trend short.** When inputs are short (e.g., chat with mostly short turns), prefill completes quickly and the decode pool empties slots faster than they refill — decode capacity is underutilized while prefill is saturated. Production answer: dynamic pool sizing based on observed length distribution (rebalance GPUs between pools every N minutes if the ratio drifts); spillover capability where decode pool pods can run small prefills inline; or fall back to co-located mode for short-prompt traffic.

3. **Cold-start KV regeneration cost when cache evicted mid-generation.** A request's KV state in the decode pool is evicted (memory pressure) before generation completes; regenerating from scratch costs full prefill latency, and may not even be possible if the original prefill pod's prompt cache has rotated. Production answer: pin in-flight KV (admission-time reservation), spillover to host-memory tier as a graceful intermediate (slower but recoverable), reject new requests if no slot guaranteed for in-flight completion.

## Notes for the coach
- **This is plausibly-asked.** No single confirmed interview question maps to this problem exactly, but it's the natural depth-cut of `inference-batching-and-multi-tenant-api` and "almost every production-grade LLM serving framework as of 2025 implements disaggregation" (Hao AI Lab retrospective). It's the most-likely follow-up question an Anthropic / OpenAI / DeepMind interviewer would ask after the candidate aces the inference-serving question.
- **The DistServe 7.4× goodput / 12.6× tighter SLO numbers are the headline.** Cite the OSDI 2024 paper if you want to ground the design pressure quantitatively. NVIDIA Dynamo's 30× claim on Blackwell + DeepSeek-R1 is the 2026 frontier number.
- **The "production-current" framing helps differentiate Sr Staff candidates.** A candidate proposing co-located serving in 2026 is 2023-era; one proposing chunked prefill is 2024-era; one proposing full disaggregation with KV transport is 2025-2026 current. The choice between disaggregation and chunked prefill (with criteria) is the L7 differentiator.
- **The MoonCake / NIXL / LMCache name-drops are the depth signals.** Candidates who know the named transport primitives have read the production papers; those who hand-wave "KV transfer" haven't.

---
slug: inference-batching
archetype: ai-infrastructure
sources:
  hello_interview: hellointerview.com (Batched Model Interface page — tagged "Asked at: Anthropic")
  vllm_paged_attention: arxiv.org/abs/2309.06180
  orca_continuous_batching: usenix.org/conference/osdi22/presentation/yu
  anthropic_prompt_caching: anthropic.com/news/prompt-caching
---

# LLM Inference Batching (single-GPU baseline → multi-tenant API)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic batching design: collect incoming requests in a queue, dispatch a batch when either `max_batch_size` (100) or `max_wait_time` is reached, run the batch on the GPU, fan responses back to per-request callers. Defines core endpoints (`POST /completion`, `GET /status`), picks a relational store for request bookkeeping. Recognizes that "100 requests cost roughly the same as 1 on the GPU" but defaults to static (request-level) batching, not iteration-level. Does not need to name PagedAttention, continuous batching, or KV-cache fragmentation unprompted.
- **Senior (L5/E5):** Names continuous batching / iteration-level scheduling (Orca / vLLM pattern) and explains why static batching wastes capacity when requests have different output lengths. Discusses KV-cache memory as the binding constraint and identifies PagedAttention (16-token blocks, ~12.8 KB per block on a 13B model) as the named solution to fragmentation. Names head-of-line blocking on a long-generation request and proposes either preemption with KV swap or per-request streaming channels (SSE) for response routing. Handles admission control (`max_batch_size` vs `max_wait_time` trade-off) with explicit tail-latency-vs-throughput reasoning.
- **Staff+ (L6/E6+):** Drives the session proactively. Quantifies KV-cache memory math (block size × token count × layers × heads × bytes) and prices admission control against it; reserves KV blocks at admission, not just request slots. Identifies the prefill/decode duality (prefill compute-bound, decode memory-bandwidth-bound) unprompted and notes co-location forces a compromise that serves neither well. Names chunked prefill (SARATHI-style) as the production answer to long-prefill HOL blocking. When the interviewer escalates to multi-tenant fleet scale (typical pattern), shifts cleanly: per-tenant token-quota rate limiting on streaming responses (must decrement as tokens emit, not on request start; reserve `max_tokens` worth, refund unused); cross-tenant prompt-cache isolation via per-tenant `cache_salt` with sticky-hash routing; SSE not WebSockets with bounded-buffer backpressure; per-connection memory cost in the gateway sizing math. Stretch (Sr Staff bar): mentions disaggregated prefill/decode as the next architectural step and speculative decoding (EAGLE-class, 0.6-0.8 acceptance rate, 2-3× speedup) as a cost lever.

## Canonical decomposition

### Requirements
**Functional (single-GPU baseline):**
- Accept synchronous inference requests; user waits for completion
- Batch up to 100 inputs per batch
- Stream output tokens back to user as they're generated
- Cancel an in-flight request

**Functional (fleet escalation):**
- Per-tenant authentication and request attribution
- Prompt caching for repeated system prompts / document contexts
- Per-tenant token-quota enforcement (input + output tokens/min)
- Usage metering and cost attribution per tenant

**Non-functional (with numbers):**
- Single-GPU baseline: a single H100 serving a 7-13B model at hundreds of tokens/sec aggregate; PagedAttention reduces KV fragmentation waste from 60-80% to <4% (vLLM, SOSP'23)
- Fleet aggregate: 100K+ QPS, 6B+ tokens/min (Sam Altman, OpenAI DevDay 2025)
- Time-to-first-token (TTFT) p50 <500ms, p99 <2s for typical request
- Time-per-output-token (TPOT) p99 <50ms steady-state
- Availability: 99.9% per region; multi-region with home-region routing
- Prompt caching: 90% cost reduction, 85% latency reduction on cached prefixes (Anthropic published; 100K-token book example 11.5s → 2.4s)
- Per-tenant fairness under overload: no tenant's burst starves another

### Core entities
- **Request:** request_id, tenant_id, prompt, max_tokens, model_id, cache_control, stream_channel
- **Batch:** batch_id, list of request_ids, time_created, current_iteration
- **KV-cache block:** 16-token unit (~12.8 KB on a 13B model), content-hashed
- **Tenant:** tenant_id, tokens_per_min_quota, cache_salt (for cross-tenant isolation), reserved_capacity_tier
- **Cached prefix:** content_hash, model_version, kv_blocks (list), tenant_namespace, ttl_remaining

### API
- `POST /v1/completions` body={model, messages, max_tokens, stream, cache_control} → SSE stream of token deltas (single-GPU baseline) or final JSON if `stream=false`
- `GET /v1/completions/:id` → status + final output (for non-streaming clients polling)
- `POST /v1/completions/:id/cancel` → abort in-flight generation, release KV blocks
- `GET /v1/usage` → tenant token consumption (input, cached input, output) per model per period
- Streaming protocol: **Server-Sent Events** (SSE) — used natively by OpenAI and Anthropic, not WebSockets (the canonical Anthropic prompt explicitly uses HTTP request-response with streaming)

### HLD
**Single-GPU baseline.** Requests arrive at a stateless **gateway** that authenticates and validates. Each request enters a **scheduler** running on the inference host. The scheduler implements continuous (iteration-level) batching: at every decode step it decides which in-flight requests get a token, which finished requests retire, and which new requests can join the batch. The **PagedAttention KV-cache manager** owns GPU memory as 16-token blocks and hands out blocks to requests on demand; when memory is full, admission control either rejects new requests or pre-empts the oldest in-flight request (its KV blocks evicted; recompute or swap-to-host on resume). Each request has a dedicated **per-request streaming channel** (SSE writer) so the scheduler can emit tokens directly to the right caller without a shared result queue.

**Fleet escalation.** The stateless gateway tier handles auth, **per-tenant token-quota** rate limiting (token-bucket per tenant_id, decremented as output tokens emit — not on request start), and request routing. A **cache-affinity-aware router** uses sticky-hash by `(tenant_id, prompt_prefix_hash)` to keep requests with the same system prompt landing on the same inference replica, maximizing prompt-cache hit rate. The **prompt-cache cluster** — KV blocks keyed by `(content_hash, model_version, tenant_salt)`, tiered HBM/DRAM/SSD, per-tenant `cache_salt` isolation — is the subject of `prompt-cache-infrastructure`; the relevant fact for batching is that the cache-affinity router determines which replica a request lands on. The **metering pipeline** (Kafka stream of `(tenant_id, model, input_tokens, cached_input_tokens, output_tokens)` per request completion) feeds billing and quota refunds. Streaming responses use SSE with bounded per-connection buffers; backpressure on slow clients drops the connection rather than buffering unboundedly.

### Deep dives
1. **Continuous batching + PagedAttention KV memory management** — Static batching (collect N requests, run them as a single fixed-shape batch) wastes capacity because the batch can't retire until the longest-output request finishes; new arrivals wait for the next batch cycle. Continuous batching (Orca, OSDI'22; vLLM, SOSP'23) makes the batching decision at every decode iteration: finished requests retire mid-batch, new requests slot into freed positions, and the batch shape changes every token. The enabling primitive is PagedAttention — KV cache is paginated into fixed-size 16-token blocks (~12.8 KB each on a 13B model), so requests with different sequence lengths can coexist without internal fragmentation. The result: vLLM reports 2-4× throughput vs Orca, 14-24× vs naive HuggingFace serving. The cost: bookkeeping per-block, slightly higher per-token kernel cost. Staff+ commit: explicit `max_batch_size` (limited by KV memory, not flops), `max_wait_time` (admission window before flushing partial batches), preemption policy on KV pressure (recompute vs swap-to-host vs reject).

2. **Per-tenant token-quota rate limiting on streaming responses (fleet)** — Generic rate limiting (requests-per-second per tenant) doesn't bound LLM cost: token cost varies by 100× across requests (100-token vs 10K-token output). Token-bucket per tenant, but on streaming output the rate-limiter must decrement *as tokens emit*, not at request start (the request might generate 1 token or 4000). At admission time, reserve `max_tokens` worth of budget; refund the unused portion at completion. Central token-bucket (Redis with Lua) is consistent but a single point of contention; eventually-consistent leaky-bucket per gateway with periodic reconciliation is more scalable. Premium tenants get reserved capacity slices (separate GPU pool, not a shared scheduler); free-tier requests get deferred to off-peak batched windows (OpenAI Batch API pattern: 50% discount, 24h SLA). Staff+ commit: window strategy (sliding vs fixed), reservation policy, reconciliation cadence, what happens when a tenant exceeds quota mid-stream (graceful close with `quota_exceeded` SSE event).

3. **Prompt cache topology and per-tenant isolation (fleet)** — Inference-batching at fleet scale depends on a cluster-grade prompt-cache layer (Anthropic: 90% cost reduction, 85% latency reduction on cached prefixes). The cached object is the transformer's KV state for a prompt prefix; topology choices (per-pod prefix tree vs shared cluster vs hybrid), pricing math (1.25× write 5-min, 0.10× read, ~3 reads/write break-even), RadixAttention, multi-tier storage, and cross-tenant isolation via `cache_salt` are detailed in `prompt-cache-infrastructure` (this archetype) — reference, don't re-derive. **For the inference-batching context, the relevant interaction is the cache-affinity-aware router**: requests with the same `(tenant_id, prompt_prefix_hash)` must land on the same inference replica to maximize hit rate, which means the batching scheduler can't be pure round-robin — it must respect sticky-hash. Staff+ commit here: how does cache-affinity routing interact with continuous batching's load balancing under uneven traffic (one replica hot with a popular prompt, others starved)?

## Known failure modes
1. **OOM on KV cache when concurrency × max-context exceeds VRAM** — Eight simultaneous 200K-token requests on a 70B model exceeds H100 memory entirely; without admission control the scheduler crashes or thrashes. Production answer: PagedAttention enables explicit KV-block reservation at admission time; admission policy reserves blocks for `min(max_tokens, recent_p99_output)` per request; if reservation fails, the request is either rejected (with `503` + `retry-after`) or queued in an admission waiting room. Spillover to a disaggregated decode pool (the natural next-architecture step) or to host-RAM-swapped KV blocks is the production answer when the admission queue grows. Anti-pattern: admit-then-pre-empt, which causes thrashing and 10× tail-latency blow-up when oldest requests get evicted just before completing.

2. **Head-of-line blocking on a long prefill** — A request with a 200K-token prompt takes ~10× the prefill time of a 20K-token request and blocks the decode pipeline for in-flight requests. Without mitigation, p99 TPOT for concurrent decodes inflates 2-30× (DistServe analysis). Production answer: chunked prefill (SARATHI-Serve, OSDI'24) splits long prefill into chunks (e.g., 8K tokens each) and interleaves chunks with decode steps of other in-flight requests — the long request makes incremental progress without starving decode. Alternative production answer at higher fleet scale: disaggregated prefill/decode pools entirely (separate problem). Knob: chunk size — smaller chunks = better decode latency but more kernel-launch overhead.

3. **Cross-tenant cache poisoning via shared prompt cache (fleet)** — Without per-tenant isolation, tenant A could discover tenant B's confidential system prompt by issuing requests with the same prefix and observing cache hit latency (timing side-channel) or by collision (if the cache key is purely content-hash). Production answer: `cache_salt` per tenant mixed into the cache key (vLLM exposes this primitive); separate namespaces per tenant in the cache directory; audit log by tenant for incident response. For high-sensitivity tenants (enterprise with confidential prompts), offer a dedicated cache pool (hard-isolated, not shared). Tested via per-tenant red team: a synthetic adversarial tenant attempting to surface another tenant's prompt content should produce zero cache hits in the audit log.

## Notes for the coach
- **This is the most-confirmed Anthropic Staff system-design prompt** per multiple independent sources (Hello Interview "Batched Model Interface" page tagged "Asked at: Anthropic"; a Blind post-mortem from a failed Anthropic Staff loop preserves verbatim *"The most common question they ask is the batched inference question. (100 requests takes the same amount of time as 1) Use a queue to batch the requests"*; Exponent 2026 Anthropic guide names it "the most commonly reported Anthropic system design prompt"). When the candidate opens the round, the interviewer is most likely to start at the single-GPU framing.
- **Fleet escalation is the typical depth move at Anthropic.** After the candidate gets the single-GPU baseline (continuous batching + PagedAttention + admission control), the interviewer escalates to "now make this serve thousands of tenants." Reward the candidate who handles the shift cleanly without restarting the design. Penalize the candidate who pre-emptively jumps to fleet on turn 1 (misses the canonical question).
- **The prefill/decode duality unlocks the Sr Staff bar.** Candidates who name the duality unprompted and mention disaggregation as the natural next step demonstrate frontier-paper literacy that is the L7 differentiator. Don't volunteer this — wait for the candidate to surface it.
- **Connection economics is the recurring gap.** At 11.4M concurrent connections (ChatGPT scale), per-connection memory in the gateway tier drives pod sizing; the candidate should pin this in HLD, not deep-dive.

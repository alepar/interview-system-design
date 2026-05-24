---
slug: prompt-cache-infrastructure
archetype: ai-infrastructure
sources:
  anthropic_prompt_caching: anthropic.com/news/prompt-caching
  sglang_radix_attention: lmsys.org/blog/2024-01-17-sglang/
  paged_attention: arxiv.org/abs/2309.06180
  anthropic_1hr_ttl: x.com/AnthropicAI/status/1925633128174899453
---

# Prompt-cache infrastructure (production KV-cache reuse across requests)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic response cache (hash request → cache response). Doesn't recognize that the cached object is KV state of a transformer, not a string response. Doesn't address TTL, eviction, or per-tenant isolation.
- **Senior (L5/E5):** Recognizes that prompt caching means caching KV-cache state for shared prefixes. Names PagedAttention as the underlying primitive (16-token blocks). Discusses TTL (LRU or explicit). Identifies per-tenant isolation as a problem. Pricing model awareness — cache writes cost more than reads, so reuse-frequency matters.
- **Staff+ (L6/E6+):** Drives proactively. Cites Anthropic's specific numbers: 90% cost reduction, 85% latency reduction on cached prefixes; 100K-token book example 11.5s → 2.4s. Names the pricing model with multipliers: 1.25× base for 5-min cache writes, 0.10× base for reads, 2× base for 1-hour writes. Break-even is ~3 reads per write — surfaces server-side decision to skip caching for low-reuse tenants. Names RadixAttention (SGLang) — KV pages stored in radix tree keyed by token sequence, LRU eviction at page level, achieves 6.4× higher throughput on workloads with shared prefixes. Discusses cross-tenant isolation via `cache_salt` per tenant (vLLM primitive). Cross-version cache invalidation — cache key includes model version, rolling deploy drains old cache while warming new. Topology choice: per-pod prefix tree (sticky routing required) vs shared cache cluster (introduces fetch latency) vs hybrid. Stretch (Sr Staff bar): multi-tier storage (GPU HBM hot → CPU DRAM warm → SSD cold) with eviction across tiers; coherence under partial-cache-hits (request matches first 80K of a 100K cached prefix → compute remaining 20K + append).

## Canonical decomposition

### Requirements
**Functional:**
- Cache KV state of shared prefixes (system prompts, document context, agent loop conversation history) across requests
- Per-tenant isolation: tenant A's cached prompts must not be observable or reusable by tenant B
- TTL with both default (5 min) and extended (1 hour) options
- Pricing transparency: cache writes vs reads have different costs
- Cross-version invalidation on model rollout
- Coherence under partial-cache-hits

**Non-functional (with numbers):**
- 90% cost reduction on cached prefixes (Anthropic published)
- 85% latency reduction on long prompts (Anthropic published)
- 100K-token chat-with-book example: 11.5s → 2.4s with caching
- Pricing multipliers (Anthropic): 1.25× base for 5-min cache writes, 0.10× base for reads, 2× base for 1-hour writes
- Break-even: ~3 reads per write
- Cache hit rate target: >70% for high-reuse workloads (agents, RAG, multi-turn chat)
- Block size: 16 tokens (PagedAttention default); 12.8 KB per block on a 13B model
- RadixAttention throughput improvement: 6.4× on shared-prefix workloads

### Core entities
- **CachedPrefix:** prefix_hash, model_version, tenant_salt, kv_blocks (list of GPU memory references), ttl_remaining, last_access_ts, access_count
- **KVBlock:** block_id (16 tokens), gpu_memory_addr, tier (HBM | DRAM | SSD), refcount
- **CacheKey:** (prefix_hash, model_version, tenant_salt) — three-tuple, never partial
- **PrefixTree:** radix tree keyed by token sequence, leaves point to KV blocks (RadixAttention pattern)
- **Tenant:** tenant_id, cache_salt (cryptographically random per tenant), cache_budget_gb

### API
- Implicit in completions API: `POST /v1/completions` with `cache_control: {type: ephemeral | persistent_1hr}` markers on system prompt or document blocks
- `GET /v1/cache/stats` per tenant → {hit_rate, write_count, read_count, cost_saved}
- `POST /v1/cache/invalidate` body={tenant_id, prefix_hash_prefix} → admin invalidation API (rare; mostly TTL-driven)

### HLD
The prompt-cache layer is integrated into the inference serving stack (it's a memory-management overlay, not a separate service). On request arrival, the **prefix matcher** walks the radix tree to find the longest cached prefix matching the request's tokenized prompt (RadixAttention pattern in SGLang; per-pod prefix tree in vLLM). The cache key is `(prefix_hash, model_version, tenant_salt)` — the salt prevents cross-tenant collision and observation. If a match is found, the cached KV blocks are reused (no prefill recompute for those tokens) and only the new-token suffix needs prefill. If no match (or partial match), prefill runs for the un-cached portion and the resulting KV blocks are added to the radix tree under the request's prefix. **Eviction** is LRU at the block level — when GPU HBM is full, oldest-unused blocks are evicted. For multi-tier storage, evicted blocks can spill to CPU DRAM (warm tier) or SSD (cold tier) with explicit cost; cold-tier hits pay fetch latency. **Routing layer** uses cache-affinity routing: requests are sticky-hashed by (tenant_id, prefix_hash_first_N_chars) so requests with the same system prompt land on the same pod, maximizing hit rate. **Cross-tenant isolation** is enforced by mixing `tenant_salt` into the cache key — even if two tenants happen to use literally identical prompts, their cache entries don't collide. **Cross-version invalidation**: model rollout includes a `model_version` bump that changes the cache key; old version's cache continues serving in-flight requests until they complete, then drains; new version starts cold and warms up over the first hours of traffic.

### Deep dives
1. **Cache topology and routing.** Three production options: (a) **per-pod prefix tree** (vLLM, SGLang) — each inference pod independently caches what passes through it; requires sticky-routing to maximize hit rate; pod-local cache means no inter-pod fetch latency. (b) **shared cache cluster** — separate fleet stores KV blocks; pods fetch on demand; uniform hit rate across pods but adds fetch latency on hot path; bandwidth bottleneck at the shared cluster. (c) **hybrid with per-pod hot tier + shared warm tier** — best of both at cost of complexity. Sticky-routing choice: consistent-hash by (tenant_id, system_prompt_hash) with bounded load (e.g., Maglev) to prevent hot-pod overload. Trade-offs are about uniformity of working set: small working set of distinct prompts → per-pod is fine; large diverse working set → shared cluster wins. Staff+ commit: pick a topology, justify with working-set assumption, name the sticky-routing algorithm.

2. **Eviction and TTL policy with cost model.** Anthropic offers 5-min default + 1-hour extended TTL. The 1-hour TTL costs 2× base for the write but maintains the cache across more requests — break-even shifts. Eviction at the block level (PagedAttention block = 16 tokens), LRU by default but cost-aware variants exist (evict blocks cheap to recompute first, since recompute is the fallback). The pricing math: cache write 1.25× input price, cache read 0.10×. Break-even reads-per-write = (1 - 0.10) / (1.25 - 1) ≈ 3.6. Surfaces a server-side decision: for low-reuse tenants (cache hit rate <30%), skip caching server-side — saves both write cost and capacity. For high-reuse tenants (agentic loops, multi-turn chat) the savings compound. Staff+ commit: TTL tier strategy, eviction policy, server-side opt-out heuristic for low-reuse tenants.

3. **Cross-version invalidation and partial-cache-hits.** Model weights change → cached KV state is invalid (numerically inconsistent with new weights). Cache key must include model version; during a rolling deploy, the old version's cache continues serving in-flight requests on old-version pods until they complete; the new version starts cold and warms over the first hours. For a fast rollback scenario, the old cache is still valid (since version is still in flux); a smart cache layer can retain old-version blocks for a grace period. **Partial cache hits**: if a request's prefix matches the cache up to token 80K of a 100K-token cached prefix, the system computes prefill for the remaining 20K and appends. The radix-tree representation makes this natural — the match terminates at the divergence point, the unmatched suffix is computed as new prefill. The KV blocks for the unmatched suffix are added to the radix tree under the request's prefix, growing the shared cache organically. Staff+ commit: deploy-time invalidation procedure, partial-hit computation flow, grace period for old version retention on rollback.

## Known failure modes
1. **Cache thrashing on diverse prompts.** When too many distinct system prompts are in flight (working set exceeds cache capacity), hit rate collapses and the cluster regresses to no-cache performance. Production answer: tenant-affined routing (sticky-hash by tenant_id) so each pod sees a small set of prompts; periodic cache-eviction telemetry to size cluster capacity to keep working set in cache; per-tenant cache budget caps to prevent one tenant's diversity from evicting another's hot prefixes.

2. **Stale cache across deploys.** A model rollout invalidates cached KV state, but in-flight requests still hold references to the old cache. Production answer: cache key includes model version, so old and new caches coexist briefly; drain timer on the old cache pool (no new admissions to old version after rollout cutover); dual-pool live for the transition window; for fast rollback, retain old-version blocks for a grace period rather than immediate eviction.

3. **Cost regression on low-reuse tenants.** Cache writes cost more than the saved reads if reuse is <3×. A naïve "cache everything" policy is a net loss for tenants whose prompts don't repeat. Production answer: server-side decision to skip caching for low-reuse tenants based on observed traffic patterns (per-tenant hit-rate tracking with hysteresis); expose explicit `cache_control` hints to clients who know their workload reuse pattern; surface per-tenant cost-saved metric so customers see the value and self-optimize.

## Notes for the coach
- **This is plausibly-asked at Anthropic** — they published the productized version and the specific numbers; a candidate who cites the 90% cost / 85% latency / 100K-token-book example demonstrates Anthropic-specific literacy.
- **The pricing math (1.25× write, 0.10× read, ~3 break-even) is the cost-architecture anchor.** Most candidates default to "cache everything"; the Staff+ candidate surfaces the server-side opt-out for low-reuse tenants as a cost-protection measure.
- **RadixAttention as the named primitive is the SGLang-literacy signal.** A candidate who reaches for "radix tree of KV pages with LRU eviction" unprompted has read the SGLang paper.
- **Cross-tenant isolation via cache_salt is the security-bar move.** Without it, tenant A could discover tenant B's confidential system prompt by replaying it and observing the cache-hit latency (timing side-channel). Surface as a category-level security gap if not addressed.
- **The deep-dive depth here is non-trivial.** A 55-min interview can comfortably cover topology + eviction + cross-version invalidation; partial-cache-hits is a stretch topic if there's time.

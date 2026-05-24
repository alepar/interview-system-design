---
slug: ai-gateway-token-quota
archetype: ai-infrastructure
sources:
  cloudflare_ai_gateway: developers.cloudflare.com/ai-gateway/features/rate-limiting/
  portkey_gateway: github.com/portkey-ai/gateway
  llmlingua: arxiv.org/pdf/2310.05736
  bedrock_quotas: milvus.io/ai-quick-reference/what-limitations-or-quotas-exist-in-amazon-bedrock-for-model-usage-request-rates-or-payload-sizes
---

# AI gateway with token-quota rate limiting (multi-provider, cost-aware)

## Bar anchors
- **Mid-level (L4/E4):** Generic API gateway with request-count rate limiting. Doesn't recognize that LLM token cost varies by 100×.
- **Senior (L5/E5):** Names token-quota vs request-quota distinction. Discusses prompt caching at gateway tier as a possibility. May propose multi-provider failover at category level.
- **Staff+ (L6/E6+):** Drives proactively. Names token-quota with sliding-window enforcement on streaming output (decrement as tokens emit, not on request start). Cites Cloudflare AI Gateway's gap: "limited TPM support vs request-count" — a known production hole. Names Portkey (1T tokens/day, 122KB binary, <1ms latency) and Helicone (~15MB Rust/Tower binary, 1-5ms P95) as reference architectures. Multi-provider failover with explicit cost vs quality vs latency trade-off; tenant pinned to provider for session coherence. LLMLingua prompt compression: 20× compression at 1.5pt quality drop, 20-30% latency reduction; reported case: SaaS monthly bill $42K → $2.1K via compression alone. Per-tenant cost attribution to sub-cent precision for billing. Stretch (Sr Staff bar): cache-key shape including model version; output_tokens reservation + refund at admission; cost-aware degradation (when tenant hits 80% of budget, downgrade to cheaper provider/model).

## Canonical decomposition

### Requirements
**Functional:**
- Multi-provider AI gateway (Anthropic + OpenAI + Google + local models behind one API)
- Per-tenant token-quota rate limiting (input + output TPM)
- Gateway-tier prompt caching for cost-reduction
- Multi-provider failover on outage with provider-specific format adaptation
- Per-tenant cost attribution + sub-cent billing precision
- Optional prompt compression for further cost reduction

**Non-functional (with numbers):**
- Gateway latency overhead: <5ms p95 (Portkey: <1ms; Helicone: 1-5ms)
- Throughput: 10K+ RPS per gateway pod (Helicone Rust/Tower) up to 1T tokens/day (Portkey scale)
- Cache hit latency reduction: up to 90% on cached requests (Cloudflare AI Gateway)
- Prompt compression: 20× compression, 1.5pt quality drop (LLMLingua)
- Default tenant quota anchor: Bedrock Claude 1000 RPM + 100K input TPM (raisable via support ticket)

### Core entities
- **Tenant:** tenant_id, plan_tier, input_tpm_limit, output_tpm_limit, monthly_cost_cap, primary_provider, fallback_chain
- **Token-Bucket:** tenant_id, period_start, input_tokens_consumed, output_tokens_consumed, reserved_for_in_flight
- **CacheEntry:** key (model_version + prompt_hash + tenant_salt), response_or_kv, ttl, hit_count
- **ProviderRoute:** request_type → primary_provider + fallback (cost-first | quality-first | latency-first)
- **CostEvent:** request_id, tenant_id, provider, model, input_tokens, output_tokens, cached_input_tokens, $-cost, ts

### API
- `POST /v1/completions` body={model, prompt, ...} → SSE stream + cost in response trailer headers
- `GET /v1/tenants/:id/usage` → real-time token + cost consumption
- `POST /v1/admin/quota` body={tenant_id, input_tpm, output_tpm} → quota update
- `GET /v1/billing` → per-tenant cost report with provider breakdown

### HLD
The gateway is a stateless edge service (Rust or Go for low overhead). Each request hits **auth + tenant resolution** (tenant_id from API key); then **token-quota admission** — token-bucket per tenant decrements as output tokens emit, not at request start; admission reserves max_tokens worth of budget conservatively, refunds unused at completion. The **prompt cache check** runs next: hash (model_version, prompt_prefix, tenant_salt) → if hit, serve from cache (gateway-tier caching delivers up to 90% latency reduction per Cloudflare). On cache miss, the **router** picks the provider per tenant's primary preference + cost/quality/latency policy; on provider 503 or timeout, falls back to next in chain (with format adaptation — OpenAI's tool-call format ≠ Anthropic's). For long prompts, **prompt compression layer** (LLMLingua-class) optionally compresses the prompt (20× compression at 1.5pt quality drop) before sending to provider — server-side decision based on tenant policy. **Streaming response** flows back through the gateway as SSE; gateway tracks output tokens emitted for both quota decrementing and cost attribution. **Cost event pipeline** emits per-request events (Kafka stream) capturing input/output/cached tokens × per-provider price → aggregated to per-tenant billing with sub-cent precision. **Multi-provider failover state**: tenant pinned to provider for session duration (avoid mid-session quality flip); session boundaries trigger re-routing decision.

### Deep dives
1. **Token-quota vs request-quota rate limiting on streaming output.** Generic rate limit (RPS per tenant) doesn't bound LLM cost because token cost varies by 100× across requests (100-token vs 10K-token outputs). Token-bucket per tenant tracks input + output tokens/min separately. On request admission, reserve `max_tokens` worth of output budget (worst case); decrement as output tokens emit; refund the unused portion at completion. Central token-bucket (Redis with Lua) is consistent but a single point of contention; eventually-consistent leaky-bucket per gateway with periodic reconciliation scales better. Hard cap on per-request max_tokens prevents a single request from exhausting a tenant's quota in one shot. Cloudflare AI Gateway explicitly documents the limited-TPM-support gap; Portkey + Helicone built specifically for this. Staff+ commit: window strategy (sliding vs fixed), max_tokens reservation, refund mechanism, central vs distributed token-bucket, what happens mid-stream when quota exhausted (graceful close with SSE quota_exceeded event).

2. **Multi-provider failover with cost/quality/latency trade-off.** Tenant primary provider returns 503 or exceeds timeout → fail over to backup. Cost, quality, latency differ across providers — failing over to a cheaper provider degrades quality; failing over to a faster provider may cost more. Per-tenant policy (cost-first, quality-first, latency-first) drives the choice. Format adaptation: each provider has slightly different API (tool-call format, system prompt structure, max_tokens semantics) — the gateway normalizes inbound to internal format and translates outbound to chosen provider's format. Tenant pinning: don't fail over mid-conversation (breaks coherence); only switch at session boundaries. Staff+ commit: per-tenant policy DSL, format normalization layer, failover decision criteria, session pinning semantics.

3. **Prompt compression as a cost lever (LLMLingua).** LLMLingua compresses prompts up to 20× with 1.5-point performance drop on benchmarks; cuts generation latency 20-30%; reported production case: SaaS monthly bill $42K → $2.1K (zero model change, only compression). Uses small classifier (GPT2-small or LLaMA-7B) to identify and drop low-value tokens from prompts. Server-side decision: enable for tenants whose workload is verbose (long context, repeated content, formatting boilerplate); disable for tenants whose prompts are already terse or where exact wording matters (legal, code). Trade-off: compression adds ~10-20ms per request (compression classifier overhead) and a small quality loss; only net-positive when input tokens dominate cost. Staff+ commit: per-tenant enable/disable policy, quality-loss budget, when to A/B test compression on/off, fallback to uncompressed on quality regression alert.

## Known failure modes
1. **Token blow-up via long max_tokens request.** Tenant sends prompt with max_tokens=128K; reserves entire quota in one shot. Production answer: hard per-request max_tokens cap at admission (e.g., 8K default, 32K premium tier); progressive reservation (reserve initial 1K, refresh as generation proceeds); multi-dim quota (request count limit too — prevents one tenant making N requests each reserving max_tokens).

2. **Cache collision across model versions.** Cached KV for model v1 served to model v2 request → wrong output. Production answer: model version in cache key always; rolling deploy with cache drain (old version's cache continues serving in-flight old-version requests; new version starts cold); explicit cache invalidation API for hot rollback scenarios.

3. **Provider failover quality regression mid-conversation.** Tenant's session pinned to Anthropic; Anthropic outage triggers failover to OpenAI mid-conversation; OpenAI's response style differs from prior Anthropic turns; conversation coherence breaks. Production answer: tenant pinned to provider for full session duration (don't fail over mid-conversation); on outage, queue new requests with brief delay rather than immediate failover; if outage persists beyond delay, fail over at next session boundary with explicit re-prompt for the new provider's preferred format.

## Notes for the coach
- **This is plausibly-asked.** Cloudflare AI Gateway, Portkey, and Helicone are documented production stacks; multi-provider AI gateways are a common SaaS pattern. "Design Portkey" or "Design an AI cost-control layer" is a natural Staff+ probe for a platform-eng role at any frontier lab or AI-infra startup.
- **The token-vs-request quota framing is the cost-architecture unlock.** Most candidates default to RPS; the Staff+ candidate immediately surfaces that LLM token cost varies by 100× and request-count rate-limiting doesn't bound cost.
- **The Portkey 1T-tokens-per-day scale anchor is the production-grade signal.** Citing it grounds the design pressure quantitatively.
- **LLMLingua compression with the $42K→$2.1K case is the cost-lever stretch move.** A candidate who reaches for prompt compression unprompted demonstrates familiarity with the cost-optimization research frontier.

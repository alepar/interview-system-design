---
slug: model-cascade-router
archetype: ai-infrastructure
sources:
  frugalgpt: arxiv.org/pdf/2305.05176
  routellm: arxiv.org/abs/2406.18665
  eagle3: arxiv.org/abs/2503.01840
  deepseek_v3: arxiv.org/abs/2412.19437
---

# Model cascade router (cost-aware routing across cheap → flagship models)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic router that picks model by request "type" (chat vs code vs vision). Doesn't address confidence-thresholded escalation or cost-vs-quality trade-off.
- **Senior (L5/E5):** Names model cascade as a pattern (cheap model first, escalate to expensive on low confidence). Discusses speculative decoding at category level. Knows about per-tenant cost caps. Discusses router training as a separate problem.
- **Staff+ (L6/E6+):** Drives proactively. Cites FrugalGPT specific numbers (up to 98% cost reduction matching GPT-4) and RouteLLM (85% cost reduction on MT-Bench, 45% on MMLU, 35% on GSM8K). Quantifies the cost ratio: Claude Opus 4.7 vs Haiku 4.5 = $5+$25 vs $1+$5 per MTok input+output (5× ratio); legacy Claude 3 Opus vs Haiku was ~60×. Names speculative decoding with EAGLE-class numbers: 0.6-0.8 acceptance rate, 2-3× speedup typical, EAGLE-3 up to 6.5× at temperature 0; SpecForge up to 4.48× on SGLang. Names MoE expert routing as a related routing problem at the *intra-model* level: DeepSeek-V3 selects top-8 of 256 experts per token; routing collapse (popular experts get hot) is the central failure mode; DeepSeek's auxiliary-loss-free dynamic bias adjustment is the named defense. Per-tenant cost cap with graceful degradation (downgrade to cheap model when 80% of budget consumed). Stretch (Sr Staff bar): router-model evaluation methodology (offline holdout + online A/B + per-tenant calibration to detect routing bias).

## Canonical decomposition

### Requirements
**Functional:**
- Per-request routing decision: which model (cheap/mid/flagship) serves this request
- Confidence-thresholded escalation: cheap model produces output + verifier; escalate on low confidence
- Speculative decoding integration: draft model proposes tokens, target model verifies
- Per-tenant cost cap with graceful degradation
- Surface routing decisions for cost attribution and quality audit

**Non-functional (with numbers):**
- Cost reduction target: 85-98% matching flagship quality (per published FrugalGPT/RouteLLM)
- Router overhead: <50ms added latency per request (router must be cheap relative to model cost)
- Quality SLA: per-tenant configurable; default same-as-flagship within tolerance
- Cost ratio anchors: Claude Opus 4.7 vs Haiku 4.5 = 5× (input + output blended); Claude 3 Opus vs Haiku = 60× (legacy)
- Speculative decoding: 2-3× speedup typical; EAGLE-3 up to 6.5× at temp 0; acceptance rate 0.6-0.8
- MoE: DeepSeek-V3 671B total / 37B activated per token; 14,848 routed experts across 58 MoE layers, top-8 of 256 per layer

### Core entities
- **Request:** request_id, tenant_id, prompt, quality_tier (default | premium | budget), max_cost_per_request
- **RoutingDecision:** chosen_model, confidence, fallback_chain, router_version
- **RouterModel:** small classifier model (e.g., a fine-tuned BERT) producing per-model fit score
- **SpeculativeDecoderPair:** target_model_id, draft_model_id, acceptance_rate_observed
- **CostBudget:** tenant_id, period_usd_cap, consumed_usd, degradation_policy (downgrade | reject | warn)

### API
- `POST /v1/completions` body={prompt, quality_tier, max_cost} → SSE stream + routing metadata in response headers
- `POST /v1/router/feedback` body={request_id, user_satisfaction_signal} → router retraining data
- `GET /v1/tenants/:id/cost` → real-time cost vs budget for current period

### HLD
Each request hits the **router model** — a small classifier (typically fine-tuned BERT or small LLM) that produces per-model fit scores (e.g., "this request needs flagship: 0.3; mid-tier sufficient: 0.7"). The router runs in <50ms (must be cheap relative to model invocation). The **routing decision engine** combines router output with: per-tenant quality tier, per-tenant cost-cap state (if at 80% of budget, prefer cheaper), per-model availability (if flagship pool is saturated, degrade). For chosen-model = cheap, the request hits the cheap-model serving stack with **speculative decoding** enabled: a tiny draft model proposes N tokens, the cheap model verifies in parallel; accepted tokens (acceptance rate 0.6-0.8 typical) bypass the per-token cost of full decoding. For chosen-model = mid-tier or flagship, full decoding without speculation (already expensive enough that speculation overhead doesn't pay back). For escalation flow: cheap model produces full response + a verifier (separate small model or self-confidence score); if confidence < threshold, escalate to mid-tier model and re-generate. **MoE serving** is a parallel routing problem at the intra-model level: for an MoE flagship (DeepSeek-V3 class), the in-model router selects top-K experts per token; expert-placement and routing-collapse defense (auxiliary-loss-free balancing) is the *intra-model* routing infrastructure. **Cost attribution**: every routing decision emits a metering event (tenant_id, chosen_model, tokens_in, tokens_out, $-cost, speculation_speedup_used) for billing and audit.

### Deep dives
1. **Confidence-thresholded cascade (cheap → flagship escalation).** Naive approach: route every request to flagship — expensive. FrugalGPT pattern: cheap model produces output + a verifier (separate small model or the cheap model's own self-rated confidence); if verifier rejects (low confidence) or quality bar not met, escalate to mid-tier; if still low, escalate to flagship. Reported numbers: FrugalGPT achieves up to 98% cost reduction matching GPT-4 quality, or +4% accuracy at the same cost. RouteLLM: 85% cost reduction on MT-Bench, 45% on MMLU, 35% on GSM8K. Trade-off: escalation adds latency (cheap inference + verifier + flagship inference vs just flagship). The router model must be calibrated per tenant — different tenants have different quality bars. Anti-pattern: hard-coded "always route coding to flagship" — misses that 80% of coding queries are simple enough for mid-tier. Staff+ commit: router model architecture, training data (paired cheap/flagship outputs with quality labels), per-tenant calibration policy, latency-vs-cost trade-off math.

2. **Speculative decoding integration.** Decode is memory-bandwidth-bound (one token at a time); speculative decoding amortizes by having a small draft model propose N tokens in parallel, the target model verifies them in parallel (verification is a single forward pass on N tokens, which is cheap). Accepted tokens bypass per-token decode cost. Acceptance rate α typical 0.6-0.8; speedup = (1 + α + α² + ... + α^N) for N draft tokens. EAGLE pattern: draft model leverages target model's hidden states for higher acceptance (vs Medusa which uses parallel decoding heads requiring target model modification). EAGLE-3 reports up to 6.5× at temperature 0; SpecForge (Mar 2026) up to 4.48× on SGLang. Together's ATLAS adaptive speculator: continuously trains the draft model from live traffic (>400% inference speedup reported) — closes the loop on draft-target distribution drift. Staff+ commit: draft model selection (smaller version of target? distilled? EAGLE-trained?), per-workload acceptance rate monitoring, fallback to non-speculative when acceptance drops below threshold (acceptance collapse on novel domains).

3. **MoE serving as intra-model routing.** DeepSeek-V3: 671B total parameters, 37B activated per token, 58 MoE layers × 256 routed + 1 shared expert each → 14,848 routed experts across the model; router selects top-8 of 256 per token. The total model lives on GPUs (multi-GPU forced — 671B at FP16 = 1.3 TB), but only 37B of activations move through compute per token. Expert parallelism partitions experts across GPUs; every layer requires an all-to-all token dispatch collective (each token routes to its selected experts, scattered across GPUs). Routing collapse: gating network learns to send most tokens to a small subset of popular experts, leaving expert-parallel hotspots. DeepSeek's defense: auxiliary-loss-free dynamic bias adjustment — runtime bias on expert scores keeps load balanced without training-time auxiliary loss (which historically hurt quality). MoETuner reports 9.3-17.5% speedup from expert-placement optimization (co-locate frequently-co-activated experts to reduce all-to-all volume). Staff+ commit: expert parallelism degree, all-to-all bandwidth math, load-balance defense, expert placement policy.

## Known failure modes
1. **Router-model bias systematically over-escalates expensive tenants.** Router trained on one distribution but production traffic skews different — e.g., a router trained on benchmarks routes most "code" requests to flagship, but a tenant whose actual code workload is mostly trivial gets over-charged. Production answer: per-tenant calibration (track per-tenant escalation rate; if anomalously high, retrain the router on tenant-specific traffic samples); fairness audit (compare escalation rate across tenant cohorts); transparent escalation reasons surfaced to tenants for self-debugging.

2. **Speculative decoding acceptance rate drops on novel domains.** Draft model trained on a general distribution underperforms on a tenant's specialized domain (legal, medical, code) → acceptance rate falls below 0.5, speculation slows things down instead of speeding up. Production answer: per-domain draft models (route to the right draft for the workload); online acceptance-rate monitoring with fallback to non-speculative decoding when below threshold; Together ATLAS-style continuous draft model training from live traffic to adapt to drift.

3. **MoE expert load imbalance under skewed traffic.** Popular expert saturates its GPU; other experts sit idle; throughput collapses to slowest expert's rate. Production answer: auxiliary-loss-free balancing during training (DeepSeek-V3); runtime bias adjustment (push down popular experts' scores); LASER-class adaptive routing (plug-and-play inference-time routing for non-uniform distributions); expert replication for the hottest few experts (sacrifice expert-specialization for throughput).

## Notes for the coach
- **This is plausibly-asked.** Strongly motivated by FrugalGPT, RouteLLM, and the published MoE work; matches the "design cost-aware AI service" Anthropic category but not seen as a verbatim single prompt. Often shows up as a follow-up to `inference-batching-and-multi-tenant-api` or `ai-gateway-token-quota`.
- **The cost-ratio numbers (5× current, 60× legacy) are the architecture-pressure anchor.** Without quantifying the price delta, candidates underestimate the value of cascade routing. The 98%/85%/45%/35% FrugalGPT/RouteLLM numbers anchor the achievable savings.
- **Speculative decoding fluency is the inference-optimization signal.** EAGLE-3 specifically (vs Medusa) is the 2025-2026 named-technique; SpecForge is the 2026 frontier. Candidates who reach for "speculative decoding" but can't name EAGLE/Medusa or articulate acceptance-rate dynamics are at Senior bar, not Staff+.
- **MoE serving is the depth-cut for Mistral/DeepSeek-influenced labs.** If the candidate is targeting Mistral specifically or working with open-source MoE models, the MoE deep-dive carries more weight than the cascade-router deep-dive. Pick one as the primary focus per candidate signal.
- **Per-tenant cost cap with degradation policy is the production-grade move.** Without it, a single tenant's burst can blow the model-spend budget. Surface as a category-level operational gap if not addressed.

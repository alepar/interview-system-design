---
slug: moe-serving
archetype: ai-infrastructure
sources:
  deepseek_v3: arxiv.org/abs/2412.19437
  mixtral: arxiv.org/abs/2401.04088
  moetuner: arxiv.org/html/2502.06643v1
  expert_choice_gshard: arxiv.org/abs/2202.09368
---

# Mixture-of-Experts inference serving (sparse activation, expert parallelism)

## Bar anchors
- **Mid-level (L4/E4):** May not be familiar with MoE; treats all experts as live for every token. Doesn't articulate why MoE is different from dense models in serving.
- **Senior (L5/E5):** Knows MoE basics — multiple expert FFNs per layer, router selects top-K per token. Discusses expert parallelism at category level. May not address routing collapse or all-to-all bandwidth.
- **Staff+ (L6/E6+):** Drives proactively. Cites DeepSeek-V3 specifics: 671B total params, 37B activated per token, 58 MoE layers × 256 routed + 1 shared expert each = 14,848 routed experts across the model; router selects top-8 of 256 per layer. Mixtral 8x7B: 47B total / 13B activated, 8 experts per layer top-2 routing. Quantifies memory: 671B at FP16 = 1.3 TB; requires multi-GPU forced. Names expert parallelism with all-to-all collective on every layer; quantifies all-to-all bandwidth as the central bottleneck. Names routing collapse (popular experts get hot, expert-parallel hotspots) and DeepSeek's auxiliary-loss-free dynamic bias adjustment as the named defense. MoETuner reports 9.3-17.5% speedup from expert placement optimization (co-locate frequently-co-activated experts). Names MLA (DeepSeek-V3) as the KV-cache compression complement on top of MoE. Stretch (Sr Staff bar): cold expert handling (rarely-selected experts still occupy GPU memory — tier to CPU or accept the memory cost); expert replication for hot experts; hierarchical all-to-all (intra-node first, inter-node second).

## Canonical decomposition

### Requirements
**Functional:**
- Serve a frontier MoE model (DeepSeek-V3 class: 671B/37B; Mixtral class: 47B/13B; future Llama 4 hypothetical sparse)
- Per-token expert routing with top-K selection (top-8 of 256 for DeepSeek-V3)
- Load-balanced expert utilization to avoid expert-parallel hotspots
- Multi-GPU deployment forced (model weights exceed single-GPU HBM)
- KV-cache compression (MLA) to fit more concurrent requests

**Non-functional (with numbers):**
- Model size: 671B parameters (DeepSeek-V3 FP16 = 1.3 TB); ~17 H100s just to hold weights
- Per-token activation: 37B (DeepSeek-V3); 13B (Mixtral 8x7B)
- Experts per layer: 256 routed + 1 shared (DeepSeek-V3); 8 (Mixtral)
- Top-K selection: top-8 of 256 per token (DeepSeek-V3); top-2 of 8 (Mixtral)
- All-to-all per layer per token; ~58 MoE layers = 58 all-to-all collectives per token (DeepSeek-V3)
- MoETuner gains: 9.3% on 8-GPU, 17.5% on 16-GPU from expert placement
- KV-cache compression (MLA): superior to MHA at significantly reduced KV memory per request

### Core entities
- **MoEModel:** model_id, num_layers, experts_per_layer, top_k, base_params, activated_params
- **Expert:** expert_id, layer_idx, gpu_assignment, recent_token_count (load tracking)
- **Router:** per-layer gating network producing per-expert scores
- **AllToAllPlan:** layer_idx, token_dispatch_pattern, intra_node_volume, inter_node_volume
- **ExpertPlacement:** layer_idx, expert_id → gpu_id mapping; updated by MoETuner-class optimizer

### API (internal)
- Standard completions API — MoE serving is invisible to the user
- Internal: scheduler interacts with expert-parallelism layer for placement + all-to-all
- `GET /v1/moe/load` → per-expert utilization (for debugging routing collapse)
- `POST /v1/moe/rebalance` → trigger expert placement optimization

### HLD
The MoE model is partitioned across N GPUs via **expert parallelism**: each GPU holds 256/N experts per layer. The base model attention layers and shared expert use **tensor parallelism** (typical TP=8) across the same GPU group. At each MoE layer, the **router** scores all 256 experts for each token, picks top-8. An **all-to-all collective** dispatches tokens to the GPUs holding their selected experts; each expert computes its output; another all-to-all gathers results back. Continuous batching at the token level requires all-to-all per layer per token across the batch. The **expert placement optimizer** (MoETuner pattern) co-locates frequently-co-activated experts on the same GPU to reduce inter-GPU all-to-all volume — measured 9.3-17.5% speedup from this alone. The **routing collapse defense** (DeepSeek-V3 auxiliary-loss-free) applies a runtime bias to expert scores: popular experts get score penalties to push tokens to less-loaded experts; bias updated dynamically based on observed load; no training-time auxiliary loss (which historically hurt quality). For **KV cache**: MLA (Multi-head Latent Attention) stores a low-rank latent projection of K/V instead of full K/V; reconstructed at attention time; gives aggressive shrinkage at higher expressive power than GQA. **Cold expert handling**: rarely-activated experts still occupy GPU memory (DeepSeek-V3's 14,848 routed experts all live on GPU at FP16); tier to CPU memory with on-demand load on first request, or accept the memory cost as the price of model coherence.

### Deep dives
1. **Expert parallelism layout and all-to-all cost.** With 256 experts per layer and N GPUs, each GPU holds 256/N experts. Every token routed to a different GPU's experts requires an all-to-all collective. For DeepSeek-V3 (58 MoE layers × top-8 of 256 routing): every token triggers 58 all-to-all per forward pass. At decode batch size B, each all-to-all moves O(B × top_k × hidden_dim) bytes. For 8 GPUs intra-node (NVLink, ~600 GB/s aggregate), all-to-all is cheap; for 64 GPUs crossing RDMA fabric, all-to-all bandwidth becomes the dominant cost. Hierarchical all-to-all: intra-node first (reduces inter-node traffic), inter-node second. Staff+ commit: EP degree, balance against latency cost, hierarchical vs flat collective, all-to-all bandwidth budget per token.

2. **Routing strategy and collapse prevention.** DeepSeek-V3 uses top-8 of 256; Mixtral top-2 of 8. Routing collapse: gating network learns to send most tokens to a small subset of popular experts, leaving the rest idle. Training-time auxiliary loss (used in GShard, Switch) historically prevented collapse but hurt quality. DeepSeek-V3's auxiliary-loss-free dynamic bias: maintain a per-expert load counter; apply runtime bias to expert scores favoring under-loaded experts; bias updated continuously; no quality cost. Expert Choice routing (Zhou et al.) is an alternative: instead of tokens choosing experts, experts choose tokens — guarantees balanced load by construction. LASER (plug-and-play inference-time routing for non-uniform distributions) is another 2025+ option. Staff+ commit: which routing technique, why (training-time vs runtime balancing, quality vs simplicity trade-off).

3. **Expert placement optimization (MoETuner).** With 256 experts per layer across N GPUs, the placement choice (which experts on which GPUs) determines the all-to-all volume. Frequently-co-activated experts (those that often appear in the same top-K together) should live on the same GPU to reduce inter-GPU traffic. MoETuner uses routing-aware clustering to optimize placement: measures co-activation frequency from production traffic, groups co-activated experts onto same GPU, reports 9.3% speedup on 8-GPU, 17.5% on 16-GPU. Trade-off: static placement is simpler operationally; dynamic re-placement adapts to traffic shifts but requires expert weight migration (non-trivial cost). Staff+ commit: placement strategy (static post-deploy vs periodic dynamic), co-activation measurement methodology, migration cost vs benefit trade-off.

## Known failure modes
1. **Routing collapse → expert hotspot.** A few popular experts get most tokens, their GPU saturates while others sit idle; throughput collapses to the slowest expert's rate. Production answer: training-time auxiliary loss (prevent at train time) OR runtime bias adjustment (auxiliary-loss-free, DeepSeek-V3) OR expert replication for the hottest few experts (trade specialization for throughput) OR Expert Choice routing (balance by construction).

2. **All-to-all bandwidth saturation.** With 64+ GPUs and a 70B+ MoE, all-to-all becomes the dominant cost; per-token latency dominated by inter-GPU communication rather than compute. Production answer: hierarchical all-to-all (intra-node NVLink first, inter-node RDMA second); expert placement optimization (MoETuner to co-locate co-activated); reduce token dispatch volume (smaller top_k if quality allows); larger batch size to amortize per-all-to-all overhead.

3. **Cold start on model deploy.** A new MoE model deployment requires loading 1.3 TB of weights (DeepSeek-V3 FP16) across the cluster — minutes to tens of minutes. Production answer: pre-warm all experts before flipping traffic; staged rollout (warm new model in parallel with old; flip traffic once warm); weight-sharding-aware deploy primitive that knows MoE's expert-parallel structure; for rapid iteration on routing layer changes, keep base experts warm and reload only the router.

## Notes for the coach
- **This is plausibly-asked at Mistral specifically** (they pioneered open-source MoE with Mixtral) and at any lab serving DeepSeek-V3 derivatives or training their own sparse models. "Design a serving stack for DeepSeek-V3 / Mixtral" is the natural framing.
- **The 671B/37B math is the scale anchor.** A candidate who can articulate "671B on GPU but only 37B activated per token" demonstrates MoE-specific literacy that distinguishes from generic dense-model serving.
- **Routing collapse is the canonical MoE failure mode.** Candidates who don't surface it are missing the central design pressure. The DeepSeek-V3 auxiliary-loss-free dynamic bias is the named 2024+ solution.
- **MoETuner expert-placement gains (9.3-17.5%) are the operational-depth signal.** Candidates who reach for expert placement optimization unprompted demonstrate Staff+ depth.
- **The MLA-on-top-of-MoE compounding is the L7 stretch move.** DeepSeek-V3 combines MoE (compute sparsity) + MLA (KV-cache compression) for the full cost-reduction stack. Naming both unprompted is the Sr Staff differentiator.

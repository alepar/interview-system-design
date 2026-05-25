---
slug: instagram-reels-ranking
archetype: ml-in-loop
sources:
  meta_explore_2023: engineering.fb.com/2023/08/09/ml-applications/scaling-instagram-explore-recommendations-system/
  meta_1000_models_2025: engineering.fb.com/2025/05/21/production-engineering/journey-to-1000-models-scaling-instagrams-recommendation-system/
  meta_adaptive_ranking_2026: engineering.fb.com/2026/03/31/ml-applications/meta-adaptive-ranking-model
---

# Instagram Reels ranking — 4-stage funnel + request-oriented optimization + value-model scalarization

## Bar anchors
- **Mid-level (L4/E4):** Treats Reels as "rank candidates by engagement score." No funnel structure; no position-bias awareness.
- **Senior (L5/E5):** Names multi-stage funnel + multi-task heads. Discusses re-ranking for diversity. May or may not address Meta's Adaptive Ranking Model request-oriented optimization or the first-stage-distilled-from-second-stage trick.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **sequential single-item-per-decision** consumption pattern (every prediction is also an exposure; extreme position bias). Names the **4-stage funnel**: retrieval → first-stage lightweight ranker → heavy ranker → re-ranking (narrowing billions → hundreds). Names **first-stage two-tower distilled from second-stage MTML** (student trained to mimic teacher's logits). Cites **value-model linear scalarization** `EV = W_click·P(click) + W_like·P(like) - W_see_less·P(see_less) + ...` blending multi-task heads. Cites **Meta's Adaptive Ranking Model** (Mar 2026): request-oriented computation shares user-request embeddings across thousands of candidates, changing cost from `O(N_candidates × user_tower)` to `O(N_candidates × MLP_top + 1 × user_tower)`; delivered +3% conversions / +5% CTR on Instagram Q4 2025 launch. Names **on-device candidate gen** for in-session interest (recent dwell signal). Stretch (Sr Staff bar): articulates **per-model stability signal** combining calibration (predicted/empirical CTR ratio) + normalized entropy.

## Canonical decomposition

### Requirements
**Functional:**
- Sequential single-item-per-decision feed (Reels For-You)
- Multi-task heads: long-watch, like, share, comment, follow, skip, not-interested, report
- Re-ranking for diversity, near-duplicate suppression, safety, contractual constraints
- On-device + server-side hybrid candidate gen

**Non-functional (with numbers):**
- ~500M Instagram DAU; Reels serves tens of billions of impressions/day
- Per-request: ~hundreds of candidates from ~10 sources → ~100 with first-stage → ~10-25 visible
- Total session opener ≤300ms (p99 ≤500ms); ranking inference ~30-60ms on GPU/AI-accelerator
- Instagram operates >1,000 ML models; >10 launches/week post-automation
- Value-model weight tuning: 1 month (Bayesian opt) → hours (offline tuning)
- Meta ARM Q4 2025 launch: +3% conversions, +5% CTR

### Core entities
- **User session sequence:** last 100-1000 actions (watch, like, share, skip, not-interested)
- **Candidate Reel:** video_id, creator, content embeddings, recency, eligibility flags
- **MTML head outputs:** {P(long_watch), P(like), P(share), P(comment), P(follow), P(skip), P(not_interested), P(report)}
- **Value model:** linear blend weights per user segment (offline-tuned)

### API
- `GET /reels/for_you?user_id=X&session_state=Y` → ordered Reel candidates
- Internal: retrieval.fetch(user_features) → ~hundreds; first_stage.score(...) → ~100; heavy_ranker.score_mtml(...) → MTML probabilities; re_ranker.apply_constraints(...)

### HLD
**Retrieval layer** pulls ~hundreds of candidates from ~10 sources (two-tower CF, recent-watch sequence, hashtag/topic, creator-following, exploration pool). **First-stage two-tower** (cheap, distilled from second-stage logits) narrows to ~100. **Heavy MTML ranker** (DLRM-class with sequence transformer over user-action sequence) emits per-engagement probabilities. **Value model** scalarizes into single score. **Re-ranking** applies diversity (DPP, MMR), near-duplicate suppression, safety filters, contractual constraints (e.g., paid-promotion pacing). **Meta ARM** pattern: compute user-sequence embedding once per request; cross-attend with each candidate (vs naive: recompute user representation per candidate). **On-device candidate gen** for in-session interest signals (recent dwell) avoids one round-trip per scroll.

### Deep dives
1. **Multi-stage funnel with distillation.** Retrieval → first-stage → heavy → re-rank. First-stage is **trained on heavy-ranker logits** (distillation) so it can be a cheap two-tower while still reflecting the heavy ranker's preferences. Staff+ commit: explain why this works (knowledge transfer) and the failure mode (calibration regression in heavy propagates upstream silently).

2. **Request-oriented optimization (Meta ARM).** Naive ranking: compute user_tower(user) for each candidate = O(N_candidates × user_tower_cost). ARM: compute user-sequence embedding once per request; cross-attend with each candidate via MLP top = O(N_candidates × MLP_top + 1 × user_tower). For long sequences (100-1000 actions) + heavy user-tower, this is a 10-100× cost reduction at the same model capacity. Per Meta: enabled scaling to LLM-scale ad ranking models at O(100ms) bounded inference.

3. **Value-model scalarization + survey weights.** `EV = Σ w_k · P(action_k) - Σ w'_k · P(neg_action_k)`. Positive actions: click, like, share, comment, follow, long-watch. Negative: skip, not-interested, report, see-less. **Survey weights**: small but pivotal labeled samples re-weight implicit signals (Meta's published countermeasure against engagement-bait). Weight tuning collapsed from >1 month (Bayesian opt) to hours (offline tuning).

## Known failure modes
1. **Distillation skew between stages.** Heavy ranker's calibration regresses; first-stage was distilled from old heavy logits; first-stage now filters from corrupted teacher signal. Production answer: regression-test calibration of every distilled-from model; alert on training-target distribution shift; periodic full retrain of student.

2. **Per-model stability across 1,000+ models.** Per Meta May 2025: `model_stability = 1` only if all underlying predictions are stable. One degraded model silently corrupts downstream value-model weight tune. Production answer: per-prediction stability monitors combining calibration + normalized entropy; auto-rollback gates on stability regression.

3. **Position-bias leakage into labels.** Top positions get more impressions regardless of relevance; clicks confounded with position. Production answer: IPS reweighting in training; position-as-feature with serving-time zeroing (PAL pattern).

## Notes for the coach
- **Asked-confirmed at Meta** (Instagram Reels, Facebook Watch). Meta Engineering blog series is explicit interview-prep canon.
- **The Adaptive Ranking Model request-oriented optimization is the 2026 frontier deep-cut.** Candidates who name it demonstrate Meta-blog literacy post-March 2026.
- **The value-model scalarization with survey weights is the multi-objective unlock.** Senior candidates miss the survey-weighted-labels mechanism; Staff+ candidates name it as Meta's explicit anti-clickbait countermeasure.
- **Adversarial probe: "you have 1000 ranking models in production — what catches a 1% calibration regression in one model before it ships?"** Strong answer: per-model stability signal (calibration + normalized entropy), auto-rollback in 30-60s on stability breach. Weak answer: "we monitor everything" without the specific signal definition.

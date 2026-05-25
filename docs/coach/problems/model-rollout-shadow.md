---
slug: model-rollout-shadow
archetype: ml-in-loop
sources:
  marktechpost_strategies: marktechpost.com/2026/03/21/safely-deploying-ml-models-to-production-four-controlled-strategies-a-b-canary-interleaved-shadow-testing/
  qwak_shadow_canary: qwak.com/post/shadow-deployment-vs-canary-release-of-machine-learning-models
  evidently_drift: evidentlyai.com/ml-in-production/data-drift
  oneuptime_rollback_2026: oneuptime.com/blog/post/2026-01-30-mlops-model-rollback/view
  mab_arxiv: arxiv.org/abs/2503.22595 (MAB for ML Model Deployment)
  linkedin_proml: linkedin.com/pulse/introducing-pro-ml-linkedins-architecture-enabling-scale-rodriguez
  airbnb_bighead: medium.com/acing-ai/airbnbs-end-to-end-ml-platform-8f9cb8ba71d8
---

# ML model rollout — shadow → canary → A/B → champion-challenger + three drift signals + auto-rollback + Thompson-sampling bandits

## Bar anchors
- **Mid-level (L4/E4):** "Deploy model to production." No staged rollout; no drift signals; no rollback strategy.
- **Senior (L5/E5):** Names canary + A/B + rollback. Discusses monitoring. May or may not articulate shadow mode, distinction between canary and A/B, three drift signals, or champion-challenger steady state.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **ML deployment is NOT software deployment** — "the service is healthy and the model is wrong" is the dominant failure mode; rollout requires its own observability beyond standard SRE metrics. Names **shadow mode** mirrors 100% production requests to challenger model whose responses are logged but discarded; zero user impact. Names **canary vs A/B distinction**: canary routes by user (stable cohort, gradually 1% → 5% → 25% → 100%); A/B routes by request, statistically designed to estimate treatment effects. Articulates **full safe-rollout sequence at maturity**: offline gating → shadow validate on live traffic → canary with auto-rollback → randomized A/B for statistical lift → champion-challenger steady state with drift monitoring. Names **three drift signals** monitored independently: feature drift (input distribution; KS/PSI), prediction drift (output distribution — best label-free proxy), concept drift (P(y|x) change; requires labels; slowest to detect). Cites **automated rollback within 30-60s** of sustained SLO breach (p99 latency, error-rate spike, accuracy proxy drop, business KPI burn rate). Names **Thompson-sampling bandits** for model selection — routes traffic proportionally to posterior win-probability, cuts time-to-decision and exposure to underperformers vs equal-split A/B. Cites reference stacks: **KServe/Seldon on Kubernetes** with native canary/A/B/shadow primitives; **LinkedIn Pro-ML** (Quasar + Feathr); **Airbnb Bighead** (Deep Thought Kubernetes + Zipline/Chronon on Spark). Stretch (Sr Staff bar): articulates **slice-based canary** (route 1% by deliberately-chosen cohorts not random — random 1% can systematically miss most-impacted slice).

## Canonical decomposition

### Requirements
**Functional:**
- Shadow mode for validation without user impact
- Slice-based canary with gradual traffic ramp
- A/B with statistical power calc for ranking lift
- Champion-challenger steady-state with continuous monitoring
- Auto-rollback on SLO breach in 30-60s
- Three drift signals (feature, prediction, concept) with independent alerts

**Non-functional (with numbers):**
- Auto-rollback within 30-60s on sustained SLO breach
- Instagram launch cadence: days → hours via automation; >10 launches/week post-Meta automation
- Stripe Radar: hundreds of submodels retrained daily
- Shadow doubles inference cost during validation; budget-conscious platforms sample

### Core entities
- **Model registry:** immutable digest-pinned versions
- **Rollout state machine:** {offline → shadow → canary_1pct → canary_5pct → canary_25pct → A/B → full → champion}
- **Drift monitor:** per-feature KS/PSI; per-prediction distribution; per-label slice
- **Auto-rollback rules:** SLO breach thresholds + sustained-breach windows + cooldown
- **Champion-challenger pool:** current production + N candidates in shadow

### API
- `model_registry.register(model_artifact, version) → digest`
- `rollout.start(model_digest, strategy=shadow|canary|ab|champion_challenger, slice=...)`
- `drift_monitor.alert(feature|prediction|concept, threshold)`
- `auto_rollback.trigger(rollout_id, reason)`

### HLD
**Model registry** stores immutable digest-pinned model versions + metadata + lineage. **Rollout orchestrator** moves model through state machine: offline gating (validation suite passes) → **shadow** (100% of production requests mirrored to challenger; predictions logged + compared to champion; zero user impact) → **canary** (slice-based: 1% by deliberately-chosen cohorts, then 5%, 25%, 50%, 100% with auto-rollback gates between steps) → **A/B** (random request-level assignment; statistical design; power calc upfront) → **champion-challenger steady state** (continuous monitoring with challengers in parallel). **Three drift monitors** run independently: feature drift (KS test on continuous features; PSI on categorical); prediction drift (output distribution KL divergence vs champion — best label-free proxy); concept drift (P(y|x) change; requires labels; slowest to detect). **Auto-rollback triggers** off sustained SLO breach (30-60s threshold): p99 latency, error-rate spike, accuracy proxy drop, business KPI burn rate. **Rollback as flag flip not redeploy**: separated policy-from-binary; pinned digests in serving config; flip atomic across replicas. **Multi-armed-bandit (Thompson sampling) for model selection** as alternative to static A/B: route traffic proportionally to posterior win-probability; cuts time-to-decision and exposure to underperformers.

### Deep dives
1. **Shadow → canary → A/B → champion-challenger sequence.** **Shadow**: 100% mirrored traffic; challenger logs discarded; zero impact; validates model in real-world load (catches infra issues — OOMs, latency spikes — that staging missed). **Canary**: cohort-stable shift 1% → 5% → 25% → 100%; per-step auto-rollback gates on metrics; **slice-based** (route by chosen cohorts not random — random 1% misses tail). **A/B**: random request-level assignment; statistical design (power calc, fixed sample size); measures lift on business metrics. **Champion-challenger steady state**: current production = champion; periodic candidates = challengers; small % traffic to each challenger; promote on sustained lift. **Full sequence**: offline gating → shadow → canary → A/B → champion-challenger + drift monitoring.

2. **Three drift signals + auto-rollback.** **Feature drift**: input distribution change (KS test on continuous, PSI on categorical). **Prediction drift**: model output distribution change — best label-free proxy because labels often delayed. **Concept drift**: P(y|x) change — requires labels; slowest to detect. **Rollback triggers**: p99 latency exceeds threshold; error-rate spike; accuracy proxy drop; business KPI burn rate. Default to rollback when guardrails trip [OneUptime 2026]. **Sustained-breach requirement** (e.g., 30-60s) before fire to avoid thrashing on transient spikes. **Auto-retraining**: triggered by event (drift detected via TFDV statistics comparison) or schedule (cron); Kubeflow Pipelines orchestrates.

3. **Thompson-sampling bandits for model selection + reference stacks.** Static A/B: equal split until N samples; expose users to underperformer regardless. **Thompson sampling**: sample from posterior over per-model rewards; route traffic to model with highest sample. Equivalent to gradually shifting traffic to winning model. Cuts both time-to-decision and exposure to underperformers [arXiv:2503.22595]. **Reference stacks**: KServe/Seldon on Kubernetes (native canary/A/B/shadow/inference-graph primitives); TFX + Vertex AI Pipelines orchestrate train → validate → deploy with auto-rollback. **LinkedIn Pro-ML**: Quasar execution engine on TF-Serving/XGBoost + central deployment service bundling features/libraries/code for validated rollout; Feathr for PIT-correct feature joins. **Airbnb Bighead**: Deep Thought (Kubernetes-served Docker containers with serialized BigHead pipelines wrapped in Java REST) + Zipline/Chronon for features on Spark.

## Known failure modes
1. **Shadow mode infra issues silent.** Shadow model OOMs or has latency spikes but production is fine because shadow responses discarded; only catch shadow issues with explicit shadow-specific monitoring. Production answer: shadow models get full observability stack same as production; alert on shadow-vs-production divergence in latency / error-rate.

2. **Canary cohort non-representative.** Random 1% may systematically miss the most-impacted slice (e.g., specific country, device class). Production answer: slice-based canary — explicitly route 1% by deliberately-chosen cohorts; per-cohort metrics; detect regressions invisible in global averages.

3. **Auto-rollback false positives.** Transient latency spike triggers rollback; thrashes between models. Production answer: sustained breach requirement (e.g., 30s of breach before rollback fires); explicit hysteresis; rollback rate-limiting (max 1 per N minutes).

4. **Rollback delayed by training-data contamination.** Bad champion's outputs were used as features in downstream models; rolling back model doesn't roll back training data. Production answer: temporal rollback — evict contaminated training windows; retrain downstream models from clean data.

5. **Champion-challenger drift.** Challenger "wins" in single A/B but fails to maintain lift in steady-state due to environmental change. Production answer: champion-challenger is steady-state monitoring (not one-time A/B); promote requires sustained lift over window; periodic re-evaluation of past promotions.

6. **Cost blowup** if shadow runs 100% of traffic on expensive models. Production answer: sample-based shadow (10% mirror) for expensive models; full shadow only for cheap models.

## Notes for the coach
- **Asked-confirmed at every ML-heavy shop (LinkedIn, Airbnb, Stripe, PayPal, Meta, Google, Uber).** Chip Huyen's book + LinkedIn Pro-ML + Airbnb Bighead + Stripe Radar blogs — all explicit interview-prep canon.
- **The "ML deployment is not software deployment" framing is the canonical Staff+ unlock.** Candidates who articulate "the service is healthy and the model is wrong" as the dominant failure mode demonstrate ML-production sophistication.
- **The shadow vs canary distinction is the depth probe.** Mid-senior candidates conflate them; Staff+ candidates name shadow (mirrored + discarded, validates infra) vs canary (cohort-stable gradual ramp with user impact).
- **The slice-based canary is the deep-cut.** Random 1% systematically misses the most-impacted cohort; explicit slice routing catches what averages miss.
- **Adversarial probe: "your model has been champion for 6 months — it's stable; do you still need monitoring?"** Strong answer: yes — concept drift accrues over time even without code changes; environmental shift (user behavior, content distribution) silently degrades model; champion-challenger steady-state with periodic challenger evaluation catches drift before user-visible regression. Weak answer: "if it's working, leave it alone" — Staff+ failure.

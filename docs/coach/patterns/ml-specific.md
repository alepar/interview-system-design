# ML-Specific Patterns

Source: `staff-engineer-study-guide.md`.

## Two-Tower / Dual-Encoder Retrieval

**Definition.** A two-tower model encodes queries and items into a shared embedding space with separate neural networks (towers), enabling approximate nearest-neighbor (ANN) search at retrieval time rather than exhaustive cross-attention scoring.

**Canonical use.** Use a two-tower model as the first retrieval stage in a recommendation or search funnel to reduce billions of candidates to thousands in milliseconds, then pass those to a heavier ranker.

**Production systems.** Google YouTube (two-tower for candidate generation), Meta FAISS + two-tower for content retrieval.

**Alternatives.** BM25 / TF-IDF lexical retrieval (no training required, poor semantic recall); sparse + dense hybrid retrieval (combines BM25 and two-tower scores).

## Multi-Stage Ranking Funnel

**Definition.** A multi-stage funnel progressively narrows a candidate set through stages of increasing model complexity and cost: candidate generation (ANN retrieval, millions → thousands) → light ranking (fast linear/tree model, thousands → hundreds) → heavy ranking (deep model, hundreds → tens) → re-ranking (business rules + diversity filters, tens → final list).

**Canonical use.** Apply a multi-stage funnel to meet strict latency SLOs: each stage prunes enough candidates that the next stage's expensive model stays within budget.

**Production systems.** Google Search (multi-stage ranking pipeline), Amazon product recommendations (candidate generation + XGBoost ranker + DNN re-ranker).

**Alternatives.** Single-stage heavy ranker (simpler, feasible at small catalog scale); cascade ranking with early-exit (similar but exits on confidence threshold rather than fixed cutoffs).

## Feature Store

**Definition.** A feature store is a centralized repository that serves precomputed features to both model training (offline, batch, high-throughput) and model inference (online, low-latency), with tooling to prevent training-serving skew between the two paths.

**Canonical use.** Use a feature store to ensure the feature values seen during training are identical to those served at inference time, and to share expensive-to-compute features (e.g., user embeddings) across multiple models.

**Production systems.** Feast (open-source, supports Redis online store + S3/BigQuery offline), Tecton (managed feature platform used at major US banks and tech companies).

**Alternatives.** Ad-hoc feature pipelines per model (fast to build, leads to skew and duplication); Vertex AI Feature Store / SageMaker Feature Store (managed cloud-native options).

## Model Registry, Versioning, Shadow Deployment, and Canary

**Definition.** A model registry stores versioned model artifacts with metadata (metrics, lineage, approval status); shadow deployment runs a new model on live traffic without serving its predictions (for offline comparison); canary routes a small live traffic fraction to the new model.

**Canonical use.** Gate promotion from shadow → canary → full production on both offline metric thresholds (AUC, NDCG) and online metric guardrails (CTR, latency p99), with automatic rollback on degradation.

**Production systems.** MLflow Model Registry (open-source, tracks experiments + model versions), SageMaker Model Registry + Deployment (managed shadow + canary).

**Alternatives.** Manual model versioning in S3/GCS with no registry (brittle, no lineage); Kubeflow Pipelines (CI/CD for models, integrates with KFServing for canary).

## Offline Metrics vs Online Metrics and A/B Testing

**Definition.** Offline metrics (AUC-ROC, NDCG, Recall@K, MAP) evaluate model quality on held-out data; online metrics (CTR, watch time, revenue, DAU) measure real user behavior; A/B testing randomly assigns users to variants to establish causal impact of the model change.

**Canonical use.** Treat offline metric improvement as a necessary but not sufficient condition for shipping: always run an A/B test to confirm the offline gain translates to an online business metric lift.

**Production systems.** Netflix Experimentation Platform (A/B at scale), Google Ads A/B + interleaving experiments (ranking comparison without splitting traffic).

**Alternatives.** Interleaved experiments (faster than A/B for ranking, mixes results from two rankers in the same list); bandit algorithms (online exploration-exploitation, no fixed hold-out period).

## Concept Drift, Data Drift, and PSI/KL Monitoring

**Definition.** Data drift is a shift in the distribution of input features over time; concept drift is a shift in the relationship between features and labels; Population Stability Index (PSI) and KL divergence are scalar statistics that quantify distribution shift between a reference window and the current window.

**Canonical use.** Compute PSI on key input features and prediction score distributions on a rolling basis, triggering a retraining alert when PSI > 0.2 (conventional "significant shift" threshold).

**Production systems.** Evidently AI (open-source drift monitoring dashboards), Arize AI / WhyLabs (managed ML observability with drift alerts).

**Alternatives.** Kolmogorov-Smirnov test (statistical significance instead of scalar magnitude); model performance monitoring (direct metric degradation — catches drift only after harm, but more actionable).

## Online Learning vs Batch Retraining Cadence

**Definition.** Online learning updates model parameters incrementally with each new example (or mini-batch) in near-real time; batch retraining periodically retrains from scratch or fine-tunes on a recent data window on a fixed schedule (hourly, daily, weekly).

**Canonical use.** Use online learning for signals with rapid distribution shift (e.g., trending news, real-time ad CTR feedback); use daily batch retraining when training cost is high and model staleness tolerance is measured in hours rather than minutes.

**Production systems.** Twitter/X Timelines (online feature updates to embedding models), Google Smart Bidding (continuous batch retraining with warm-start from prior model).

**Alternatives.** Triggered retraining on drift detection (combines benefits of both — retrain only when needed); continual learning / EWC (prevents catastrophic forgetting during incremental updates).

## Cold Start

**Definition.** Cold start is the problem of generating useful recommendations for new users (no interaction history) or new items (no engagement signal), requiring fallback strategies that do not rely on collaborative filtering.

**Canonical use.** Layer fallbacks in order: content-based features (item metadata) → popularity prior (top-N globally or by segment) → heuristic rules (geo, time-of-day) — switching to collaborative signals as soon as sufficient interaction data accumulates.

**Production systems.** Spotify (content features + editorial playlists for new-item cold start), TikTok (fast item warm-up via small forced-exploration traffic pool).

**Alternatives.** Onboarding flow to elicit explicit preferences (reduces cold start at cost of friction); cross-domain transfer (use signals from a related domain with history).

## LLM Serving: KV Cache, Speculative Decoding, RAG, Prompt Caching

**Definition.** LLM serving optimizations include KV cache (stores computed key-value attention tensors across tokens to avoid recomputation), speculative decoding (a small draft model proposes tokens verified in parallel by the large model), RAG (Retrieval-Augmented Generation retrieves relevant documents into the context window at inference time), and prompt caching (reuses KV cache for a static prompt prefix shared across requests).

**Canonical use.** Apply prompt caching for high-traffic endpoints with a fixed system prompt (e.g., customer support bots) to reduce time-to-first-token and compute cost; use RAG when the LLM needs up-to-date or private knowledge that cannot be baked into weights.

**Production systems.** vLLM (PagedAttention for efficient KV cache management), Anthropic Prompt Caching (API-level prefix caching), Pinecone + LlamaIndex (vector DB + RAG orchestration).

**Alternatives.** Fine-tuning (bakes knowledge into weights, no retrieval latency, but costly to update); long-context models (avoids RAG chunking, but expensive and hits context limits).

## Always-On Low-Power Wake / Detection

**Definition.** A dedicated low-power coprocessor (Apple AOP "Always On Processor", Google Tensor low-power island, Qualcomm aDSP) continuously runs a tiny model (~100KB-few MB) to gate the high-power compute path; only on positive detection does the main AP wake to run a heavier second-pass model. A temporal integrator across short audio/sensor frames produces the gating confidence.

**Canonical use.** Use an AOP-resident tier-0 detector for wake-word, geofence, screen-off voice activity, or motion-class triggers when the main SoC's idle power would dominate battery — the coprocessor stays on continuously while the AP sleeps.

**Production systems.** Apple Hey Siri (AOP DNN on 0.2s frames → temporal integrator → main-AP second-pass), Google Pixel Voice on Tensor low-power island, Qualcomm aDSP wake-word on Android.

**Alternatives.** Main-AP always-on (simpler, battery-prohibitive); cloud-only wake detection (privacy-prohibitive — would stream mic 24/7); single-stage on-device detector (higher false-accept rate without temporal integration).

## On-Device Cascade with Cloud Escalation

**Definition.** Inference is tiered: tier-0 (~10-100MB on-device) handles common cases at <100ms with no network; tier-1 (medium on-device, e.g., distilled student model) handles borderline cases; tier-2 (large cloud model) is invoked only when tier-0/1 confidence falls below threshold. Each tier has its own latency budget and confidence-gated handoff.

**Canonical use.** Use a cascade when the head of the query distribution is dispatched by simple intents (timer, music) that a small model handles offline, but the long tail (open-ended Q&A, multi-turn reasoning) requires a cloud LLM — minimizes cloud spend and tolerates network loss.

**Production systems.** Apple Siri (on-device NLU + Private Cloud Compute escalation), Google Assistant (Gemini Nano on Pixel + cloud Gemini), Amazon Alexa (on-device wake + cloud ASR/NLU), Alexa Teacher Model distillation (700M-9.3B teacher → 17M-170M production student on-device).

**Alternatives.** Pure cloud inference (latency- and offline-prohibitive); pure on-device (accuracy ceiling on long tail, no model upgrades without OTA); router-only architectures with no on-device tier-0 (loses offline operation).

## Safety-Critical Dual-SoC Redundancy

**Definition.** Two independently developed inference stacks (often on physically distinct SoCs, sometimes different silicon vendors) run in parallel and cross-check outputs; on disagreement or single-channel failure, the system enters a fail-operational degraded mode rather than a fail-safe shutdown. ISO 26262 ASIL-D is typically achieved by decomposing into two ASIL-B channels with design diversity at compute, network, and power layers.

**Canonical use.** Apply dual-SoC redundancy for L4 autonomy and other fail-operational obligations where "shut down" is not a safe state (a vehicle at 120 km/h must continue safe control until pulled over) — cross-check perception and planning outputs each cycle, declare per-channel health, gracefully degrade on partial failure.

**Production systems.** Tesla FSD HW3/HW4 (dual-SoC cross-check, ~36-72 / 50-280 TOPS), NVIDIA DRIVE AGX Pegasus/Thor (2,000 TFLOPS + ASIL-D with lockstep safety cores), Waymo 6th-gen Driver (redundant compute + sensors), aerospace flight-control triple-modular redundancy (analogous pattern).

**Alternatives.** Single-SoC fail-safe shutdown (acceptable for L2 driver-assist where the human is the fallback, not L4); lockstep cores on a single chip (cheaper, but shared-fault domain — common-cause failures not mitigated); software-only diversity on identical hardware (no protection against hardware fault).

## Sensor Fusion + Physics-Bounded Latency Budget

**Definition.** Synchronized multi-modal sensor streams (cameras, lidar, radar, IMU, audio) are fused either early (raw/feature-level fusion via Kalman filtering, particle filters, or learned fusion networks before model inference) or late (independent per-sensor models combined at decision level); the entire perception → prediction → planning → control loop is allocated a hard end-to-end latency budget derived from physics (e.g., 3.3m unactuated travel per 100ms at 120 km/h), with each stage given a sub-budget.

**Canonical use.** Use early fusion when cross-sensor correlations carry signal (lidar depth + camera texture jointly resolve occlusions that either sensor alone cannot); allocate the latency budget top-down from the physics envelope, sizing models so the deepest acceptable network still fits the per-stage slice at the control-loop rate (10-20 Hz typical, up to 100 Hz+ for inner control).

**Production systems.** Tesla HydraNet (shared backbone + ~50 task heads amortizing compute across 8-camera input) + Occupancy Network (~10ms on FSD chip), Waymo (13 cameras + 4 lidars + 6 radars, no single-sensor priority — AI merges all available data when sensors disagree), NVIDIA DRIVE sensor-fusion stack.

**Alternatives.** Late fusion of independent per-sensor models (simpler to develop and validate per modality, loses cross-sensor correlations); single-modality perception (e.g., vision-only Tesla bet — viable at L2 with fleet-scale data, contested at L4); soft-real-time best-effort latency (acceptable for advisory systems, not safety control loops).

# ML-Specific Patterns

Pattern reference for `/study-patterns 3M`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3M.

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

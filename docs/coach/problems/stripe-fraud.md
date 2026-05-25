---
slug: stripe-fraud
archetype: ml-in-loop
sources:
  stripe_guides_ml_fraud: stripe.com/resources/more/how-machine-learning-works-for-payment-fraud-detection-and-prevention
  bytebytego_stripe_fraud: blog.bytebytego.com/p/how-stripe-detects-fraudulent-transactions
  stripe_annual_letter_2025: Stripe 2025 Annual Letter (Feb 2026) — $1.9T payment volume
  paypal_quokka: medium.com/paypal-tech/machine-learning-model-ci-cd-and-shadow-platform-8c4f44998c78
  korycki_adversarial_drift: arxiv.org/abs/2009.09497 (Korycki & Krawczyk "Adversarial Concept Drift Detection" 2020)
---

# Stripe Radar payment fraud — sub-100ms decision + 1000+ features / 3-5 online lookups + ResNeXt-DNN + chargeback labels + shadow-mode rollout

## Bar anchors
- **Mid-level (L4/E4):** "XGBoost on transaction features." No latency budget; no adversarial-drift handling; no per-merchant calibration.
- **Senior (L5/E5):** Names ML scoring + chargeback labels. May or may not address sub-100ms latency budget breakdown, embedding-based cross-merchant transfer, fraud-ring detection, or shadow-mode protocol.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **adversarial sub-100ms ML** with extreme class imbalance (~1/1000) and rapidly-evolving label distributions. Per ByteByteGo: "online payment fraud occurs in roughly 1 out of every 1,000 transactions." Cites **latency budget**: 1-2ms model inference + 98ms feature collection; at 2-5ms per RPC feature fetch, **3-5 online lookups** per transaction even though model uses 1000+ features. Names **2022 Wide&Deep → ResNeXt-DNN migration**: pure DNN inspired by ResNeXt (Network-in-Neuron multi-branch); cut training time **85% to <2 hours** because XGBoost "was hard to parallelize, which meant retraining the combined model was slow. It was incompatible with advanced ML techniques like transfer learning... and embeddings." Names **2025 Payments Foundation Model**: transformer pre-trained on billions of charges (charge = token; user history = context); on large-merchant card-testing **detection 59% → 97%** overnight with no false-positive increase. Cites **embeddings enable cross-geo transfer** (Brazil pattern → US without retraining). Cites **chargeback labels** automatic and cost-free from payment flow itself. Names **shadow-mode** (PayPal calls theirs Quokka). Cites **per-merchant calibrated precision-recall** (thin-margin food delivery aggressive blocking; high-margin SaaS tolerates more fraud). Stretch (Sr Staff bar): cites Stripe 2025 Annual Letter: **$1.9T total payment volume in 2025**, up 34% from $1.4T in 2024.

## Canonical decomposition

### Requirements
**Functional:**
- Per-transaction fraud score within <100ms of authorization request
- Score + reason codes + human-review queue routing
- Continuous retrain to adapt to adversarial drift
- Per-merchant precision-recall threshold tuning
- Fraud-ring detection across accounts

**Non-functional (with numbers):**
- $1.9T total payment volume in 2025 (up 34% from $1.4T in 2024) per Stripe 2025 Annual Letter
- ~1/1000 fraud base rate
- <100ms decision latency p99
- 1-2ms model inference; 98ms feature collection; 2-5ms per RPC feature fetch
- Stripe Radar retrain cadence tripled post-ResNeXt migration (XGBoost was bottleneck)
- Payments Foundation Model: 59% → 97% card-testing detection on large merchants
- 92% of Stripe-network cards seen before per Stripe Radar

### Core entities
- **Transaction:** card, merchant, amount, currency, location, device fingerprint, BIN, browser signals
- **Features:** velocity (last-1-min, last-1-hour, last-24-hour windows), aggregate spend patterns, embedding lookups (cross-merchant card embeddings, device-graph features, BIN risk)
- **Account-pair edges:** (account_A, account_B, shared_card, shared_BIN, shared_device, similar_text) for fraud-ring detection
- **Decision:** score + reason codes (route to allow / block / step-up auth / human review)

### API
- `POST /authorize` body=transaction → fraud verdict within 100ms
- Internal: feature_store.fetch(transaction.entity_ids) → 3-5 freshest signals; model.score(features) → P(fraud) within 1-2ms; threshold.classify(score, merchant) → decision

### HLD
**API edge** receives authorization request. **Feature collection** in parallel: precomputed offline features (account age, lifetime spend velocity, network embeddings) from feature store + streaming velocity features (last-N-min counters from Kafka → Flink → online store updated <200ms). **3-5 online lookups** per transaction capped by latency budget. **Model inference** (1-2ms): pure ResNeXt-DNN (post-2022 migration) over feature vector; emits P(fraud) + reason codes. **Decision routing**: threshold per-merchant tuned for FP-rate target. Below threshold → allow; above → block; gray zone → step-up auth (OTP/3DS) or human-review queue. **Shadow-mode pipeline** (PayPal Quokka pattern): candidate model receives every live request, logs decision+score+latency alongside production, takes no action. **Fraud-ring detection** as separate XGBoost similarity-learning over account-pair features; builds candidate edges → scores → connected components; catches hundreds of accounts/week. **Daily retraining** of hundreds of submodels; +0.5pp recall/month from fresher data.

### Deep dives
1. **Latency budget breakdown + 3-5 online lookups.** Total 100ms (payment auth timeout). Model inference 1-2ms. Feature collection ~98ms. Per-feature RPC 2-5ms. **3-5 online lookups** per transaction even though model trained on 1000+ features. **Strategy**: precompute aggregate features offline (30-day spending velocity, account age, merchant trust score); store in feature store; online lookups fetch only most-recent / freshest aggregations. **Streaming aggregations** via Kafka → Flink: velocity counters (>5 txns / 10min flagged); <200ms event → feature-store read.

2. **Wide&Deep → ResNeXt-DNN migration (2022) + Payments Foundation Model (2025).** Pre-2022 Radar: ensemble of XGBoost (wide) + DNN (deep). Post-2022: **pure DNN inspired by ResNeXt** (Network-in-Neuron with multi-branch computation). **Why drop XGBoost**: not parallelizable (slowed retraining); incompatible with embeddings + transfer learning that team wanted to add. Result: **85% training time reduction to <2 hours**. **2025 Payments Foundation Model**: transformer pre-trained on billions of charges; charge = token, user history = context; produces dense payment embeddings reusable across fraud + AML + risk scoring. **Card-testing detection 59% → 97%** on large merchants. **Embeddings enable cross-geo transfer**: Brazil-learned fraud pattern transfers to US without explicit retraining because geography embedding captures merchant/region similarity.

3. **Production stack: shadow-mode + per-merchant thresholds + adversarial-aware retraining.** **Shadow mode** (PayPal Quokka): candidate model receives every live request, logs decision+score+latency alongside production, takes no action. Banks use universally because fraud is high-stakes. **Per-merchant threshold**: thin-margin food delivery aggressive blocking (high FP cost acceptable); high-margin SaaS tolerates more fraud (FP loses customer). Requires **calibrated probability scores**, not hard labels. Example: dropping threshold 0.5 → 0.3 + adding device fingerprint features can lift recall to 70% (precision 85%) and save $10M/year. **Adversarial drift** qualitatively different from natural drift — attackers can deliberately inject samples that fool drift detectors (ADWIN, KSWIN); detection-then-retrain alone fragile [Korycki 2020]. Production answer: layered defenses (rules + ML); shadow-mode validation before rollout; daily retraining cadence; **layered rules**: Layer 1 deterministic block sub-ms (known-bad BIN/IP); Layer 2 lightweight ML 10-50ms. ML model never sees obvious garbage.

## Known failure modes
1. **Velocity-counter staleness during burst.** Kafka→Flink→store→model pipeline: aggregate features lag freshest events by seconds, exactly when fraudsters launch coordinated bursts. Production answer: dual-path features (real-time + on-the-fly); explicit burst-detection rules ahead of ML.

2. **Hard-timeout failure mode.** If scoring can't return in budget, **allow-but-flag-for-monitoring or trigger step-up auth** (OTP/3DS) — blocking on missed deadline is self-DOS. Production answer: layered rules (Layer 1 deterministic block sub-ms; Layer 2 ML 10-50ms) with explicit fallback policies.

3. **Regulatory explainability** required (GDPR Article 22; emerging financial-AI rules). Production answer: SHAP attributions alongside scores; per-feature reasoning for human review + audit; declined-transaction → review → audit loop preserved.

4. **Calibration breakage across merchants** — global model mis-calibrated for niche verticals (B2B, gaming, crypto). Production answer: per-merchant-vertical calibration heads; per-merchant threshold tuning; explicit calibration monitor per slice.

5. **Label delay** — chargebacks land weeks after transaction, biasing recent retrains. Production answer: short-horizon proxy labels (e.g., immediate decline patterns); periodic backfill correction; explicit accounting for label-delay in offline metrics.

## Notes for the coach
- **Asked-confirmed at Stripe, Adyen, PayPal, banks.** Stripe Guides "A primer on machine learning for fraud detection", ByteByteGo "How Stripe Detects Fraudulent Transactions Within 100ms" (citing Stripe Engineering), Stripe 2025 Annual Letter, PayPal Tech on Quokka — all explicit interview-prep canon. Hello Interview "Design Fraud Detection" canonical.
- **The 100ms / 1-2ms / 98ms / 3-5-lookups budget is the canonical Staff+ unlock.** Candidates who articulate the per-component allocation demonstrate fraud-ML specificity; candidates who say "we use ML to detect fraud" miss the architectural reality.
- **The 2022 Wide&Deep → ResNeXt migration is the depth probe.** Mid-senior candidates default to "XGBoost is best for fraud"; Staff+ candidates name the operational reasons (parallelizability + embeddings + transfer learning) that motivated the architectural overhaul.
- **Adversarial probe: "fraudsters launch a coordinated burst — your velocity counters lag. What stops them?"** Strong answer: dual-path features (real-time + on-the-fly); explicit burst-detection rules ahead of ML; rate-limit at payment-gateway; cross-merchant graph signal (Stripe network effect catches new attackers because cards already seen with anomalous behavior). Weak answer: "we retrain quickly" without addressing the bursting-window vulnerability.

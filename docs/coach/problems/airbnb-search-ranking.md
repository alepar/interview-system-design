---
slug: airbnb-search-ranking
archetype: ml-in-loop
sources:
  haldar_2019: arxiv.org/abs/1810.09591 (Haldar et al. "Applying Deep Learning to Airbnb Search" KDD 2019)
  grbovic_2018: dl.acm.org/doi/10.1145/3219819.3219885 (Grbovic & Cheng "Real-time Personalization using Embeddings for Search Ranking at Airbnb" KDD 2018 best applied paper)
  airbnb_ebr_blog: airbnb.tech/uncategorized/embedding-based-retrieval-for-airbnb-search/
  airbnb_interleaving_blog: medium.com/airbnb-engineering/beyond-a-b-test-speeding-up-airbnb-search-ranking-experimentation-through-interleaving-7087afa09c8e
  bernardi_2019: KDD 2019 (Bernardi et al. "150 Successful ML Models at Booking.com")
---

# Airbnb search ranking — geo-constrained two-sided marketplace LTR + listing2vec + IVF EBR + interleaving

## Bar anchors
- **Mid-level (L4/E4):** "GBDT over listing features." No two-sided objective; no embeddings; no marketplace business constraints.
- **Senior (L5/E5):** Names DNN ranker + listing embeddings + interleaving. May or may not articulate listing-ID overfit, multi-task orthogonality, IVF-over-HNSW choice, or Booking 150-models lesson.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **two-sided marketplace** ranking — both guest and host preferences modeled; listings are perishable inventory (booked night gone); most searched in narrow geo windows. Cites **DNN ranker architecture**: 195 features → ReLU 127 → ReLU 83 → score; trained on **1.7B pairs** (booked, not-booked) from same search session with pairwise CE [Haldar KDD 2019]. Names **listing-ID overfit failure**: Airbnb tried embedding raw listing IDs as features and overfit because supply is capacity-bounded (most popular listing books ≤365 times/year, insufficient positives). Names **multi-task failure**: jointly predicting bookings + long-views increased long-views but kept bookings neutral — proxy and target have large orthogonal component. Cites **listing2vec** (32-d skip-gram on 800M click sessions of 4.5M active listings; **booked-listing-as-global-context**; **market negatives** sampled from same city; +21% CTR on similar-listing carousel; +4.9% guest-to-booking discovery; Search Ranking + Similar Listings = 99% of bookings). Names **IVF over HNSW** for EBR: HNSW memory grew with high-volume real-time listing updates + HNSW + geo-filter caused poor tail latency. Cites **interleaving** at Airbnb: 50× speedup (6% of A/B traffic, 1/3 the runtime, 82% agreement with A/B outcomes). Cites **17× training speedup** from CSV → Protobuf+tf.data alone (data pipeline was bottleneck). Stretch (Sr Staff bar): cites **Booking.com 150-models lesson** — model gains don't always translate to business gains (saturating curve); ML production failures arise from pipeline/system mismatch with training assumptions, not statistical issues.

## Canonical decomposition

### Requirements
**Functional:**
- Geo-constrained search (hard filter before ML re-rank)
- Two-sided objective: guest CTR/book-rate + host accept-rate
- Listing-availability + price-elasticity as ranking features
- Business-rule re-rank: dispersion (don't cluster on map), diversity (price/type), Superhost boosts, anti-discrimination

**Non-functional (with numbers):**
- ~7M+ active listings worldwide; search QPS low tens of thousands
- "Search Ranking + Similar Listings drive 99% of booking conversions" [Grbovic & Cheng KDD 2018]
- Label space `y ∈ {1 (booked), 0.25 (host contacted), 0.01 (clicked), 0 (viewed-not-clicked), -0.4 (host-rejected)}`
- Ranker: 195 features → ReLU 127 → ReLU 83; 1.7B training pairs
- Listing embeddings d=32; 4.5M active listings × 800M sessions
- Interleaving: 50× speedup; 82% A/B agreement
- Average price elasticity ≈ -2.2

### Core entities
- **Listing:** listing_id, geo, type, price, capacity, attributes, listing2vec embedding (32-d)
- **Search session:** guest, geo bounding box, date range, party size, clicked listings, contacted hosts, booked listing
- **Pair label:** (booked listing, not-booked listing) with negative reward for host rejection
- **Re-rank context:** dispersion map, diversity constraints, Superhost flag

### API
- `GET /search?location=X&dates=Y&guests=Z` → ordered listings within geo filter
- Internal: geo_filter.candidates(bbox) → eligible; ebr.candidates(query_emb) → expand candidates; ranker.score(features) → ordered; rerank.apply_business_rules(ordered)

### HLD
**Geo-pre-filter** is hard: candidate set restricted to user's destination polygon BEFORE ML re-rank — IVF + geo filter performs better than HNSW + geo filter at tail latency. **Two-tower EBR**: listing tower runs offline daily (precomputed 32-d embedding); query tower runs online per-request. **Contrastive training** with in-session hard negatives (homes shown but not booked) — random negatives "degraded performance significantly." **Euclidean distance over dot product** because Euclidean produces more balanced ANN cluster sizes; dot-product concentrates norms and degrades IVF partitioning. **DNN ranker** consumes 195 features → ReLU 127 → ReLU 83 → score; trained on 1.7B pairs with pairwise CE. **Multi-task heads** with care — bookings is the only true positive. **Re-rank** applies business rules. **Interleaving experimentation harness** at 50× faster than A/B for ranker tuning.

### Deep dives
1. **Listing2Vec + cold-start.** Skip-gram on 800M click sessions: window = recent click sequence; target = clicked listing. **Booked-listing as global context**: every step of skip-gram window also predicts eventual booking — embeds booking signal into embedding space. **Market negatives**: sampled from same city (not random) — forces embedding to differentiate within market, not across markets. Random negatives "degraded performance significantly." **Cold-start for new listings**: bootstrap embedding by averaging 3 geographically-closest listings of same type and price band.

2. **DNN ranker over GBDT + listing-ID overfit + multi-task orthogonality.** Migration GBDT → GBDT+FM+NN ensemble → pure DNN (2015-2019 Airbnb path). 195 features, modest ReLU 127 → 83. Pairwise CE loss weighted by NDCG-swap. **Booking signal sparse positive**: cross-entropy minimizes score-diff between booked listing and not-booked listings in same session. **Feature normalization**: most features [-1, 1]; un-normalized monetary features (price) cause vanishing gradients. **Dropout slightly degraded metrics** — counterintuitive; reflects overfit-resistant feature pipeline. **Listing-ID failure**: embed raw listing IDs as features → overfit; supply capacity-bounded (≤365 nights/year/listing). **Multi-task failure**: jointly predicting bookings + long-views increased long-views but kept bookings neutral — proxy and target have large orthogonal component.

3. **EBR with IVF + interleaving + 17× pipeline speedup.** **IVF over HNSW** for EBR despite slightly worse recall because HNSW memory grew with frequent listing updates + HNSW + geo-filter caused poor tail latency [Airbnb EBR post]. **Euclidean distance over dot product** for balanced clusters. **Interleaving**: team-draft interleaving with 50× speedup — uses ~6% of regular A/B test traffic + 1/3 running length; consistent with A/B outcomes 82% of time. **17× training speedup** from CSV → Protobuf+tf.data alone — data pipeline was bottleneck not model.

## Known failure modes
1. **Listing-ID feature overfit.** Capacity-bounded supply (365 nights/year/listing); too few positives per ID. Production answer: drop raw IDs; use derived features (listing2vec embeddings, listing attributes); explicit regularization on listing-side features.

2. **Multi-task orthogonality.** Optimizing proxy (long-views) doesn't move target (bookings). Production answer: align proxy with downstream target via correlation analysis; A/B test multi-task vs single-task before deploy; per-task weighting based on observed business-metric correlation.

3. **Business-value saturation** (Booking.com lesson). Offline model gain doesn't translate to business gain past some point; ML in production fails when pipeline/system assumptions deviate from training. Production answer: business-value as primary eval metric, not offline AUC; monitor production-vs-training feature distribution; champion-challenger with explicit business-metric guardrails.

## Notes for the coach
- **Asked-confirmed at Airbnb.** Haldar KDD 2019, Grbovic KDD 2018 (best applied paper), Airbnb EBR blog, interleaving blog, Booking 150-models KDD 2019 — all explicit interview-prep canon.
- **The user has shipped variants** — surface this as reference, but allocate write-up time to deep-cuts where intuition gives less leverage (DLRM-class CTR; autonomous-driving; real-time feature store).
- **The listing-ID overfit failure is the canonical marketplace-ranking deep-cut.** Candidates who recognize "supply is capacity-bounded" demonstrate marketplace literacy; candidates who default to "embed everything" miss the failure mode.
- **The Booking 150-models lesson is the broader Staff+ wisdom.** Offline-gain vs business-gain saturation curve is the Staff+ inflection point for ML system design.
- **Adversarial probe: "your DNN ranker is great offline but business metrics don't move — what's wrong?"** Strong answer: feature-pipeline mismatch (offline-online skew); proxy-target orthogonality; calibration drift; population mismatch between training and deployed traffic. Weak answer: "the model is fine, must be UI" without the systematic ML-production-failure framework.

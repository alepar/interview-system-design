---
slug: web-search-ranking
archetype: ml-in-loop
sources:
  burges_2010: microsoft.com/en-us/research/wp-content/uploads/2016/02/MSR-TR-2010-82.pdf (Burges "From RankNet to LambdaRank to LambdaMART" MSR-TR-2010-82)
  joachims_2017: arxiv.org/abs/1608.04468 (Joachims/Swaminathan/Schnabel "Unbiased Learning-to-Rank with Biased Feedback" WSDM 2017)
  nayak_bert_2019: blog.google/products/search/search-language-understanding-bert/ (Nayak "Understanding searches better than ever before" Oct 2019)
  doj_trial_2023: 2023 US v. Google DOJ trial transcripts (Pandu Nayak testimony on DeepRank + NavBoost)
  wang_lambdaloss_2018: CIKM 2018 (Wang et al. "The LambdaLoss Framework for Ranking Metric Optimization")
---

# Web search ranking — LambdaMART → BERT-class cross-encoder + multi-stage funnel + IPS counterfactual LTR

## Bar anchors
- **Mid-level (L4/E4):** "Score docs by BM25." No LTR; no neural reranker.
- **Senior (L5/E5):** Names LambdaMART + neural reranker. Discusses NDCG. May or may not articulate LambdaMART gradient trick, position bias / IPS, multi-stage funnel composition, or DeepRank/NavBoost from public Google disclosures.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **RANKING, not retrieval** (retrieval substrate in archetype #7 search-indexing). Names **LambdaMART gradient trick** — loss never defined explicitly; gradient (the "lambda") = RankNet pairwise gradient scaled by `|ΔNDCG|` from swap. LambdaMART = "LambdaRank with MART as function class" (GBDT) — still production workhorse at Bing per Burges' MSR retrospective. Names **LTR loss families**: pointwise (regression), pairwise (RankNet pairwise CE), listwise (LambdaMART NDCG-weighted, ListNet outperforms RankNet by ~10% NDCG). Cites **multi-stage funnel at Google**: Neural Matching/RankEmbed retrieval → RankBrain (2015 coarse) → DeepRank (BERT-derived fine, confirmed by Pandu Nayak at 2023 US v. Google DOJ trial: "DeepRank is taking on more and more of that capability now") → NavBoost (click-driven re-rank using 13 months of click data, also disclosed at trial). Cites **BERT for ranking + featured snippets** (Oct 2019, 1 in 10 US English queries, Cloud TPUs) per Nayak Google blog. Names **IPS counterfactual LTR** under position-based examination hypothesis: weight clicks by `1/P(examination at position k)`; circular dependency on accurate propensity estimation. Articulates **retrieval/ranking boundary enforced by latency**: retrieval cuts O(billions) → O(thousands) in <10ms with inverted-index/HNSW; ranking spends 50-200ms on NN over ≤1000 candidates.

## Canonical decomposition

### Requirements
**Functional:**
- Rank top-K documents per query with NDCG@10 as primary offline metric
- Multi-stage funnel: retrieval → L1 → L2 → final cross-encoder re-rank
- BERT-class semantic understanding for long conversational queries
- Click-based online evaluation with position-bias correction

**Non-functional (with numbers):**
- Web corpus ~10¹¹ pages indexed; tens of thousands QPS sustained
- Funnel: retrieval ~10⁵ → 10³ → L1 ranker ~10³ → 10² → L2 heavy ~10² → 10¹ → re-rank cross-encoder ~10¹ reordered
- BERT: 1 in 10 US English queries since Oct 2019 [Nayak]
- ListNet ~10% NDCG improvement over RankNet [Cao ICML 2007]
- LambdaMART won 2010 Yahoo LTR Challenge; remains production at Bing
- NavBoost: 13 months of click data per 2023 DOJ trial

### Core entities
- **Query:** raw text + intent classification + entity recognition
- **Document:** doc_id, BM25F features, anchor stats, freshness, host signals, URL depth
- **Feature vector:** hundreds to low-thousands per query-doc pair
- **Label:** human-rated relevance OR click-derived (with position-bias correction)
- **Funnel stages:** Neural Matching → RankBrain → DeepRank → NavBoost (Google);  L1 BM25/GBDT → L2 NN → cross-encoder (generic)

### API
- `GET /search?q=...` → ordered top-K results (SERP)
- Internal: retrieval.fetch(q) → top-10⁵; l1_ranker.score(q, docs) → top-10³; l2_ranker.score(q, docs) → top-10²; cross_encoder.score(q, docs) → top-10 reranked

### HLD
**Retrieval substrate** (archetype #7) returns ~10⁵ candidates via Neural Matching (semantic match), keyword inverted index, or RankEmbed (learned-retrieval embedding). **L1 coarse ranker** (RankBrain class): GBDT or shallow NN on cheap features (BM25F, anchor, freshness); cuts to ~10³. **L2 heavy ranker** (DeepRank class): BERT-derived deep model evaluating top hundreds; cuts to ~10². **Final cross-encoder** runs BERT-class model on top ~10 to reorder. **NavBoost** click-driven re-rank using historical CTR per (query, doc) pair from 13 months click history. **IPS training pipeline** for offline LTR: clicks weighted by `1/P(examination at position k)` from position-based examination hypothesis; propensity estimated via result-randomization (expensive — costs revenue/relevance) or EM-based examination model. **Each stage has strict per-doc latency budget**; staging exists because heavy cross-encoder can only see ~hundreds in budget.

### Deep dives
1. **LambdaMART gradient trick + LTR loss families.** **RankNet pairwise CE**: `L = log(1 + exp(-(s_i - s_j)))` over (relevant, less-relevant) pairs; minimizes inversions but weights all equally (misaligned with NDCG). **LambdaRank**: multiply each pairwise gradient by `|ΔNDCG|` from swapping i and j — directly optimizes a smoothed list metric. **LambdaMART**: GBDT trained on lambda gradients. Provably upper bound on NDCG [Wang et al. CIKM 2018 LambdaLoss]. **ListNet**: listwise; outperforms RankNet by ~10% NDCG. **ApproxNDCG**: sigmoid surrogate for rank indicator so NDCG directly differentiable.

2. **Multi-stage funnel (Google).** **Neural Matching/RankEmbed**: cuts billions of indexed docs → tens of thousands via embedding similarity. **RankBrain** (2015, "third most important signal" per Greg Corrado): lighter ML on top-K from retrieval; cuts to hundreds. **DeepRank** (BERT-derived): heavy model evaluates top hundreds; produces final scores. **NavBoost**: click-driven re-rank using 13 months of click data. Per Nayak 2023 DOJ trial: "DeepRank is taking on more and more of that capability now." Each stage has per-doc latency budget; cross-encoder only on final 20-30.

3. **IPS counterfactual LTR + position-bias correction.** **Examination hypothesis**: `P(click | relevant, position) = P(examined | position) × P(click | relevant)`. Under this model, weight each click by `1/P(examination at k)` for unbiased empirical risk [Joachims WSDM 2017]. **Propensity estimation**: result-randomization swaps (costs revenue/relevance) or EM-based examination model. **Variance problem**: IPS variance explodes with sparse clicks; doubly-robust + affine-correction estimators reduce variance but require accurate propensity → circular dependency on relevance estimates. **PAL pattern** (Huawei RecSys 2019): include position as feature at training, set to 0 / dropout at serving — sidesteps IPS but requires careful pre-processing.

## Known failure modes
1. **Training-data position-bias confounds LTR.** Naive training on biased click logs produces ranker that reproduces existing position bias. Production answer: IPS reweighting with propensity model; result randomization for propensity learning; UnbiasedLambdaMART jointly estimating click + bias.

2. **Calibration drift in coarse → fine cascade.** Coarse ranker's scores become miscalibrated as content distribution shifts; downstream fine ranker over- or under-selects right candidates. Production answer: periodic recalibration of coarse on fresh data; monitor coarse-ranker calibration via held-out fine-ranker scores.

3. **Heavy cross-encoder timeout at p99.** Causes mass fallback to L2 rankings on tail queries → user-visible regression. Production answer: timeout + fallback policy explicit; degraded SERP markered (less personalized but never empty); per-region cross-encoder pool sizing.

4. **Long-tail query under-served.** Tail queries (rare, conversational) have less click data; LTR learns poorly. Production answer: BERT-class semantic models bridge query-doc semantic gap without needing per-query click history; LLM-derived query rewriting (modern era).

## Notes for the coach
- **Asked-confirmed at Google, Bing, Yandex.** Burges 2010 MSR-TR is primary for LambdaMART; Joachims WSDM 2017 for IPS; Pandu Nayak 2023 US v. Google DOJ trial transcripts for DeepRank/NavBoost disclosures; Nayak Google Search Blog Oct 2019 for BERT in Search — all explicit interview-prep canon.
- **The LambdaMART gradient trick is the canonical Staff+ unlock for LTR.** Candidates who can articulate "the loss is the gradient" demonstrate LTR depth.
- **The DeepRank + NavBoost public disclosures are the 2023 deep-cut.** Candidates who reference them demonstrate they read the DOJ trial transcripts.
- **Adversarial probe: "your heavy cross-encoder times out at p99 — what do users see?"** Strong answer: explicit fallback to L2 rankings; degraded SERP markered (less personalized but never empty); per-region cross-encoder pool sizing to keep tail latency bounded. Weak answer: "we have circuit breakers" without specifying the user-visible fallback.

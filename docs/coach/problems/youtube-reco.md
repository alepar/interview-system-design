---
slug: youtube-reco
archetype: ml-in-loop
sources:
  covington_2016: dl.acm.org/doi/10.1145/2959100.2959190 (Covington et al. "Deep Neural Networks for YouTube Recommendations" RecSys 2016)
  yi_2019: dl.acm.org/doi/10.1145/3298689.3346996 (Yi et al. "Sampling-Bias-Corrected Neural Modeling" RecSys 2019)
  scann_blog: research.google/blog/announcing-scann-efficient-vector-similarity-search/
  hello_interview_youtube: hellointerview.com/learn/system-design/problem-breakdowns/youtube-recommendations
---

# YouTube recommendations — two-tower retrieval + watch-time-weighted DNN ranking

## Bar anchors
- **Mid-level (L4/E4):** "Retrieve top-K then rank top-N." No retrieval/ranking objective distinction. Treats CTR as the ranking target.
- **Senior (L5/E5):** Names two-tower retrieval + DNN ranker. Discusses ANN serving. May or may not address sampling-bias correction, watch-time-weighted LR trick, example-age, freshness handling.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **why the funnel exists** (computational asymmetry between billions of videos and ~100-document ranking budget). Names retrieval-vs-ranking objective difference: **sampled softmax over corpus** (retrieval) vs **pointwise/listwise regression over expected watch time** (ranking). Cites Covington 2016's **watch-time-weighted logistic regression** — positives weighted by observed watch-time so `e^(Wx+b) ≈ E[watch time]`. Cites Yi 2019's **logQ correction** for sampling-bias on in-batch negatives: subtract `log(p_j)` from logit; item frequency `p_j` estimated online via hash-bucket EMA `B[h(y)] = (1-α)·B[h(y)] + α·(t - A[h(y)])`. Names **example-age feature** (fed at training, zeroed at serving) as bias-correction trick. Articulates **freshness as architectural concern**: new uploads reachable within minutes via two-tower over content features (audio + visual + text) for cold items. Names **ScaNN/HNSW** sharded ANN serving at sub-10ms / ~99% recall on billion-vector corpora. Stretch (Sr Staff bar): articulates atomic dual-version pinning of model + index to prevent skew.

## Canonical decomposition

### Requirements
**Functional:**
- Serve personalized recommendations across home page / Watch Next / search-suggested-videos
- Two-stage funnel: billions of videos → ~hundreds candidates → ~10 ranked
- Optimize expected watch time, not raw CTR (clickbait mitigation)
- Cold-start coverage for new uploads (freshness within minutes)

**Non-functional (with numbers):**
- ~800M+ videos hosted; 500 hours uploaded/minute (Statista / YouTube)
- ~2B DAU; home-page QPS in millions globally
- Retrieval: 10⁹ → 10³ candidates in <50ms (p99 <100ms)
- Ranking: 10³ → 10² in <100ms
- Two-tower: 256-dim user/item embeddings; hundreds of millions of item embeddings in sharded ScaNN/HNSW
- Ranking model: O(10⁸) parameters (sparse-id embeddings dominate); MLP top [1024, 512, 256]
- Sampled softmax with several thousand negatives + logQ correction
- Retrieval retrained daily; ranking retrained every few hours

### Core entities
- **User context:** recent watch history (capped 50), search queries (capped 50), subscriptions, demographics
- **Video:** video_id, content embeddings (YAMNet audio + vision encoder + text), age-at-impression
- **Candidate set:** top-K from retrieval (typically K = a few hundred to a few thousand)
- **Score:** ranking model output = expected watch time

### API
- `GET /recommendations?user_id=X&surface=home|watchnext` → ordered list of video_ids
- Internal: `retrieval.user_tower(user_features) → user_emb` (online); `retrieval.item_tower(video_features) → item_emb` (offline daily); ANN lookup `top_k(user_emb)`
- Internal: `ranking.score(user_features, video_features, candidate_set) → scored_list`

### HLD
**Two-tower retrieval**: user tower runs online per request (user history + context → 256-d embedding); item tower runs offline daily (video metadata + content features → 256-d embedding); item embeddings indexed in ScaNN/HNSW sharded by item-id hash. **ANN lookup** returns top-K candidates. **Multi-source retrieval** combines two-tower + recent-watch sequence + subscriptions + co-watch. **Ranking model** (DLRM-class) scores each candidate against user + context; outputs expected watch time via weighted-LR trick. **Value model** blends per-objective heads (CTR, watch-time, share, dislike, survey "meaningfulness") into final score. **Index management**: daily full rebuild + delta index for last 24h; atomic dual-version pinning of model + index. **Serving stack**: dedicated retrieval service + ranking pods on GPU/TPU.

### Deep dives
1. **Two-tower retrieval with sampling-bias correction (Yi 2019).** User tower: recent history + context → 256-d. Item tower: video metadata + content features → 256-d. Trained with sampled softmax: in-batch negatives drawn from minibatch (oversamples popular items because they appear more frequently). **logQ correction**: subtract `log(p_j)` from logit so popular items aren't over-penalized as negatives. Item frequency `p_j` estimated online via hash-bucket EMA — no static vocabulary needed. Sequential daily training consumes log shards oldest-to-newest to track distribution shift. 2025-era production: 300B+ user-item interactions; 8,192 in-batch + 8,192 corpus negatives [arXiv 2507.09331].

2. **Watch-time-weighted ranking (Covington 2016).** Standard binary logistic regression on click predicts P(click). Watch-time-weighted LR: positives weighted by observed watch-time T; negatives unit-weighted. Solving for the log-odds: `log(odds) ≈ E[T | impression]` because expectation collapses cleanly when N negatives ≫ N positives and positive weights = watch-times. At serving, `e^(Wx+b)` directly approximates expected watch time → use as ranking score. Why not optimize CTR? Switching from CTR rewarded clickbait thumbnails; watch-time aligns with long-term satisfaction. Multi-objective heads (CTR, watch-time, share, dislike) blended into final value model.

3. **Example-age feature for bias correction.** Training examples have `age = (training_window_end - example_time)`. At serving, age is set to zero so the model predicts "if this were a freshly-emitted impression." Without this, the model over-predicts engagement on stale popular content (because such content has had more impressions in the training window). Combined with content-feature pathway for cold-start: new uploads get a two-tower embedding from features (no engagement history needed).

## Known failure modes
1. **Training-serving skew at embedding level.** Hash collisions, late-arriving uploads, vocabulary drift between offline trainer and online server cause silently-wrong predictions. Production answer: embedding-norm distribution monitors; offline-online feature parity tests; consistent hashing across pipelines.

2. **Index/model version skew.** ScaNN index built with model v_k while ranking calls user tower of v_{k+1}; embeddings live in different geometries. Production answer: atomic dual-version pinning — index version pinned to model version in serving config; rollout flips both atomically.

3. **Watch-time gaming + feedback loops.** Creators optimize thumbnails for early watch-time spike then content nosedives; engagement-optimized loop amplifies "engaging but harmful" content. Production answer: survey-based re-weighting (Meta-style), per-objective heads (dislike, see-less, report) explicitly subtracted in value model, periodic random exploration to inject low-popularity items into slate.

## Notes for the coach
- **Asked-confirmed at Google/YouTube** (Hello Interview answer key; explicit interview-prep canon).
- **The two-stage funnel + watch-time-weighted LR + logQ correction trio is the canonical Staff+ unlock.** Candidates who can derive the logQ correction from first principles demonstrate RecSys depth; candidates who default to CTR optimization miss the entire industry shift post-2016.
- **The example-age trick is the deep-cut.** Mid-senior candidates miss it; Staff+ candidates name it because they've read the paper.
- **Adversarial probe: "show me how the logQ correction works mathematically — what is `p_j` and how do you estimate it online?"** Strong answer: in-batch negatives sampled with prob proportional to item frequency; subtracting `log(p_j)` from logit corrects the over-penalization; `p_j` estimated via hash-bucket EMA streaming algorithm. Weak answer: "we use sampled softmax" without addressing the bias.

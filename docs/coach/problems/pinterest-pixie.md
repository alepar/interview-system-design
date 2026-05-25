---
slug: pinterest-pixie
archetype: ml-in-loop
sources:
  pixie_paper: arxiv.org/abs/1711.07601 (Eksombatchai et al. "Pixie" WWW 2018)
  pinsage_paper: arxiv.org/abs/1806.01973 (Ying et al. "Graph Convolutional Neural Networks for Web-Scale Recommender Systems" KDD 2018)
  pinnersage_paper: arxiv.org/abs/2007.03634 (Pal et al. "PinnerSage" KDD 2020)
  multibisage_paper: arxiv.org/abs/2205.10666 (Pinterest MultiBiSage)
---

# Pinterest Pixie + PinSage + PinnerSage — graph-based recommendation at billion-node scale

## Bar anchors
- **Mid-level (L4/E4):** "Item-similarity from co-saves." No graph algorithms; no PageRank.
- **Senior (L5/E5):** Names Pixie / PinSage at high level. Discusses graph reco. May or may not articulate biased Personalized PageRank, importance-sampled neighborhoods, or hard-negative curriculum.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **graph-based reco** as a distinct architectural family from CF or two-tower. Names **PinSage's importance-sampled neighborhoods** via short random walks (sub-samples for compute + provides importance weights for aggregation) vs naive GCN that loads global Laplacian. Distinguishes **Pixie (real-time random-walk over live graph)** from **PinSage (offline-batch GCN producing embeddings indexed in ANN)** as complementary, not alternatives. Cites **Pixie scale**: ~100,000 random walks/query on 3B-node / 17B-edge graph; 1,200 RPS / 60ms latency on single r3.8xlarge (244 GB RAM, ~120 GB after 86% pruning). Names **multi-hit booster** `(Σ √V)²` for aggregating visits across multiple query pins (58% offline improvement). Cites **PinSage hyperparameters**: K=2 conv layers, hidden 2,048 / output 1,024, sampling T=50 neighbors via random walks; trained on 7.5B pairs over 3B nodes / 18B edges on 16 K80 GPUs with batch 2,048. Names **curriculum hard-negative mining** at PPR rank 2,000-5,000 (12% offline gain); importance pooling +46%. Stretch (Sr Staff bar): articulates **PinnerSage** multi-vector user representations via hierarchical Ward clustering of last 90 days of actions; each cluster summarized by medoid pin.

## Canonical decomposition

### Requirements
**Functional:**
- Real-time related-pins (Pixie) at query time on live graph
- Offline-batch embedding generation (PinSage) for ANN-served recommendations
- Multi-vector user representations (PinnerSage) for users with diverse interests
- Cold-start for new pins via content features (visual + text)

**Non-functional (with numbers):**
- ~500M MAU; corpus ~5B+ pins on ~1B+ boards
- Pixie: 3B nodes, 17B edges, 1,200 RPS at 60ms latency on r3.8xlarge (~120 GB after 86% pruning)
- PinSage: 7.5B training pairs over 3B nodes / 18B edges; "graph 10,000× larger than typical GCN applications"
- PinSage trained on 16 Tesla K80 GPUs / 32 cores / 500 GB RAM / batch 2,048; 67% hit-rate (150% over baseline); A/B 10-30% lift in repins
- MapReduce inference: 378-node Hadoop2 cluster regenerates 3B node embeddings in <24h
- PinnerSage serves 400M+ MAU

### Core entities
- **Pin:** pin_id, board_id, content features (image CNN + text)
- **Board:** board_id, member pins, owner, topic
- **Pin-board graph:** bipartite, 3B nodes / 17B edges (pruned to 1B / ~120 GB for Pixie)
- **PinSage embedding:** 1,024-d per pin, regenerated daily
- **PinnerSage user representation:** 10-100 medoid pins (Ward-clustered from 90-day actions)

### API
- `GET /related_pins?pin_id=X&user_id=Y` → ordered related pins (Pixie real-time + PinSage ANN)
- `GET /home_feed?user_id=X` → personalized feed via PinnerSage medoids
- Internal: pixie.random_walks(query_pins, n=100K) → visit counts → ranked pins; pinsage.embed(pin_features) → 1024-d; ann.search(user_medoid, k) → candidates

### HLD
**Pixie real-time path**: client sends query pins; Pixie server runs ~100,000 biased Personalized PageRank random walks on the pin-board graph (3B-1B nodes after pruning, fits ~120 GB on r3.8xlarge); each walk starts at query pin, with prob α resets, else follows edge; aggregate visit counts via **multi-hit booster** `(Σ √V_k)²` for multi-pin queries; ranks pins by aggregate visits. **Personalization** biases walk per user via `PersonalizedNeighbor(E, U)` without per-user graph copies. **PinSage offline path**: GCN trains on 16 K80 GPUs; inductive (new pins embedded from features without retraining); 2-layer conv with importance-pooled neighborhoods sampled via short random walks; **378-node Hadoop2 MapReduce** regenerates 3B embeddings in <24h; bulk-load to ANN index. **Online serving** = ANN lookup against PinSage embeddings. **PinnerSage user representation**: per-user hierarchical Ward clustering on last 90 days of actions; each cluster summarized by medoid pin; user has 10-100 medoid pins (vs single averaged user embedding). Recommend top-k from each medoid → distinct interest-aligned slates.

### Deep dives
1. **Pixie biased Personalized PageRank random walks.** ~100,000 walks per query; at each step, prob α reset to query pin, else follow edge. Walks visit pins; visit counts approximate PPR distribution. **Personalization**: walk biased per-user via `PersonalizedNeighbor(E, U)` — edges relevant to user's features (language, topic) preferred — without per-user graph copies. **Multi-hit booster**: when query has K pins, aggregate visits via `(Σ √V_k)²` (square-root-then-square), elevating pins related to many query pins over those concentrated under one. Combined with pruning, +58% offline gain. **Engineering**: SNAP in C++ for graph ops; parallel walks; early-stopping when top-1000 visited pins stabilize (often well before 100K steps).

2. **PinSage inductive GCN architecture.** Standard GNNs transductive (need full graph at training; new nodes require retraining). PinSage **inductive** (GraphSAGE-derived): for target node, sample T=50 neighbors via short random walks (importance-pooled by visit frequency), aggregate features via learned conv layer, repeat K=2 times. Final embedding = function of features + sampled neighborhood. **Hard-negative curriculum**: epoch n includes n-1 hard negatives drawn at PPR rank 2,000-5,000 (items that are *almost* relevant but not target). Importance pooling (weight neighbor contributions by visit frequency) added 46% gain.

3. **MapReduce inference + PinnerSage multi-vector user representations.** Re-embedding 3B nodes after daily model update can't run in serving latency. PinSage runs two-stage MapReduce on **378-node Hadoop2** cluster: <24h to regenerate all 3B node embeddings; bulk-load to ANN. **PinnerSage** (extension): per-user hierarchical Ward clustering on last 90 days of actions; each cluster summarized by medoid pin → multi-modal user representation captures distinct interest clusters (cooking + sports + travel as 3 medoids rather than averaged blur). Daily batch inference of past 90 days + lightweight online inference of most recent 20 actions.

## Known failure modes
1. **Visual-confound errors.** Pinterest published example: tree-logging clustered with war photos by visual similarity. Production answer: multi-modal grounding (visual + text + behavioral); per-image content-safety classifier.

2. **PinSage staleness.** Daily batch can't represent latest content. Production answer: Pixie fills gap (real-time PPR over live graph); hybrid serving — recent pins via Pixie, older via PinSage ANN.

3. **Hot-board pollution.** Viral board attracts random-walk mass and dominates recommendations. Production answer: transition-probability caps (per-edge max walk-mass); diversity post-filter.

## Notes for the coach
- **Asked-confirmed at Pinterest.** Pixie WWW 2018, PinSage KDD 2018, PinnerSage KDD 2020 are explicit interview-prep canon.
- **The Pixie/PinSage complementarity is the architectural Staff+ unlock.** Candidates who treat them as alternatives miss the design space; candidates who articulate "Pixie for real-time freshness, PinSage for ANN-scaled serving" demonstrate the right framework.
- **The hard-negative curriculum at PPR rank 2,000-5,000 is the deep-cut.** Random negatives don't discriminate near-duplicates; PPR-ranked negatives force the model to learn fine-grained similarity.
- **Adversarial probe: "PinSage retrains daily — what about new pins uploaded in the last hour?"** Strong answer: inductive nature gives new pins an embedding immediately from features (image CNN + text); ANN can recommend new pins without random walks; Pixie + PinSage hybrid covers both ends. Weak answer: "we wait until next batch" — but Pinterest's freshness target is sub-hour.

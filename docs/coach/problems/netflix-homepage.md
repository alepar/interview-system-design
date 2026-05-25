---
slug: netflix-homepage
archetype: ml-in-loop
sources:
  gomez_uribe_hunt_2015: doi.org/10.1145/2843948 (Gomez-Uribe & Hunt "The Netflix Recommender System" ACM TMIS 6(4) Dec 2015)
  netflix_homepage_blog: netflixtechblog.com/learning-a-personalized-homepage-aa8ec670359a
  netflix_interleaving_blog: netflixtechblog.com/interleaving-in-online-experiments-at-netflix-a04ee392ec55
  netflix_artwork_blog: netflixtechblog.com/artwork-personalization-c589f074ad76
---

# Netflix homepage row-and-rank — 2D ranking + interleaving + contextual bandits for artwork

## Bar anchors
- **Mid-level (L4/E4):** "Sort titles by predicted rating." No row structure; no interleaving; no artwork personalization.
- **Senior (L5/E5):** Names row-then-rank funnel + per-row ranking. Discusses A/B testing. May or may not address interleaving's sample-efficiency, contextual bandits for artwork, or 2D position bias.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **two-dimensional ranking** — rows have themes ("Because You Watched X," "Top 10 in Country," "Trending Now") and inside each row titles are ordered. Names the **page** optimization problem (not list ranking) — eval metric (long-term satisfaction inferred from retention, not click) breaks standard NDCG harness. Cites Gomez-Uribe & Hunt ACM TMIS 2015: recommendations "in total influences choice for about 80% of hours streamed at Netflix. The remaining 20% comes from search." Names **interleaving** for ~100× sample efficiency vs A/B on retention; explains *why* (within-user comparison removes variance from heavy- vs light-users). Names **Personalized Video Ranker (PVR)** for in-row item order. Cites **stage-wise page-level scorer with k-row look-ahead** scoring each row conditional on already-selected rows. Names **contextual bandits (Thompson Sampling, Doubly Adaptive TS)** for artwork personalization (each title × N candidate artwork × member context → bandit). Stretch (Sr Staff bar): articulates 2023 consolidation from 20+ task-specific models into unified multi-task DNN with +5-10% top-k recall lift.

## Canonical decomposition

### Requirements
**Functional:**
- 10-30 rows per homepage; 20-50 titles per row
- Per-row ranking (Top Picks, Trending Now, Continue Watching) — each row uses different ranker
- Page-level ranking deciding which rows + order
- Artwork personalization (per-title × per-member × context → which image)
- Interleaving for ranker A/B at 100× sample efficiency

**Non-functional (with numbers):**
- 301.6M paid subscribers globally as of Dec 31 2024 [Netflix Q4 2024 shareholder letter]
- Homepage opens billions of times/day
- Catalog small by web-recsys standards (~10⁴-10⁵ titles) — inverts funnel cost (retrieval cheap; ranking is workload; page construction is optimization)
- Per Gomez-Uribe & Hunt 2015: ~80% of hours streamed influenced by recs
- Interleaving: ~100× sample efficiency over A/B on retention [Netflix Tech Blog]
- 2023 unified multi-task model: +5-10% top-k recall vs 20+ task-specific predecessors
- Signals excluded: age, gender (Netflix policy)

### Core entities
- **Row:** row_id, theme (Top Picks | Trending | Continue Watching | Because You Watched X), candidate titles, per-row ranker
- **Title:** title_id, metadata (genre, cast, year), per-user predicted score
- **Member context:** viewing history, time-of-day, language, device, recently-played
- **Artwork:** title_id, candidate images, bandit-selected per member

### API
- `GET /homepage?member_id=X&device=Y&time=now` → ordered rows × ordered titles + artwork per title
- Internal: row_generator(member) → candidate rows; row_ranker(member, candidate_rows) → ordered rows; pvr(member, row) → ordered titles within row; artwork_bandit(member, title, context) → image

### HLD
**Offline batch precompute** (nightly): per-user candidate rows; per-row title scores; **edge-cached** at PoPs to avoid recomputing on every homepage open. **Online re-ranker** incorporates real-time context (device, time-of-day, recently-played) to adjust ordering. **Row generation**: rule-based + ML candidate rows. **Per-row ranker** (PVR — Personalized Video Ranker) scores candidate titles per row's theme. **Page-level ranker**: chooses row inclusion + order. Two variants: **greedy** (pick highest-scoring rows independently) vs **stage-wise k-row look-ahead** (at each row slot, score remaining rows conditional on already-picked rows to penalize redundancy). **Artwork bandit** runs per-impression: contextual bandit (Thompson Sampling, Doubly Adaptive TS) selects artwork from candidates. **Interleaving harness** for ranker A/B: stage-1 interleaves rankers in single list (prunes many candidates in days), stage-2 traditional A/B on survivors.

### Deep dives
1. **Row generation → row ranking → item ranking (PVR).** Three stages and their respective models. Row generators are independent: Top Picks (personalized ranking), Trending Now (recent popularity + personalization), Continue Watching (in-progress titles), Because You Watched X (item-similarity rows). Each row's PVR scores candidate titles. **Page-level ranker**: greedy or stage-wise. Stage-wise: at each slot, score remaining candidate rows conditional on already-picked (penalize redundancy: "Action Films" row 1 → don't pick "Action Movies for Weekend" row 2). K-row look-ahead increases compute but reduces redundancy. **Page-level metrics**: extending NDCG/MRR to 2D (row × column); Expected Reciprocal Rank with cascading position bias models in both axes.

2. **Interleaving for ranker A/B at 100× sample efficiency.** **Population-split A/B**: half users see ranker A, half see ranker B; compare engagement. Requires very large samples for ranking changes (low signal-to-noise). **Interleaving**: each user sees mixed list — top-K of A interleaved with top-K of B; track which ranker's items get clicked. Same user is unit of comparison; eliminates user-population variance. Per Netflix: **~100× sample efficiency**; stage-1 prunes many rankers fast, stage-2 confirms with traditional A/B. **Team Draft Interleaving** and **Balanced Interleaving** as named variants. Trade: interleaving needs careful design (assignment rule to avoid systematic bias); only measures relative ranker quality, not absolute engagement.

3. **Contextual bandits for artwork personalization.** Each title has ~5-20 candidate artwork images. For a given (member, title, context), pick artwork. Treat artwork choices as arms; member context (genre affinity, recent watches) as bandit context. **Thompson Sampling**: sample from posterior over arm-rewards, pick highest. **Doubly Adaptive TS**: adapts to both arm-reward uncertainty and exploration-budget concerns. Result: same title gets different "best artwork" for different members.

## Known failure modes
1. **Row-rank objective gaming.** Row produces many clicks but no completion. Production answer: long-watch + retention as composite metric, not click alone.

2. **Personalization undermines discovery.** "Because You Watched" dominates; user sees same genre. Production answer: explicit unfamiliar-content rows; diversity penalty in stage-wise page ranker.

3. **Bandit cold-start for new titles.** New title has no observed engagement; bandit can't compute posterior. Production answer: bootstrap from content features (genre, cast, similar-title behavior); bandit exploration-arm budget biased toward new titles; pre-warm bandit with simulated data from similar titles.

## Notes for the coach
- **Asked-confirmed at Netflix.** Gomez-Uribe & Hunt ACM TMIS 2015 is the canonical reference; Netflix Tech Blog posts on row-and-rank, interleaving, artwork personalization are explicit interview-prep canon.
- **Interleaving's 100× sample efficiency is the canonical Staff+ unlock for ranking experimentation.** Candidates who can articulate within-user comparison vs population-split variance demonstrate experimentation-design sophistication.
- **The 2D position bias is the depth probe.** Standard NDCG/MRR assume 1D ranking; row × column requires Expected Reciprocal Rank with cascading position bias in both axes.
- **Adversarial probe: "Netflix has small catalog — why all this funnel machinery?"** Strong answer: small catalog inverts the cost ratio — retrieval is cheap, ranking is the workload, **page-construction is the optimization** (which rows + order). The complexity is in page composition, not item retrieval. Weak answer: "we use ML everywhere" without the cost-asymmetry framing.

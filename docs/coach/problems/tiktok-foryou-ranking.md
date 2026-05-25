---
slug: tiktok-foryou-ranking
archetype: ml-in-loop
sources:
  monolith_paper: arxiv.org/abs/2209.07663 (Liu et al. "Monolith: Real Time Recommendation System With Collisionless Embedding Table" ByteDance 2022)
  nyt_algo_101: nytimes.com/2021/12/05/business/tiktok-algorithm.html (NYT "How TikTok Reads Your Mind" + leaked TikTok Algo 101 document)
  datareportal_2025: datareportal.com/reports/digital-2025-global-overview-report
---

# TikTok For-You ranking — Monolith online learning + collisionless embeddings + exploration pool

## Bar anchors
- **Mid-level (L4/E4):** Treats For-You as "recommend videos by engagement score." No awareness of online learning vs batch retrain.
- **Senior (L5/E5):** Names video reco funnel + multi-task heads. Discusses cold-start. May or may not address Monolith parameter server, collisionless embeddings, or explicit exploration pool.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **three architectural differences from YouTube/Meta reco**: (1) full-screen single-item-per-decision makes calibration of completion-rate and skip-rate dominant signals (not click); (2) extreme cold-start tolerance because TikTok's growth thesis depends on serving new creators their first impressions; (3) **Monolith parameter server** with sparse-id embeddings updated continuously with no batch boundary, breaking standard "train daily, deploy snapshot" pattern. Cites **Cuckoo HashMap** for collisionless embedding tables (two tables with different hashes; insert evicts and rehomes). Names **Training-PS / Serving-PS split** with minute-scale sync (only IDs updated in sync cycle pushed; dense weights less often; 24h snapshots for fault tolerance). Cites Monolith paper's Criteo Ads result: real-time training beat batch at every tested sync interval (30 min / 1h / 5h). Names **explicit exploration pool** (fraction of impressions reserved for under-served items). Per leaked NYT Algo 101: `score = P(like)·V_like + P(comment)·V_comment + E[playtime]·V_playtime + P(play)·V_play`. Stretch (Sr Staff bar): articulates explicit contrast with YouTube/Meta nightly-retrain paradigm.

## Canonical decomposition

### Requirements
**Functional:**
- Full-screen single-item-per-decision For-You feed
- Cold-start tolerance: new creators served their first 10K impressions
- Real-time training: signal → embedding update in minutes, not days
- Explicit exploration pool for under-served items
- Multi-task heads: like, comment, share, playtime, play (per leaked Algo 101)

**Non-functional (with numbers):**
- ~1.59B MAU as of Jan 2025 [DataReportal Global Digital 2025]
- ~50B+ daily video impressions; sustained per-user QPS during 30-60min sessions
- Corpus ~10⁹ videos; tens of millions daily new uploads
- Per leaked Algo 101: tracks 1,000+ features per user
- Latency ~200ms p99 end-to-end; ranking 20-40ms
- Monolith: minute-scale sparse embedding sync; 24h snapshots; dense weights synced less often

### Core entities
- **Embedding tables (sparse-id):** user_id, video_id, creator_id, hashtag, audio_id, location; TTL-based expiry
- **Cuckoo HashMap state:** two tables T0/T1 with hash functions h0/h1
- **User context:** recent watch/like/skip sequence + interest tags + device + locale
- **Heads:** P(like), P(comment), P(share), E[playtime], P(play)
- **Value weights:** V_like, V_comment, V_playtime, V_play (per-market tuned)

### API
- `GET /foryou?user_id=X` → next Reel
- Internal: trainer.consume(kafka_click_event) → gradient updates; serving_ps.lookup(ids) → embeddings; ranker.score_mtml(features) → head probabilities; value_model.blend(probs)

### HLD
**Training-PS (parameter server)** consumes Kafka click/watch/like streams via Flink-like real-time pipeline; updates sparse embeddings continuously. **Serving-PS** holds production embeddings; **delta-sync from Training-PS at minute cadence** (only IDs updated within sync cycle pushed). Dense weights synced less frequently. **24h snapshot** for fault tolerance. **Cuckoo HashMap** for embedding tables: two tables T0/T1 with different hashes; insert into T0[h0(A)]; if occupied by B, evict B to T1[h1(B)]; recursively evict. Stable when load factor <0.5; collision-free in steady state. **Ranker** scores MTML over current candidate set. **Value model** linear blend `score = Σ V_k · P_k`. **Re-ranker** enforces explicit **exploration pool** (e.g., 5-10% of slots reserved for items with low impression count). **Cold-start path**: new user gets bootstrap recommendations from device + locale + interest-tag seed (1000+ features per leaked doc).

### Deep dives
1. **Monolith online-learning parameter server.** Naive RecSys: train nightly on click logs; deploy snapshot; embeddings stale for hours. Monolith: **continuous training** — trainer workers consume Kafka click streams, stream gradients to Training-PS in real-time; **delta-sync** minute-cadence pushes only updated IDs to Serving-PS. Trade: freshest embeddings improve few percent of metrics but require careful guard rails against catastrophic forgetting (e.g., a poisoned batch). **Validation gates** between trainer and parameter server reject batches with anomalous statistics. **24h snapshots** for recovery.

2. **Cuckoo HashMap for collisionless embeddings.** Standard fixed-size embedding tables hash IDs into M buckets; collisions inevitable when |IDs| > M (popular case at TikTok scale). **Cuckoo HashMap**: maintain two tables T0 and T1 with different hash functions h0 and h1. Insert A: try T0[h0(A)]; if occupied by B, evict B to T1[h1(B)]; if that's occupied, recursively evict. Stable when load factor <0.5; collision-free in steady state. Per Monolith paper: this is the production solution at TikTok + BytePlus. Trade vs hash-bucketing: more memory (need slack in tables) but eliminates collision degradation.

3. **Explicit exploration pool + cold-start.** Naive: ranker optimizes engagement; under-served items never accumulate enough signal to rise. **Exploration pool**: reserve a fraction (5-10%) of impressions for items with low impression count — TikTok's published countermeasure. Connect to contextual bandits (ε-greedy or Thompson sampling). **Cold-start via seed**: new user has no behavior; bootstrap from device features + locale + interest tags collected at signup (per leaked Algo 101: "the system tracks over 1,000 features about each user"). New videos get bootstrap impressions from the exploration pool.

## Known failure modes
1. **Filter-bubble harm.** NYT-reported "sad content" amplification is the canonical example of engagement-optimized loop with insufficient countervailing objectives. Production answer: explicit anti-amplification rules; periodic survey-based labels; diversification penalties.

2. **Online-learning instability.** Malformed batch poisons embeddings; serving quality drops. Production answer: validation gates between trainer and parameter server (reject batches with anomalous statistics); auto-rollback to last good snapshot; per-class accuracy monitors.

3. **Embedding TTL too aggressive.** Long-tail items get evicted right when they go viral. Production answer: dynamic TTL based on access rate; warm-back from Hive cold storage on first impression after eviction.

## Notes for the coach
- **Plausibly-asked at ByteDance/TikTok.** Monolith paper is open-source. NYT Dec 5 2021 with leaked "TikTok Algo 101" is the public reference for the value-model structure.
- **The Monolith online-learning architecture is the Staff+ TikTok-specific anchor.** Candidates who can contrast with YouTube/Meta nightly-retrain paradigm demonstrate the right framework; candidates who treat it as "same as YouTube reco" miss the architectural moat.
- **The Cuckoo HashMap collisionless embedding is the deep-cut.** Mid-senior candidates default to hash-bucketing; Staff+ candidates name Cuckoo as the production solution at TikTok scale.
- **Adversarial probe: "your embedding TTL evicts an item right before it goes viral — how do you recover?"** Strong answer: dynamic TTL; warm-back from Hive cold storage; backup signal via content features (audio fingerprint, video CNN). Weak answer: "we make TTL longer" without addressing the memory growth.

---
slug: linkedin-pymk
archetype: ml-in-loop
sources:
  linkedin_pymk_blog: linkedin.com/blog/engineering/recommendations/building-a-large-scale-recommendation-system-people-you-may-know
  glmix_paper: KDD 2016 (Zhang et al. "GLMix: Generalized Linear Mixed Models for Large-Scale Response Prediction")
  photon_ml_blog: 2016 LinkedIn Engineering "Open Sourcing Photon ML"
  gdmix_blog: 2020 LinkedIn Engineering "GDMix: A deep ranking personalization framework"
  pytorch_biggraph_paper: arxiv.org/abs/1903.12287 (Lerer et al. "PyTorch-BigGraph" SysML 2019)
---

# LinkedIn People-You-May-Know — explicit L0→L1→L2→re-rank funnel + GLMix random effects + PyTorch-BigGraph embeddings

## Bar anchors
- **Mid-level (L4/E4):** "Recommend 2nd-degree connections." No funnel; no fairness re-rank; no calibration.
- **Senior (L5/E5):** Names graph-walk candidates + ML scoring. May or may not address explicit L0→L1→L2→re-rank funnel, calibration sensitivity for marketplace allocation, invitation-decay, or GLMix random effects.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **multi-stage L0→L1→L2→re-rank funnel** with different model class + different evaluation metric per stage. L0 optimized for **recall@k (k≈3000-5000)**, not precision. L1 is **calibration** across heterogeneous candidate sources (graph-walk, EBR, heuristics). L2 is **per-engagement prediction** with deep models (AUC + Precision@k + ECE). Final re-rank handles **fairness** (gender, age protections), **diversity**, **power-user dampening**. Names **graph-traversal**: 2nd-degree neighbors dominate candidate pool; n-hop walks limited by computational cost. Names **impression-discounting** (downranking PYMK results shown but ignored) creates counterfactual feedback issue: ignored ≠ disinterested. Cites **GLMix** [Zhang KDD 2016]: fixed-effect GLM + per-user / per-job random-effect coefficients; per LinkedIn published results: "GLMix models trained using Photon ML improved job recommendations by 15 to 30 percent in job applications." Names **log-loss over AUC** because downstream allocations require calibrated probabilities; recalibration formula `q = p/(p + (1-p)/w)` corrects for negative downsampling. Names **invitation-decay** anti-popularity-runaway: as recipient accumulates pending invites, threshold to appear as candidate increases. Stretch (Sr Staff bar): cites **PyTorch-BigGraph** [Lerer SysML 2019] — Freebase 121M entities × 2.4B edges; 88% memory reduction; 4× distributed speedup.

## Canonical decomposition

### Requirements
**Functional:**
- L0 retrieval: graph-walks + EBR via GraphSAGE-style GNN over 1B-node graph
- L1 calibration ranker across heterogeneous L0 sources (XGBoost)
- L2 per-engagement deep ranker (DNN with pair features)
- Re-rank: fairness, diversity, power-user dampening
- Daily refresh for most users

**Non-functional (with numbers):**
- ~1B LinkedIn members
- Per LinkedIn KDD'14: "daily processes 100s of terabytes of data, 100s of billions of potential connections"
- L0 selects few thousand candidates from billions; Recall@k k=3K-5K
- L1 narrows to 500-800; L2 down to ~100 with AUC + Precision@k + ECE
- GLMix: +15-30% job applications [LinkedIn published]
- PyTorch-BigGraph: Freebase 121M entities × 2.4B edges; 88% memory reduction; 4× distributed speedup

### Core entities
- **Member:** member_id, profile (education/workplace with timespans, location, interests), behavior history
- **Candidate pair:** (requester, candidate) with pair features (mutual_friend_count, education_overlap, workplace_co_tenure, location, real-time interaction counters)
- **Graph:** 1B-node connection graph with edge weights (interaction recency, mutual friend strength)
- **L0 sources:** graph-walks (n-hop), EBR (GraphSAGE embedding similarity), heuristics (same school/employer/geography)
- **Fatigue state:** per-recipient pending-invite count → threshold multiplier

### API
- `GET /pymk/{member_id}` → daily-refreshed list of suggested connections
- Internal: l0.retrieve(member) → ~thousands; l1.calibrate(candidates) → ~500-800; l2.score(member, candidates) → ~100; rerank.apply_fairness_diversity_fatigue(scored)

### HLD
**L0 retrieval** combines: graph-walks (FoF at 1-2 hops; cheap, range-limited; misses candidates beyond 2-hop), EBR via GraphSAGE GNN over 1B-node graph (finds candidates beyond 2-hop range; doubles as re-ranker of FoF candidates), simple heuristics (same school/employer/geography). **L1 light ranker** (XGBoost): calibration over heterogeneous L0 sources so scores are comparable; cheap pair features; Recall@k 500-800. **L2 heavy ranker** (deep NN with rich pair features): predict P(invite_sent), P(invite_accepted), P(message); AUC + Precision@k + ECE. **L3 re-ranker**: Bayesian optimization of multi-objective weights; fairness (gender/age protections via constrained optimization); diversity (don't show 5 connections from same company); **power-user dampening** (invitation-decay). **Daily batch** for most users; per-event refresh for new members. **GLMix** stack: shared fixed-effect GLM + per-user random-effect + per-item random-effect coefficients; trained via Photon ML. **PyTorch-BigGraph** for 1B-node embedding generation (Lerer SysML 2019).

### Deep dives
1. **L0→L1→L2→re-rank funnel.** Each stage has different model class + different evaluation metric. L0: recall@k optimization (3K-5K); L1: calibration; L2: per-engagement deep NN; L3: business constraints. Why staged: L0 produces heterogeneous candidates from multiple sources at different score scales — L1 calibrates so L2 sees comparable inputs; L2 is expensive so must run on small set; L3 enforces non-ML constraints (fairness, diversity).

2. **GLMix + calibration for marketplace allocation.** GLMix architecture: shared fixed-effect GLM + per-user random-effect coefficients + per-item random-effect coefficients. Captures global trends + per-user heterogeneity + per-item heterogeneity in one trainable model. Trained via Photon ML (open-sourced). **Why log-loss over AUC**: AUC measures rank-correlation but is insensitive to absolute probability scale; LinkedIn's downstream allocator needs **calibrated probabilities** because P(accept) drives expected-utility ranking. **Recalibration after negative downsampling**: training samples downsampled to balance classes (e.g., 1:10 positive:negative); inference probabilities `p` need recalibration via `q = p / (p + (1-p)/w)` where `w` is downsampling weight.

3. **Invitation-decay anti-popularity-runaway.** Naive PYMK: top candidates are most-likely-to-accept users → highly-connected users dominate everyone's PYMK → recipients spammed with invites → quality degrades. **Solution**: as recipient accumulates pending invites, raise their threshold to appear as candidate. **Mechanism**: per-recipient "fatigue" multiplier on candidate score; saturating over time. Result: user with 50 pending invites suppressed from PYMK until pending resolve. **Marketplace-fairness mechanism** pure ranking-score optimization would miss.

## Known failure modes
1. **Impression discounting bias.** Downweighting "ignored" results assumes user saw and rejected, but they may not have scrolled. Production answer: explicit "user-actually-saw" signal (viewport visibility, time-on-screen); separate impression-from-rejection.

2. **Fairness re-rank breakage** when group definitions drift. Production answer: per-protected-group monitoring; periodic group-definition audit; explicit equal-opportunity fairness constraints (not just demographic parity).

3. **Cold-start member starvation** for new members with empty graphs. Production answer: bootstrap from explicit signup data (location, industry); leverage email contact-imports as initial graph signal; explicit onboarding-flow connection suggestions.

4. **Spam exploitation** — adversaries optimize profile features to land on PYMK lists. Production answer: spam classifier as L3 filter; adversarial-aware feature selection; community report signal as training input.

5. **Two-stage skew** — L0 and L2 trained on different label distributions → L2 over-promotes a subset of L0 sources. Production answer: joint training; or L2 trained on L0-output distribution explicitly.

## Notes for the coach
- **Asked-confirmed at LinkedIn.** PYMK blog 2023, GLMix KDD 2016, Photon ML 2016, GDMix 2020, PyTorch-BigGraph SysML 2019 — all explicit interview-prep canon.
- **The explicit L0→L1→L2→re-rank funnel with per-stage metrics is the canonical Staff+ unlock.** Candidates who articulate "L0 = recall, L1 = calibration, L2 = AUC+ECE, L3 = fairness" demonstrate funnel-design sophistication.
- **The invitation-decay anti-runaway is the marketplace-fairness deep-cut.** Mid-senior candidates miss it; Staff+ candidates name it because they recognize pure ranking-score optimization breaks two-sided marketplaces.
- **Adversarial probe: "your daily PYMK refresh stalled — what's the user-visible degradation?"** Strong answer: stale candidates (yesterday's still shown; mild quality drop); fall back to graph-walk-only path (cheap, fresh, lower quality); explicit "results may be limited" UX. Weak answer: "we cache" without addressing freshness vs quality trade.

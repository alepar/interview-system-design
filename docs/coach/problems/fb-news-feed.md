---
slug: fb-news-feed
archetype: ml-in-loop
sources:
  meta_newsfeed_2021: engineering.fb.com/2021/01/26/ml-applications/news-feed-ranking/
  meta_transparency: transparency.fb.com (Our Approach to Facebook Feed Ranking)
  twitter_algo_2023: blog.x.com/engineering/en_us/topics/open-source/2023/twitter-recommendation-algorithm
  hello_interview_fb_feed: hellointerview.com/learn/system-design/problem-breakdowns/fb-news-feed
---

# Facebook News Feed ranking — 3-pass funnel + value-model scalarization + DLRM + hybrid fan-out

## Bar anchors
- **Mid-level (L4/E4):** "Sort posts by score." No multi-objective; no impression-budget; no negative-action heads.
- **Senior (L5/E5):** Names multi-stage funnel + multi-task heads. Discusses A/B testing. May or may not address value-model scalarization with negative-action subtraction, survey-weighted labels, hybrid fan-out, or impression budgeting as knapsack.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **multi-objective value-model** scoring: per-post `V_ijt = Σ w_k(j) · P(action_k | user_j, post_i)` summed over actions (like, comment, share, click, hide, report), each with own model and per-user-segment weight, plus **survey-based "meaningfulness" weights** anti-correlating with raw engagement to mitigate clickbait. Per Meta Eng Jan 26 2021: "we survey people about how meaningful they found an interaction with their friends or whether a post is worth their time." Names **3-pass funnel**: Pass 0 lightweight retrieval selects ~500 from inventory → Pass 1 main scoring with multi-task NN → Pass 2 contextual re-rank for diversity/integrity. Names **impression budgeting** (user's session is finite; ranker solves a knapsack, not a sort). Cites ~1000+ posts/user/day scored; ~100,000 ranker weights (replaced EdgeRank affinity×weight×decay by 2013). Names **hybrid fan-out**: write-time for most users (cheap reads); read-time for celebrities (avoid 100M write amplification). Stretch (Sr Staff bar): cites Twitter For-You 50/50 split (in-network via RealGraph + out-of-network via GraphJet/SimClusters/TwHIN; ~48M-param MaskNet heavy ranker emitting 10 engagement probabilities).

## Canonical decomposition

### Requirements
**Functional:**
- Per-user score for each candidate post via multi-task NN
- Multi-objective value blend (likes, shares, comments, click) − (hide, spam-report)
- Diversity + integrity re-rank
- Hybrid fan-out (push for most users; pull for celebrities)
- Survey-weighted labels for anti-engagement-bait

**Non-functional (with numbers):**
- ~3B DAU across Meta surfaces; News Feed serves tens of thousands of candidates per request narrowed to ~100 visible
- ~1000+ posts/user/day scored
- ~100,000 ranker weights [Lars Backstrom MarTech]
- Thousands of features per candidate; ~10 prediction models per candidate in parallel
- Latency <300ms p99 first painted post
- Feed read budget <500ms; up to 1 minute post staleness tolerated [Hello Interview]

### Core entities
- **Inventory:** posts since last login from friends/groups/pages followed
- **Multi-task head outputs:** P(click), P(like), P(share), P(comment), P(dwell), P(hide), P(spam-report)
- **Value model:** linear blend `V = Σ w_k · P_k` with personalized w_k per user segment
- **Predictor servers:** sharded; co-locate feature lookup with scoring
- **Re-rank constraints:** dispersion (no two consecutive from same source), integrity (downrank borderline content), pacing (ads, paid promotion)

### API
- `GET /newsfeed/{user_id}` → ordered posts (with budget for ~100 visible)
- Internal: pass0_retrieval(user) → ~500 candidates; pass1_ranker.score(user, candidates) → MTML probabilities → V; pass2_rerank.apply(scored_candidates) → final order

### HLD
**Pass 0** lightweight model (small MLP, cheap features) selects ~500 most relevant posts from eligible inventory (post-since-last-login + followed-pages + group memberships). **Pass 1 main scoring**: heavier multi-task NN (DLRM-class with sequence transformer over user-action history) scores each of 500 on multiple objectives — P(click), P(like), P(share), P(comment), P(dwell), P(hide), P(spam-report). Each prediction model runs per candidate in parallel on **predictor servers** (sharded; co-locate feature lookup with scoring; request-oriented optimization). **Value model**: `V = Σ w_k(j) · P_k` blending into single score with **per-user weights** (different users care more about likes vs comments). **Negative actions subtracted**: `-W_hide · P(hide) - W_spam · P(spam-report)`. **Survey-weighted labels**: small but pivotal samples re-weight implicit signals (Meta's published anti-engagement-bait mechanism). **Pass 2 contextual ranking** applies diversity (DPP, MMR), integrity, ads injection, pacing. **Hybrid fan-out** at retrieval substrate: write-time push for most users; read-time pull for celebrities.

### Deep dives
1. **3-pass funnel with explicit value model.** Pass 0: lightweight model (cheap; reduces inventory to ~500). Pass 1: heavy multi-task NN scores each candidate on multiple objectives. Pass 2: contextual ranking + diversity + integrity. **Value model**: `V = Σ w_k · Y_k` where `w_k` are personalized weights, `Y_k` are head probabilities. **Negative actions** explicitly subtracted (per Meta Eng): "what's the probability you'll hide this story?" — `-W_hide · P(hide)` mitigates clickbait. This is the canonical multi-objective scalarization that Facebook publishes.

2. **DLRM as ranking architecture + predictor server.** See `ctr-prediction` for full DLRM details. Production implications for Feed: embedding tables dominate (user_id, page_id, post_id, content features); MLPs small (dense: time-of-day, recency, network distance); pairwise feature interactions capture user × post affinity. **Predictor servers**: sharded prediction; co-location of feature lookup with scoring; request-oriented optimization shares user-representation across thousands of candidates.

3. **Hybrid fan-out (Hello Interview pattern).** **Write-time fan-out (push)**: when user A posts, write to all followers' feeds. Cheap reads (fetch from feed); expensive writes (N writes per post where N = follower count). **Read-time fan-out (pull)**: gather posts from followed users at read time. Expensive reads; cheap writes. **Hybrid**: write-time for most users (cheap reads); read-time for celebrities (avoid 100M write amplification at celebrity post time). Read latency <500ms; up to 1 minute post staleness tolerated.

## Known failure modes
1. **Negative-action under-prediction.** Hide / spam-report events are rare; classifier under-fits. Production answer: separate per-class classifiers with class-imbalance handling (focal loss, weighted sampling); aggressive negative-action weighting in value model; explicit user-feedback collection.

2. **Calibration drift across heads.** Multi-task model heads drift independently; if hide-head over-predicts, value model over-suppresses content. Production answer: per-head calibration monitor; per-task isotonic regression post-hoc; head-specific monitoring during rollout.

3. **Filter bubble + reciprocal feedback.** Engagement-heavy users see more engaging content; entrenches narrow interests. Production answer: explicit diversity targets in Pass 2; explore arm in value model; periodic "fresh content" injection from underrepresented categories.

## Notes for the coach
- **Asked-confirmed at Meta** (Facebook + Instagram + Threads). Meta Engineering News Feed Ranking blog + Transparency Center are explicit interview-prep canon.
- **The value-model scalarization with negative-action subtraction is the canonical Staff+ unlock.** Candidates who default to "engagement = clicks" miss the multi-objective framework entirely.
- **The survey-weighted labels mechanism is the Staff+ depth probe.** Mid-senior candidates miss it; Staff+ candidates name it as Meta's explicit anti-clickbait countermeasure published in 2021.
- **Adversarial probe: "value-model blend tunes a knob — how do you know if a weight change is safe?"** Strong answer: per-objective offline metrics + holdout A/B with reverse-chronological control (no-ranking baseline) + slow ramp + auto-rollback on integrity/sentiment regression. Weak answer: "we A/B test" without addressing the per-head calibration interactions.

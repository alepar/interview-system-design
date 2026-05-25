---
slug: spam-abuse-ranking
archetype: ml-in-loop
sources:
  twitter_botmaker_2014: blog.twitter.com/engineering/en_us/a/2014/fighting-spam-with-botmaker
  twitter_spam_drift_2016: dl.acm.org/doi/10.1145/2897845.2897928 (MobiHoc 2016 "Twitter Spam Drift")
  pinterest_spam_blog: medium.com/pinterest-engineering/how-pinterest-fights-spam-using-machine-learning
  linkedin_viral_spam_2023: engineering.linkedin.com/blog/2023/viral-spam-content-detection-at-linkedin
  reddit_crossmod_2019: dl.acm.org/doi/10.1145/3338243
---

# Spam / abuse detection ranking — Twitter BotMaker 3-tier + Spam Drift + propagation features + Reddit AutoModerator + Pinterest hybrid

## Bar anchors
- **Mid-level (L4/E4):** "Classify spam with a model." No latency tier; no rule-then-ML; no adversarial drift awareness.
- **Senior (L5/E5):** Names spam classifier + rule layer. Discusses retraining. May or may not address 3-tier latency architecture, rule-DSL hot-deploy, propagation features, or label-scarcity mitigations.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **3-tier architecture by latency budget** — Twitter BotMaker's **Scarecrow** (write-time, sub-100ms, blocks at write-path of Tweet/Retweet/follow/favorite/DM before publish — must not add user-visible latency); **Sniper** (continuous near-real-time post-publish); **periodic models** (score user behavior over days/weeks). Cites **rule-DSL hot-deploy**: engineers create new rules/models that deploy in minutes (not retrain cycles); result: 40% reduction in overall spam metrics, 55% drop in spam content written. Names **Twitter Spam Drift** as named phenomenon — statistical properties of spam tweets vary over time; classifier performance degrades without retraining. Cites **user + content + propagation features**: user-based (account age, follower/following ratio, profile completeness), content-based (URL, n-grams, LM perplexity), propagation-based (retweet graph patterns). **Propagation features alone add ~20% accuracy** over user+content. Names **Reddit's intentional rule-first posture** (AutoModerator wiki of regex rules per-subreddit hand-tuned by mods + Crowd Control ML+heuristic trust gating); research finds mods want audit tools to tune FP rates → rule-then-ML is deliberate. Names **Pinterest hybrid** (lightweight unsupervised clustering for early-emerging-pattern detection + DNN classifier batch-scored as PySpark+Tensorflow job). Stretch (Sr Staff bar): names **semi-supervised label propagation** on bipartite (user × domain) graphs for label scarcity.

## Canonical decomposition

### Requirements
**Functional:**
- 3-tier latency hierarchy: write-time blocking + near-real-time + periodic
- Rule-DSL for fast deployment of patterns
- Multi-feature-family scoring (user + content + propagation)
- Per-community / per-platform calibrated thresholds
- Cold-start handling for new behavior patterns

**Non-functional (with numbers):**
- Twitter BotMaker launch: 40% reduction in spam metrics; 55% drop in spam content written
- Random Forest on Twitter spam: 95.7% precision / 95.7% F1 [ResearchGate]
- Propagation features +20% accuracy over user+content alone
- Pinterest: PySpark+Tensorflow batch scoring of millions of Pinners
- Reddit AutoModerator: regex rules per-subreddit, mod-configurable

### Core entities
- **Account:** account_id, age, follower/following ratio, profile completeness, behavioral history
- **Content:** text, URLs, embedded media, n-grams, language-model perplexity score
- **Propagation graph:** retweet graph patterns, reply chains, coordinated-action detection
- **Rule:** DSL-defined pattern with deploy timestamp + per-rule FP rate
- **Decision:** allow / block / shadow-ban / human-review-queue

### API
- Write-path: `POST /tweet` → Scarecrow check sub-100ms → allow or block at source
- Post-publish: Sniper continuously classifies (background)
- Periodic: account-reputation models score user behavior days-to-weeks
- Internal: rule_engine.evaluate(payload) → list of triggered rules; ml_classifier.score(features) → probability; combined_decision(rules, ml_score)

### HLD
**Scarecrow (write-time, sub-100ms)**: lightweight classifiers + rule DSL applied on write-path of Tweet/Retweet/follow/favorite/DM. Must not add user-visible latency to core actions. Blocks dubious account names + URLs before publish. **Sniper (continuous near-real-time)**: heavier ML post-publish; classifies users + content Scarecrow missed. **Periodic models**: account-level reputation scored over days/weeks; account_id-level batch scoring. **Rule DSL**: engineers create rules that deploy in minutes (not retrain cycles) — critical because adversaries adapt faster than retrain cycles. Per Twitter BotMaker 2014 launch: 40% spam-metric reduction, 55% spam-content reduction. **Feature pipelines**: user features (account age, follower ratio); content features (URL/n-gram/LM perplexity via Kafka + Flink stream processors); propagation features (retweet graph patterns via batch graph processing). **Graph-based detection** (FraudEagle, SPEagle, DeFrauder) catches coordinated rings where individual items look benign but collective coordination signature doesn't. **Reddit AutoModerator** layered over Crowd Control (ML+heuristic auto-collapse for users without sufficient subreddit-specific karma — per-community trust gating). **Pinterest hybrid**: unsupervised clustering early-detection + DNN classifier batch via PySpark+Tensorflow. **Bipartite label propagation** (user × domain) for label scarcity — small seed labels propagate scores across edges.

### Deep dives
1. **Twitter BotMaker 3-tier with latency budget.** **Scarecrow (write-time, sub-100ms)**: identifies dubious account names + URLs before publish; blocks at write-path of Tweet/Retweet/follow/favorite/DM. **Latency constraint**: cannot add user-visible latency to core actions → lightweight classifiers + rule DSL only. **Sniper (continuous near-real-time)**: heavier ML post-publish; classifies users + content Scarecrow missed. **Periodic models**: account-level reputation over days/weeks. **Rule DSL** for hot-deploy: engineers deploy new rules in minutes, not retrain cycles — critical for spam where adversaries adapt faster than retrain cycles.

2. **Twitter Spam Drift + propagation features + ring detection.** **Spam Drift**: statistical properties of spam tweets vary over time; classifier performance degrades without retraining. Observable as smooth quality-metric decay; regression-test against. **Feature families**: user-based (account age, follower/following ratio, profile completeness), content-based (URL, n-grams, LM perplexity), propagation-based (retweet graph patterns). **Propagation features alone add ~20% accuracy** over user+content — coordinated rings produce distinctive graph patterns single-tweet features miss. **Graph-based ring detection** (FraudEagle: Belief Propagation on bipartite reviewer-product graph with edge potentials from review sentiment; SPEagle: improves with richer node/edge meta-data; DeFrauder: unsupervised group detection) — catches coordinated rings where individual items look benign but collective coordination doesn't.

3. **Reddit rule-first + Pinterest hybrid + cold-start mitigation.** **Reddit AutoModerator**: wiki of regex rules per-subreddit, hand-tuned by mods. **Crowd Control**: ML + heuristic auto-collapses comments from users without sufficient subreddit-specific karma (per-community trust gating; ML-driven). Research [Crossmod 2019]: mods explicitly want **audit tools to tune FP rates** — rule-then-ML is deliberate posture, not transitional. **Pinterest hybrid**: lightweight unsupervised clustering for early-emerging-pattern detection (catches what classifiers haven't been trained on yet) + DNN spam-user classifier batch-scored as PySpark+Tensorflow job over millions of users. **Bipartite label propagation** (user × domain): small labeled seed sets propagate scores across edges → labels for unseen entities. **Cold-start unsolved**: new users have no behavior history (strongest feature); behavioral signals take weeks to accumulate; published mitigations use GANs to synthesize plausible behavior features from easily-accessible features.

## Known failure modes
1. **Spam Drift quality decay.** Production answer: continuous per-class precision/recall monitoring; automated retraining triggers; rule-DSL hot-deploy for emerging patterns ahead of retrain.

2. **False-positive over-block.** Mod-flagged "good content blocked." Production answer: audit tools (Reddit research finding); per-rule precision targets; explicit human-review queue for ambiguous; Crowd-Control-style "collapse" not "delete" allows reversibility.

3. **Cold-start label scarcity.** New behavior pattern has no labels. Production answer: semi-supervised propagation (bipartite graph); GAN-synthesized behavior features; manual seed-labeling sprint at platform launch.

## Notes for the coach
- **Asked-confirmed at Twitter (pre-Musk era), Reddit, Pinterest, LinkedIn.** Twitter BotMaker 2014 engineering blog, Twitter Spam Drift MobiHoc 2016, Pinterest spam blog, LinkedIn viral-spam blog 2023, Reddit Crossmod 2019 research — all explicit interview-prep canon.
- **The 3-tier architecture (Scarecrow/Sniper/periodic) is the canonical Staff+ unlock.** Candidates who default to "classify everything in one pass" miss the latency-tier-by-action-importance design.
- **The rule-DSL-hot-deploy pattern is the depth probe.** Spam moves faster than retrain cycles — Staff+ candidates name DSL deploy as the adversarial-velocity countermeasure.
- **The Reddit deliberate-rule-first posture is the broader Staff+ wisdom.** Production moderation systems intentionally layer rules-then-ML because mods need audit tools to tune false-positive rates — not all problems should be pure-ML.
- **Adversarial probe: "spam classifier accuracy drops 5% in one week — what now?"** Strong answer: Spam Drift detected; deploy rule-DSL for emerging patterns ahead of retrain (fast); kick off retraining job (slow); validate via shadow-mode before swap; per-class precision/recall monitor confirms recovery. Weak answer: "we retrain" without addressing the time-to-recovery during the drift window.

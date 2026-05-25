---
slug: medium-following-feed
archetype: fan-out
sources:
  digest_p1: medium.engineering/engineering-stories-behind-the-medium-daily-digest-algorithm-part-1-909a7ca5e807
  digest_p2: medium.engineering/engineering-stories-behind-the-medium-daily-digest-algorithm-part-2-c977ad0b134f
  digest_p4: medium.engineering/engineering-stories-behind-the-medium-daily-digest-algorithm-part-4-ec7136f21acd
---

# Medium following feed + Daily Digest — 15-story fixed-shape daily artifact + unified ranking model serves both on-platform feed AND email digest (surface-specific filter chains only) + Bloom-filter dedup → user-keyed DB queries + 7-day backoff tuned to 4-day = 10% conversion lift + oversteering toward repetition for power users + Neo4j follow-graph + multiple subscription primitives (digest / writer / publication newsletter)

## Bar anchors
- **Mid-level (L4/E4):** Designs append-only follower inbox.
- **Senior (L5/E5):** Names digest + ranking. May or may not articulate unified-model-multi-surface, Bloom-filter dedup, or backoff tuning.
- **Staff+ (L6/E6+):** Names (a) **15-story fixed-shape artifact** per user per day; 1 story reserved as email subject line + disqualified from future digests; (b) **unified ranking model** for BOTH on-platform "For You" feed AND email Daily Digest — same candidate sourcing, same ML model, same feature set; surfaces differ ONLY by post-ranking filters (digest stricter than homepage); (c) **Bloom-filter dedup** (Filter Read, Presentation Filter, Sent-in-Opened-Digest Filter) → later migration to user-keyed direct DB queries; (d) **7-day backoff tuned to 4-day** + converted hard rules to soft scoring features → 10% lift in member conversion; (e) **oversteering risk**: removing too many hard filtering rules caused digest power users to see repetitive content; re-introduced soft filters; (f) **multi-channel notification surface**: Daily Digest email (algorithmic), New-Stories-from-Subscribed-Writers email (author-subscription, separate channel), per-publication newsletter (independent) — multiple subscription primitives on same follow graph; (g) **Neo4j graph DB** for follow graph + recommendations (chosen over DynamoDB/MySQL/FlockDB); (h) **pixel-based email opens degraded** by Apple Mail Privacy Protection — conservative about treating opens as confirmed reads.

## Canonical decomposition

### Requirements
**Functional:**
- Follow author / publication
- "For You" on-platform feed
- Daily Digest email (15 stories)
- New-Stories-from-Subscribed-Writers email
- Per-publication newsletter subscription

**Non-functional:**
- 15 stories/user/day; "millions of readers every day"
- 4-day backoff window (tuned from 7-day) = 10% member conversion lift
- Pixel-based email opens weakened by Apple Mail Privacy Protection

### Core entities
- **Story:** story_id, author_id, publication_id, tags[], created_at, signals
- **Follow:** user_id, target_type ∈ {author, publication, topic}, target_id
- **DigestRecord:** user_id, date, story_ids[], subject_story_id
- **PresentationLog:** user_id, story_id, presented_at, surface ∈ {feed, digest, newsletter}

### API
- `POST /follows` body={target_type, target_id}
- `GET /feed?cursor=<>` → on-platform For You
- Email pipeline: daily cron → per-user digest

### HLD
Candidate sourcing: Neo4j follow-graph traversal + topic affinity + collaborative-filtering recs → candidate pool per user.

Unified ranking model: ML scorer (gradient-boosted or DNN) over feature set {actor, item, recipient, context}. Same model serves both Feed Service (read-time) and Digest Pipeline (daily batch).

Surface-specific filter chains:
- **Feed**: minimal filters; allow recent content + diversity
- **Digest**: stricter — Filter Read (Bloom), Presentation Filter (Bloom: remove posts presented ≥3× to same user), Sent-in-Opened-Digest Filter (Bloom: avoid re-sending opened content), 4-day backoff window

Digest pipeline: daily batch job; per user → candidates → unified ranker → digest filters → top-15 with 1 reserved as subject line story; render + send via SendGrid.

### Deep dives
1. **Unified model + multi-surface filter chains.** ONE candidate sourcing + ML model + feature set serves Daily Digest AND on-platform For You. Surfaces differentiated ONLY by post-ranking filters (digest stricter). Architectural pattern: one model, many distribution surfaces with surface-specific filter chains.
2. **Bloom-filter dedup → DB-query migration + backoff tuning.** Bloom for fast cheap "have we presented this to user" lookups. Presentation Filter = remove posts presented ≥3× (soft → score feature). Sent-in-Opened-Digest Filter to avoid re-sending opened content. Migration to user-keyed DB queries as scale grew. Backoff 7-day → 4-day = 10% lift. **Oversteering**: filter removal caused power-user repetition; re-introduced soft filters.
3. **Multi-channel surface + Neo4j follow graph.** Channels: Daily Digest (algorithmic 15-story), New-Stories-Subscribed-Writers (author-subscription, separate), per-publication newsletter (independent). Multiple subscription primitives on same follow graph. Neo4j chosen over DynamoDB/MySQL/FlockDB — graph traversal drives distribution.

## Known failure modes
1. *Digest staleness for power users* — over-removed filters → repetition. Production answer: soft scoring features instead of hard rules; per-user diversity tracking; A/B test re-introduce.
2. *Email-tracking signal degradation* — pixel opens weakened by Apple Mail Privacy Protection. Production answer: weight in-app engagement higher in training; conservative about treating opens as confirmed reads.
3. *Cold-start subscriber* — new user has no follow graph. Production answer: bootstrap from topic affinity + onboarding survey + popular content default.

## Notes for the coach
- **Plausibly-asked at Medium.** 4-part Daily Digest engineering series is canon. Neo4j case study covers graph DB choice.
- **Cross-coverage** with ML-in-loop (digest model). With `email-digest-pipeline` (canonical email-digest patterns). With `notification-aggregation-service` (multi-channel surface).
- **The unified-model-multi-surface pattern is the canonical Staff+ unlock.** Mid-senior candidates design separate models per surface; Staff+ candidates name one model + surface-specific filter chains.
- **Adversarial probe: "User complains digest shows same 3 authors every day. What's wrong with the filter chain?"** Strong answer: Presentation Filter hard cutoff at "≥3× presented" lets borderline-popular authors saturate digest slots; needs soft diversity feature in ranker rather than post-rank filter; backoff window may also be too short (4-day means same author can reappear every 5 days). Production answer = multiplicative diversity demotion (Instagram-style). Weak answer: "increase backoff" without naming the soft-vs-hard trade.

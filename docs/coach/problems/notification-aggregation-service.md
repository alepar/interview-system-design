---
slug: notification-aggregation-service
archetype: fan-out
sources:
  linkedin_atc: linkedin.com/blog/engineering/messaging-notifications/air-traffic-controller-member-first-notifications-at-linkedin
  linkedin_concourse: engineering.linkedin.com/blog/2018/05/concourse--generating-personalized-content-notifications-in-near
  pinterest_nep: medium.com/pinterest-engineering/nep-notification-system-and-relevance-a7fff21986c7
  pinterest_user_state: medium.com/pinterest-engineering/user-state-based-notification-volume-optimization-7764118f73ff
  ig_uplift: engineering.fb.com/2022/10/31/ml-applications/instagram-notification-management-machine-learning/
  ig_diversity_2025: engineering.fb.com/2025/09/02/ml-applications/a-new-ranking-framework-for-better-notification-quality-on-instagram/
  slack_rebuild: slack.engineering/how-slack-rebuilt-notifications/
  slack_tracing: slack.engineering/tracing-notifications/
---

# Notification aggregation service — "X and 27 others liked your post" + LinkedIn ATC (Samza+RocksDB per-user queue, member-historical batching, 1B+ req/day, p90 12s→1.5s) + Pinterest NEP (multi-head ranker push/email/unsub + PID-controlled volume + 6 user-states) + Instagram causal-inference uplift Pr(active|do(send)) − Pr(active|do(drop)) + budget allocation + 2025 multiplicative diversity demotion D(c) = ∏(1 − w·p) + Slack rebuild 5× settings engagement + 100%-sampled trace IDs

## Bar anchors
- **Mid-level (L4/E4):** Pushes individual notifications per event; no collapsing.
- **Senior (L5/E5):** Names collapse by (action_type, target_id). May or may not articulate uplift modeling, per-user queue with delayed aggregation, multi-channel selection, or diversity demotion.
- **Staff+ (L6/E6+):** Names (a) **LinkedIn ATC** per-user RocksDB queue on local SSDs inside Samza; member-keyed state (tracking, device, settings, historical profile); RocksDB reads ~couple ms vs 10-100ms remote; aggregation example "a week of invitation reminders → one email"; channel selection from member settings + app-install state + ML click-prob + disable-rate; **1B+ requests/day; p90 12s→1.5s**; (b) **LinkedIn Concourse**: feature store hundreds of billions of records / several TB; pipeline priority separation (sub-second messaging vs hours-tolerant Daily Rundown 100M-request batch); (c) **Pinterest NEP** multi-head GBDT (push-open / email-click / unsub); Policy sends if utility > segment threshold; **PID controller** auto-tunes per-segment thresholds aligning realized volume to target — replaces manual tuning that drifted; (d) **Pinterest user-state segmentation** 6 activity states / 2 groups; GBDT WAU-optimized binary low-engagement / DAU-optimized multi-label high-engagement; A/B +1% WAU / +17% resurrected / -3% dormant; (e) **Instagram causal-inference uplift**: ui = Pr(active|do(send)) − Pr(active|do(drop)) trained via 50% random-drop; stopped sending digests to already-active users; **budget allocation**: fixed daily budget, sort by uplift, top-N within budget; online quantile-computation stabilizes send rates across retrains; (f) **2025 multiplicative diversity demotion** D(c) = ∏(1 − w_i × p_i(c)); dimensions = content, author, type, surface; Final = R(c) × D(c); (g) **Slack rebuilt**: 5× settings engagement post-launch (decoupled "what" from "how"); notification gets its own trace_id with 100% sampling vs 1% backend (avoids @here/@channel hundreds-of-thousands fan-out span explosion).

## Canonical decomposition

### Requirements
**Functional:**
- Produce notifications for app events (likes, comments, mentions, follows, replies, etc.)
- Aggregate similar events into single notification
- Select delivery channel per (user, notification) — push / email / SMS / in-app
- Rate-limit per user (e.g., 200 msgs/hour)
- Diversity demotion across author/content/type/surface

**Non-functional:**
- LinkedIn ATC: 1B+ notification requests/day; p90 12s → 1.5s
- LinkedIn Concourse: 500K QPS scoring at peak; feature store hundreds of billions of records / several TB
- Pinterest NEP: PID-controlled per-segment volume
- Slack: notification trace_id with 100% sampling vs 1% backend

### Core entities
- **Candidate:** {actor, item, recipient, edge, event_type}
- **MemberState:** RocksDB per-user — tracking, device, settings, historical profile
- **AggregationGroup:** (recipient, action_type, target_id, time_window) → list of candidates
- **DeliverySlot:** (recipient, channel, scheduled_at)

### API
- Internal: `enqueue(candidate)` from producer services
- Internal: `subscribe(recipient, channel, pref)` from settings UI

### HLD
Concourse (LinkedIn): producer event → actor-partitioned Kafka topic → Samza fanout job emits (candidate, recipient) → **re-partitioned by recipient_id** onto downstream Kafka topic → recipient-partitioned Samza scoring task → loads 4 feature categories from local RocksDB cache → predicts click-prob + disable-rate → publishes to ATC.

ATC (LinkedIn): per-user RocksDB queue on local SSDs; absorbs N candidates over rolling window; periodic aggregation pass collapses by (action_type, target_id); channel selection per notification from member settings + app-install + ML score; rate-limit per user; emits to delivery gateway (APNs/FCM/SES).

Uplift gating (Instagram pattern): each candidate scored by uplift model trained via 50%-random-drop experiments; sort by uplift; admit top-N within fixed daily budget; quantile-computation stabilizes thresholds across retrains.

Diversity demotion (Instagram 2025): D(c) = ∏(1 − w_i × p_i(c)) over (content, author, type, surface); Final = R(c) × D(c).

Tracing: each notification gets dedicated trace_id (notification_id) with span links to originating message; 100% sampling for notification flows vs 1% for backend requests (avoids @here/@channel fan-out span explosion).

### Deep dives
1. **LinkedIn ATC + Concourse 2-layer.** Concourse = nearline fanout + feature decoration + scoring on Samza/Kafka/RocksDB; Kafka actor-partitioned pre-fanout, recipient-partitioned post-fanout (all candidates for recipient → same scoring host). ATC = per-user delay queue + channel selection. Aggregation: week of invites → one email.
2. **Pinterest NEP multi-head + PID volume + user-state segmentation.** Multi-head GBDT (push-open / email-click / unsub). Policy sends if utility > threshold. PID controller auto-tunes thresholds for target volume. User-state segmentation: 6 states / 2 groups / different GBDT objectives. A/B +1% WAU / +17% resurrected / -3% dormant.
3. **Instagram causal-inference uplift + diversity demotion.** Uplift = Pr(active|send) − Pr(active|drop) via 50% random-drop. Budget = fixed daily × top-N by uplift. Quantile-computation stabilizes across retrains. 2025 diversity: D(c) = ∏(1 − w·p); dimensions = author, content, type, surface; Final = R × D.

## Known failure modes
1. *Spam-fatigue from no aggregation* — 27 individual "X liked your post" pushes. Production answer: ATC-style aggregation by (action_type, target_id) within 1-hour window.
2. *Channel mis-selection* — push to user who only opens email. Production answer: ML per-channel CTR + user-historical opt-out patterns.
3. *Diversity collapse* — all notifications from same author. Production answer: 2025 multiplicative demotion D(c) penalizes repeat-author / type / surface.

## Notes for the coach
- **Asked-confirmed at Meta (Instagram), LinkedIn, Pinterest.** Engineering blogs are canon. Slack also published rebuild + tracing posts.
- **Cross-coverage** with messaging `push-notification` (delivery gateway). With ML-in-loop (uplift modeling, diversity, ranking).
- **The causal-inference uplift Pr(active|do(send)) − Pr(active|do(drop)) is the canonical Staff+ unlock.** Mid-senior candidates rank by CTR; Staff+ candidates name the do-calculus framing + 50%-random-drop training + budget allocation.
- **Adversarial probe: "User says they get spammed despite all your ML. What's still wrong?"** Strong answer: rank-by-CTR ≠ rank-by-uplift (high-CTR sends to user who'd visit anyway); diversity demotion D(c) needed beyond ranker; per-user rate-limit (e.g., 200/hour) still binds; user-state segmentation may have misclassified them. Weak answer: "lower the threshold" without naming uplift vs CTR.

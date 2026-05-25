---
slug: youtube-subscriptions
archetype: fan-out
sources:
  yt_notif: support.google.com/youtube/answer/7457584
  yt_personalized: support.google.com/youtube/answer/3382248
  yt_websub: developers.google.com/youtube/v3/guides/push_notifications
  yt_2025_change: tubefilter.com/2025/03/27/youtube-subscriber-notifications-new-flow-update/
---

# YouTube subscriptions — subscription-only delivery + 3 notifs/channel/24h hard cap + bell tri-state (None/Personalized/All) with ML gating + 10-20 min staggered per-user optimal-time scheduling + WebSub public per-channel topics + Subscriptions-tab algorithmic-vs-chronological split

## Bar anchors
- **Mid-level (L4/E4):** Pushes a notification to every subscriber on upload. No throttle, no gating, no scheduling.
- **Senior (L5/E5):** Names per-channel rate-limit + opt-in. May or may not articulate ML personalization gating, per-user staggered scheduling, or publisher-side gating.
- **Staff+ (L6/E6+):** Names (a) **hard per-channel cap**: max 3 upload+livestream notifications from each channel per 24h — exceeding suspends notifications from that channel for 24h; (b) **bell-icon tri-state** per (user, channel): None / Personalized (default) / All; Personalized gated by ML using watch history, recency, channel popularity, notification open rates; (c) **staggered delivery** with per-user optimal-time scheduling: "10-20 minutes for all notifications to be sent; Personalized notifications sent at optimal time for each individual subscriber, which might mean some subscribers get their notification hours after you publish"; (d) **per-upload publisher gating**: "Publish to subscriptions feed and notify subscribers" checkbox; when disabled excludes from BOTH subscription feed AND notification queue; (e) **WebSub (PubSubHubbub) public per-channel topic feeds** `videos.xml?channel_id=...` — external subscribers POST to hub to register callback; implies channel-level new-video events are first-class topics internally; (f) **Subscriptions tab algorithmic vs chronological split**: "Most Relevant" (default) algorithmic, "Latest from your Subscriptions" preserves chronological — same subscription store, two ranking strategies; (g) **2025 disengaged-subscriber pruning** silences notifications for channels user stopped engaging with.

## Canonical decomposition

### Requirements
**Functional:**
- Subscribe/unsubscribe to channel
- Bell tri-state per channel (None/Personalized/All)
- Subscriptions tab (Most Relevant + Latest variants)
- WebSub public per-channel topic feeds
- Per-upload publisher notification gating

**Non-functional:**
- ~2.5B logged-in MAU; 500+ hours uploaded/minute; ~35K channels with >1M subscribers
- 3 notifs/channel/24h hard cap; 10-20 min full fan-out window
- Top channels reach 100M+ subscribers per upload event

### Core entities
- **Channel:** channel_id, owner_id, subscriber_count
- **Video:** video_id, channel_id, publish_notification_enabled, created_at
- **Subscription:** user_id, channel_id, notification_pref ∈ {none, personalized, all}
- **NotificationEngagement:** user_id, channel_id, opens, watches, clicks

### API
- `POST /subscribe` body={channel_id, notification_pref}
- `PUT /subscribe/:channel_id` body={notification_pref}
- WebSub: `POST https://pubsubhubbub.appspot.com/subscribe` body={hub.topic, hub.callback}

### HLD
Publish path: Upload Service writes video metadata. If `publish_notification_enabled=true`, publishes `video.published` event to per-channel Kafka topic + invokes Subscription Notification Service. SNS fetches subscribers; partitions into 3 cohorts (None=skip, All=immediate, Personalized=ML-gated). For Personalized cohort, runs each (user, channel, video) through ML model predicting open-probability; below threshold = skip. For users above threshold, places into per-user Scheduler queue with optimal-send-time (timezone + engagement model).

Delivery path: Scheduler dispatches at scheduled time via FCM/APNs push gateway. Throttle enforces per-(user, channel) rolling count; if user has received ≥3 in 24h from this channel, drops + flags 24h suspension.

WebSub public path: hub maintains subscriber list per channel topic; on `video.published`, POSTs payload to all registered callbacks.

### Deep dives
1. **3 notifs/channel/24h hard cap + staggered delivery.** Per-channel back-pressure built into SNS. Exceeding cap suspends 24h. Staggered: notifications NOT pushed instantly; 10-20 min to fully fan out; per-user scheduling layer picks "optimal time" via timezone + engagement-prediction. Implies queue between upload event and push gateway with per-user dispatch.
2. **Bell tri-state + ML gating.** Per (user, channel) tuple: None / Personalized (default) / All. Personalized gating uses watch history, recency, channel popularity, notification open rates. Storage: (user_id, channel_id, notification_pref) not a global subscription bit.
3. **WebSub public + Subscriptions-tab algorithmic-vs-chronological.** WebSub exposes per-channel feed publicly: `videos.xml?channel_id=...`. External subscribers register callback. Subscription tab UI offers algorithmic Most Relevant (default) + chronological Latest — same subscription store, two ranking strategies overlaid at read time (Twitter-style home/follow split).

## Known failure modes
1. *Notification storm from prolific channel* — 3/24h cap prevents but only after first 3 fire. Production answer: per-channel rate-limit at producer.
2. *Cold-start subscriber* — no engagement history for ML personalization. Production answer: bootstrap from device + locale + topic affinity until N notifications observed.
3. *Disengaged-subscriber notification spam* — user hasn't watched in 6 months but still gets pushes. Production answer: 2025 disengagement-based pruning suppresses push channel; still pushes to in-app inbox.

## Notes for the coach
- **Asked-plausibly at YouTube/Google.** Help docs + Tubefilter 2025 pruning coverage are public; engineering blog material limited.
- **Cross-coverage** with messaging `push-notification` (delivery channel). With `notification-aggregation-service` (ML gating pattern).
- **User has Snapchat-side intuition for friend-feed delivery (Snap Discover analog); surface as adjacent reference.**
- **The 3-notifs/channel/24h cap + per-user optimal-time scheduling is the canonical Staff+ unlock.** Mid-senior candidates push immediately; Staff+ candidates name the throttle + scheduling layers.
- **Adversarial probe: "MrBeast uploads at midnight. 200M subscribers, 100M with All bells. How long until everyone's notified?"** Strong answer: 10-20 min full fan-out window per Help docs; per-user optimal-time scheduling means some subscribers receive hours later (e.g., wake-up time in their timezone); Personalized cohort gated by ML — many never receive; Scheduler queue absorbs the burst. Weak answer: "we send 100M pushes immediately" without naming the throttle/scheduler.

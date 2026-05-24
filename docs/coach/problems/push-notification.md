---
slug: push-notification
archetype: realtime-messaging
sources:
  apns_docs: developer.apple.com/documentation/usernotifications
  fcm_docs: firebase.google.com/docs/cloud-messaging
---

# Push notification — APNs + FCM gateway at 1B+ devices

## Bar anchors
- **Mid-level (L4/E4):** Treats push as "send to APNs/FCM." Doesn't address payload constraints, priority semantics, or token lifecycle.
- **Senior (L5/E5):** Names APNs payload cap (4KB), FCM topic messaging, retry on failure. May or may not address per-project rate limits, token cleanup on 410 Unregistered, or topic-sharding for 1M-subscriber broadcasts.
- **Staff+ (L6/E6+):** Drives proactively. Articulates (a) **APNs payload + priority semantics** — 4 KB regular / 5 KB VoIP; `apns-priority=10` (immediate) vs `5` (power-considerate, mandatory for silent push); (b) **FCM fan-out limits** — 1,000 concurrent fanouts/project; ~10K QPS topic send (not SLA); 2,000 topic subs/instance; 3,000 QPS subscription rate; (c) **TTL + collapse_key semantics** — FCM default 4 weeks; `apns-expiration=0` = drop offline; `collapse_key='sync:userId'` replaces prior pending; (d) **token lifecycle** — purge on 410 Unregistered; never cache; periodic re-validation; (e) the **FCM-on-iOS double-hop** (FCM API → APNs underneath; two SLO budgets stacked). Stretch (Sr Staff bar): articulates **topic-sharding** for 1M-subscriber broadcasts; per-tenant multi-project FCM sharding during viral surges.

## Canonical decomposition

### Requirements
**Functional:**
- Deliver notifications to mobile devices via APNs (iOS) + FCM (Android + Web)
- TTL-bounded delivery; collapse_key for state-update notifications
- Silent push for background sync (priority 5; iOS may batch)
- Topic-based fan-out for broadcasts (1M+ subscribers)
- Token registration + lifecycle management
- Per-tenant rate-limit + multi-tenant isolation

**Non-functional (with numbers):**
- APNs payload: 4 KB regular, 5 KB VoIP
- FCM: 1,000 concurrent fanouts/project; ~10K QPS topic send (not SLA); 2,000 topic subs/instance
- TTL: APNs default 0 (drop offline); FCM default 4 weeks (max 28 days = 2,419,200s)
- Mobile-push delivery target: <500ms p99 (Slack's published)
- At Discord/WhatsApp scale: ~1B device-tokens active

### Core entities
- **Token:** (user_id, device_id, platform=ios|android|web, token, registration_id, last_validated_at)
- **PushRequest:** (recipient_user_id, payload, priority, ttl, collapse_key?)
- **Topic:** (topic_id, subscribed_tokens[]); shard ID for very-large topics
- **TokenStore:** authoritative registry; purge pipeline on 410
- **RateLimiter:** per-tenant + per-FCM-project quotas

### API
- Customer-facing: `POST /push/send` body=(user_id, payload, priority, ttl) → routes via APNs or FCM
- Token registration: client-side, `POST /push/tokens` on app launch
- Topic management: `POST /push/topics/{id}/subscribe`, `unsubscribe`, `publish`
- Internal: APNs HTTP/2 connections; FCM HTTP/HTTP-v1 connections

### HLD
**Push gateway** receives customer push requests; looks up recipient's active tokens from **token store** (per-user 1-3 active tokens typical, capped ~5); routes per-token to APNs (iOS) or FCM (Android). **APNs HTTP/2 connections** are persistent (long-lived; reused for many requests); provider auth via token-based JWT or certificate. Per-request: POST to `/3/device/{deviceToken}` with payload + headers (priority, expiration, push-type). **FCM connections** similar; HTTP-v1 API. **Token-cleanup pipeline**: on 410 Unregistered response, **immediately** purge token from token store; on 400 BadDeviceToken, also purge; periodic re-validation sweep (monthly silent push to all tokens; purge 410s). **Per-tenant rate-limiter** caps push QPS at API edge to prevent saturation of APNs/FCM per-project limits. **Topic-broadcasting**: small topics (<10K subscribers) use FCM topic-messaging (FCM internally fans out); large topics shard into N sub-topics, parallel publish to all shards.

### Deep dives
1. **APNs HTTP/2 architecture + payload constraints.** APNs accepts notifications via HTTP/2 (replaced binary protocol in 2015; legacy retired March 2021). Each request: provider auth (token-based JWT or certificate-based) → POST to `/3/device/{deviceToken}` with payload (4 KB cap, 5 KB VoIP); headers control priority, expiration, push-type. **Priority 10** = immediate delivery, must wake device; **Priority 5** = power-considerate, mandatory for `content-available=1` silent push (iOS may batch and deliver later for battery). **apns-expiration**: 0 = drop if device offline (ephemeral notifications like typing indicators); future timestamp = store-and-forward up to that time (most user-visible messages set ~24h). **Per-request status**: 200 OK = accepted (not delivered); 400 BadDeviceToken / 410 Unregistered = token invalid, purge from token store. Staff+ commit: token-store schema with purge pipeline; payload-size budget (rich content needs Notification Service Extension + CDN fetch); priority/expiration policy per notification class.

2. **FCM fan-out at 1M+ subscribers per topic.** FCM topic = pub/sub-style broadcast; multiple devices subscribe to a topic (e.g., `news_sports`, `match_alert_team_X`); server publishes once, FCM fans out. Per-project limits: 1,000 concurrent fanouts; ~10K QPS topic send; 3,000 QPS subscription rate. For a 1M-subscriber topic at ~10K QPS fanout: ~100s to fully fan-out (acceptable for non-urgent; not for urgent like sports scores). **Sharding strategy** for very-large topics: split into N sub-topics (e.g., `match_alert_team_X_shard_0` through `_shard_99`); server publishes to all N sub-topics in parallel; total fan-out time = single-shard-fanout-time. Per-app cap: 2,000 topic subscriptions per instance — multi-channel apps (Discord, Slack) cannot map every channel to an FCM topic; need server-side fan-out per token instead.

3. **Token lifecycle + the 410 Unregistered cleanup pipeline.** Tokens change across reinstall, backup-restore, dev/prod swap, OS update. Apple's guidance: never cache, always re-register at app launch. Server-side: `(user_id, device_token, platform, last_seen)` table; on each push, **on 410 Unregistered immediately purge the token**; on 400 BadDeviceToken also purge. Stale tokens inflate per-message cost (each send to stale token costs ~1 HTTP request to discover it's stale). Periodic re-validation: silent push monthly to all tokens; purge 410s; budget alerts on stale-token ratio exceeding threshold. Per-user token list: typically 1-3 active (phone + tablet + web push); cap at ~5 to prevent abuse.

## Known failure modes
1. **Token cleanup lag inflates push spend.** 20% of tokens stale; each broadcast pays ~20% wasted HTTP requests. Production answer: real-time cleanup on 410 responses; periodic silent-push sweep; per-month token-validity check; budget alerts on stale-token ratio.

2. **APNs/FCM rate-limit during viral notification surge.** Major event (sports goal, news alert) triggers per-project FCM concurrent-fanout cap; backlog grows; latency spikes. Production answer: multi-project sharding (split tokens across N FCM projects); pre-event capacity warmup; priority queue for time-sensitive (sports scores) vs deferrable (marketing); circuit breaker if backlog exceeds threshold (drop low-priority).

3. **Silent push batched indefinitely by iOS.** Server sends silent push to wake app for background sync; iOS holds it for hours (battery optimization); user opens app, fetches state freshly anyway. Production answer: never rely on silent push for SLA-critical sync; treat as a hint that may or may not arrive; foreground sync on app launch as fallback; for truly-urgent state changes, use priority-10 with user-visible content.

## Notes for the coach
- **Plausibly-asked widely.** Push-notification design is on most infra interview-prep lists. Apple APNs documentation and Firebase FCM documentation are primary references.
- **The 410 Unregistered cleanup pattern is the Staff+ depth probe.** Candidates who articulate "real-time purge on 410 + periodic silent-push re-validation" demonstrate token-lifecycle awareness; candidates who treat tokens as static miss the inflated-spend implication.
- **The topic-sharding trick is the Staff+ depth probe for fan-out.** Candidates who recognize FCM topic's 10K QPS ceiling and the sub-topic-sharding workaround demonstrate the right framework.
- **Adversarial probe: "1M-subscriber breaking-news topic — first 60 seconds, how many delivered?"** Strong answer: at 10K QPS FCM ceiling, 600K in 60s; topic-sharding to 10 sub-topics parallel = 1M in 10s; pre-event warmup. Weak answer: "we use FCM topics" without the per-project rate-limit math.

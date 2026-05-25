---
slug: spotify-friend-activity
archetype: fan-out
sources:
  musconv: musconv.com/blog/spotify-friend-activity
  buddylist_repo: github.com/valeriangalliat/spotify-buddylist
  spotify_newsroom_2026: newsroom.spotify.com/2026-01-07/listening-activity-request-to-jam-messages-updates/
  spotify_event_delivery: engineering.atspotify.com/2016/03/spotifys-event-delivery-the-road-to-the-cloud-part-ii
---

# Spotify friend activity — deliberately throttled 15-20 min refresh (cost decision) + last-write-wins per friend (NOT append-only log) + 2026 Messages-integrated bidirectional-acknowledged gating + per-friend "now listening" → "most recently played" inactivity fallback + 700K events/sec broader event substrate + deliberately omitted from public Web API

## Bar anchors
- **Mid-level (L4/E4):** Designs real-time per-friend presence updates with per-user push.
- **Senior (L5/E5):** Names polling + caching. May or may not articulate the deliberate throttle as cost decision, last-write-wins storage, or bidirectional gating.
- **Staff+ (L6/E6+):** Names (a) **15-20 min refresh as explicit architectural decision**: "maintaining real-time updates would be too resource-heavy" — sidebar is low-priority UX, doesn't drive primary engagement; throttling is deliberate; (b) **last-write-wins per friend storage**: buddy-list endpoint returns ONE most-recent entry per friend with `{timestamp_ms, user(uri,name), track(uri,name,album,artist,context)}` — NOT append-only history; (c) **2026 Messages-integrated bidirectional gate**: Listening Activity visible only to friends/family connected via Messages (mutual acknowledgment), narrower than follow; asymmetric (see others without sharing own); age-gated to 16+; (d) **inactivity fallback**: when user not actively listening, sidebar shows "most recently played" instead of presence-state "now listening" — graceful degradation avoiding explicit "stopped listening" event broadcast; (e) **broader Spotify event delivery**: 700K events/sec at peak across 500+ event types (each = separate Pub/Sub topic); ~20s median end-to-end latency; 1Gbps network. Friend-activity is one consumer of similar listening events but intentionally throttled at read-aggregation; (f) **deliberately omitted from public Web API** (issue closed without plans to expose) — operational signal that buddy feed is "soft" feature without API-grade SLOs.

## Canonical decomposition

### Requirements
**Functional:**
- Show sidebar list of friends' current/most-recent track
- 15-20 min refresh cadence
- Bidirectional-acknowledged friend relationship gate (post-2026: Messages)
- Asymmetric visibility (see without sharing)
- Age-gating 16+

**Non-functional:**
- Broader event delivery: 700K events/sec, 500+ topics, ~20s median latency, 1Gbps
- Friend-feed: refresh 15-20 min; per-friend storage = 1 row last-write-wins
- Internal cookie-auth (sp_dc, ~1yr lease) on undocumented endpoint

### Core entities
- **FriendActivity:** {friend_user_id, timestamp_ms, user(uri,name), track(uri,name,album,artist,context)}
- **MessagesConnection:** user_a, user_b, ack_a→b, ack_b→a, age_verified
- **ListeningEvent:** user_id, track_id, started_at, context (one of 500+ event types)

### API
- Internal: `GET /buddylist` (cookie-auth, returns last-write-wins per friend)
- Public Web API: not exposed (deliberate)

### HLD
Source stream: every "now playing" / "track-completed" event from clients lands on Pub/Sub topic (one of 500+). Stream consumers include analytics, recommendations, and the Friend Activity aggregator.

Friend Activity Aggregator: subscribes to listening events; applies sliding window — picks most recent per-user event; writes to per-user "current state" row (last-write-wins; not append). Updates throttled to 15-20 min refresh cadence.

Read path: client polls `/buddylist` every 15-20 min; server returns N rows for friends in user's Messages-connected acknowledged set (filtered by ack + age-gate). Each row carries timestamp; if older than activity threshold, served as "most recently played" instead of "now listening."

### Deep dives
1. **15-20 min refresh + last-write-wins per friend.** Explicit cost decision; sidebar doesn't drive primary engagement so doesn't deserve real-time budget. Storage: per-friend last-write-wins keyed by friend_user_id; NOT append-only log. Simplifies storage to O(friends) rows total.
2. **Bidirectional-acknowledged gating (2026 Messages-integrated).** Friend-activity visible only to mutual Messages-connected friends — narrower than follow. Age-gated 16+. Asymmetric: see without sharing. Implies social-graph layer with explicit relationship type beyond follow.
3. **Inactivity fallback + broader event substrate.** When user not actively listening, sidebar shows "most recently played" instead of presence. Avoids "stopped listening" broadcast. Broader Spotify event delivery (700K events/sec / 500+ topics / ~20s latency) feeds friend-activity as one downstream consumer — throttled aggressively because of UX priority.

## Known failure modes
1. *Sidebar staleness during inactivity* — user sees "Alice listened to X" when Alice stopped 30 min ago. Production answer: timestamp on every entry; UI shows "Alice 30 min ago" not "Alice now."
2. *Privacy leak from over-broad fan-out* — exposing listening to broader social-graph layer. Production answer: 2026 Messages-only gating + bidirectional acknowledgment required.
3. *Public API absence frustrates third-party clients* — buddy-feed unavailable for partner integrations. Production answer: explicit decision to keep "soft" features off API to avoid SLO commitments; community reverse-engineers via internal endpoint.

## Notes for the coach
- **Plausibly-asked at Spotify.** Spotify event delivery engineering post + 2026 Messages newsroom + reverse-engineered buddylist GitHub repo are public.
- **User has Snapchat-side intuition** for friend-feed (Snap Discover friend-status); surface as adjacent.
- **The deliberate-throttle-as-cost-decision is the canonical Staff+ unlock.** Mid-senior candidates assume real-time; Staff+ candidates recognize the explicit UX-priority-to-budget mapping.
- **Adversarial probe: "Make this real-time."** Strong answer: 700K events/sec already exists on the substrate; cost of fan-out to every friend's sidebar in real-time = N² friend-graph traversal × 700K events/sec = orders-of-magnitude budget increase for a feature that doesn't drive primary engagement; PM-grade trade-off, not a tech limit. Counter-proposal = SSE push only to currently-foreground users + 15-min poll for everyone else. Weak answer: "we'd add WebSockets" without the cost framing.

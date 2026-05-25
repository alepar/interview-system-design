---
slug: sports-scores-fanout
archetype: fan-out
sources:
  espn_highscalability: highscalability.com/espns-architecture-at-scale-operating-at-100000-duh-nuh-nuhs/
  ws_scaling: medium.com/@jickpatel611/10-websocket-scaling-tricks-for-millions-of-fans-d770c9cb5c3b
  dazn_azure: developersvoice.com/blog/practical-design/scaling-dotnet-sports-platform-10m-users/
  sportz_ws: github.com/adrianhajdin/sportz-websockets
  fanout_patterns: medium.com/@bhagyarana80/top-10-websocket-fan-out-patterns-for-millions-of-rooms-6b0a9bd0f3ed
  dazn_fifa: aws.amazon.com/blogs/media/dazn-streams-2025-fifa-club-world-cup-to-billions-of-fans-with-m2a-media-and-aws/
---

# Sports scores fan-out — ESPN Caster 100K+ concurrent sockets/server + 100K req/sec World Cup peak + 3B+ msgs/day + WebSocket scaling tiers (5-30K self-managed / 1M hundreds of machines / 10M+ managed hyperscale) + sub-500ms canonical pipeline: provider event 5-15ms → Event Hubs/Kafka durable stream → Redis state compute 15-50ms → Web PubSub fan-out + viewport-based subscribe/unsubscribe per match channel + tree-style fan-out for very large rooms + thin push (tiny notification + client pulls full payload) for large game-recap payloads + DAZN 2025 FIFA Club World Cup 108 concurrent events × 27 feed variants × 200 territories

## Bar anchors
- **Mid-level (L4/E4):** WebSocket broadcast to all users on every score event.
- **Senior (L5/E5):** Names per-match topics. May or may not articulate WebSocket scaling tiers, the substrate pipeline, viewport-based subscription, or thin-push.
- **Staff+ (L6/E6+):** Names (a) **ESPN Caster scale**: 100K+ concurrent open sockets/server, 100K req/sec World Cup peak, 3B+ WebSocket msgs/day; degraded-mode fallback to 30-60s polling when sockets unavailable; (b) **WebSocket scaling tiers**: self-managed 5-30K connections/node well-tuned; ~1M needs hundreds of machines; 10M+ requires hyperscale (Azure Web PubSub / AWS AppSync / Cloudflare PubSub); sub-500ms end-to-end target; (c) **canonical pipeline**: provider event 5-15ms → Event Hubs/Kafka durable stream → in-memory state compute on Redis 15-50ms → Web PubSub fan-out; "Push delivery should never happen directly from the core event stream"; WebSockets cover foreground users + push notifications handle backgrounded/locked devices in parallel; **caches must be primary source of truth for hot data**; (d) **viewport-based subscription**: clients open ONE WebSocket and dynamically subscribe/unsubscribe per match channel; server enforces subscription caps + heartbeats + backpressure; (e) **tree-style fan-out**: root → branch nodes → leaf clients for very large rooms; (f) **thin push** for large payloads (game recaps): tiny notification triggers client to fetch body from object storage — keeps WebSocket pipe narrow; (g) **DAZN 2025 FIFA Club World Cup**: 108 concurrent events × 27 feed variants × 200 territories with millions of concurrent streaming viewers.

## Canonical decomposition

### Requirements
**Functional:**
- Real-time score updates per match
- Subscribe/unsubscribe per match (viewport-based)
- Push notification for goals when app backgrounded
- Game-recap delivery (large payload)

**Non-functional:**
- 100K+ sockets/server (ESPN); 100K req/sec World Cup peak; 3B+ msgs/day
- Sub-500ms end-to-end
- WebSocket scaling tiers per concurrent users

### Core entities
- **Match:** match_id, status, score, last_event
- **Subscription:** session_id → set of match_ids (viewport)
- **Event:** match_id, type ∈ {goal, card, sub, halftime, ft}, payload, timestamp
- **RecapNotification:** match_id, url, snippet (thin push)

### API
- WebSocket: `subscribe(match_id)`, `unsubscribe(match_id)`
- HTTP: `GET /matches/:id/recap` (full payload for thin-push reverse fetch)

### HLD
Source: data provider → Event Hubs/Kafka (durable stream, 5-15ms ingest).

State compute: Redis in-memory state (per-match score + last event); 15-50ms compute. Cache is source of truth for hot data; OLTP DB is for cold/archive.

Fan-out: Web PubSub (or self-managed connection servers with consistent-hash sharding) reads from Redis and pushes to all sessions subscribed to that match_id. Tree-style for very large rooms: root → branch nodes → leaf clients to reduce per-server connection count.

Parallel push: for backgrounded/locked devices, push notification service (APNs/FCM) gets the same events via separate consumer.

Thin push for recaps: WebSocket message = small JSON with recap URL; client fetches body from CDN-cached object storage.

Degraded mode: if WebSocket layer unavailable, clients fall back to 30-60s HTTP polling.

### Deep dives
1. **ESPN Caster + WebSocket scaling tiers.** Dedicated connection-management servers 100K+ sockets each. Degraded fallback to 30-60s polling. Scaling tiers: 5-30K/node self-managed → 1M needs hundreds of machines → 10M+ requires managed hyperscale.
2. **Canonical pipeline (provider → Kafka → Redis → Web PubSub).** Decomposed substrate: provider event (5-15ms) → Event Hubs/Kafka durable stream → in-memory state on Redis (15-50ms) → Web PubSub fan-out. Never push directly from core event stream. WebSockets foreground + push backgrounded in parallel. Cache as source of truth for hot match state.
3. **Viewport subscription + tree fan-out + thin push.** Clients open ONE WebSocket; dynamically subscribe/unsubscribe per match. Server caps + heartbeats + backpressure. Tree-style root → branches → leaves reduces per-server connection count. Thin push for large payloads: small notification → client fetches body from object storage.

## Known failure modes
1. *Reconnect storm after server restart* — millions of clients simultaneously reconnect. Production answer: exponential backoff + jitter; admission control.
2. *WebSocket pipe saturation on viral moment* — World Cup final goal triggers 100K+ msg/sec/server. Production answer: thin push for large payloads; CDN-cached video clips on object storage.
3. *Per-match state explosion* — Redis cache for all matches in flight. Production answer: TTL on inactive matches; cold-storage of completed.

## Notes for the coach
- **Plausibly-asked at ESPN, Sky Sports, DAZN, The Athletic.** ESPN High Scalability post + DAZN/Azure architecture are public.
- **Cross-coverage** with messaging `push-notification` (parallel delivery). With infra-primitives `kafka` (durable stream). With `breaking-news-fanout` (priority delivery). With `stock-alert-fanout` (per-symbol subscriber list architecture).
- **The "never push directly from core event stream" + canonical 4-stage pipeline is the canonical Staff+ unlock.** Mid-senior candidates collapse stages; Staff+ candidates name the decoupled substrate.
- **Adversarial probe: "World Cup final, 50M concurrent viewers, goal scored. Walk through the next 500ms."** Strong answer: t=0 provider event into Kafka (5-15ms); t=20ms Redis state update; t=30ms Web PubSub fans out to ~500 connection servers (each 100K sockets); per-server publishes to ~100K sockets subscribed to that match (viewport-filtered); foreground users see at t=80-300ms via WebSocket; backgrounded users see at t=2-5s via parallel APNs/FCM push. Weak answer: "we push to everyone" without the substrate decomposition.

---
slug: twitch-chat
archetype: live-media-broadcast
sources:
  twitch_engineering_overview: blog.twitch.tv/en/2015/12/18/twitch-engineering-an-introduction-and-overview
  twitch_irc_docs: dev.twitch.tv/docs/irc
---

# Twitch chat — IRC-based chat fan-out for 100K-viewer streams

## Bar anchors
- **Mid-level (L4/E4):** Treats chat as "WebSocket + Redis pub-sub." Doesn't address 100K-chatter rooms or moderation pipeline. Defaults to per-message DB write.
- **Senior (L5/E5):** Names per-channel pub-sub, WebSocket fan-out, rate limits. Discusses slow mode. May or may not address the Edge↔Pubsub hierarchy or the moderation latency budget.
- **Staff+ (L6/E6+):** Drives proactively. Recognizes this as **one logical room with hundreds of thousands of subscribers** — different problem from WhatsApp 1024-member group. Articulates the **Edge / Pubsub / Clue / Room** architectural split: Edge (IRC/WebSocket gateway, raw TCP), Pubsub (internal cross-edge fan-out), Clue (moderation policy decisions: sub-status, ban-state, abusive-text classifier), Room (presence/membership). Names the **hierarchical pub-sub** pattern: each Edge subscribes only to channels its connected clients are in; Pubsub routes events across Edges; avoids N²-edge mesh. Articulates **moderation pipeline on hot path** with explicit latency budget. Stretch (Sr Staff bar): articulates **bot connection limits** (100 channel joins/OAuth user, broadcaster-authorized higher tiers) and slow-client drop policy.

## Canonical decomposition

### Requirements
**Functional:**
- Modified IRC protocol over WebSocket (PASS/NICK/JOIN/PRIVMSG + IRCv3 tags for badges/sub-state)
- Per-channel chat broadcast to all viewers
- Moderation: bans, timeouts, slow mode, follower-only, sub-only, abusive-text auto-filter
- Bot integration with per-OAuth connection limits

**Non-functional (with numbers):**
- 10B+ chat messages/day platform-wide (blog.twitch.tv 2015)
- Top streams: 100K+ concurrent chatters; viewer:chatter ratio ~10:1
- Bot limits: 100 channel joins/OAuth user (broadcaster-authorized higher tiers)
- Delivery target: <500ms p99

### Core entities
- **EdgeNode:** terminates client WebSocket/IRC connections; per-channel local subscriptions
- **Pubsub:** internal cross-edge message bus; routes channel events Edge→Edge
- **Clue:** moderation service; check chain on every PRIVMSG (sub-status, ban-state, abusive-text)
- **Room:** per-channel state; presence list (eventually consistent), slow-mode timer, banned-user set
- **ChatMessage:** (channel, user, content, tags{badges, color, emotes, mod})

### API
- WebSocket: `wss://irc-ws.chat.twitch.tv` with IRC framing
- IRC commands: PASS (OAuth), NICK, JOIN #channel, PRIVMSG #channel :text
- IRCv3 tags: `@badge-info=...; color=...; emotes=...; mod=1`
- Bot API: `wss://irc-ws.chat.twitch.tv` with bot OAuth + concurrent-join limits

### HLD
**Edge nodes** terminate raw TCP/WebSocket IRC connections; consistent-hash clients to edges (or round-robin with sticky-session). Each Edge maintains a local subscription map: for each (channel, set-of-local-clients-in-that-channel). When client sends PRIVMSG: Edge applies per-channel rate limits + slow-mode check; routes message through **Clue** (moderation: is sender banned? sub-only channel and sender not subbed? abusive-text classifier score?); on pass, publishes to **Pubsub** (internal bus, partitioned by channel). All Edges subscribed to that channel receive the event from Pubsub and fan out to their local clients. **Room** service holds per-channel state (presence list — eventually consistent aggregation from all Edges; banned-user set; slow-mode timer). Bots use the same WebSocket entrypoint but with bot OAuth + per-token concurrent-join cap (100 default; higher tiers for broadcaster-authorized bots).

### Deep dives
1. **Hierarchical pub-sub — Edge subscribes only to its clients' channels.** Naive: every Edge subscribes to every channel; for 100K channels and 1000 Edges, every Edge gets every channel's events (1000× amplification). Hierarchical: Edge subscribes to Pubsub only for channels it has local clients in. On client JOIN: Edge adds channel to its Pubsub subscription set if first local client; on last client LEAVE, drops subscription. Pubsub routing reduces from O(channels × edges) to O(channels × edges_with_clients_in_channel). For a viral stream where 100K viewers connect to 1000 Edges (~100 viewers/Edge), all 1000 Edges subscribe — but only for this one channel; the long tail of cold channels stays cheap.

2. **Moderation pipeline (Clue) — latency budget on hot path.** Every PRIVMSG runs through Clue: (a) ban-state check (is sender banned in this channel?), (b) sub-status check (sub-only channel and sender not subbed?), (c) follower-only check (follower-only enabled and sender not following long enough?), (d) abusive-text classifier (ML model scoring; threshold-based drop or shadow-ban). Latency budget: <100ms total to keep p99 message delivery <500ms. Optimization: ban-state + sub-status cached at Edge (push from Room on update); abusive-text classifier batched per-Edge or per-region (small batches of pending messages). Trade: caching at Edge means moderation actions take a moment to propagate; for hot moderation (banning a spammer mid-flood), accept brief stale window or use synchronous invalidation.

3. **Bot connection economics + slow-client drop policy.** Bots can join hundreds of channels per OAuth user. Naive: unlimited joins → bot can saturate Edge with many channel subscriptions. Limit: 100 channel joins/OAuth user (broadcaster-authorized higher tiers via Twitch Developer console). Slow-client drop policy: if Edge's outbound buffer to a client exceeds threshold (client is reading slowly — network laggy, browser tab backgrounded), Edge drops the client connection. Trade: prevents memory blowup; client must reconnect on resume. Per-channel rate limits at Edge (e.g., 20 messages/30s for non-mod users) absorb floods at the source.

## Known failure modes
1. **Hot channel saturating a single Edge.** Top streamer attracts 100K viewers all hashing to a small set of Edges via sticky session. Production answer: clients consistent-hashed across Edges (no per-channel affinity); Pubsub absorbs cross-Edge fan-out cost; per-Edge subscription cap with re-balance on saturation.

2. **Bot floods.** Bot author writes scraper that joins every channel + spams messages. Production answer: token-level join concurrency limits (100/user); per-channel rate-limits at Edge; broadcaster-authorized higher tiers via Developer console; ML-driven spam detection.

3. **Slow client / unbounded outbound queue.** Client's read is slow (network lag); Edge buffer grows; memory pressure. Production answer: drop policy at Edge — if outbound buffer > threshold, kill the connection; client reconnects on resume; for slow-mode channels, server-side rate limit absorbs floods so buffer growth is bounded.

## Notes for the coach
- **Asked-confirmed at Twitch.** blog.twitch.tv 2015 engineering overview is the primary reference.
- **The Edge / Pubsub / Clue / Room split is the Staff+ unlock.** Candidates who name the four-tier split demonstrate Twitch-blog literacy; candidates who default to "WebSocket + Kafka" miss the architectural separation.
- **The "one room with 100K subscribers" framing is the key contrast vs WhatsApp.** Candidates who treat this as a WhatsApp 1024-group variant miss the unbounded-room cardinality.
- **Adversarial probe: "moderation budget is <100ms — what if abusive-text classifier ML model is slow?"** Strong answer: batched scoring per Edge, optimistic forward + retract on classifier flag, edge-cached lightweight signals (sub-status, ban-state); weak answer: "we use a faster model" without the latency-budget engineering.

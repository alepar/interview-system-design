---
slug: slack-web-client
archetype: frontend
sources:
  slack_flannel: slack.engineering/flannel-an-application-level-edge-cache-to-make-slack-scale/
  slack_incremental_boot: slack.engineering/getting-to-slack-faster-with-incremental-boot/
  slack_lazy_part2: slack.engineering/making-slack-faster-by-being-lazy-part-2/
  discord_mobile_perf: discord.com/blog/supercharging-discord-mobile-our-journey-to-a-faster-app
---

# Slack web client — persistent WebSocket + Flannel edge cache + message virtualization + single-leader BroadcastChannel

## Bar anchors
- **Mid-level (L4/E4):** Persistent WebSocket; renders all channels' messages. No bootstrap-cost containment; no virtualization.
- **Senior (L5/E5):** Names WebSocket reconnect + virtualization. Discusses presence. May or may not articulate Flannel-style edge cache, incremental boot, single-leader-tab pattern.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **THE messaging archetype's client-side problem** — sharply distinct from server-side message-storage round (archetype #3). Bar covers: (a) **bootstrap-cost containment** — Slack's classic problem was many-megabyte initial payload; per Flannel post verbatim: "Flannel has been running in our edge locations since January. It serves 4 million simultaneous connections at peak and 600K client queries per second." Lazy-load user/channel metadata from edge cache, never full eager fetch; (b) **channel-switch latency** — clicking channel must show top messages in ≤100ms (cached) or ≤300ms (uncached); LRU of last ~10 channels' messages in memory + IndexedDB; (c) **message virtualization** per Discord verbatim: "uses a native virtualized list, aka Android RecyclerView under the hood, not a ScrollView … combined with what we lovingly refer to as 'View Portaling' which is a technique that allows native code to move around rendered JS views as they enter the viewport"; on web implement equivalent with `@tanstack/react-virtual`; (d) **scroll preservation** when older messages load on scroll-up.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Persistent WebSocket for real-time messages, typing, presence
- Channel sidebar + active-channel message list
- Threaded replies in sidebar
- Notification badges (per-channel unread count)
- Offline composing with replay on reconnect
- Multi-tab coordination

**Non-functional:**
- Slack peak: **4M simultaneous WS connections + 600K queries/sec** across Flannel
- Per-team channel count: median 30, p99 ~5,000
- Rendered window ~50 messages, virtualized to DOM ≤200 nodes regardless of scrollback
- Persistent WebSocket: 1/tab, multiplexed for all subscriptions
- Reconnect target ≤5s end-to-end after network restore
- **Slack incremental boot**: content-visible ~7s → <5s
- **1s faster saves 49.5 days/day** across 4.2M loads
- **Channel-list consolidation**: 10% global improvement, 65% in stress-test teams

### Architecture (A)
**Layers**: WebSocket transport / Channel store (LRU + IndexedDB) / Virtualized message list / Pub/sub subscription manager / Cross-tab coordinator (BroadcastChannel).

### Data model (D)
- **Channel**: `{id, name, type, unreadCount, lastReadId, members[]}`
- **Message**: `{id, channelId, authorId, body, ts, threadParentId?, sequence}`
- **Subscription state**: `{currentChannelId, subscribedChannels: Set, presenceUsers: Set}`

### Interface (I)
- WebSocket protocol: `{type: 'message'|'typing'|'presence'|'ack', ...}`
- REST: `GET /channels/:id/messages?since=lastSeq` for backfill

### Optimization (O)
**WebSocket reconnect with backoff + jitter**: base 500ms, doubling, cap 30s, ±50% random jitter to prevent thundering herd after server restart. Reset backoff on successful open. **Snapshot+delta resume**: monotonic sequence number per channel; on reconnect send `{lastSeenSeq}`; server replays gap or returns snapshot if buffer evicted. Server keeps short-TTL resume tokens keyed by user/channel in Redis.

**Pub/sub subscription model** per Slack: "clients can subscribe to the series of events that are relevant in the current view, and change subscriptions when users switch to another view... the number of presence events received by clients was reduced by a factor of 5."

**Single-leader WebSocket via BroadcastChannel**: one tab elected via localStorage owns socket; broadcasts inbound events to peer tabs via BroadcastChannel; forwards outbound. Avoids N parallel sockets per user across N tabs. Same-origin only.

**Chat virtualization** via react-virtuoso: ~20-30 visible messages out of thousands; ~700ms → ~200ms initial render. Variable item heights out-of-box; **native reverse-scroll support critical for chat**.

**Service worker** for offline support: cache assets + prior team data; cold reload starts from local cache.

**Message rendering**: Markdown→AST→React tree; cache parsed AST per message ID.

**Notification badge correctness**: unread-counts server-canonical; client may compute optimistic but reconcile on reconnect.

## Known failure modes
1. **Reconnect storm after regional outage** (Slack's published pain point: "Reconnect storm — we lost thousands and hundreds of thousands of connections within minutes or even seconds"). Production answer: exponential backoff + ±50% jitter; cap retries at 10-15 attempts (~2min total) before "reconnect failed" UX.
2. **Memory bloat from caching all messages** of all visited channels. Production answer: LRU bound (10 channels); evict older to ID-only.
3. **Race between WebSocket-pushed message + REST backfill**. Production answer: dedupe by message ID.
4. **Typing-indicator stuck on** after typer disconnects without sending stop-event. Production answer: server-side TTL; client honors.
5. **Channel-switch shows previous channel's messages** for one frame. Production answer: key-based remount + Suspense fallback.

## Notes for the coach
- **Asked-confirmed at Slack** (Flannel post is interview canon). Plausibly Discord, Meta (Messenger web), Microsoft (Teams web). GreatFrontEnd "Chat application (Messenger)" canonical.
- **THE cross-coverage problem** with messaging archetype #3. Server side covered there; this is browser side. Reuses IndexedDB / sync-engine story from `google-docs-client`.
- **The single-leader BroadcastChannel pattern is the canonical Staff+ unlock for multi-tab.** Without it, N tabs = N WebSockets per user; with it, 1 WebSocket multiplexed.
- **The Slack-published "1s = 49.5 days/day saved" framing is the engineering-narrative anchor.** Quote it for the perf-budget framing.
- **Adversarial probe: "10K simultaneous tabs reconnect after server restart. What's the failure mode if no jitter?"** Strong answer: synchronized retry waves overload recovering server; thundering herd; even after server up, repeated re-overload. ±50% jitter spreads retries. Weak answer: "we have backoff" without addressing jitter.

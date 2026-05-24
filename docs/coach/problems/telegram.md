---
slug: telegram
archetype: realtime-messaging
sources:
  mtproto_spec: core.telegram.org/mtproto
  techcrunch_950m: techcrunch.com/2024/07/23/telegram-says-it-now-has-950-million-users
  fcm_topic: firebase.google.com/docs/cloud-messaging
---

# Telegram — broadcast channels at millions-of-subscribers scale

## Bar anchors
- **Mid-level (L4/E4):** Treats channels as a big group chat. Doesn't differentiate fan-out-on-write vs fan-out-on-read. Doesn't size push-notification fan-out for offline subscribers.
- **Senior (L5/E5):** Names append-only log per channel + subscriber cursors. Discusses push for offline. May or may not address sharded subscriber lists for very large channels, edit/delete propagation, MTProto specifics.
- **Staff+ (L6/E6+):** Drives proactively. Recognizes this as **fan-out-on-read, not fan-out-on-write** — you do not write 200M inboxes. Articulates **per-channel append-only log** with monotonic message_id; reads served from CDN-like cache fronting the log shard; subscribers maintain client-side cursors. Names **subscriber-list sharding** for hot channels (split by subscriber_id range; publish writes log once, push fan-out workers scan subscriber shards). Articulates **edit/delete as tombstones in the log** (messages immutable; edit = new entry referencing original; tombstone with future message_id allowed). Names **MTProto transport** (custom binary protocol, AES-IGE, custom framing; rationale = control over the protocol for push-via-long-poll + multi-DC routing; acknowledges cryptographic critiques). Stretch (Sr Staff bar): articulates the push fan-out tail for offline subscribers using FCM topic-messaging (only sane choice past ~10K subscribers); compares to Twitter-timeline fan-out (which misses the persistent-history-seekability requirement).

## Canonical decomposition

### Requirements
**Functional:**
- 1 creator publishes to channel with up to 200M subscribers
- Edits and deletes (with reasonable propagation latency)
- Pinned messages, persistent history seekable by any joiner
- Push notifications to offline subscribers (the majority)
- Not E2E (channels are server-readable for moderation + history seekability)

**Non-functional (with numbers):**
- 950M MAU (Durov on his channel, July 2024 per TechCrunch)
- Largest channels: 10M+ subscribers
- Publish rate: 1-100 msg/min news; 1000+/min during events
- APNs payload cap 4 KB; FCM topic-send ~10K QPS / 1,000 concurrent fanouts/project
- Latency: publish → first online subscriber receive <1s typical

### Core entities
- **Channel:** channel_id, owner_id, member_count, message_id_counter
- **Message:** message_id (monotonic per channel), channel_id, content, edit_ref?, tombstone?, pinned?
- **Subscription:** (user_id, channel_id, joined_at, last_read_message_id, notification_pref)
- **PushTopic:** per-channel FCM topic (when subscriber count >10K); APNs distribution by per-device tokens or fan-out workers

### API
- `POST /channels/{id}/messages` — owner publishes; appends to log
- `PATCH /channels/{id}/messages/{msg_id}` — edit (writes new tombstoned reference)
- `DELETE /channels/{id}/messages/{msg_id}` — tombstone
- `GET /channels/{id}/messages?cursor=X` — paginated history scroll
- `POST /channels/{id}/subscribe` — join; on large channels, subscriber added to a sharded subscriber-list
- Push: server publishes to FCM topic for the channel (subscribers auto-subscribed at FCM topic-join)

### HLD
Each channel's messages live in a **per-channel append-only log** (Kafka-style or custom — Telegram uses MTProto over their own storage layer); message_id is monotonically increasing per channel. Reads served from a **CDN-like cache** fronting the log shard (most reads are recent messages — high cache hit rate). Subscribers maintain client-side cursor `last_read_message_id`; on connect, fetch all messages with `id > last_read`. **Subscriber list** is sharded by `subscriber_id` range for hot channels (a 10M-subscriber channel split into ~100 shards of 100K subscribers each). On publish: writer appends to the log once; pushes a notification (a) via FCM topic-messaging for the channel (FCM fans out internally to all subscribed tokens), (b) for online WebSocket-connected subscribers, server delivers in-band via the persistent connection. **Edit/delete**: messages immutable in log; edit = new entry referencing original message_id; client reconciles (renders edit_ref as updated content). Deletion = tombstone entry; client hides the original.

### Deep dives
1. **Per-channel append-only log with subscriber-side cursors.** Channel log = ordered list of messages keyed by monotonic message_id. Reader fetches `messages WHERE id > last_seen AND id <= MAX(message_id) AT subscription_time` (a subscriber joining at message_id=1M doesn't get all history; they get messages from join onwards unless they explicitly request "load history"). History scrollback fetches older messages via `GET messages?before=X LIMIT N` — served from CDN-cached log segments (recent hot, older cold). Per-shard write throughput: log is single-writer (the owner / admins), so write contention is low; reads are massively fan-out (10M cursors all pulling from same log).

2. **Subscriber-list sharding for hot channels.** Naive: one subscriber list per channel. At 200M subscribers, this is unmanageable for fan-out workers. Sharded: subscriber list split by `hash(subscriber_id) % N`; N tuned per channel size (N=1 for small channels, N=100+ for mega channels). Publish writes log once (single source of truth for content); fan-out workers parallelize across shards (each scans its shard's subscribers and pushes to APNs/FCM). For FCM topic-messaging, this is simplified — clients subscribed to FCM topic for the channel, FCM does the internal fan-out; for APNs (which has no topic primitive), per-token fan-out via workers is required.

3. **MTProto transport — layered custom protocol.** Telegram's published custom protocol [MTProto spec: core.telegram.org/mtproto]. Transport: TCP or UDP with custom framing + symmetric encryption (AES-IGE; auth_key derived from DH). Service: RPCs for message sending, presence, sync. Auth: initial DH exchange to establish auth_key, then key reuse. Why not TLS + HTTP/2? Control over the protocol enables push via long-poll, custom framing, multi-DC routing. Controversy: cryptographers have published critiques (AES-IGE is unusual; auth-key key-stretching is non-standard). For interview purposes: candidate should articulate the layered design + rationale + acknowledge the cryptographic concerns. Staff+ commit: protocol-layer design, what HTTPS-based alternative looks like, why Telegram's choice is defensible (or not).

## Known failure modes
1. **Thundering herd on channel join during viral event.** Million new subscribers in minutes; all request recent history simultaneously. Production answer: CDN-cache hot history segments (last N hours of messages cached at edge); pre-warm cache when a channel goes viral (subscriber-growth-rate trigger); admission control on history-fetch QPS per channel.

2. **Notification fan-out backlog.** FCM topic-send rate ~10K QPS; 1M-subscriber channel takes ~100s to fan out. Production answer: GenStage-style back-pressure between push collector and APNs/FCM transport; **topic-sharding** for very-large broadcasts (split into N sub-topics, publish to all in parallel; total fan-out time = single-shard-fanout-time); priority queue for urgent vs deferrable (sports score vs marketing).

3. **Edit/delete arriving before original** (rare but possible across DCs). Production answer: tombstone with future message_id allowed; client buffers tombstones referencing unseen message_ids; reconciles when original arrives. Server enforces causal ordering within a channel (edits cannot precede their original message_id in the log).

## Notes for the coach
- **Plausibly-asked at Staff+.** Telegram has not published infrastructure blogs comparable to Meta's, but MTProto is documented. The problem appears in interview canon as "design Telegram channels" / "design a broadcast feed."
- **Differentiates from `twitter-timeline`** by adding edit/delete semantics, persistent history seekability, and push fan-out for offline majority.
- **The "fan-out-on-read, not fan-out-on-write" framing is the Staff+ unlock.** Candidates who default to writing 200M inboxes miss the bar; candidates who recognize "cursor-based pull from a single log" demonstrate the right mental model.
- **Adversarial probe: "what happens when a 50M-subscriber channel goes viral — first 10s?"** Strong answer: CDN absorbs history-fetch spike; FCM topic-sharding absorbs notification fan-out; weak answer: "we add more shards" without acknowledging the temporal spike.

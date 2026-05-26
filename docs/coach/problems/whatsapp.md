---
slug: whatsapp
archetype: interactive-messaging
sources:
  whatsapp_2m_connections: blog.whatsapp.com/1-million-is-so-2011
  reed_erlang_factory: Rick Reed "Scaling to Millions of Simultaneous Connections" Erlang Factory SF 2012
  whatsapp_multi_device: engineering.fb.com/2021/07/14/security/whatsapp-multi-device
  whatsapp_security_whitepaper: whatsapp.com/security/WhatsApp-Security-Whitepaper.pdf
  hello_interview_whatsapp: hellointerview.com/learn/system-design/answer-keys/whatsapp
---

# WhatsApp — chat-at-scale messaging with E2E + multi-device

## Bar anchors
- **Mid-level (L4/E4):** Draws WebSocket + Kafka + database. Treats server as the source of truth. Doesn't size connection count per server or address multi-device fan-out math.
- **Senior (L5/E5):** Names persistent WebSocket, presence service, group fan-out. Discusses message queueing during recipient offline. Mentions Signal Protocol for E2E. May or may not surface connection economics, sender-keys for groups, or multi-device device-list complexity.
- **Staff+ (L6/E6+):** Drives proactively. Cites **WhatsApp's 1-2M TCP connections per FreeBSD/Erlang box** (Rick Reed, Erlang Factory 2014) and defends the per-connection memory budget (300B-10KB in Erlang BEAM). Articulates **client-fanout multi-device math**: encrypt N times where N = union of sender + recipient device lists (up to 5 devices each); server-fanout is impossible under E2E. Names **ADV (Automatic Device Verification)** that hashes over the device set so safety numbers stay stable across companion-device churn. Sender-Keys for groups: each sender device distributes a symmetric sender key pairwise once, then encrypts each group message **once** with that key (collapses O(N) per-message to O(1) once-per-key-rotation). Server is a **relay with bounded soft-state**; source of truth is on the device. Stretch (Sr Staff bar): articulates cross-region "islands" with primary-secondary async; explicit which mutations need strong consistency (device-list mutation) vs which tolerate eventual (read receipts).

## Canonical decomposition

### Requirements
**Functional:**
- 1:1 + group chat up to 1024 members
- E2E encryption (Signal Protocol + Sender Keys for groups)
- Multi-device delivery: 1 phone + up to 4 companion devices per user
- Offline message queueing; delivery on reconnect; ack-then-delete
- Read receipts (two-tick / blue-tick state machine)

**Non-functional (with numbers):**
- ~140B messages/day platform-wide
- ~2B MAU; 1M+ new registrations/day
- 1-2M concurrent TCP connections per chat server (Erlang BEAM)
- 1024-member group limit
- <500ms p99 intra-region delivery for online recipients
- 99.99% uptime target

### Core entities
- **User:** user_id, identity_public_key, device_list, last_seen
- **Device:** device_id, user_id, device_identity_key, registration_id, push_token
- **Group:** group_id, members[], permissions, sender_key_state_per_sender
- **Message:** message_id, sender_device, recipient_devices[], ciphertext_per_recipient, timestamp
- **OfflineQueue:** per-recipient-device queue of undelivered messages; ack-then-delete

### API
- WebSocket persistent connection: `WSS /chat` with auth on CONNECT
- `POST /messages` — client fans out to N device recipients; one encryption + transport per recipient device
- `GET /prekeys/{user_id}` — fetch recipient's pre-key bundles for X3DH session init
- `GET /devices/{user_id}` — fetch current device list (versioned)
- Push fallback: server sends APNs/FCM wake when WebSocket inactive

### HLD
**Chat servers** terminate millions of persistent WebSocket connections on Erlang/BEAM nodes (1-2M per box). On message send: client encrypts the plaintext N times (once per recipient device using established Double Ratchet sessions) and uploads N ciphertext envelopes. Server is a **relay**: routes each envelope to the recipient device's owning chat server (consistent-hash by device_id); writes to **Mnesia/in-memory offline queue** if device is offline; pushes APNs/FCM wake if offline. On delivery, server acks the sender; on read, recipient acks back through the relay. Server **stores no plaintext, never** — server-side abuse reporting requires the user to forward the offending message back (re-encrypted to a moderation key). **Device-list service** is authoritative for which devices belong to a user; mutations (link/unlink) must be strongly consistent (any sender encrypting to a stale device list risks delivery to a deprecated device). **Group fan-out**: sender encrypts a group message once with their **Sender Key** (a symmetric ratchet); Sender Key was previously distributed pairwise via Double-Ratchet to each member device; server fans out the single ciphertext to all member devices. **Cross-region islands** are primary-secondary clusters with async replication for offline-queue mirroring; device-list service is multi-region with sync replication.

### Deep dives
1. **Connection economics — defending 1-2M connections/server.** Erlang BEAM allows millions of lightweight processes (each ~300B-2KB heap minimum). One process per connection holds the socket + session state (ratchet keys, last activity, recipient-of-pending messages). Per-server memory budget at 2M connections × 5KB avg = ~10GB just for connection state. Idle culling: heartbeat every 30-60s; close after 3 misses. Reconnect storms (app update → millions reconnect): rate-limited LB accept queue; exponential jittered backoff client-side; Flannel-class edge cache shields warm metadata; **never** rely on cold cache. Compare: thread-per-connection in JVM ~1MB/connection = 100× memory cost — infeasible at this scale.

2. **Multi-device fan-out + ADV.** Pre-multi-device: one identity key per user; safety-number = pairwise fingerprint. Multi-device: each device has its own identity key; sender encrypts N times per message. Naive: safety-number changes every time companion device added/removed → UX disaster. **ADV (Automatic Device Verification)**: server publishes a signed "device list" with a hash over the set; safety-number is derived from the user's master identity key (long-lived) not from individual devices, so the user-visible safety number stays stable across companion churn. Caveat: server must be trusted to publish honest device-list — auditing via client-side device-list-change UX. Server rejects any send whose device-list-hash doesn't match current; client retries with refreshed list.

3. **Sender Keys for groups.** Pairwise Double-Ratchet for N-member group = O(N) ciphertext per message (sender encrypts N times). Sender Key: sender generates symmetric chain key, distributes to each member once via existing Double-Ratchet sessions; each subsequent group message encrypted **once** with the Sender Key chain (advances per message). Member removal → rotate the Sender Key (re-distribute pairwise to remaining members). Trade vs MLS (RFC 9420): Sender Keys = O(N) member-removal cost; MLS = O(log N). At 1024-member cap, O(N) is tolerable but bound; for 50K+-member groups WhatsApp is piloting MLS.

## Known failure modes
1. **Reconnect storm after app update / network blip.** Millions of clients reconnect simultaneously; server accept-queue saturates. Production answer: client-side exponential jittered backoff (0-60s spread); LB connection-rate-limit on accept; Flannel-class edge cache so backend isn't hit cold; pre-warm replacement servers before rotation.

2. **Hot group write spike** (1024-member group with celebrity sender → simultaneous typing/reactions). Production answer: sender-side rate limits per group; server coalesces typing/read-receipts (dropping non-final states); async fan-out workers separate from synchronous send path.

3. **Device-list race: sender encrypts to stale list while new device linked mid-flight.** Production answer: server rejects sends with stale `device_list_hash` header; client refreshes and retries; ADV stabilizes user-visible safety number across the retry; for adversarial cases (compromised device unlink), server enforces a brief no-send window after device-list mutation.

## Notes for the coach
- **Asked-confirmed at Staff+** at Meta (WhatsApp/Messenger). Hello Interview's WhatsApp answer key explicitly states the Staff+ bar; Glassdoor/Blind L6+ reports cite this loop.
- **The 1-2M connections/server number is the canonical anchor.** Candidates who size their per-connection memory in Erlang BEAM terms (KB) demonstrate awareness; candidates who default to JVM (MB/connection) reveal a gap.
- **The Snapchat-shipped variant is implicit context.** User has done friend-graph fan-out + mobile push; the WhatsApp-specific gaps are (a) Erlang connection economics, (b) multi-device math, (c) Sender Keys vs MLS comparison.
- **If candidate jumps to "design Twitter DMs," redirect with adversarial probe: "2B users on persistent connection — what does that cost?"** The answer must arrive at per-connection memory + Erlang BEAM (or equivalent millions-of-lightweight-processes pattern); if they default to one HTTP request per message, the bar is missed.

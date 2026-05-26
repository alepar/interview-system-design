---
slug: matrix
archetype: interactive-messaging
sources:
  matrix_spec: spec.matrix.org
  synapse_scaling: matrix.org/blog (Synapse worker-based scaling 2020)
  matrix_reloaded: arxiv.org/abs/2408.12743 (Ginesin & Nita-Rotaru "The Matrix Reloaded")
---

# Matrix — federated messaging with state-resolution + Olm/Megolm E2E

## Bar anchors
- **Mid-level (L4/E4):** Treats federation as "replicate everything." Doesn't address state-resolution, signed events, or byzantine peers.
- **Senior (L5/E5):** Names HTTP-based federation, signed events, Olm/Megolm for E2E. May or may not address the room-DAG state resolution, soft-failure, or worker-based homeserver scaling.
- **Staff+ (L6/E6+):** Drives proactively. Articulates (a) **room DAG model** — events form append-only DAG with parent refs; state computed by **state resolution** when branches conflict; (b) **state resolution + soft-failure** — events failing current authorization (e.g., banned-user posting) are **accepted in the DAG** (so they participate in future state resolution) but **withheld from clients** — preserves DAG integrity while preventing ban evasion via DAG forks; (c) **HTTP PUT Transaction API** with ed25519 signing — `PUT /_matrix/federation/v1/send/{txnId}` with ≤50 PDUs + 100 EDUs per transaction; (d) **Synapse worker-based scaling** with Redis pub/sub (federation_senders, event_persisters sharded by room_id, generic workers); (e) **MLS migration in federated context** — RFC 9420 designed for centralized DS; ongoing IETF work for federation. Stretch (Sr Staff bar): articulates **faster joins** (2022+ lazy-load membership; pre-2022 mega-room joins took minutes); names IETF MIMI WG for cross-provider interop.

## Canonical decomposition

### Requirements
**Functional:**
- Independent homeservers federate (anyone can run one)
- Users on different homeservers join the same room
- Room state = DAG of signed events; state resolution reconciles concurrent updates
- E2E via Olm (1:1, Signal-derived) and Megolm (groups; like Sender Keys but server-replicated)
- Cross-signing + key verification for safety-numbers across federations

**Non-functional (with numbers):**
- 115M+ users on public data-reporting homeservers (Sep 2024, per Ginesin & Nita-Rotaru arxiv 2408.12743)
- 80K+ federated servers by end of 2023
- Matrix Transaction: ≤50 PDUs + 100 EDUs per transaction
- Synapse production at matrix.org: message-send p50 ~50ms (post-Redis-pubsub scaling); pre was seconds
- Faster-joins (2022+): mega-room join went from minutes to seconds

### Core entities
- **Homeserver:** independent server instance with its own users + rooms
- **Room:** DAG of events; state computed via state resolution
- **PDU (Persistent Data Unit):** persistent room event (message, state change); signed; references parent PDUs
- **EDU (Ephemeral Data Unit):** typing, presence, read receipts; not persisted in DAG
- **Transaction:** batch of ≤50 PDUs + 100 EDUs sent between homeservers; signed via X-Matrix
- **OlmSession:** 1:1 E2E session (Signal-derived); Megolm for groups

### API
- Federation: `PUT /_matrix/federation/v1/send/{txnId}` with Transaction JSON; signed via `X-Matrix` header (ed25519)
- Federation: `GET /_matrix/federation/v1/state/{roomId}` — fetch room state at given event
- Client-Server: `PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}` — client sends event
- Key discovery: `.well-known/matrix/server` + per-server public key endpoint

### HLD
**Homeservers** are independent administrative domains; each serves its own users + their rooms. **Federation** is server-to-server JSON over HTTPS: when user on homeserver A sends an event to a room with members on homeserver B, A's federation_sender sends a **Transaction** (`PUT /_matrix/federation/v1/send/{txnId}`) to B with the new PDU. **Auth via X-Matrix header**: ed25519 signature using A's server signing key (published at A's `/.well-known/matrix/server` + key endpoint). B's federation listener accepts, validates signature, applies auth rules (does the sender have permission to post in this room?), runs **state resolution** if needed (if the new event conflicts with B's current view of room state), then persists the PDU into the room DAG. **Worker-based Synapse**: monolithic pre-2020; modern Synapse uses workers coordinated via Redis pub/sub: **federation_senders** (outbound federation), **event_persisters** (DB writes, sharded by room_id), **generic workers** (read paths). Vector-clock 'persisted-up-to' positions track which events are durably persisted; readers wait until their target position is persisted before serving. **Olm/Megolm**: Olm = 1:1 Signal-derived (X3DH + Double Ratchet); Megolm = group ratchet where sender ratchets a chain and shares chain key with members (similar to Signal Sender Keys but server-replicated; future migration to MLS RFC 9420 ongoing).

### Deep dives
1. **Room DAG + state resolution + soft-failure.** Each event is signed and references parent events; the room forms a DAG. State (room name, members, permissions) is computed by walking the DAG. When two homeservers concurrently send conflicting state changes (e.g., both try to add the same alias), the DAG forks; **state resolution algorithm** (version-specific per room) picks authoritative state by event auth + timestamp + sender power level. **Soft-failure**: an event that passes basic validation but violates current authorization rules (e.g., banned user trying to post) is **accepted into the DAG** but **withheld from clients**. This is critical for security: if you simply rejected the event, a malicious peer could fork the DAG and successfully evade bans; by accepting in DAG (so state resolution sees it) + withholding from clients, byzantine peers can't evade. Staff+ commit: DAG model; state-resolution algorithm version; soft-failure semantics; what happens to a peer that consistently sends soft-failed events (no protocol-level penalty; reputation systems at homeserver-admin level; eventually defederation).

2. **HTTP PUT Transaction API + per-destination delivery.** Federation uses HTTP PUT: `PUT /_matrix/federation/v1/send/{txnId}` with Transaction JSON containing up to 50 PDUs (persistent room events) + 100 EDUs (ephemeral: typing, presence, read receipts). Auth via `X-Matrix` header (ed25519 signature using sender's published per-server keys). **Per-destination retry queue**: if recipient server is down, Transaction queued for delivery; retry with exponential backoff; on prolonged failure, eventually give up + admin alert. Bidirectional: each room's homeservers federate with each other via this same API. **Federation senders** (Synapse worker type) are dedicated outbound workers; **event persisters** handle inbound + DB persistence. Staff+ commit: Transaction batching cap; retry policy; what happens during long peer outages (queue grows; eventual drop after retention; affected-rooms admin indicator).

3. **Synapse worker-based scaling with Redis pub/sub.** Pre-2020 monolithic Synapse struggled at matrix.org scale. Modern (per matrix.org blog 2020): worker processes coordinated via Redis pub/sub. **federation_senders**: outbound federation; horizontal scaling. **event_persisters**: write to DB sharded by room_id; vector-clock 'persisted-up-to' position. **generic workers**: read-heavy paths (room state lookups, /sync long-poll). Redis pub/sub coordinates: federation_sender notifies event_persister of new event; event_persister broadcasts persistence position; generic workers wait until target position. Result: matrix.org's message-send p50 dropped from seconds to ~50ms. Trade: Redis becomes a SPOF (need Redis HA); cross-worker coordination complexity. **MLS in federated context**: RFC 9420 designed for centralized DS; Matrix is decentralized; ongoing IETF MIMI WG work to adapt MLS for federation (negotiation/ciphersuite handling to prevent downgrade attacks).

## Known failure modes
1. **Slow peer drags federation queue.** One homeserver is consistently slow to accept Transactions; per-destination queue grows. Production answer: per-destination concurrency cap; circuit breaker after sustained failure; eventual queue truncation with admin alert; affected-rooms indicator (rooms with federation degradation visible to admins).

2. **Mega-room join (10K+ members) times out.** Pre-faster-joins, transferring full state took minutes; client timed out. Production answer: **faster-joins** (2022+) lazy-load membership; user appears in room immediately with basic state (room name, recent messages); full membership backfills in background.

3. **Byzantine peer floods with spam events.** Compromised homeserver pushes thousands of spam events; recipient's DB grows; legitimate events queued behind. Production answer: per-room + per-sender rate limits at recipient; reputation system at homeserver admin level; abuse-reporting workflow; eventually defederation (admin blocks peer at protocol level).

## Notes for the coach
- **Plausibly-asked at Matrix Foundation / Element** + federated-messaging interested companies. Matrix's published spec [spec.matrix.org] is primary; Synapse engineering blog covers the scaling story.
- **The room DAG + soft-failure pattern is the Staff+ unlock.** Candidates who articulate "events accepted in DAG but withheld from clients" demonstrate understanding of byzantine-peer-safety; candidates who reject malicious events upfront miss the ban-evasion-prevention property.
- **The federated MLS gap is the depth probe.** Candidates who recognize "RFC 9420 designed for centralized DS, federation requires adaptation" demonstrate awareness of bleeding-edge crypto-federation work (IETF MIMI WG).
- **Adversarial probe: "what stops a malicious homeserver from rewriting history?"** Strong answer: each event is signed; DAG is immutable; clients independently validate signatures + auth chain back to room creation; rewriting would require forging signatures (cryptographically infeasible). Weak answer: "we trust the homeserver" — but the threat model assumes byzantine peers.

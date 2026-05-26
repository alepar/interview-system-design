---
slug: messenger-multi-device-sync
archetype: interactive-messaging
sources:
  whatsapp_multi_device: engineering.fb.com/2021/07/14/security/whatsapp-multi-device
  signal_protocol: signal.org/docs/specifications/x3dh
---

# Messenger multi-device sync — companion-mode device sync under E2E

## Bar anchors
- **Mid-level (L4/E4):** Treats devices as independent endpoints; doesn't address app-state sync. Suggests server-side state replication without acknowledging E2E constraint.
- **Senior (L5/E5):** Names client-fanout for messages, device list maintained by server, push for offline. May discuss per-device keys but doesn't address replicated mutable application state under E2E.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the **app-state-sync sub-problem**: how do you replicate ordered, mutable application state (chat-list ordering, mute settings, archive state, read pointers) across devices that may be offline for days, when the server is a blind relay? Answer = **E2E-encrypted log replicated through server with rotating keys** — Git over E2E. Names the **device-list as CRDT-like signed log** with deterministic ordering. Articulates **history transfer to newly-linked device** as E2E-encrypted phone-to-companion tunnel (phone never uploads plaintext to server). Articulates **Sender-Key rotation cost on device-remove**: every group containing the removed device must rotate sender keys. Stretch (Sr Staff bar): voice/video group rekeying with 32-byte SRTP master-secret regeneration per recipient device on every join/leave.

## Canonical decomposition

### Requirements
**Functional:**
- Pair up to 4 companion devices to a primary phone
- Deliver every message to every device (sender's + recipient's union)
- Keep chat-list, read-state, starred messages, mute/archive settings consistent across devices
- All under E2E (server cannot read content or metadata)
- History transfer to newly-linked device without phone uploading plaintext

**Non-functional (with numbers):**
- 5 devices per user (1 phone + 4 companion)
- App-state mutation rate ~10-100 ops/user/day
- Per-call SRTP master secrets: 32 bytes per recipient device; rekeyed on every call join/leave
- Replication lag tolerance: minutes (devices may be offline)

### Core entities
- **DeviceList:** signed CRDT-like log of (device_id, added_at, identity_key, status); ordered + authenticated by user's master key
- **AppStateLog:** hash-chained, E2E-encrypted mutation log per user; rotating per-epoch key derived from user's key bundle
- **AppStateMutation:** (op, target, value, timestamp); ops: read_pointer_advance, archive_chat, mute_chat, star_message
- **HistoryTransferSession:** phone-to-companion E2E tunnel for one-shot history sync
- **SenderKeyState:** per-(group, sender-device) symmetric ratchet; rotated on group membership change

### API
- `POST /devices/link` — initiate companion device linking; QR-code-bound ephemeral key exchange
- `POST /devices/unlink` — primary removes companion; triggers Sender-Key rotation in every group
- `POST /app-state/mutations` — encrypted batch of mutations appended to user's encrypted log
- `GET /app-state/since/{epoch}` — encrypted log delta since epoch (server cannot decrypt, just streams)
- `POST /history-transfer/initiate` — phone uploads chunked E2E-encrypted history to companion via server relay

### HLD
**Device-list service** maintains a per-user CRDT-like signed log; each mutation (link/unlink) signed by the user's master key (rooted on the primary phone); server orders mutations and rejects unsigned entries. **App-state-log service** is a per-user append-only log of opaque encrypted blobs; each blob contains a hash-chained batch of mutations encrypted under a per-epoch key derived from the user's key bundle (server never sees plaintext or knows the schema). Devices read the log, decrypt locally, and apply mutations; conflicts resolved by deterministic CRDT-style merge (LWW on read_pointer, OR-Set on starred messages). **History transfer**: when a new companion is linked, phone establishes a one-shot E2E tunnel through the server (chunked transfer, resumable, re-keyable session); phone uploads ciphertext blobs of historical messages; companion downloads and decrypts; server is a blind store-and-forward. **Sender-Key rotation** on device-unlink: client must iterate every group that ever contained the removed device and re-distribute new sender keys pairwise to remaining members — O(groups × members) cost is real, can be amortized in background.

### Deep dives
1. **Device-list as CRDT-like signed log.** Each mutation is a signed entry: `(op, device_id, timestamp, signer_device_key)`. Server orders by `(timestamp, signer)` for total ordering; clients accept mutations only if signature chains back to the user's master key. Concurrent link/unlink mutations: both accepted into the log; CRDT semantics determine final state (LWW on link_unlink, OR-Set on device set). The user-visible safety number is derived from the master key, **not** the device set — so safety number doesn't flip on every link/unlink (this is the ADV pattern from `whatsapp`).

2. **App-state encrypted log: hash-chained mutation log under rotating key.** Each batch is encrypted under a per-epoch key (epoch rotates every N hours or N batches); KDF from user's master key + epoch counter. Server stores opaque blobs in a log; clients fetch deltas since last-applied-epoch; decrypt + apply; on conflict, deterministic merge (LWW on scalar state, OR-Set on set state). Snapshot vs delta: clients snapshot every M epochs (compress old deltas into a snapshot); old deltas can be pruned by server (still encrypted, but pruneable). Critical: server cannot collude to omit an entry, because the hash chain detects gaps — a tamper-evident log under E2E.

3. **History transfer to newly-linked device.** Naive: server retains plaintext history → violates E2E. WhatsApp's answer: phone uploads E2E-encrypted history blob to server over a one-shot ephemeral key; companion downloads + decrypts. Chunked + resumable (history can be GB-class for power users); re-keyable session (if interrupted, new ephemeral key on resume); server is a blind temporary store (deletes blob after companion acks). Failure mode: phone offline mid-transfer → companion stuck without history → retry on phone reconnect; UX: companion shows "syncing history" until complete.

## Known failure modes
1. **Lost device-list update propagation.** User unlinks compromised device, but a sender's client still has stale list → message goes to attacker. Production answer: server-enforced device-list-version stamping per message envelope; sender includes `device_list_version` in send; server rejects if stale; client refreshes and retries; ADV stabilizes user-visible identity.

2. **App-state divergence across devices offline-then-online.** Two devices generate conflicting mutations while offline; on reconnect, both upload conflicting log entries. Production answer: deterministic CRDT merge — LWW on read pointers (last-write-wins by timestamp), OR-Set semantics on starred-messages set; mute/archive use scalar LWW. Hash-chain detects divergence; clients automatically reconcile.

3. **History bootstrap stuck on phone disconnect mid-transfer.** Companion waits indefinitely; UX shows "syncing." Production answer: resumable chunked transfer with re-keyable session; phone resumes from last-acked chunk on reconnect; companion can partially function (recent messages only) while old-history backfills; explicit progress UX.

## Notes for the coach
- **Plausibly-asked at Staff+** at Meta/WhatsApp/Signal-adjacent. The engineering.fb.com WhatsApp multi-device post (July 14, 2021) is the primary public reference.
- **Higher signal than canonical `whatsapp` at Sr Staff** because it forces reasoning about encrypted-replicated state — a strict superset of basic chat-at-scale.
- **The "Git over E2E" framing is the Staff+ unlock.** Candidates who frame app-state as a hash-chained encrypted log under a rotating key demonstrate the right mental model; candidates who suggest "server holds the state" miss the E2E constraint entirely.
- **Adversarial probe: "what if server is malicious and omits a mutation from the log?"** Strong answer: hash-chain detects gaps; clients refuse to apply a log with a broken chain; safety property holds even under fully byzantine server.

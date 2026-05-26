---
slug: signal-protocol
archetype: interactive-messaging
sources:
  x3dh: signal.org/docs/specifications/x3dh
  double_ratchet: signal.org/docs/specifications/doubleratchet
  pqxdh: signal.org/docs/specifications/pqxdh
  iacr_2016_1013: eprint.iacr.org/2016/1013 (Cohn-Gordon et al. "A Formal Security Analysis of the Signal Messaging Protocol")
---

# Signal Protocol — X3DH + Double Ratchet + Sender Keys for E2E messaging

## Bar anchors
- **Mid-level (L4/E4):** Treats E2E as "we use TLS." Doesn't distinguish forward secrecy from post-compromise security. No protocol layering.
- **Senior (L5/E5):** Names X3DH for session setup, Double Ratchet for messages, forward secrecy. May or may not articulate post-compromise security, Sender Keys for groups, or PQXDH.
- **Staff+ (L6/E6+):** Drives proactively. Reasons carefully about **what the server stores** (public pre-keys, identity public keys, encrypted ciphertext blobs, opaque envelopes) vs **what only the device computes** (ratchet state, symmetric keys, plaintext). Explains **forward secrecy** (compromise today → past messages safe), **post-compromise security** (compromise today → future messages safe after one round-trip), and **out-of-order delivery handling** (chain keys advance deterministically; receivers buffer skipped keys). Articulates **Sender Keys for groups** (symmetric chain distributed pairwise once; encrypt-once per group message; rotation on member-change is O(N)). Names **PQXDH** (Signal's Sep 2023 post-quantum extension; hybrid Kyber-768 + classical X3DH). Stretch (Sr Staff bar): articulates **multi-device extension** (per-device identity key, server-maintained device list, ADV-style aggregated safety number); cites IACR 2016/1013 (Cohn-Gordon et al.) formal-analysis paper.

## Canonical decomposition

### Requirements
**Functional:**
- Pairwise asynchronous session: initiator + recipient may be offline at any moment
- Forward-secret + post-compromise-secure 1:1 messaging
- Out-of-order delivery (message N+1 may arrive before N)
- Group messaging extension (Sender Keys)
- Post-quantum resistance against "harvest now, decrypt later"
- Server cannot decrypt content; server is a public-key directory + ciphertext relay

**Non-functional:**
- Deployed in WhatsApp (2B+), Signal, Messenger secret conversations, Google Messages RCS E2E
- Pre-key bundle on server: identity (long-term) + signed pre-key (rotated weeks) + one-time pre-keys (consumed on use)
- Ratchet state per session: ~few KB per recipient
- PQXDH layered Sep 2023

### Core entities
- **IdentityKey:** long-term Ed25519/Curve25519; rooted by user's master device
- **SignedPreKey:** rotated weekly; signed by IdentityKey
- **OneTimePreKey:** rotated per-use; consumed on each new session
- **Session:** per-(local-device, remote-device) ratchet state; root_key + chain_keys
- **DoubleRatchetState:** DH ratchet (root key advance on new DH) + symmetric ratchet (chain key advance per message)
- **SenderKey:** per-group-per-sender symmetric chain for group messages

### API
- `GET /prekeys/{user_id}` — fetch recipient's pre-key bundle (identity_key + signed_pre_key + one optional one-time_pre_key)
- `POST /prekeys` — client uploads new one-time pre-keys when pool low
- `POST /messages` — opaque ciphertext envelope; server routes by recipient_id only
- `GET /messages` — fetch pending ciphertext envelopes

### HLD
Server is a **public-key directory** (per-user identity key, signed pre-key, one-time pre-keys pool) + **ciphertext relay** (opaque envelopes routed by recipient_id only). **X3DH session setup**: initiator fetches recipient's pre-key bundle from server; combines initiator's identity + ephemeral keys with recipient's identity + signed pre-key + (optional) one-time pre-key in 3 or 4 Diffie-Hellmans → shared **root key**. Initiator can immediately encrypt the first message (asynchronous — recipient need not be online). **Double Ratchet** advances state per message: **DH ratchet** (each new ephemeral DH ratchets the root key — provides post-compromise security after one round-trip) + **symmetric ratchet** (each message in a chain advances the chain key one step — provides forward secrecy). Per-message: `message_key = KDF(chain_key, counter)`; chain_key advanced to next. **Out-of-order**: receiver caches skipped message keys (e.g., expected 3, received 5; cache keys 3 and 4 for when they arrive). **Sender Keys** (groups): each sender device generates symmetric sender chain key; distributes pairwise once via Double-Ratchet sessions; subsequent group messages encrypted once with that key. **PQXDH**: hybrid handshake adds Kyber-768 KEM alongside classical X3DH; protects against "harvest now, decrypt later" against future quantum attacker.

### Deep dives
1. **X3DH — asynchronous session setup with offline recipient.** Server holds public keys only: identity (long-term), signed pre-key (rotated weeks, signed by identity), one-time pre-keys (consumed). Initiator's algorithm: (a) fetch recipient's pre-key bundle; (b) generate ephemeral key; (c) compute 3 or 4 DHs (initiator-identity × recipient-signed-pre-key, initiator-ephemeral × recipient-identity, initiator-ephemeral × recipient-signed-pre-key, initiator-ephemeral × recipient-one-time-pre-key); (d) concat + KDF → shared root key; (e) attach first message ciphertext + initiator's public ephemeral + which pre-keys used. Recipient (when online): fetches the bundle from server, identifies which pre-keys were used, derives the same root key, decrypts. **Why this works asynchronously**: server holds the publics; recipient can be offline; initial setup needs no live response from recipient. **OTPK consumption**: each successful X3DH consumes one OTPK from server's pool (single-use property — prevents some replay variants); clients top up OTPK pool on every connect.

2. **Double Ratchet — forward secrecy + post-compromise security.** Two ratchets: **DH ratchet** advances on every new DH key exchange (each party rotates their DH key periodically; new DH → new root_key → new chain_keys). **Symmetric ratchet** advances per message within a chain. Per message: `message_key = KDF(chain_key, counter); chain_key' = KDF(chain_key); encrypt(payload, message_key)`. After use, message_key + counter discarded; chain_key advances. **Forward secrecy**: compromise today reveals current chain_key only; past message_keys discarded; past messages remain safe. **Post-compromise security**: after compromise, next DH ratchet renews root_key from fresh ephemeral DH; attacker without ongoing access loses future visibility. **Out-of-order**: receiver buffers skipped message_keys (with a bound — typically 1000-2000 per chain; older skipped keys forgotten); receiver advances chain on out-of-order receive, decrypts buffered messages when they arrive.

3. **Sender Keys for groups + PQXDH.** **Sender Keys**: pairwise Double Ratchet for N-member group = O(N) ciphertext per message. Sender Key = one symmetric chain per (group, sender device); sender encrypts each group message once with chain key; chain advances per message (forward secrecy within the chain). Distribution: pairwise via existing Double-Ratchet sessions, once per session lifetime. **Member-remove cost**: O(N) — every remaining member must receive a new sender chain. This is what MLS RFC 9420 improves to O(log N) (see `mls-group`). **PQXDH** (Sep 2023): adds Kyber-768 KEM to X3DH; recipient's pre-key bundle now includes Kyber public key; X3DH derives shared secret from both classical DH and Kyber encapsulation; combined via KDF. Result: even if quantum attacker breaks classical DH later (harvest now, decrypt later), the Kyber leg holds. Trade: ciphertext + key sizes ~1KB larger; minimal latency impact.

## Known failure modes
1. **One-time pre-key exhaustion.** OTPK pool runs out on server; new X3DH falls back to signed-pre-key only (still secure, but the per-OTPK PFS for initial message lost). Production answer: clients top up OTPK pool on every connect; server alerts when pool low; minimal practical impact.

2. **State desync after device wipe.** User reinstalls; previous identity key + ratchet state gone. Production answer: re-establish session (new identity key → new X3DH → new safety number); user prompted to re-verify safety number with counterparties; UX flags "session was reset" so users notice.

3. **Compromised identity key.** Attacker steals device's identity private key. Production answer: identity-key change → all sessions rebuild from scratch; safety number changes on every counterparty (entire point of safety numbers — user notices "Alice's safety number changed" and verifies out-of-band). Long-term: identity key rotation policies (Signal's design assumes long-lived identity key; rotation is a user-initiated reset).

## Notes for the coach
- **Asked-confirmed at Signal, Meta** (WhatsApp/Messenger). Increasingly asked at privacy-positioning companies. IACR 2016/1013 (Cohn-Gordon et al.) formal-analysis paper is the canonical academic reference.
- **The server-stores-publics-only framing is the Staff+ unlock.** Candidates who clearly articulate "server is a public-key directory + opaque ciphertext relay" demonstrate the right mental model; candidates who suggest "server helps with key management" miss the threat model entirely.
- **The FS vs PCS distinction is the depth probe.** Candidates who explain "FS = past safe, PCS = future safe after one round-trip" demonstrate understanding; candidates who conflate the two miss the protocol's distinctive guarantee.
- **Adversarial probe: "what if the server tampers with the pre-key bundle? Inserts attacker's keys?"** Strong answer: this is the MITM risk; safety numbers (out-of-band verification) detect; key-transparency systems (CONIKS-class) are the long-term mitigation. Weak answer: "TLS to server prevents this" — but the server itself is the threat.

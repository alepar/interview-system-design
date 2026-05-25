---
slug: google-docs
archetype: conflict-resolution
sources:
  ellis_gibbs: "Ellis & Gibbs, Concurrency Control in Groupware Systems, SIGMOD 1989 (original OT / dOPT)"
  jupiter: "Nichols, Curtis, Dixon, Lamping, High-latency low-bandwidth windowing in the Jupiter collaboration system, UIST 1995"
  wave_ot: svn.apache.org/repos/asf/incubator/wave/whitepapers/operational-transform/operational-transform.html
  new_google_docs: "Google Drive Blog, What's different about the new Google Docs, 2010"
  ot_tp2: "Imine et al., Proving correctness of transformation functions, 2003 (TP2 counterexamples)"
---

# Google Docs (Operational Transformation at central-server scale)

## Bar anchors
- **Mid-level (L4/E4):** Proposes locking or "send the whole document on every keystroke." May mention "merge changes" without a mechanism. Doesn't know OT, can't explain how two concurrent inserts converge, treats it as a CRUD app over WebSockets.
- **Senior (L5/E5):** Names Operational Transformation: clients apply edits locally and optimistically; a server serializes; each op is transformed against concurrent ops before applying. Can derive T(insert@i, insert@j) index-shifting. Knows there are 3 op types (insert/delete/style) and a revision log. May not articulate TP1 vs TP2, why decentralized OT is unsafe, or why intention preservation is separate from convergence.
- **Staff+ (L6/E6+):** Drives proactively. Separates **convergence** (all replicas reach the same state) from **intention preservation** (the merged result reflects what each user meant — concurrent "Alice" and "Bob" don't interleave into "ABloibce"). States the two transform properties: **TP1** (op1∘T(op2,op1) ≡ op2∘T(op1,op2) — both orders converge) and **TP2** (transforming a third op against two others is order-independent) — and that **TP2 is the real difficulty**: virtually every published multi-way OT algorithm (dOPT, adOPTed, GOTO, SOCT2) has had a TP2 counterexample published (Imine et al. 2003). Resolves it the way Google does: the **Jupiter central-server model** keeps a single linear history, transforms each incoming op only against that history, and **never needs TP2**. Notes Google Docs reduces all edits to 3 op types, applies locally without waiting for ack, and that **peer-to-peer Wave was abandoned** while server-mediated Docs shipped. Quantifies ~100 concurrent editors per doc; presence on a separate channel (no OT for cursors).

## Canonical decomposition

### Requirements
**Functional:**
- Multiple users edit one rich-text document concurrently; everyone converges
- Local edits apply instantly (optimistic) without a server round-trip
- Edits are insert text, delete text, apply style-to-range (3 op types)
- Full revision history; any client can reconnect and catch up from its last revision
- Cursors/selections shown live (separate ephemeral channel)

**Non-functional (with numbers):**
- Up to ~100 concurrent editors per document (beyond which new joiners are throttled/view-only)
- Local apply latency ~0 (optimistic); convergence within a network RTT of the server
- Central serializer is the single source of truth (linear op history)
- Presence updates degrade noticeably past ~50 active cursors before the OT channel does

### Core entities
- **Operation:** `insert(pos, text)` | `delete(pos, len)` | `style(range, attrs)` with a base revision
- **Revision log:** server-side linear history; revision N = the doc after N applied ops
- **ClientState:** last acknowledged revision + a single pending (composed) op buffer
- **TransformFn:** `T(op_a, op_b) → op_a'` adjusting op_a to apply after op_b
- **Presence:** cursor/selection per user (ephemeral, not in the revision log)

### API
- WebSocket `client → server`: `{baseRevision, op}` (one in-flight op; compose while waiting for ack)
- WebSocket `server → client`: `{revision, transformedOp}` broadcast to all other clients
- `client → server`: `{type: "sync", lastRevision}` on reconnect → server replays transformed ops since
- WebSocket `client ↔ server`: `{type: "cursor", pos, selection}` (separate presence channel)

### HLD
Each client keeps the last server-acknowledged revision plus **one** pending op (the Jupiter rule: at most one op in flight; compose further local edits into a single op while awaiting ack — composition of two document operations is itself one operation). When a client makes an edit it applies it locally immediately and sends `{baseRevision, op}` to the server. The **central server** holds the canonical linear revision log. On receiving an op based on revision R, the server transforms it against every op committed since R (R+1…current), applies the result as the next revision, and broadcasts the transformed op to all other clients. Because the server has a single state space (its own history), it only ever transforms an incoming op against a *linear* sequence — so the multi-way TP2 case never arises. This is exactly why Google Docs gets away with OT where peer-to-peer designs struggle.

Each transform function encodes intention preservation via index arithmetic: `T(insert(i,s), insert(j,t))` shifts i by len(t) if j ≤ i; `T(insert(i,s), delete(j,n))` shifts i left by the overlap; concurrent inserts at the same index are ordered by a stable tiebreak (site id) so all replicas agree (convergence) even though the chosen order is arbitrary (a small intention compromise). Style ops are a third op type over ranges, transformed independently of text content where possible. **Presence** (cursors/selections) rides a separate channel and is *not* OT-transformed or logged — it's ephemeral, and a cursor index is reanchored as text shifts (see `presence-awareness`). On reconnect, a client sends its `lastRevision` and the server replays the transformed tail.

### Deep dives
1. **Deriving the transform functions + intention preservation.** Work T(insert,insert), T(insert,delete), T(delete,delete) on a concrete string, showing how index shifts implement "what the user meant survives concurrent edits." Surface the hard case: two users insert different text at the same index — convergence requires a deterministic tiebreak (site id), but that means one user's intention (their text first) loses; this is acceptable for Docs (no character interleaving within a single insert) but is exactly the *interleaving* problem that bites character-granular CRDTs (see `collaborative-text-editor`). The Staff+ point: convergence is mechanical; intention preservation is the design judgment.
2. **The Jupiter dual-buffer model and why it dodges TP2.** TP2 (three-way transform order-independence) is required for *decentralized* OT and is famously hard — most published proofs were later shown wrong. Jupiter sidesteps it: a 2-way state space per client against the server, the server holding one linear history, so any op is only ever transformed against a sequence, never against two concurrent transforms simultaneously. Explain the per-client server-side buffer, the single-in-flight-op rule, and op composition while waiting for ack. This is the architectural move that made OT shippable at Google scale.
3. **Scaling the serializer + reconnect/catch-up.** The central server scales fine with editor *count* (broadcast fan-out) but the per-document op stream is inherently serial, so a hot document is a single-writer bottleneck — mitigate with op composition (batch a burst of keystrokes into one op), per-document process affinity, and capping concurrent editors (~100). Reconnect: client sends lastRevision; server transforms-and-replays the tail or, after long divergence, sends a snapshot. Note OT's weakness here: merging a long offline divergence is O(n²) in op count (vs CRDTs' load cost) — a reason Docs keeps clients online and bounded.

## Known failure modes
1. **Attempting decentralized (peer-to-peer) OT.** Without a central serializer you need TP2, and correct TP2 transform functions are extraordinarily hard — the literature is littered with published-then-disproven algorithms. Production answer: collapse to a single central serializer (Jupiter), as Google Docs does; peer-to-peer collaborative text is better served by a sequence CRDT.
2. **Long offline divergence.** A client edits offline for hours; on reconnect the server must transform its op against a huge tail (or vice versa), which is O(n²) and can take seconds. Production answer: bound offline editing, send a state snapshot + rebase rather than replaying thousands of transforms, or use a CRDT/Eg-walker design where long-branch merge is cheaper.
3. **Lost intention on concurrent same-position insert.** Two users insert at index i; the tiebreak makes one win deterministically, but if the system tiebreaks per-character rather than per-insert, the two inserts interleave into garbage. Production answer: tiebreak at the *operation* granularity (whole insert ordered atomically) with a stable site id, preserving convergence and keeping each user's run intact.

## (Spine note)
`google-docs` owns OT specifically. The OT-vs-CRDT decision for text and the sequence-CRDT alternatives live in `collaborative-text-editor`; the general CRDT math is `crdt-primitive`. The WebSocket transport + broadcast fan-out is shared with messaging `slack`/`discord-presence` — reference, don't re-derive.

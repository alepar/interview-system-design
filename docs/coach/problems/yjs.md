---
slug: yjs
archetype: conflict-resolution
sources:
  yjs_internals: github.com/yjs/yjs/blob/main/INTERNALS.md
  yata_paper: "Nicolaescu, Jahns, Derntl, Klamma — Near Real-Time P2P Shared Editing on Extensible Data Types (YATA), 2016"
  jahns_suitable: blog.kevinjahns.de/are-crdts-suitable-for-shared-editing
  crdt_benchmarks: github.com/dmonad/crdt-benchmarks
  y_protocols: github.com/yjs/y-protocols/blob/master/PROTOCOL.md
---

# Yjs (production CRDT library: YATA, encoding, GC, awareness)

## Bar anchors
- **Mid-level (L4/E4):** Knows Yjs is "a CRDT library for collaborative editing." Can't describe the internal model, assumes CRDTs are automatically slow/huge, treats it as a black box behind a WebSocket.
- **Senior (L5/E5):** Knows Yjs implements a sequence CRDT (YATA), gives each item a unique id, and syncs updates as binary blobs over a provider (y-websocket/y-webrtc). Knows deletions are tombstoned and there's an awareness channel for cursors. May not explain run coalescing, the state-vector sync protocol, why Yjs survives out-of-order delivery, or quote benchmark numbers.
- **Staff+ (L6/E6+):** Drives proactively. Walks the **Item** struct (`id=(clientID,clock)`, `origin`, `originRight`, `left`, `right`, `parent`, `content`, deleted-flag) and the YATA `integrate()` conflict loop (ordering concurrent inserts that share an origin via `originRight` + clientID). Explains **run coalescing** (a left-to-right typed run "abc" is 3 clock ticks but **one Item**, split only if interrupted), so metadata is O(runs) not O(chars). Explains **deletion = a flag + a compact delete-set** (the B4 trace's 182k inserts / 77k deletes yield only a **~4.5KB delete set**), and **~88 bytes per integrated Item**. Explains the **state-vector sync** (SyncStep1 exchanges state vectors `{client→clock}`; SyncStep2 ships exactly the missing structs as one binary blob) and that updates are **state-based**, so Yjs converges under arbitrary reordering/duplication *without* a causal-broadcast layer. Quotes the **dmonad benchmark** (B4 ~5.7s Yjs vs ~14.3s Automerge; Yjs ~46× faster parse) and that **GC of tombstones is disabled by default** (deletes are already cheap; GC risks convergence). Names the **awareness sidecar** (30s expiry / 15s rebroadcast) as separate from the doc.

## Canonical decomposition

### Requirements
**Functional:**
- Converge a shared sequence/map/text type across peers with arbitrary network behavior (reorder, duplicate, offline)
- Apply local edits instantly; integrate remote updates incrementally
- Sync efficiently: a reconnecting peer fetches only what it's missing
- Carry ephemeral awareness (cursors/presence) without polluting the document
- Keep memory/encoding small enough for real documents

**Non-functional (with numbers):**
- ~88 bytes per integrated Item (before run coalescing collapses runs)
- B4 trace (182k inserts): delete set ~4.5KB; encoded doc ~160KB (~53% over raw text)
- dmonad B4: Yjs ~5.7s apply vs Automerge ~14.3s; parse ~39ms vs ~1805ms
- Awareness: clients expire after 30s without update; rebroadcast ≥ every 15s
- Survives lossy/duplicating/reordering channels (state-based updates; no causal broadcast required)

### Core entities
- **Item (struct):** id `(clientID, clock)`, `origin`/`originRight` (neighbor ids at insert time), `left`/`right`, `parent`, `content`, `deleted` flag
- **Delete set:** compact `(clientID, clock-range)` ranges marking deleted content (not per-char tombstones)
- **State vector:** `{clientID → highest clock}` summarizing what a peer has
- **Update:** binary-encoded set of structs (lib0 encoding) shipped between peers
- **Awareness:** ephemeral `{clientID → {clock, state, lastUpdated}}` map, separate from the doc

### API
- `ytext.insert(index, content)` / `ydoc.transact(fn)` — local edits
- `Y.encodeStateVector(doc) → Uint8Array`; `Y.encodeStateAsUpdate(doc, remoteSV) → Uint8Array` (SyncStep2)
- `Y.applyUpdate(doc, update)` — integrate a remote binary update (idempotent, order-independent)
- `awareness.setLocalStateField('cursor'|'user', …)`; awareness update messages over the provider

### HLD
A Yjs document is a set of **Items** in a doubly-linked list per type. Each Item records the ids of the items immediately to its left (`origin`) and right (`originRight`) **at insertion time**; the **YATA integrate()** algorithm uses these plus clientID to deterministically order concurrent inserts that share an origin, achieving convergence without OT-style transforms. A run of characters typed left-to-right coalesces into a **single Item** (clock increments per char, but one struct), split only when interrupted — so a 260k-op real document collapses to ~11k Items (~2MB). **Deletion** sets the Item's deleted flag and (with GC, optional) drops its content to a tiny GC marker; the set of deletions is encoded as a compact **delete set** of clock ranges, not per-character tombstones — which is why the B4 trace's 77k deletes cost ~4.5KB.

**Sync** is a two-step state-based protocol: a peer sends its **state vector** (`{clientID → clock}`); the other replies with exactly the structs the first is missing (`encodeStateAsUpdate(doc, theirStateVector)`) as one binary blob, plus its own state vector. Because updates are **state-based and idempotent**, applying them in any order, multiple times, converges — Yjs needs no causal-broadcast middleware (unlike a generic op-based CRDT). A **provider** (y-websocket: one server fans out updates + awareness; y-webrtc: peer-to-peer) carries updates and the **awareness** protocol. Awareness is a separate state-based CRDT (`{clientID → {clock, state}}`, LWW per client) holding cursors/presence; it is **never stored in the document** (ephemeral), expires after 30s without refresh, and clients rebroadcast ≥ every 15s.

### Deep dives
1. **The Item model + YATA integration + run coalescing.** Walk `integrate()`: when inserting between `origin` and `originRight`, scan items whose origin falls in that range and order by `(originRight, clientID)` so all replicas agree — a couple-dozen-line loop that replaces OT's transform-function zoo. Run coalescing is the performance trick: contiguous same-client inserts share one Item with multi-char content, so metadata is O(runs) not O(chars); a middle-of-run delete splits the Item. This is why Yjs's ~88-bytes-per-Item overhead is acceptable in practice — real prose has few runs. Contrast with naive per-character CRDTs that blow up memory (the reason older Automerge was slow).
2. **Deletion, the delete-set, and why GC is off by default.** Deletion is a flag, not removal — the Item stays so concurrent inserts still resolve against it — but its content can be dropped and the deletion recorded in a compact range-encoded delete set (~4.5KB for 77k deletes). Tombstone **GC** (physically removing deleted Items) is *disabled by default* in Yjs: it risks divergence if a peer that hasn't seen the delete reconnects, and deletes are already cheap, so it's not worth the convergence risk. This is the concrete answer to the `collaborative-text-editor` tombstone-growth problem: don't GC per-element; keep a tiny delete-set.
3. **State-vector sync and why Yjs tolerates any channel.** SyncStep1 (send state vector) + SyncStep2 (send missing structs) means a reconnecting peer transfers only the delta, computed from `{clientID → clock}` diffs. Because updates are state-based and `applyUpdate` is idempotent and order-independent, Yjs converges under reordering, duplication, and offline gaps with **no causal-broadcast requirement** — a major operational simplification vs op-based CRDTs. Benchmarks (dmonad/crdt-benchmarks B4): Yjs applies the 260k-op trace in ~5.7s vs Automerge ~14.3s and parses ~46× faster, with encoded size ~53% over raw — the evidence that "CRDTs are too slow/big" is outdated for a well-engineered library. (Note: Loro/Diamond Types now beat Yjs on some traces; quote relative orders of magnitude, not frozen absolutes.)

## Known failure modes
1. **Tombstone/metadata bloat over years of edits.** Even with a compact delete set, a document edited for years accumulates Items. Production answer: periodic server-side snapshot + state reset behind a flag; rely on run coalescing; do not enable per-element GC casually (convergence risk).
2. **Cold load of a multi-megabyte history.** A huge document is slow to parse if you replay all structs. Production answer: columnar binary encoding (Yjs v13+), load from a snapshot rather than the full update log, or adopt Eg-walker for an order-of-magnitude smaller steady state (see `collaborative-text-editor`).
3. **Awareness flooding the channel.** High-frequency cursor moves broadcast naively saturate the provider. Production answer: throttle awareness to ~33ms/30FPS, keep awareness state tiny, and rely on the 30s expiry + explicit removeAwareness on disconnect rather than streaming every pointer pixel.

## (Spine note)
`yjs` owns the production CRDT-library reality. The general math is `crdt-primitive`; the sequence-CRDT theory and OT-vs-CRDT decision is `collaborative-text-editor`; Yjs's awareness protocol is the reference implementation for `presence-awareness`; Yjs as the merge engine inside a sync system connects to `local-first-sync`.

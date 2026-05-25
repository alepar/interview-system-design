---
slug: presence-awareness
archetype: conflict-resolution
sources:
  y_protocols: github.com/yjs/y-protocols/blob/master/PROTOCOL.md
  yjs_awareness: docs.yjs.dev/api/about-awareness
  yjs_relative_position: docs.yjs.dev/api/relative-positions
  figma_presence: sujeet.pro/articles/figma-multiplayer-infrastructure
  liveblocks_presence: liveblocks.io/docs/tutorial/react/getting-started/presence
---

# Presence / Awareness (ephemeral collaborative editing state)

## Bar anchors
- **Mid-level (L4/E4):** Stores cursor positions in the document/database and updates them on every move. Doesn't recognize presence is ephemeral, floods the channel, and corrupts cursors when text shifts.
- **Senior (L5/E5):** Broadcasts cursors over a separate channel, throttles updates, and doesn't persist them. Knows each user shows a colored cursor + name. May not articulate the awareness CRDT (LWW per client + expiry), anchor-stable cursor positions, or the "never journal presence" decision.
- **Staff+ (L6/E6+):** Drives proactively. States the four pillars: (1) **awareness is never persisted** — Figma never journals cursors because at 30 FPS × 200 editors it would dominate the >2.2B/day journal writes for **zero recovery value**; (2) **state-based LWW per client** — Yjs awareness is a `{clientID → {clock, state, lastUpdated}}` map where only the owning client mutates its slot and a higher clock wins, with **30s expiry / ≥15s rebroadcast** and `state=null` signaling explicit offline; (3) **anchor-stable cursors** via **Y.RelativePosition** — a cursor is fixated to a *character/Item id*, not an integer index, so a concurrent insert before it doesn't misplace it (it falls back to a neighbor if its anchor is deleted); (4) **throttle ~33ms/30FPS** and interpolate to 60Hz on receive. **Delineates from `discord-presence`**: that is *connection-scale* online/offline with GenStage fan-out to millions; **this is document-scale** ephemeral editing state, capped at the editor limit (200 Figma / 100 Docs / 50 FigJam).

## Canonical decomposition

### Requirements
**Functional:**
- Show who's in the document, their cursors/selections, name, and color, live
- Cursor positions stay correct as the document is concurrently edited
- A disconnected user's cursor disappears promptly
- Optional follow-mode / spotlight (share a viewport)

**Non-functional (with numbers):**
- Never persisted (ephemeral; lost on disconnect by design)
- Awareness expiry 30s without update; clients rebroadcast ≥ every 15s
- Cursor update throttle ~33ms (30 FPS); interpolate to ~60Hz on receive
- Capped at the document's editor limit (200 Figma / 100 Docs / 50 FigJam); payload ~50–200 bytes/update

### Core entities
- **Awareness map:** `{clientID → {clock, state, lastUpdated}}` (state = {cursor, selection, user{name,color}, viewport})
- **RelativePosition:** an anchor `(Item.ID, assoc)` that survives concurrent edits (vs an absolute index)
- **Client slot:** owned exclusively by one client; LWW by its monotonic clock
- **(optional) followingClientID:** a one-field flag enabling spotlight/follow-mode

### API
- `awareness.setLocalStateField('cursor', relativePos)` / `('user', {name, color})`
- awareness update message: `[ (clientID, clock, state) … ]` (send any subset, ≥ own); applied iff clock strictly greater
- `relativePositionFromIndex(type, index) → anchor`; `absolutePositionFromRelative(anchor) → index | null`
- on disconnect: `removeAwarenessStates([clientID])` (or set state=null) → others drop the cursor immediately

### HLD
Presence is a **separate, ephemeral CRDT**, deliberately *not* part of the document. The canonical design (Yjs awareness) is a **state-based LWW-per-client** map: `{clientID → {clock, state, lastUpdated}}`, where **only the owning client mutates its own slot**, each update carries a monotonically increasing **clock**, and a receiver applies an incoming entry **iff its clock is strictly greater** than the locally known clock for that client. Because each client owns exactly one slot, there are no write conflicts to resolve — it's LWW per client by construction. State is small (cursor, selection, name, color, viewport ~50–200 bytes), so awareness skips the state-vector minimal-sync machinery and just sends the (subset of the) map. Liveness uses timeouts: a client whose slot hasn't been refreshed in **30s** is removed (marked offline), so clients **rebroadcast their own state ≥ every 15s**; an explicit disconnect sets **state=null** (or calls removeAwareness) so peers drop the cursor *immediately* rather than waiting 30s.

The subtle correctness piece is **cursor positioning under concurrent edits**. A naive `cursor = charIndex` becomes wrong the instant another user inserts text before it. Yjs's **Y.RelativePosition** fixates the cursor to a specific **character/Item id** (with an association bit for "before/after"), so as the document changes the relative position still resolves to the same logical spot on every client; if the anchored character is deleted, it falls back to a neighbor. Cursor moves are **throttled to ~33ms (30 FPS)** on the wire and **interpolated to ~60Hz** on receive for smoothness (Figma samples/coalesces at ~30 FPS and interpolates inside requestAnimationFrame). **Follow-mode/spotlight** is just one more awareness field (a `followingClientID` or a shared viewport rect) that subscribers react to. Server-side, presence rides the same per-document/WebSocket fan-out as document changes but is **never written to the journal/DB** — the decision that keeps the durability path tractable.

### Deep dives
1. **Why awareness is never persisted (the "don't journal cursors" decision).** Figma's journal handles >2.2B changes/day; at 30 FPS across up to 200 editors, persisting cursor positions would *dominate* that write volume — and cursor history seconds old has **zero recovery value** (you never need to "restore" where someone's mouse was). So presence is broadcast-only, in-process, ephemeral. This is the canonical example of *not* over-engineering: the Staff+ move is to explicitly separate durable document state (journaled, recovered) from ephemeral collaborative state (broadcast, discarded), and to justify it on the write-amplification + zero-recovery-value argument. A candidate who proposes storing cursors in the DB has missed the core insight.
2. **The awareness CRDT: LWW-per-client + expiry.** Presence converges trivially because the state space is partitioned by ownership — each client writes only its own slot, so there's never a real conflict, just LWW by the client's own monotonic clock. The interesting parts are *liveness*, not safety: the 30s expiry + 15s rebroadcast handle "a client vanished without saying goodbye" (crash, network drop), and `state=null` handles graceful disconnect. Contrast with `crdt-primitive`'s general CRDTs (which need genuine merge of concurrent writes to *shared* slots) — awareness is the easy case *because* of ownership partitioning, and recognizing that is the depth signal.
3. **Anchor-stable cursors via relative positions.** The one genuinely hard correctness problem in presence: an absolute index cursor is wrong the moment the document shifts under it. The fix is to express the cursor as a **relative position** anchored to a character/Item id (the same identifiers the sequence CRDT in `yjs`/`collaborative-text-editor` already maintains), so it survives concurrent inserts/deletes and resolves to the same logical location on every client. Deletion of the anchor degrades gracefully to a neighbor. This is why presence is tightly coupled to the document's convergence model even though it's stored separately — the cursor anchor *is* a document position identifier, just used ephemerally.

## Known failure modes
1. **Persisting cursor moves (the cardinal sin).** Journaling presence explodes write volume for no recovery value. Production answer: ephemeral, broadcast-only, never in the journal/DB — the explicit Figma decision.
2. **Stale cursor lingering after a client disconnects.** Without liveness handling, a crashed client's cursor stays forever. Production answer: 30s expiry + ≥15s rebroadcast for crash/drop, plus explicit `state=null`/removeAwareness on graceful disconnect so peers drop it immediately.
3. **Cursor drift on concurrent edits.** An absolute-index cursor lands in the wrong place after a remote insert. Production answer: relative positions anchored to character/Item ids that survive edits and fall back to a neighbor on anchor deletion.

## (Delineation / spine note)
`presence-awareness` owns **document-scale ephemeral editing state** (cursors/selections/viewport, awareness CRDT, relative positions). Connection-scale online/offline presence with server-side GenStage fan-out to millions is messaging `discord-presence` — a different problem on the same WebSocket wire. The awareness implementation reference is `yjs`; the relative-position anchors come from the sequence CRDT in `collaborative-text-editor`. The "don't journal ephemeral state" decision is shared with `figma`.

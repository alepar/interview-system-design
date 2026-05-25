---
slug: figma
archetype: conflict-resolution
sources:
  figma_multiplayer: figma.com/blog/how-figmas-multiplayer-technology-works/
  figma_ordered_sequences: figma.com/blog/realtime-editing-of-ordered-sequences/
  figma_reliable: figma.com/blog/making-multiplayer-more-reliable/
  hello_interview_figma: hellointerview.com/community/questions/multiplayer-figma-design
---

# Figma (server-authoritative LWW-per-property multiplayer)

## Bar anchors
- **Mid-level (L4/E4):** Proposes "broadcast every change over WebSockets" with no conflict model, or reaches for OT/CRDT as a buzzword without justification. Doesn't model the document as objects-with-properties or address ordering/reparenting.
- **Senior (L5/E5):** Models the document as a tree of objects, uses a central server to serialize changes, and applies last-writer-wins per object. Knows cursors are separate from document state. May not articulate property-level (not object-level) LWW, fractional indexing for child order, cycle rejection on reparent, or why Figma rejected both OT and pure CRDTs.
- **Staff+ (L6/E6+):** Drives proactively. States Figma's document model as **`Map<ObjectID, Map<Property, Value>>`** and its conflict resolution as **last-writer-wins per (object, property)** with the **server defining order (no timestamp needed)** — so two clients editing *different properties* of the same object never conflict. Explains why Figma **rejected OT** (combinatorial explosion of transform pairs across dozens of op types) **and pure CRDTs** (P2P metadata overhead is unnecessary when you already have a central authority). Explains **fractional indexing** for child order (arbitrary-precision fractions in (0,1), base-95 ASCII strings; insert between A,B = a value between them; the server hands the *second* concurrent insert at the same spot a fresh unique position) and that fractional indexing **interleaves under concurrent runs** — fine for design objects, wrong for text. Handles **reparenting cycles** (server rejects a parent update that would create a cycle). Quotes: **200 concurrent editors/cursors cap**; per-document **Rust process**; ~33ms/30FPS client batches; the journal handles **>2.2B changes/day, 95% persisted within ~600ms**; checkpoints to S3 cross-region, journal checkpointed within 30 min. Treats **presence as never-journaled** (ephemeral).

## Canonical decomposition

### Requirements
**Functional:**
- Many designers concurrently edit one file (a tree of objects with typed properties)
- Edits to different properties/objects merge without conflict; same-property conflicts resolve deterministically
- Objects can be reordered within a parent and reparented across the tree
- Live cursors/selection; the file is durable across server-process crashes

**Non-functional (with numbers):**
- 200 concurrent editors per file (also the visible-cursor cap); FigJam 50
- Journal >2.2B received changes/day; 95% of edits persisted within ~600ms
- Client→server batches at ~33ms (≈30 FPS)
- Per-document server process (Rust); checkpoints in S3 cross-region; journal checkpointed within 30 min
- Eventual consistency (server-arbitrated), not strong consistency

### Core entities
- **Object:** an ID with a `Map<Property, Value>` (e.g. x, y, fill, parent, fractional-index)
- **Document:** `Map<ObjectID, Map<Property, Value>>`, forming a tree via each child's `parent` link
- **Change:** `(objectID, property, value)` with a server-assigned sequence number
- **Journal:** write-ahead log of changes per document (durability between checkpoints)
- **Presence:** cursor/selection/viewport per editor — ephemeral, never journaled

### API
- WebSocket `client → server`: batched `{objectID, property, value}` changes (~33ms cadence)
- WebSocket `server → clients`: changes with assigned sequence numbers, fanned out from the per-document process
- Reparent: a change setting child's `parent` property (server rejects if it would create a cycle)
- Reorder: a change setting child's fractional-index property
- Presence channel: cursor/selection/viewport (broadcast, not persisted)

### HLD
Each open document runs in a **dedicated server process** (Rust, no GC pauses) that holds the document as `Map<ObjectID, Map<Property, Value>>` and is the **single source of truth**. Clients apply edits locally for responsiveness and send batched `(objectID, property, value)` changes (~33ms). The server applies changes in arrival order, assigns each a **sequence number**, and fans out to all connected clients. Conflict resolution is **LWW at the property granularity**: the server simply keeps the latest value any client sent for a given (object, property) — no timestamps needed because the server *defines* the order. Two clients editing `x` and `fill` of the same object both succeed; two clients editing the same `x` resolve to whoever's change the server processed last. A client discards incoming server changes that conflict with its own *unacknowledged* property changes, showing a best-prediction of the eventually-consistent value.

**Ordering of children** within a parent uses **fractional indexing**: each child's position is an arbitrary-precision fraction in (0,1) stored as a base-95 ASCII string; inserting between two children picks a value strictly between their indices (averaging), so an insert touches only the new child. To avoid two children colliding on an identical index under concurrency, the **server assigns a fresh unique position** to the second concurrent insert. **Reparenting** is just setting the `parent` property; the server **rejects** any update that would create a **cycle** (A→B while B→A), and clients hide optimistic cycles until the server confirms. **Durability**: a per-document **journal** (write-ahead log) records changes and is checkpointed to **S3 (cross-region)**; the journal handles >2.2B changes/day and persists 95% of edits within ~600ms, with all journal entries checkpointed within 30 minutes (the journal itself isn't cross-region replicated — durability comes from prompt checkpointing). **Presence** (cursor/selection/viewport) rides the same WebSocket but is **never journaled** — it's ephemeral and carries zero recovery value (see `presence-awareness`).

### Deep dives
1. **Why property-level LWW beats OT and pure CRDTs here.** Figma is a tree of typed-property objects, not a long string. OT would need a transform function for every pair of dozens of op types — a combinatorial explosion "very difficult to reason about." Pure CRDTs carry per-replica metadata to converge *without* a central authority — but Figma *has* a central authority, so that metadata is pure overhead. Server-arbitrated LWW-per-property is the minimal correct design: the server defines order (no timestamps, no vector clocks), and property granularity means most concurrent edits (different properties, or different objects) never conflict at all. The Staff+ insight: the right convergence model is a function of your topology — *centralized → let the server arbitrate; don't pay CRDT P2P costs you don't need.*
2. **Fractional indexing for ordering, and its interleaving caveat.** Child order is a fraction in (0,1) (base-95 ASCII, arbitrary precision so you never run out of room between two keys); insert = average of neighbors, touching only the new object. The server breaks identical-index collisions by minting a fresh position for the second concurrent insert. The known weakness: concurrent insertion of *runs* can interleave (the same anomaly as text CRDTs) — Figma accepts this because design documents don't have the "two pasted paragraphs must not interleave" requirement that text does. This is the precise reason fractional indexing is fine for object z-order but *inappropriate for text* (where you need RGA/Fugue — see `collaborative-text-editor`).
3. **Durability: the journal + checkpoint design.** A per-document Rust process holding state in memory is fast but volatile, so a **write-ahead journal** records every change with start/end sequence numbers and is checkpointed to S3. The reliability rework drove worst-case data loss from ~minutes (checkpoint-only) to sub-second by journaling first (95% persisted within ~600ms). Cross-region durability is achieved not by replicating the journal but by guaranteeing every journal entry is checkpointed (to cross-region-replicated S3) within 30 minutes. On process death, recovery replays the journal onto the last checkpoint. This is the answer to "what happens when the per-document server crashes" — and the contrast with presence, which is deliberately *not* in this durability path.

## Known failure modes
1. **Reparent cycle under concurrency.** Two clients concurrently move A under B and B under A; applied naively the tree becomes a cycle. Production answer: the server rejects any parent update that would create a cycle (it has the authoritative tree); the losing client rolls back its optimistic move. Clients never persist a cycle.
2. **Per-document process crash mid-session.** The in-memory document is volatile. Production answer: the write-ahead journal (95% within 600ms) + S3 checkpoints (within 30 min) bound data loss to sub-second; recovery replays the journal onto the latest checkpoint. The reliability work specifically targeted shrinking this window.
3. **Presence updates overwhelming the system.** At 200 editors moving cursors at 30 FPS, journaling presence would dominate the >2.2B/day write volume for zero recovery value. Production answer: treat presence as ephemeral in-process state, broadcast-only, never journaled — the decision that keeps the durability path tractable (see `presence-awareness`).

## (Spine note)
`figma` owns server-authoritative LWW-per-property multiplayer for a structured document. The infinite-canvas/whiteboard variant (versionNonce LWW, P2P) is `figjam-whiteboard`; ephemeral cursors are `presence-awareness`; the OT and CRDT alternatives it rejected are `google-docs` and `collaborative-text-editor`/`crdt-primitive`.

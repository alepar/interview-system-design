---
slug: figjam-whiteboard
archetype: conflict-resolution
sources:
  excalidraw_p2p: plus.excalidraw.com/blog/building-excalidraw-p2p-collaboration-feature
  excalidraw_deepwiki: deepwiki.com/excalidraw/excalidraw/7-collaboration-system
  tldraw_collab: tldraw.dev/sdk-features/collaboration
  miro_bytes: medium.com/miro-engineering/fighting-for-bytes-in-the-frontend-419c48103ef8
  figma_ordered_sequences: figma.com/blog/realtime-editing-of-ordered-sequences/
---

# FigJam / Whiteboard (infinite canvas, versionNonce LWW)

## Bar anchors
- **Mid-level (L4/E4):** Proposes broadcasting shape edits with no conflict model and rendering everything every frame. Doesn't address concurrent edits to the same shape, deletion conflicts, z-order, or culling on an unbounded canvas.
- **Senior (L5/E5):** Per-shape last-writer-wins, tombstone deletes, WebSocket broadcast, render only the viewport. Knows an infinite canvas needs spatial indexing. May not give a deterministic tiebreak for concurrent same-shape edits, handle connector referential integrity, or explain z-order under concurrency.
- **Staff+ (L6/E6+):** Drives proactively. Specifies **per-element `version + versionNonce` LWW** (Excalidraw): increment `version` on each edit; on merge keep the highest version; break ties by the **lower `versionNonce`** (a random int regenerated per change) so every peer deterministically converges to the same winner. **Deletes are tombstones** (`isDeleted` flag, filtered at render) so union-merge can't resurrect. **Z-order via fractional indices** (insert between layers without reindexing; `syncInvalidIndices()` recomputes if inconsistent). **Connectors** carry bidirectional bindings (startBinding/endBinding ↔ the target's boundElements); on concurrent endpoint delete, unbind to a floating arrow rather than corrupt. **Infinite canvas** → spatial index (quadtree) + viewport culling (`display:none` offscreen) + structured tiles (Miro) not raster. Quotes: cursor throttle ~33ms/30FPS on a separate channel, 20s periodic full-scene resync, tldraw room = Cloudflare Durable Object + SQLite (~50 collaborators), perf cliff in the low thousands of objects (community lore — flag it).

## Canonical decomposition

### Requirements
**Functional:**
- Many users concurrently create/move/edit/delete shapes, sticky notes, connectors, and freehand strokes on a shared infinite canvas
- Concurrent edits to the same element converge deterministically; deletes don't resurrect
- Z-order (stacking) is stable under concurrent inserts
- Connectors stay referentially consistent when endpoints are concurrently deleted
- Live cursors; smooth pan/zoom over a huge board

**Non-functional (with numbers):**
- ~50 concurrent collaborators per board (tldraw); cursor throttle ~33ms (30 FPS) on a separate channel
- 20s periodic full-scene resync (catch-up/keep-alive) atop incremental updates
- Render cliff in the low thousands of objects (community-reported ~8k — not vendor-confirmed)
- Per-room isolation (e.g. Cloudflare Durable Object + SQLite per room in tldraw)

### Core entities
- **Element:** id, type, geometry, `version` (int), `versionNonce` (random int), `isDeleted` flag, fractional `index` (z-order)
- **Binding:** connector's startBinding/endBinding → element id; target's `boundElements` lists the connector (bidirectional)
- **Scene:** the element set; visible elements = `!isDeleted`, ordered by fractional index
- **Cursor/presence:** per-user pointer + selection (ephemeral, separate channel)

### API
- broadcast `SCENE_UPDATE` (element set deltas); `MOUSE_LOCATION` (throttled cursor, separate type)
- `reconcile(local, remote)` → union by id, keep higher `(version, then lower versionNonce)`
- periodic `SYNC_FULL_SCENE` every ~20s for reliability
- `syncInvalidIndices()` → recompute fractional indices when ordering is inconsistent

### HLD
Each element carries a monotonically-incremented `version` and a random `versionNonce`. On a local edit a peer bumps `version` (and sets a fresh `versionNonce`) before broadcasting. **Reconciliation** takes the **union** of local and incoming element arrays and, per id, keeps the element with the higher `version`; if versions tie (two peers edited concurrently) it keeps the one with the **lower `versionNonce`** — a deterministic, peer-independent tiebreak that guarantees every client converges to the identical scene. **Deletion** is never a removal: an `isDeleted` flag is set and the element is filtered out at render time, so the union-merge cannot resurrect a deleted element (a concurrent edit lands on the tombstoned element, which stays deleted). **Z-order** uses **fractional indices** so a new layer inserts between two others without reindexing the whole array; if concurrent inserts make indices inconsistent, `syncInvalidIndices()` recomputes them.

**Connectors** reference two endpoints via startBinding/endBinding, and each endpoint shape redundantly lists the connector in its `boundElements` (a bidirectional link). On concurrent delete of an endpoint, the system **unbinds** the connector (nulls the binding, removes it from boundElements) leaving a floating arrow rather than a dangling reference. The **infinite canvas** is made tractable by a **spatial index** (quadtree) + **viewport culling** (offscreen elements set to `display:none`, only `getShapeIdsInsideBounds(viewport)` rendered) + structured object **tiles** loaded/discarded on pan/zoom (Miro keeps objects interactive by tiling structured data, not pre-rendered images, and cut canvas memory 3× via typed arrays). **Cursors** ride a **separate throttled channel** (~33ms) and a **20s full-scene resync** provides catch-up. Per-room isolation (tldraw: a Cloudflare Durable Object owning one WebSocket server + SQLite per room) keeps a board's state and fan-out self-contained.

### Deep dives
1. **version + versionNonce LWW and why the nonce matters.** Plain per-element LWW needs a tiebreak when two peers edit concurrently and land on the same `version` number — without one, peers can keep *different* data at the same version and diverge silently. `versionNonce` (a random int regenerated on every change) breaks the tie deterministically (lower wins) so every peer picks the identical winner. Walk the original Excalidraw race: a single z-ordered array meant "peer A adds an element while peer B edits one" could lose either A's element or B's edits on a third peer — fixed by per-element versioning + union-merge + fractional z-index. The Staff+ point: LWW is only convergent with a *total, peer-independent* tiebreak.
2. **Tombstones + connector referential integrity.** Deletes must be tombstones (`isDeleted`), not removals, so the union-merge has something to land concurrent edits on and can't resurrect — the same lesson as OR-Set, applied to shapes. Connectors add referential integrity: a connector binds two shapes bidirectionally; concurrent deletion of an endpoint must not leave a connector pointing at nothing. The design unbinds (floating arrow) rather than corrupting; an alternative is cascade-delete the connector. Either is defensible, but the candidate must *name the dangling-reference hazard* and pick a rule.
3. **Infinite-canvas scaling: spatial index + culling + tiles.** A board can hold tens of thousands of objects across an unbounded plane, but a client only sees a viewport. Use a quadtree (or R-tree) spatial index so "what's in this viewport" is sub-linear; cull offscreen elements (`display:none`) and lazy-load/discard structured tiles on pan/zoom so per-client memory/bandwidth is roughly constant regardless of board size; cap interactive object count and drop to level-of-detail/raster for far-away content. Miro's memory wins (typed arrays over object arrays → 3× less; pooled WebGL buffers to avoid GC spikes) are the concrete engineering. This is what separates "a whiteboard demo" from "a whiteboard that survives a 50k-object board."

## Known failure modes
1. **Resurrected element after concurrent delete + edit.** Without tombstones, union-merge re-adds a deleted element when another peer concurrently edited it. Production answer: `isDeleted` tombstone filtered at render; the edit lands on the tombstone, which stays deleted (and supports undo).
2. **Non-deterministic divergence on concurrent same-element edit.** Two peers bump to the same `version` with different data; without a tiebreak they keep different states. Production answer: `versionNonce` random-int tiebreak (lower wins) — a total, peer-independent order.
3. **Render/sync collapse on a large board.** Naively rendering and syncing all objects melts the client past a few thousand elements. Production answer: spatial-index + viewport culling + tile lazy-load + LOD; throttle cursors on a separate channel; periodic full resync for correctness without streaming everything continuously.

## (Spine note)
`figjam-whiteboard` is the P2P/versionNonce-LWW sibling of `figma` (server-arbitrated LWW). Cursors are `presence-awareness`; the tombstone/union-merge lesson traces to `crdt-primitive` (OR-Set). WebSocket transport is shared with messaging — reference, don't re-derive.

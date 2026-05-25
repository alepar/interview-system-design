---
slug: figma-canvas-client
archetype: frontend
sources:
  figma_multiplayer: figma.com/blog/how-figmas-multiplayer-technology-works/
  figma_wasm: figma.com/blog/webassembly-cut-figmas-load-time-by-3x/
  figma_webgpu: figma.com/blog/figma-rendering-powered-by-webgpu/
  pragmatic_engineer_figma: pragmaticengineer.com Figma interview with Jonathan Kaufman + Noah Finer
---

# Figma canvas client — WebAssembly C++ renderer + WebGL/WebGPU + 60 FPS multiplayer cursors + spatial index + property-level LWW

## Bar anchors
- **Mid-level (L4/E4):** Treats canvas as `<canvas>` with rAF redraw of everything. No spatial index, no WebGL.
- **Senior (L5/E5):** Names WebGL + viewport culling. Discusses multiplayer. May or may not articulate WASM/C++ substrate, bindings cost, time-slicing, or cursor interpolation.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **Highest-substrate-leverage problem in catalog** — entire rendering layer canvas/WebGL (NOT DOM), editor core WebAssembly (compiled from C++), UI shell React/TypeScript. **Per Pragmatic Engineer Figma interview** (Jonathan Kaufman + Noah Finer): "Figma's core editors use a C++ codebase and custom renderer outputting to a `<canvas>` element via WebGL or WebGPU. UI elements outside the canvas use TypeScript and React. A 'bindings layer' enables communication between the C++ codebase and the web UI." Bar covers (a) **render pipeline** — scene-graph diff → render-list → WebGL draw calls with batching; only redraw dirty rect; (b) **input pipeline** — pointer events on canvas, hit-test in WASM against scene-graph spatial index (R-tree), result back to JS for cursor styling; (c) **presence at 60 FPS** per Figma multiplayer post verbatim: cursors coalesced at ~30 Hz on wire, interpolated inside `requestAnimationFrame` on receiver — **"presence (cursors, selection, viewport) rides on the same WebSocket as document deltas but is treated as ephemeral — coalesced at ~30 FPS, fan-out broadcast, never journaled or checkpointed"**; (d) **property-level LWW** — document = `Map<ObjectID, Map<Property, Value>>` with atomicity at property-value boundary.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Vector design canvas: rectangles, paths, text, frames, components
- Pan/zoom with momentum; multi-select with marquee + shift-click
- Layer panel (DOM-side) synced with canvas
- Multi-user editing with 60 FPS cursors
- Undo/redo (per-user, collaborative-safe)
- Comment threads pinned to canvas locations

**Non-functional:**
- Median file ~5K objects; p99 hundreds of thousands
- **Visible cursors capped at 200 per file** (published limit; same as concurrent editor cap)
- Frame budget 16ms; render-list build ≤2ms; WebGL submit ≤4ms; ~10ms slack
- WASM heap up to ~2 GB on Chrome (practical ceiling)
- **WebGPU migration in progress (Sept 2025)** with WebGL fallback
- **WASM cut load time >3× faster** regardless of doc size

### Architecture (A)
**Three layers**: (1) C++ canvas engine via WebAssembly with TypeScript bindings (rendering, scene graph, hit-test); (2) UI shell React/TypeScript (panels, menus, toolbars); (3) bindings layer relays JS ↔ WASM.

### Data model (D)
- **Document**: `Map<ObjectID, Map<Property, Value>>` (tree of objects)
- **Spatial index**: R-tree or quadtree in WASM for hit-testing
- **Cursor presence**: `{userId, x, y, viewport_rect, selection_ids}` ephemeral (never journaled)
- **Property atomicity**: last-writer-wins at property-value boundary — final value always one client's literal, never merge artifact

### Interface (I)
- Canvas event handlers (pointer events on canvas)
- WASM ↔ JS bindings API (integer handles, NOT strings in hot loops)
- WebSocket protocol (document deltas + presence)

### Optimization (O)
**WASM ↔ JS bindings**: every read of canvas state from React crosses bindings layer; batch reads at frame boundaries. Pass integer handles not strings in hot loops.

**Spatial index for hit-testing**: quadtree or R-tree in WASM. Multi-select via marquee uses bbox intersection on R-tree.

**Vector text rendering**: Figma's custom renderer (per Pragmatic Engineer: "custom text rendering for consistency across browsers and operating systems") — side effect: spellcheck/IME require custom integration.

**Multiplayer cursors at 60 FPS from 30 Hz wire**: broadcast `{x, y, viewport_rect, selection_ids}` at 30 Hz; **receiver-side interpolation inside requestAnimationFrame** at 60 Hz; drop on disconnect after timeout. Decouples network rate from visual frame rate. **Hard cap 200 cursors** = same as concurrent editors.

**Parent-cycle prevention**: server rejects parent updates that would cycle; clients temporarily reparent objects to each other and remove from tree on local-cycle detection until server arbitration. Deleted objects' state lives only in deleting client's undo buffer (not server) to avoid orphans.

**Per-user undo principle** (Figma): "if you undo a lot, copy something, and redo back to the present... the document should not change" — undo modifies redo history at time of undo so user's redo doesn't clobber concurrent edits by others.

**Time-slicing of rendering** (Figma's published lesson): sometimes GPU-bound, not always CPU, rarely I/O — prioritize local edits over remote changes on slower devices.

**Persistence boundary**: only document deltas journal to S3; presence is in-memory only.

## Known failure modes
1. **WASM-JS string-marshaling overhead** in hot loop. Production answer: integer handles only; batch reads at frame boundaries.
2. **Cursor teleport** when interpolation buffer underflows on packet drop. Production answer: fall back to instant jump after 200ms timeout.
3. **WebGL context loss** (driver crash, GPU reset). Production answer: handle `webglcontextlost`; rebuild scene from WASM model.
4. **Memory leak from undo-redo history** retaining references to deleted nodes' GPU buffers. Production answer: explicit `gl.deleteBuffer`; tie buffer lifetime to undo-stack retention policy.
5. **Long-task jank from synchronous scene-graph rebuild** on massive paste. Production answer: chunk via `MessageChannel`-based scheduler.

## Notes for the coach
- **Asked-confirmed at Figma** per Techinterview.org Figma interview guide: "Frontend deep-dive: a meaty discussion of browser rendering, reflows, paint, WebGL or canvas rendering, memory profiling, bundle splitting. Figma's rendering pipeline is custom — they expect you to have real opinions about this layer, not just React lifecycle knowledge." **Plausibly at Adobe (web Photoshop), Miro, Linear.**
- **The C++/WASM substrate is the canonical Staff+ unlock.** Mid-senior candidates treat canvas as JS; Staff+ candidates name WebAssembly + bindings layer + spatial index in WASM.
- **The 30 Hz wire → 60 Hz interpolation is the depth probe.** Decouples network rate from visual frame rate; receiver-side rAF interpolation between last two samples.
- **Adversarial probe: "200K objects in document, user pans the viewport — what's the frame budget breakdown?"** Strong answer: viewport culling (only render visible via spatial index); render-list build ≤2ms; WebGL submit ≤4ms; ~10ms slack. WASM/WebGPU paint cost. Web Worker for buffer prep. Weak answer: "we use WebGL" without articulating per-stage budget.

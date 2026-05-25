---
slug: google-docs-client
archetype: frontend
sources:
  prosemirror_collab: prosemirror.net/docs/guide/#collab
  yjs_docs: docs.yjs.dev/
  notion_offline: notion.so engineering blog "How we made Notion available offline"
  figma_multiplayer: figma.com/blog/how-figmas-multiplayer-technology-works/
---

# Google Docs client — collaborative editor: presence cursors as overlay + OT/CRDT client + optimistic typing + offline-first + IME

## Bar anchors
- **Mid-level (L4/E4):** Uses contenteditable; broadcasts every keystroke; no presence cursors.
- **Senior (L5/E5):** Names OT/CRDT + presence cursors. Discusses offline. May or may not address DOM-not-source-of-truth, cursor-as-overlay, IME during remote ops.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Splits server-side OT/CRDT story (covered in conflict-resolution catalog #8) from **client concerns**: (a) **optimistic typing with rollback** — local op applied to local model + DOM before server ACK; on server reject (rare; conflict only after offline) replay canonical transformed stream; (b) **presence cursors** — every collaborator broadcasts `{userId, color, selection: [anchorBlockId, anchorOffset, focusBlockId, focusOffset]}` over WebSocket at ~30 Hz with throttled rebroadcast (Figma's approach); render as **absolutely-positioned `<div>` overlays** measured via `Range.getBoundingClientRect()`, NOT DOM nodes inserted into document tree (would pollute selection + undo); (c) **offline-first via IndexedDB** per Notion pattern verbatim: "TransactionQueue stores transactions safely in IndexedDB or SQLite (depending on platform) until they're persisted by the server or rejected"; (d) **DOM is NOT source of truth** — maintain internal document model; DOM is render output.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Rich-text editing with collaborative presence
- Real-time remote cursor + selection display
- Optimistic local typing with conflict resolution
- Offline editing with reconciliation on reconnect
- IME support (CJK languages)
- Per-user undo (your undo doesn't undo my edits)

**Non-functional:**
- GDoc median 12 KB text; p99 1 MB+
- Concurrent editors per doc: 1-10 typical; Figma caps "visible cursors per file" at 200
- Op rate per active user ~5-10 ops/s while typing
- Presence broadcast ~30 Hz coalesced to local frame rate
- Memory: ~200 KB typical doc; ~5 MB worst case
- **INP ≤50ms on keypress** (typing-latency budget); remote-cursor perceived latency ≤150ms

### Architecture (A)
**State + view separation**: internal document model (ProseMirror-style EditorState) vs EditorView rendering to contenteditable.

**Layers**: Document model / OT/CRDT engine / Selection overlay / IndexedDB persistence / WebSocket presence + ops.

### Data model (D)
- **Document**: tree of blocks (`{type, content, attrs}`); positions as flat integer tokens
- **Operation**: invertible Step (ReplaceStep, AddMarkStep) with timestamp + author
- **Selection (own + remote)**: `{userId, anchorBlockId, anchorOffset, focusBlockId, focusOffset, color}`
- **IndexedDB queue**: pending ops awaiting server ACK

### Interface (I)
- WebSocket protocol: `{type: 'op'|'selection'|'ack', ...}`
- Editor commands: `editor.dispatch(transaction)`, `editor.applyRemoteOp(op)`

### Optimization (O)
**Local op application**: keep `local` model (pending ops) + `confirmed` model (server-acked); render `local`; on remote op arrival, transform against pending and rebase.

**Typing burst grouping** (Google Docs): ops within 50ms from same cursor position coalesced and applied atomically — improves perceived latency + reduces OT transform cost.

**Stable position model**: never address into DOM; use `[blockId, offset]` so selections survive React rerenders.

**Cursor overlay**: computed via `window.getSelection() / Range.getBoundingClientRect()` on cloned anchor. Absolutely-positioned `<div>` above contenteditable. Never inserted into document tree.

**IndexedDB tiering**: queue local op log + baseline snapshot; on reconnect send queued ops in order, receive transformed remote ops. Notion's "forest of offline page trees" reconciliation model.

**IME composition** [compositionstart/compositionupdate/compositionend]: cannot touch DOM or change selection during composition (input cancels). Defer model updates until compositionend; ProseMirror's strategy: let native browser typing complete, re-parse affected region post-hoc into transactions.

**Cursor coalescing**: accept all server cursor updates but commit to React state at most once per `requestAnimationFrame`.

**Per-user undo** under OT/CRDT: maintain per-user undo stack of inverse operations re-transformed against intervening remote ops; user's undo semantically targets only own intent.

## Known failure modes
1. **Optimistic-typing drift** after long offline session — local op log diverges from server canon. Production answer: pre-commit reconciliation reruns full transform sequence; degrades gracefully via "syncing..." UX.
2. **Memory leak from un-removed cursor overlays** when users disconnect. Production answer: tie overlay lifetime to presence-WebSocket message (heartbeat-based), NOT React component lifecycle.
3. **IME composition collides with remote ops** — Asian-language users see characters disappear. Production answer: pause op application while compositionupdate active; queue remote ops; flush at compositionend.
4. **IndexedDB quota exhaustion** on huge offline docs. Production answer: degraded "view-only-offline" mode rather than silently dropping ops.
5. **Cursor flicker** because we re-measure caret rect every animation frame on a paint-heavy page. Production answer: only re-measure on document change events; coalesce in rAF.

## Notes for the coach
- **Asked-confirmed at Google (Docs)**, Microsoft (Word Online), Notion, Quip, Atlassian. GreatFrontEnd "Collaborative editors (Google Docs)" canonical.
- **The cursor-as-overlay (not in document tree) is the canonical Staff+ unlock.** Mid-senior candidates insert remote-cursor markers into the document; Staff+ candidates name overlays to avoid polluting selection + undo history.
- **The IME-during-remote-op pause is the depth probe.** Mid-senior candidates ignore IME; Staff+ candidates name "pause op application while compositionupdate active" explicitly.
- **Adversarial probe: "user is typing in Chinese with IME, simultaneous edit from collaborator inserts text 2 chars before cursor. What happens?"** Strong answer: composition must complete before applying remote edit; defer remote op via mark-as-pending; reapply after compositionend; cursor position rebased via position map. Weak answer: "we handle it" without walking through the queue + flush sequence.

---
slug: rich-text-editor
archetype: frontend
sources:
  greatfrontend_editor: greatfrontend.com/questions/system-design/rich-text-editor
  prosemirror_guide: prosemirror.net/docs/guide/
  lexical_docs: lexical.dev/docs/intro
  mdn_contenteditable: developer.mozilla.org/en-US/docs/Web/HTML/Global_attributes/contenteditable
  dompurify: github.com/cure53/DOMPurify
---

# Rich text editor — contenteditable + internal document model + Selection/Range API + paste sanitization + IME

## Bar anchors
- **Mid-level (L4/E4):** Uses `contenteditable="true"` + `document.execCommand`. No internal document model. No paste sanitization.
- **Senior (L5/E5):** Names ProseMirror/Lexical/Slate/Quill. Discusses paste handling. May or may not address Selection/Range API serialization, IME composition, or contenteditable-vs-canvas trade-off.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Names GreatFrontEnd classifies **Hard / 40-min** with four reference implementations: Lexical, Tiptap, Slate, Quill. Articulates **DOM is NOT source of truth** — maintain internal document model (ProseMirror tree); DOM is render output. Cites **ProseMirror state/view separation**: EditorState (immutable doc + selection + plugin state, DOM-agnostic) vs EditorView (renders state, translates browser events into transactions). **Invertible Steps** (ReplaceStep, AddMarkStep) → free undo/redo + rebasable steps enable collaborative editing without custom OT code. Names the **canvas-vs-contenteditable trade-off**: Google Docs since 2021 renders to canvas for perf parity; declare contenteditable but acknowledge canvas. Cites **Lexical core: 22kb min+gzip** (lexical.dev verbatim: "you only ever pay the cost for what you need"); powers FB/IG/Messenger/WhatsApp/Workplace. **Paste sanitization** via DOMPurify with explicit `ALLOWED_TAGS` (e.g., `['b','i','em','strong','a','p']`) + `ALLOWED_ATTR`. **IME (CJK)**: listen for compositionstart/compositionupdate/compositionend; do NOT mutate DOM during composition or input cancels.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Inline formatting: bold, italic, underline, strikethrough, code, link
- Block formatting: headings (H1-H3), bullet/numbered lists, blockquote, code block
- Paste from Word / Google Docs / Markdown
- Image insertion (drag-drop, paste, picker)
- Undo/redo with collaborative-safe semantics

**Non-functional:**
- Notion median 60 blocks; p99 5,000+
- Memory ~2 KB/block JS + React fiber; budget 50 MB for 5,000-block doc
- Keypress→paint ≤16ms (one frame); INP ≤100ms
- Lexical core: 22kb min+gzip; full @lexical ~43.9 KB gzipped
- Bundle size for editor core ≤120 KB gzip

### Architecture (A)
**State + View separation** (ProseMirror model): EditorState (immutable doc tree + selection + plugin state) vs EditorView (renders state to contenteditable DOM, translates DOM events into transactions).

**Document is tree** of immutable Node/Fragment; positions are flat integer tokens.

### Data model (D)
- **Document**: tree of nodes (`{type, attrs, content, marks}`)
- **Selection**: `{anchor: position, head: position}`
- **Transaction**: chain of invertible Steps + selection change

### Interface (I)
**Editor API**: `editor.dispatch(transaction)`, `editor.state`, `editor.view`, `editor.execCommand(name, params)`.

**Plugin system**: props (event handlers, decorations, node views), state (immutable per-plugin slots), transaction metadata.

### Optimization (O)
**Block-based vs flat document**: block-based (Notion, Lexical) makes virtualization trivial + collapse-hidden-blocks; flat (Medium) makes selection-across-elements simpler.

**Paste pipeline**: `paste` event → `clipboardData.getData('text/html')` → DOMPurify (strict allowlist) → Word-specific normalizer mapping `<o:p>`, `mso-list` → semantic HTML → AST conversion → block insertion at selection with focus restoration.

**Selection/Range API**: `anchorNode/focusNode + offsets` describe selection; `setBaseAndExtent()`, `addRange()`, `collapse()` write it. **Cross-browser caveat**: Safari/Chrome focus editing host on programmatic selection writes; Firefox does not. **Multi-range selections only supported in Gecko** — Chrome/Safari treat selection as single range.

**IME composition**: on `compositionstart` suspend the op log; on `compositionend` commit composed text as single op so undo works. ProseMirror's strategy: let native browser typing complete, re-parse affected region post-hoc into transactions.

**Undo/redo**: maintain own operation log (browser's native undo unusable once you intercept input events); bind Cmd+Z to it; per-user undo stack for collaborative editing.

**Input events**: listen to `beforeinput` (gives `inputType` like `insertText`, `deleteContentBackward`, `historyUndo`), not deprecated `keypress`.

**contenteditable values**: `true` (rich; retains paste formatting), `false`, `plaintext-only` (strips paste formatting — cheapest XSS hardening but loses rich content).

## Known failure modes
1. **XSS via paste** — failing to sanitize `<img onerror>`, `<script>`, `javascript:` URLs. Production answer: DOMPurify with explicit `ALLOWED_TAGS` + `ALLOWED_ATTR`; CSP `script-src 'nonce-...'` as defense-in-depth.
2. **Lost selection on re-render** — React rerenders, browser collapses Selection to start. Production answer: serialize selection as stable `[blockId, offset]` (not raw DOM nodes); reapply after render.
3. **Phantom newlines** (Firefox vs Chrome contenteditable). Production answer: normalize input via own internal model; never rely on contenteditable default behavior.
4. **Undo-stack drift** when external mutation (collaborator's edit) lands while user has 5 local ops queued. Production answer: per-user undo stack; remote ops update redo history at time of undo (Figma's principle).
5. **iOS Safari autocorrect** inserts via non-cancelable input event. Production answer: `beforeinput.preventDefault()` partially ignored; model must reconcile after-the-fact via `MutationObserver`.

## Notes for the coach
- **Asked-confirmed** at Meta (Draft.js → Lexical), Notion (interview reports), Google (Docs team), Atlassian (Confluence editor). GreatFrontEnd Hard canonical.
- **The DOM-is-not-source-of-truth framing is the canonical Staff+ unlock.** Mid-senior candidates treat contenteditable as the data layer; Staff+ candidates name internal model + DOM-as-render.
- **The IME composition handling is the depth probe.** Mid-senior candidates ignore CJK input; Staff+ candidates name compositionstart/compositionupdate/compositionend explicitly + defer ops until compositionend.
- **Adversarial probe: "your editor must support both Chinese IME input AND collaborative editing — what's the worst case?"** Strong answer: remote op arrives during local composition → cannot apply until compositionend; queue remote ops in pending buffer; flush at compositionend; if composition takes too long, surface "syncing..." indicator. Weak answer: "we handle IME" without addressing the remote-op-during-composition race.

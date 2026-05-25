---
slug: copilot-inline-completions
archetype: frontend
sources:
  vscode_inline_completions_api: github.com/microsoft/monaco-editor/issues/4491
  vscode_inline_completions_finalization: github.com/microsoft/vscode-discussions (Inline Completions API finalized)
  cursor_tab_rl: cursor.com/blog/tab-rl
  fireworks_cursor: fireworks.ai/blog/cursor
  github_copilot_completions: docs.github.com/en/copilot/concepts/completions/code-suggestions
  github_copilot_acceptance_30pct: GitHub blog research finding "developers accepted around 30% of GitHub Copilot's suggestions"
---

# Copilot inline completions — Monaco InlineCompletionItemProvider + ghost-text decoration + view-zone + debounce + cancellation + FIM prompt + Cursor MoE

## Bar anchors
- **Mid-level (L4/E4):** Fetches completion on every keystroke; renders as suggestion box (not ghost text). No cancellation.
- **Senior (L5/E5):** Names debounce + AbortController + Monaco. May or may not articulate InlineCompletionItemProvider with decoration + view-zone, FIM prompt, or local Prompt Library.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **Tier-1 AI-lab interview problem.** Bar covers: (a) **InlineCompletionItemProvider API** per Microsoft vscode-discussions verbatim: "We have finalized the Inline Completions API. This allows extensions to provide inline completions that are decoupled from the suggestion widget. An inline completion is rendered as if it was already accepted, but with a grey color. Users can cycle through suggestions and accept them with the Tab key. An example extension that uses Inline Completions is GitHub Copilot." Method signature `provideInlineCompletionItems(document, position, context, token: CancellationToken)` reveals cancellation primitive built into platform; (b) **debouncing**: ~200-500ms after user stops typing — but exact ms NOT officially published by GitHub/Microsoft (Plate.js documents 500ms; Continue.dev default 300ms); justify chosen number against measured typing speeds rather than citing "GitHub Copilot uses 500ms"; (c) **cancellation on keystroke** via CancellationToken; (d) **multi-line ghost-text rendering**: overlay span absolutely positioned at caret; first line is content-widget decoration overlaid inline; additional lines as view-line elements inside a view zone; (e) **accept/reject/cycle keyboard**: Tab = accept full, Cmd+→ = accept next word, Esc = reject, Alt+]/[ = cycle alternatives; (f) **Fill-in-the-Middle (FIM) prompt format**: prefix (text before cursor) + suffix (text after cursor) → model generates middle; naive chat-model use causes cursor-misaligned insertions; (g) **local Prompt Library + Contextual Filter Model**: IDE extension assembles prompt locally before network call; Contextual Filter Model safety screen before LLM.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Inline ghost-text suggestion after typing pause
- Multi-line completions
- Tab to accept full; Cmd+→ word-by-word partial accept
- Esc dismiss; Alt+]/[ cycle alternatives
- Cancel in-flight on keystroke
- Privacy: don't send `.gitignore`'d files or secrets-like patterns

**Non-functional:**
- Per Cursor "Tab RL" verbatim: **"400 million requests per day"**; "21% fewer suggestions with a 28% higher acceptance rate"
- Per Fireworks AI Cursor case study: "speeds >1000 tokens/s" via speculative decoding + speculative edits
- Per GitHub research: **30% acceptance rate**
- Latency: TTFT ≤200ms; full short completion ≤500ms
- Debounce 200-500ms (production-justified, not officially published Copilot number)
- Per-keystroke at typing speed (~6 keystrokes/sec) cancel rate ~80%

### Architecture (A)
**Layers**: IDE extension (Monaco / VS Code) → local Prompt Library (context assembly) → HTTPS to backend → Contextual Filter Model (safety) → LLM with FIM fine-tuning → SSE stream back → ghost-text decoration.

### Data model (D)
- **Completion request**: `{prefix, suffix, file_path, language, neighboring_open_tabs}`
- **Completion response**: streaming tokens forming insertText + range
- **Ghost-text state**: `{visible: bool, insertText: string, alternatives: string[], activeIndex: number}`

### Interface (I)
- Monaco `monaco.languages.registerInlineCompletionsProvider(language, { provideInlineCompletionItems })`
- VS Code native: `vscode.languages.registerInlineCompletionItemProvider`
- `CancellationToken` for per-keystroke abort

### Optimization (O)
**Monaco ghost-text rendering** per Microsoft Monaco issue verbatim: "Monaco's inline completion provider renders an inline completion suggestion using a combination of decoration and view zone which has view lines, where the first line is typically rendered as a decoration and any additional lines in the suggestion introduced by '\n' is rendered as a view line inside a view zone."

**Debounce + cancel**: 200-500ms after user stops typing; each keystroke during in-flight cancels prior request via AbortController on fetch (or CancellationToken in VS Code). Per Copilot docs: "Ghost text appears after a short pause — typically under 200ms"; per Continue.dev defaults: 300ms. **Justify chosen debounce against measured typing speeds in interview, don't cite "Copilot uses 500ms"** since it's not officially published.

**Fill-in-the-Middle (FIM) prompt format**: model receives prefix (text before cursor) + suffix (text after cursor) and generates the middle. Naive chat-model use causes: cursor-misaligned insertions; duplication of code before cursor (prefix); overwriting code after cursor (suffix). Copilot fine-tunes specifically to prevent.

**Local Prompt Library** (Copilot architecture): IDE extension contains a local ML system that gathers context from your editor and assembles it into a structured prompt before anything leaves your machine — surrounding code window, file path, language, neighboring open tabs.

**Contextual Filter Model**: runs prompt through safety screen which screens for content safety BEFORE routing to selected LLM.

**Cursor architecture difference**: Sparse Mixture-of-Experts (MoE) model predicting next edit (not just next token continuation); specialized "fast apply" model for rapidly applying large code changes. Per Fireworks AI: "Fireworks deployed a custom trained 'llama-70b-ft-spec' model on the inference engine using speculative decoding, enabling the model to generate speeds >1000 tokens/s. Cursor built a variant of speculative decoding called 'speculative edits', an algorithm that uses much longer speculations to make code edits substantially faster."

**Acceptance telemetry** per GitHub: **30% acceptance rate** drives RL training loop. Distinguish "shown ≥1s" from instantly-overwritten suggestions.

**Privacy / context boundary**: block sending of files matching `.gitignore` or content with secrets-like patterns.

## Known failure modes
1. **Race condition** where slow server response from previous keystroke commits stale ghost-text. Production answer: strict sequence-number / AbortController gating; only commit if request seq === current.
2. **Ghost-text mis-positioning** after remote LSP edit shifts caret. Production answer: re-anchor or abort.
3. **IME composition triggers spurious completions**. Production answer: gate by compositionend; suspend during compositionupdate.
4. **Tab-key collision** with auto-indent or other completions. Production answer: provider ordering; InlineCompletionItemProvider decoupled from standard suggestion widget specifically for this.
5. **Word-wrap conflict** in multi-line ghost text (open Monaco bug). Production answer: render first line as decoration only; subsequent lines via view zone with explicit word-wrap handling.
6. **Memory leak from un-cancelled in-flight requests** in long sessions. Production answer: explicit AbortController per request; cleanup on unmount.
7. **Acceptance-rate skew** when user keeps typing past suggestion (silent reject). Production answer: distinguish "still-shown" vs "overwritten" at telemetry time.

## Notes for the coach
- **Asked-confirmed at GitHub (Copilot), Cursor, Continue.dev, Cody (Sourcegraph), Codeium.** **Plausibly-asked at Anthropic (Claude Code), OpenAI (Codex), Replit.** **TIER-1 for user's AI-lab interview targets.**
- **Shared substrate with `chatgpt-claude-chat-ui`** (cancellation, streaming, sequence-number guard). Cross-coverage with `autocomplete-typeahead` (same async-hazards taxonomy applied to richer streamed output).
- **The InlineCompletionItemProvider decoration + view-zone is the canonical Staff+ unlock.** Mid-senior candidates describe as "ghost text"; Staff+ candidates name the specific Monaco API rendering primitives.
- **The FIM prompt format is the depth probe.** Mid-senior candidates assume chat model; Staff+ candidates name FIM (prefix + suffix → middle) as the specifically-tuned format that prevents cursor-misaligned insertions.
- **Adversarial probe: "user types 6 chars per second — what's your debounce + cancel ratio?"** Strong answer: 300-500ms debounce → on average ~80% of keystrokes get cancelled mid-flight; only ~20% reach inference; per-keystroke AbortController fires; commit only on sequence match. Justify debounce against typing speed not "Copilot uses 500ms." Weak answer: cite a specific Copilot number without acknowledging it's not officially published.

---
slug: chatgpt-claude-chat-ui
archetype: frontend
sources:
  anthropic_streaming: docs.anthropic.com (streaming Messages with SSE)
  openai_streaming: platform.openai.com/docs/api-reference/streaming (Chat Completions stream=true)
  vercel_streamdown: github.com/vercel/streamdown
  incremark: medium.com/@kingshuai01/weekend-project-incremark-an-incremental-markdown-parser-for-ai-streaming-28c9fa95962f
  langchain_branching_chat: LangChain docs / Ably engineering on conversation tree (msgId, parentId, forkOf)
  vercel_ai_sdk: ai-sdk.dev (useChat, stop, regenerate)
  openai_devday_2025: techcrunch.com / Sam Altman OpenAI Dev Day Oct 6 2025
---

# ChatGPT/Claude chat UI — SSE streaming + ref-buffer rAF flush + streaming-safe markdown + conversation tree + virtualization + multipart attachments + abort with /cancel endpoint

## Bar anchors
- **Mid-level (L4/E4):** `EventSource` + setState per token. React reconciles every token; visible jank. Conversation as flat list.
- **Senior (L5/E5):** Names SSE + AbortController + markdown rendering. May or may not articulate ref-buffer + rAF flush, streaming-safe markdown, conversation tree, or stop-generation /cancel endpoint.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **THE highest-priority AI-lab interview problem.** Bar covers every layer of streaming token UX. **Architectural twin** of `stock-trading-dashboard` AND `figma-canvas-client` (RAF-batched streaming UI). Articulates: (a) **SSE response headers** per Anthropic/OpenAI streaming docs verbatim; **nginx must set proxy_buffering off, X-Accel-Buffering no, gzip disabled** on stream endpoint; (b) **Browser EventSource limitations**: GET-only + no custom headers — production chat clients use `fetch() + ReadableStream + manual SSE framing parser` with `AbortController.abort()` to tear down on Stop Generation; (c) **render decoupling principle**: naive setState-per-token causes 50-100+ React re-renders per second + visible jank; solution buffers tokens in useRef + flushes via requestAnimationFrame (one render per frame); **network layer must NEVER directly drive React renders**; (d) **TTFT (time-to-first-token)** typically 287-400ms; (e) **streaming-safe markdown** per Vercel Streamdown verbatim: "designed to handle unterminated chunks, interactive code blocks, math, and other cases that are unreliable with existing Markdown packages"; (f) **conversation as tree** per Ably model verbatim: "Every message has three headers: a `msgId`, a `parentId`, and an optional `forkOf`. Together those three fields describe a directed acyclic graph rooted at the start of the conversation"; (g) **stop-generation requires BOTH client AbortController.abort() AND separate POST to /cancel endpoint** — closing socket alone may not halt GPU work upstream.

## Canonical decomposition

### Requirements (R)
**Functional:**
- SSE-streamed token rendering with markdown + code blocks
- Conversation branching tree (edit message + regenerate creates sibling)
- File/image attachments via multipart upload
- Conversation history virtualization (long sessions)
- Edit-and-regenerate / share-conversation
- Tool-call rendering (collapsible thinking blocks)
- Stop-generation mid-stream

**Non-functional:**
- Per Sam Altman OpenAI Dev Day (TechCrunch Oct 6 2025): **"More than 800 million people use ChatGPT every week, and we process over 6 billion tokens per minute on the API."**
- Per-message text 200-2000 tokens output
- Streaming rate 30-100 tok/s Claude Sonnet, faster Haiku
- Render budget 16ms/frame; token-batch flush ≤4ms
- Conversation length median 10 turns, p99 200+
- INP ≤200ms on send
- TTFT typically 287-400ms

### Architecture (A)
**Layers**: SSE transport (fetch + ReadableStream) → token ref-buffer ring → rAF flush to React state → streaming-safe markdown parser (Streamdown/Incremark) → message virtualization (TanStack Virtual measureElement) → conversation tree state.

### Data model (D)
- **Message** (tree node, per Ably verbatim): `{msgId, parentId, forkOf?, role, content, createdAt}`. Tree describes a DAG; `activePath: [messageIds]` = currently-rendered conversation.
- **Token buffer**: useRef array; flushed via rAF
- **Streaming state**: `{streaming: boolean, partialContent: string, abortController}`

### Interface (I)
- POST `/chat/completions` with `stream=true` → SSE response stream
- POST `/cancel` with `streamId` → server-side stop
- `useChat` hook (Vercel AI SDK) exposing `messages, sendMessage, stop(), regenerate()`

### Optimization (O)
**SSE protocol** per Anthropic docs verbatim: "When creating a Message, you can set 'stream': true to incrementally stream the response using server-sent events (SSE)." Per OpenAI verbatim: "To stream completions, set stream=True when calling the Chat Completions or legacy Completions endpoints. This returns an object that streams back the response as data-only server-sent events." Headers: `Content-Type: text/event-stream` + `Cache-Control: no-cache` + `Connection: keep-alive`; events `data: <JSON>\n\n` framed; **nginx must set `proxy_buffering off` + `X-Accel-Buffering no`, gzip disabled** on stream endpoint.

**Browser EventSource insufficient**: GET-only + no custom Authorization headers. Production uses `fetch() + ReadableStream + manual SSE framing parser`: read from `response.body.getReader()`; decode `Uint8Array` through `TextDecoderStream`; buffer-split on `\n\n`; parse `data:` lines as JSON deltas. Heartbeats: `event: ping` every 15s to detect dead connections.

**Ref-buffer + rAF flush architectural principle** (verbatim): "your network layer should never directly drive React renders." Naive setState-per-token → 50-100+ re-renders/sec → jank. Buffer tokens in useRef; rAF loop drains buffer + setState once per frame (~60 renders/s). Refs avoid re-renders entirely; only the rAF flush commits to React state. Alternative: 30-100ms setInterval batching (commonly 50ms = ~20 updates/s).

**Backpressure**: server-side `res.write()` returns false when TCP send buffer full → 'drain' event; client-side buffer SSE chunks + flush on rAF to prevent unbounded memory growth during fast streams.

**Streaming tool-call arguments**: JSON fragments arrive across many SSE chunks; cannot `JSON.parse()` single chunk; accumulate fragments + attempt parse after each addition (or use streaming JSON parser like partial-json).

**Streaming-safe markdown** (Streamdown / Incremark): standard react-markdown UNSAFE because half-arrived ` ``` ` makes subsequent text render as code then unrender on close. **Incremark verbatim**: lock completed blocks so they won't be re-parsed; 17-23× speedup at 10KB documents; 37-46× at 20KB. **Block boundary detection**: code blocks close on matching ``` / ~~~; lists close on indentation change; blockquotes close when > prefix discontinues.

**Syntax highlighter trade-off**: **Shiki** uses TextMate grammars (server-grade accuracy, identical to VS Code) but **~10× slower than Prism** (~50ms vs ~5ms per 10-block article); Shiki emits inline style attributes (theme baked in); Prism/highlight.js emit semantic CSS classes — defer Shiki highlight to post-stream-complete.

**Conversation as tree** per LangChain + Ably model: `{msgId, parentId, forkOf?}` describes DAG. Editing a user message creates a sibling under same parent (branch). UI exposes 1/N arrow navigation between branches. Model receives only the active branch path as context.

**Conversation history virtualization** via TanStack Virtual `measureElement` with `getBoundingClientRect().height` for variable heights; off-screen messages unmount their markdown trees.

**Tool-call rendering** (Vercel AI SDK `message.parts`): text/tool-call/tool-result/reasoning parts; collapsible 'thinking' blocks with duration timer + auto-collapse on stream finish + per-tool status indicators.

**Multipart S3 attachments**: 5 MB chunks; create-multipart-upload → upload-part (parallel) → complete-multipart-upload; **list-parts enables true resumability** across browser refresh.

**Stop-generation requires BOTH** client `AbortController.abort()` to tear down SSE fetch AND server-side mechanism (separate POST to `/cancel` endpoint or signal piped to inference worker) to actually halt token generation upstream — closing socket alone may not stop GPU work.

## Known failure modes
1. **50-100 React re-renders/second** on naive setState-per-token. Production answer: ref buffer + rAF flush.
2. **Half-arrived code-fence markdown re-renders entire suffix**. Production answer: Streamdown/Incremark with stable/unstable block detection.
3. **AbortController alone doesn't stop GPU inference**. Production answer: separate POST /cancel endpoint; server signals inference worker.
4. **Browser refresh loses 80% of large attachment upload**. Production answer: multipart S3 with list-parts resumability.
5. **SSE auto-reconnects from beginning**, doubling message. Production answer: send resumption cursor on resume OR abort + retry with replay.
6. **Branching state corruption** when user edits old message. Production answer: clone subtree, do NOT mutate; new sibling under same parentId.
7. **XSS via model output** — model can output `<script>`. Production answer: render through DOMPurify with allowlist permitting `<code>`, `<pre>`, `<a href>`.
8. **Memory leak in long conversations** from un-evicted message DOM. Production answer: virtualize via TanStack Virtual measureElement.

## Notes for the coach
- **Asked-confirmed at Anthropic, OpenAI, Google DeepMind, Cursor, Continue, Aider.** Direct product observation of Claude.ai + ChatGPT. **TIER-1 for user's AI-lab interview targets.**
- **Architectural twin** to `stock-trading-dashboard` AND `figma-canvas-client` (RAF-batched streaming UI). Drill one, prep all three.
- **The ref-buffer + rAF flush architectural principle is the canonical Staff+ unlock.** "Network layer should never directly drive React renders" is the verbatim framing.
- **The conversation-as-tree (vs list) framing is the depth probe.** Edit-and-regenerate creates a sibling under same parent; model only sees active path; users navigate branches via 1/N arrows.
- **The streaming-safe markdown problem is unique to AI products.** Half-arrived ``` flips formatting; Streamdown/Incremark with stable-block locking is the production answer.
- **Adversarial probe: "user clicks Stop after the model has been streaming for 5 seconds — what happens?"** Strong answer: client `AbortController.abort()` tears down SSE fetch (frees client memory + connection); separate POST /cancel endpoint signals server to halt GPU work upstream; without /cancel the model keeps generating but no one reads the output. Weak answer: "we abort" without addressing server-side GPU work.

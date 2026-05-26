# Front-End System Design

Source: design spec §9 + `staff-engineer-study-guide.md` (Category 12).

## RADIO framework

**Definition.** RADIO is a five-phase structure for front-end system design answers: Requirements, Architecture, Data model, Interface definitions, and Optimization — providing the same scaffolding role as the generic HLD/deep-dive framework for backend SD.

**Canonical use.** A candidate designing a collaborative rich-text editor opens with RADIO to align the scope (R), sketch the component graph (A), define the document data model (D), specify API/event contracts (I), and enumerate performance trade-offs (O).

**Production systems.** Canonical framework published by GreatFrontEnd; adopted by candidates in Meta, Google, Airbnb, and Atlassian front-end SD rounds.

**Alternatives.** Backend-style HLD structure (skips client-side concerns like state management and render performance); freeform whiteboard (works for experts; lacks visible structure judges look for at senior+ levels).

## Virtualized lists

**Definition.** Virtualized lists render only the DOM nodes visible within the current viewport plus a small buffer, recycling node instances as the user scrolls to keep memory and paint cost constant regardless of list length.

**Canonical use.** A social-media feed with thousands of posts uses list virtualization so the browser maintains a fixed number of live DOM nodes rather than holding the entire feed in memory.

**Production systems.** React Window, React Virtualized (open-source; used in production at scale at Facebook and Twitter feeds).

**Alternatives.** Pagination / infinite scroll with DOM accumulation (simpler; DOM grows unbounded on long sessions); server-side rendering with cursor-based pagination (reduces client DOM; requires page reload or partial hydration).

## Ref-buffer + requestAnimationFrame render decoupling

**Definition.** Incoming updates (SSE tokens, WebSocket ticks, IPC events) are appended to a `useRef`-held buffer rather than calling `setState` directly; a `requestAnimationFrame` loop drains the buffer to React state once per frame (~60Hz), so the network arrival rate is fully decoupled from the render rate.

**Canonical use.** An LLM chat UI receiving 50-100 SSE tokens/sec buffers them in `tokenBufferRef.current` and flushes once per `rAF` tick, turning 100 re-renders/sec into ~60 — preventing input-box jank and dropped frames during streaming.

**Production systems.** ChatGPT / Claude streaming chat UIs, GitHub Copilot inline completions, Bloomberg-style trading dashboards with thousands of ticks/sec.

**Alternatives.** Fixed-interval `setInterval` batching at 30-100ms (simpler; not aligned with the browser's paint cycle, can still drop frames or waste work); direct `setState` per event (works under ~10 events/sec; collapses under streaming load).

## Canvas / WebGL vs DOM renderer choice

**Definition.** Once visible item count exceeds roughly 5-10k DOM nodes, React reconciliation and browser layout become the bottleneck; switching to a Canvas 2D or WebGL/WebGPU renderer treats the viewport as a single `<canvas>` element and paints items imperatively, trading off accessibility and per-element event handlers for raw throughput.

**Canonical use.** A design canvas with 50k shapes or a map with 100k pins renders to WebGL, maintains a parallel ARIA tree for accessibility, and implements hit-testing (quadtree / spatial index) to translate pointer events back to logical items.

**Production systems.** Figma (WebGL renderer driven by WASM-compiled C++), Google Maps (Canvas raster tiles + WebGL vector layer), Airbnb search map (Mapbox GL / WebGL), Bloomberg trading dashboards.

**Alternatives.** List/grid virtualization with `react-window` (keeps DOM + accessibility for free; caps out around 10k items); SVG rendering (declarative; better than DOM for medium scale; still per-node layout cost).

## Optimistic UI with rollback

**Definition.** Optimistic UI applies a user action to local state immediately and then reconciles with the server response, reverting the local change if the server rejects it.

**Canonical use.** A user taps a "like" button on a post; the UI increments the count and fills the icon instantly while the network request is in flight, rolling back if the request times out or returns an error.

**Production systems.** Twitter/X (like button), Facebook (reactions); both documented in Meta's front-end engineering blog posts on optimistic mutations.

**Alternatives.** Blocking UI (disable the control until the server responds; eliminates rollback complexity; feels sluggish); eventual-consistency sync without rollback (accepts divergence; unsuitable for user-visible counts).

## IndexedDB / local-storage strategies

**Definition.** IndexedDB is a transactional browser database for structured, queryable, large-scale client-side storage, while localStorage provides a synchronous key-value store limited to a few megabytes of string data.

**Canonical use.** An email client stores the full message body and attachment metadata in IndexedDB (supporting queries by date, sender, thread) and keeps only lightweight session flags (e.g., `theme`, `last_open_folder`) in localStorage.

**Production systems.** Gmail (IndexedDB for offline message cache), Figma (IndexedDB for local document state).

**Alternatives.** Cache Storage API via service worker (bytes, not structured records; suited for resource caching, not queryable data); in-memory store only (lost on page reload; no offline support).

## Service workers for offline

**Definition.** A service worker is a browser-controlled background script that intercepts network requests and applies a cache strategy — cache-first, network-first, or stale-while-revalidate — to serve content when the device is offline or the network is slow.

**Canonical use.** A progressive web app uses a stale-while-revalidate strategy for its shell assets (HTML, JS, CSS) so the app loads instantly from cache and then silently refreshes in the background.

**Production systems.** Workbox (Google open-source library; used in Google Search PWA, Twitter Lite), Spotify Web Player (offline track caching via service worker).

**Alternatives.** App Cache (deprecated; removed from most browsers); server-side rendering with no client cache (no offline capability; simpler deployment).

## Cross-origin iframe sandbox + postMessage protocol

**Definition.** Sensitive UI (card input, auth widget, captcha) is loaded inside a sandboxed cross-origin iframe served from the vendor's domain; the parent page and child iframe communicate via `window.postMessage` with strict `origin` checks and a versioned message-shape schema, so the parent never reads the sensitive fields directly and stays outside the vendor's compliance scope.

**Canonical use.** Stripe Elements loads the card-number input in a `js.stripe.com` iframe; the merchant page only exchanges tokenized handles via `postMessage`, keeping the merchant out of PCI-DSS SAQ-D scope and reducing them to SAQ-A.

**Production systems.** Stripe Elements (PCI scope reduction), Plaid Link (bank credentials), Auth0 Universal Login (embedded mode), Google reCAPTCHA.

**Alternatives.** Full-page redirect to the vendor's hosted page (eliminates iframe complexity; breaks inline checkout UX and conversion); direct fields on the merchant page (simplest integration; pulls the merchant fully into PCI-DSS SAQ-D scope — operationally expensive).

## WebSocket connection management

**Definition.** WebSocket connection management encompasses reconnect-with-exponential-backoff, heartbeat ping/pong frames, and sequence-numbered messages to detect and recover from missed events after a dropped connection.

**Canonical use.** A real-time collaborative document editor maintains a WebSocket to the server, sends client-generated sequence numbers on every operation, and on reconnect requests any missed operations since the last acknowledged sequence number.

**Production systems.** Slack (WebSocket multiplexing + sequence numbering for message delivery guarantees), Figma multiplayer (WebSocket with reconnect and full-state resync).

**Alternatives.** Server-Sent Events (SSE) (unidirectional; simpler for read-heavy push; no backpressure from client); long polling (HTTP-native; higher overhead; natural reconnect on each poll).

## SSE / fetch + ReadableStream streaming

**Definition.** For one-way server-to-client streaming where bidirectional WebSocket framing is overkill, the browser exposes Server-Sent Events (`EventSource` over `text/event-stream`) for line-delimited text and `fetch()` + `response.body.getReader()` over a `ReadableStream` for binary or custom-encoded streams — both ride normal HTTP/2, multiplex on a single connection, and auto-reconnect (SSE) or expose a cancellation handle (fetch).

**Canonical use.** An LLM chat backend pushes token deltas as `data: {"delta":"..."}\n\n` SSE frames; the client `EventSource` feeds each delta into the ref-buffer + rAF render loop above, yielding sub-100ms first-token latency without WebSocket session management.

**Production systems.** ChatGPT / Claude streaming responses (SSE), GitHub Copilot completions (SSE), Datadog Live Tail (fetch + ReadableStream for log frames).

**Alternatives.** WebSocket (bidirectional; more session/heartbeat complexity; required only if the client also streams to the server); long polling (HTTP-native; one round-trip per chunk; higher overhead); GraphQL subscriptions (typed schema; rides WebSocket — inherits its complexity).

## Media Source Extensions / Encrypted Media Extensions / adaptive bitrate

**Definition.** Media Source Extensions (MSE) let JavaScript append media segments into a `SourceBuffer` attached to a `<video>` element, making in-browser HLS/DASH players possible; Encrypted Media Extensions (EME) plug a Content Decryption Module (Widevine, FairPlay, PlayReady) into that pipeline for DRM; adaptive bitrate (ABR) is the client-side control loop that measures throughput and buffer level to pick the next segment's bitrate.

**Canonical use.** A web video player fetches a DASH manifest, downloads the next 4-second segment at the bitrate selected by an ABR algorithm (e.g., BOLA or throughput-based), passes the bytes through EME for decryption, and appends to the MSE `SourceBuffer` while monitoring buffer health to upshift or downshift.

**Production systems.** Netflix, YouTube, Twitch (MSE + EME + ABR); Spotify Web Player (HLS audio via MSE); video-player problem reference design.

**Alternatives.** Native `<video src="*.m3u8">` with HLS.js polyfill (covers HLS playback without writing MSE/ABR app code; less control over the buffer / ABR policy); progressive MP4 download (simplest; no bitrate adaptation; no DRM).

## Code-splitting and lazy loading

**Definition.** Code-splitting divides a JavaScript bundle into chunks loaded on demand, and lazy loading defers fetching those chunks until the user navigates to or near the relevant route or component, reducing initial parse and execution time.

**Canonical use.** A single-page application splits each route into its own chunk so users on the landing page never download code for the settings panel, the admin dashboard, or other routes they may never visit.

**Production systems.** Webpack (dynamic `import()` for route-based splitting), Vite (native ESM with rollup chunking; preload hints via `<link rel="modulepreload">`).

**Alternatives.** Single-bundle delivery (zero split-point complexity; poor initial load for large apps); server-side rendering with selective hydration (shifts parse cost to the server; reduces client JS at the cost of server capacity).

## Observer / store patterns

**Definition.** The observer/store pattern centralizes mutable application state in a single store object and notifies subscribed components on each state change, replacing ad-hoc prop-drilling or distributed local state.

**Canonical use.** A shopping cart component subscribes to a centralized cart store so any page (header count badge, checkout drawer, product page add-to-cart button) reflects the same quantity without explicit prop chains.

**Production systems.** Redux (Meta; Facebook Messenger web client), Zustand (lightweight; used widely in React ecosystem as a simpler Redux alternative).

**Alternatives.** React Context + useReducer (no external dependency; re-renders all consumers on each state change unless memoized carefully); prop-drilling (acceptable for shallow component trees; becomes fragile at depth).

## CRDT vs OT for collaboration

**Definition.** CRDTs (Conflict-free Replicated Data Types) allow concurrent edits to merge deterministically without a central coordinator, while Operational Transformation (OT) serializes concurrent operations through a server that transforms them into a consistent order.

**Canonical use.** A peer-to-peer or offline-capable collaborative editor uses a CRDT (e.g., Yjs) so each client can apply local edits immediately and merge on reconnect without a server ordering step, whereas a centralized real-time editor (e.g., Google Docs) uses OT because the server is always available and can enforce a single canonical operation order.

**Production systems.** Yjs / Automerge (CRDT; used in Notion block editor, Liveblocks), Google Docs (OT; server-mediated).

**Alternatives.** Last-write-wins with version vectors (simple; causes data loss on concurrent edits); lock-based editing (prevents conflicts; serializes all writes; poor UX for collaborative editing).

## Image lazy-load with intersection observer

**Definition.** Image lazy-load with Intersection Observer defers fetching image resources until the element approaches the viewport boundary, using the browser's native `IntersectionObserver` API rather than scroll-event polling to trigger the load.

**Canonical use.** A photo gallery page uses Intersection Observer to load only the above-the-fold images on initial render and swap in a low-quality placeholder (blurhash or a tiny LQIP JPEG) for below-the-fold slots until they scroll near.

**Production systems.** Native browser `loading="lazy"` attribute (Chrome/Firefox/Safari; no JS required for images), Medium (LQIP blur-up technique for article images).

**Alternatives.** Eager loading all images (simplest; high initial bandwidth and LCP penalty on long pages); scroll-event listener with debounce (older approach; causes layout thrash; replaced by Intersection Observer).

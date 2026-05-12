# Front-End System Design

Pattern reference for `/study-patterns frontend`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

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

## WebSocket connection management

**Definition.** WebSocket connection management encompasses reconnect-with-exponential-backoff, heartbeat ping/pong frames, and sequence-numbered messages to detect and recover from missed events after a dropped connection.

**Canonical use.** A real-time collaborative document editor maintains a WebSocket to the server, sends client-generated sequence numbers on every operation, and on reconnect requests any missed operations since the last acknowledged sequence number.

**Production systems.** Slack (WebSocket multiplexing + sequence numbering for message delivery guarantees), Figma multiplayer (WebSocket with reconnect and full-state resync).

**Alternatives.** Server-Sent Events (SSE) (unidirectional; simpler for read-heavy push; no backpressure from client); long polling (HTTP-native; higher overhead; natural reconnect on each poll).

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

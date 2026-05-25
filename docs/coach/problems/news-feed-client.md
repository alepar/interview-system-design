---
slug: news-feed-client
archetype: frontend
sources:
  greatfrontend_news_feed: greatfrontend.com/questions/system-design/news-feed-facebook
  meta_q4_2025: investor.atmeta.com (Meta Q4 & Full Year 2025 press release)
---

# News feed client — hybrid pull-push + optimistic posting + viewport-scoped WebSocket + three-tier code-split

## Bar anchors
- **Mid-level (L4/E4):** Renders posts in a list; fetches more on scroll. No WebSocket, no optimistic mutations.
- **Senior (L5/E5):** Names WebSocket for live updates + IntersectionObserver. Discusses virtualization. May or may not articulate viewport-scoped subscriptions, optimistic-create with submit-time idempotency, or tiered code-splitting.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **User has shipped variants at Airbnb** (search-listings client) — Staff+ ceiling shifts upward. Bar pushes past "render the list" to: (a) **hybrid pull-push** — WebSocket layered on cursor-paginated fetch; subscription scoped to **visible viewport posts only**, unsubscribe on scroll-off (GreatFrontEnd: "It is not efficient to fetch updates for posts that have gone out of view"); (b) **optimistic create with rollback** — submit-time (not send-time) idempotency key; local prepend with `pending: true`; on rejection (rate limit, policy) surface banner with retry/discard; persist draft in IndexedDB; (c) **ad slot policy** — every 8th post; never reflow earlier items when ad loads (reserve aspect ratio); track impression via IntersectionObserver ≥50% visible for ≥1s; (d) **three-tier code-split** with **data-driven dependencies** via GraphQL `@match`/`@module` directives — client lazy-loads only matched renderer.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Cursor-paginated infinite feed with virtualization
- WebSocket-pushed live updates (new posts, reaction counts, comments)
- Optimistic post composer with retry on failure
- Ad slots inserted every Nth post without reflow
- Cross-tab consistency (reaction in tab A propagates to tab B)
- Offline writes queued for replay

**Non-functional:**
- Per Meta Q4 2025 investor data (Jan 2026): **Facebook ~2.11B DAU; Meta Family DAP 3.58B Dec 2025**
- Per-client median 150 posts viewed/session; p99 ~1,200
- Per-post hydrated payload ~6 KB
- LCP ≤2.5s, INP ≤200ms, CLS ≤0.1
- WebSocket: one persistent connection/tab; subscribed channels limited to visible viewport (~20 posts) + 10-post lookahead
- Client cache: 5 most recent pages (~750 posts) in normalized store; evict older to ID-only

### Architecture (A)
**Layered**: View / normalized Store / Data Access layer / Server.

**Normalized client store**: `{posts, users, comments}` tables with relational refs (not nested JSON) — single reaction-count update touches one record.

### Data model (D)
- **Post**: `{id, authorId, content, mediaIds[], createdAt, updatedAt, reactionsCount, commentsCount}` (refs not nested)
- **Feed**: `{postIds[], olderCursor, newerCursor, hasOlder, hasNewer}`
- **Optimistic post**: `{tempId, pending: true, idempotencyKey, retryCount}`

### Interface (I)
- REST `GET /feed?cursor=...` for hydration
- WebSocket `subscribe(post_ids[])` for incremental updates
- REST `POST /posts` with `Idempotency-Key` header
- WebSocket reconcile via Lamport-style `updated_at` to prevent stale-overwrite

### Optimization (O)
**Hybrid pull-push protocol**: REST GET for hydration; WebSocket subscribe per-viewport for live updates. Unsubscribe on scroll-off (don't subscribe to posts user can't see).

**Optimistic create**: submit-time idempotency key (generated at submit, NOT send time) so retries don't double-post; local prepend with `pending: true`; reduced opacity UX; reconcile on server response.

**Image strategy**: `srcset` with DPR + viewport variants; `loading="lazy"` below-the-fold; preload first 3 hero images.

**Prefetch on hover**: `<a onMouseEnter>` triggers low-priority `fetch()` for post-detail page.

**Three-tier code-split**: Tier 1 shell + skeleton CSS; Tier 2 above-the-fold renderers + like/comment/share; Tier 3 reaction pickers + hover cards + live subscriptions. **Data-driven dependencies** via GraphQL `@match`/`@module` directives — client lazy-loads only chunk for actual post variant present in response.

**Cross-tab consistency** via BroadcastChannel: optimistic reaction in tab A writes to channel; tab B subscribes and re-reads affected entity.

**Offline writes** in IndexedDB outbox with idempotency keys; flush via Service Worker on reconnect; exponential backoff + jitter; short-circuit non-retryable 4xx.

**Telemetry** via `navigator.sendBeacon` so viewability events survive page unload.

## Known failure modes
1. **Reconnect storm** — 100K clients lose WebSocket and reconnect within 1s. Production answer: exponential backoff + jitter (`2^attempts * random(0.5, 1.5)` seconds, cap 30s).
2. **Cache invalidation drift** — reaction count updates via WebSocket while user has post open. Production answer: last-write-wins on count field; never on reactions list (granular sub-field reconciliation).
3. **Memory pressure** beyond 10 pages cached. Production answer: switch from full-post retention to ID-only; refetch by ID-batch on backscroll.
4. **Optimistic-create double-post** on flaky network. Production answer: server-side idempotency key validation; client generates + reuses across retries.
5. **XSS via post body** — server returns user content with embedded HTML. Production answer: render through DOMPurify; never trust server output.

## Notes for the coach
- **Asked-confirmed** at Meta (Facebook, Instagram), Twitter/X, LinkedIn. GreatFrontEnd flagship.
- **User has shipped variants at Airbnb** — surface as reference; allocate write-up time to viewport-scoped WebSocket + tiered code-split deep-cuts where intuition gives less leverage.
- **The viewport-scoped subscription is the canonical Staff+ unlock.** Mid-senior candidates subscribe to all posts ever seen; Staff+ candidates subscribe only to visible posts and unsubscribe on scroll-off.
- **The submit-time idempotency key is the depth probe.** Mid-senior candidates use send-time; Staff+ candidates name submit-time because retries from different network attempts must hash to same key.
- **Adversarial probe: "user posts; network drops mid-request; user clicks Retry. What happens?"** Strong answer: submit-time idempotency key reused on retry; server sees second request with same key → returns cached response (the original post) → no duplicate. Local UI replaces tempId with server ID; opacity normalizes. Weak answer: "we retry" without addressing the dedup mechanism.

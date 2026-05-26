---
slug: infinite-scroll-feed
archetype: frontend
sources:
  greatfrontend_news_feed: greatfrontend.com/questions/system-design/news-feed-facebook
  mdn_scroll_restoration: developer.mozilla.org/en-US/docs/Web/API/History/scrollRestoration
  discord_mobile_perf: discord.com/blog/supercharging-discord-mobile-our-journey-to-a-faster-app
---

# Infinite scroll feed — IntersectionObserver pagination + virtualization + scroll restoration + cursor-based API

## Bar anchors
- **Mid-level (L4/E4):** `onScroll` handler that calls `getBoundingClientRect()` + fetches more. No virtualization, no scroll restoration, offset pagination.
- **Senior (L5/E5):** Names IntersectionObserver + cursor pagination. Discusses virtualization. May or may not address scroll restoration on back-nav, jump-to-anchor, or virtualization-vs-infinite-scroll distinction.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **Distinguishes infinite scroll (fetch policy) from virtualization (render policy)** — they solve different problems and you almost always want both. Articulates **IntersectionObserver** with `rootMargin: '200px 0px'` (or 1-viewport-height before bottom) — avoids synchronous `getBoundingClientRect` of scroll listeners. Names **virtualization** rendering only viewport + overscan (typically 10-50 items regardless of total) with **DOM spacer divs** sized to measured content. **Cursor-based pagination** (post ID/timestamp) mandatory — offset pagination fails on dynamic feeds because inserts shift indices. Deep-cut: **scroll restoration on back-nav** via `history.scrollRestoration = 'manual'` (browser default 'auto' is unreliable with dynamic content) + serialized `{cursor, scrollTop, mountedPages}` in `history.state`. Second deep-cut: **anchor/permalink** to item at position 4,127 via `?cursor=` API returning 50-item window centered + `?since=` token for upward backfill.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Infinite scroll fetching next page near bottom
- Variable-height items (text + image + nested previews)
- Optimistic mutations (likes, comments) without scroll jump
- Scroll restoration on back-navigation
- Jump-to-anchor (`#post-id`)

**Non-functional:**
- DOM-node budget on mid-range Android (Pixel 6a) ≤2,000 nodes total
- INP ≤200ms on scroll-paginate trigger
- LCP cold open ≤2.5s; CLS ≤0.1
- Per-item ~3 KB text post; per-page ~50 items
- Twitter timeline median 80 items/session, p95 800

### Architecture (A)
**Layered**: View / normalized Store (postsById, usersById, mediaById, feedsById with cursor) / Data Access layer / Server.

### Data model (D)
- **Feed entity**: `{postIds[], olderCursor, newerCursor, hasOlder, hasNewer, lastFetchedAt}`
- **Post entity**: references author via `authorId` and media via `mediaIds[]` (not nested JSON)
- **History state**: `{cursor, scrollTop, mountedPages}` in `history.state`

### Interface (I)
- API: `GET /feed?cursor=X&direction=older|newer&count=N` → `{items, nextCursor, hasMore}`
- Anchor API: `GET /feed?anchor=postId` → window centered on post

### Optimization (O)
**Virtualization libraries**: `@tanstack/react-virtual` for dynamic-height rows uses `ResizeObserver` to remeasure; `react-window` faster with fixed/estimated heights but breaks on variable text. DOM spacer divs sized to measured content preserve scroll geometry.

**IntersectionObserver pattern**: sentinel element with `rootMargin: '200px 0px'` (~1 viewport height); IO callback fires next page fetch. Avoids synchronous `getBoundingClientRect` of scroll listeners.

**Cursor pagination**: `?cursor=lastSeenId&direction=older|newer&count=N`. Stable IDs prevent duplicate/missing items when new posts inserted at top.

**Scroll restoration**: `history.scrollRestoration = 'manual'` in SPAs; persist `{cursor, scrollTop, mountedPages}` in `history.state` + IndexedDB cache; on `popstate` rehydrate from cache before re-fetching.

**Optimistic mutations**: like/comment with `state: 'pending'` flag; reconcile on server response; rollback with toast on error.

**Cross-tab consistency** via BroadcastChannel; **offline writes** in IndexedDB outbox with idempotency keys + exponential backoff + jitter.

**Impression tracking** reuses IntersectionObserver: post counts as impression once ≥50% visible for ≥1 second; deduplicated per session; batched on `visibilitychange` to avoid INP cost.

**Discord's published win** (verbatim): "users with 100+ servers saw a 14% reduction in memory usage at startup, and a 10% decrease in overall startup time" via native virtualized list + view portaling.

## Known failure modes
1. **Jumpy scroll** when virtualized row's measured height changes after image load. Production answer: `aspect-ratio` reserve + ResizeObserver compensation; recompute spacer height before paint.
2. **Duplicate items** when cursor pagination races with WebSocket push. Production answer: dedupe by stable ID; reconcile via `updated_at`.
3. **Lost scroll position on back-nav** because Next.js App Router auto-resets. Production answer: opt out per route; restore from IndexedDB cache before re-fetching.
4. **Memory exhaustion** in long sessions. Production answer: keep at most ~10 pages mounted; evict older to ID-only; refetch by ID-batch on backscroll.
5. **Inline ad insertions shift items** off user's reading line. Production answer: reserve ad-slot aspect ratio; never reflow earlier items when ad loads.

## Notes for the coach
- **Asked-confirmed** at Meta, Twitter/X per candidate reports. GreatFrontEnd "News Feed (Facebook)" canonical.
- **The infinite-scroll-vs-virtualization distinction is the canonical Staff+ unlock.** Mid-senior candidates conflate them; Staff+ candidates separate "fetch policy" from "render policy."
- **Scroll restoration on back-nav is the deep-cut.** Mid-senior candidates assume browser handles it; Staff+ candidates name `history.scrollRestoration = 'manual'` + `history.state` serialization as the explicit pattern.
- **Adversarial probe: "user scrolls to post #500, clicks a post, comes back. What's loaded?"** Strong answer: from `history.state` restore `{cursor, scrollTop, mountedPages}`; rehydrate from IndexedDB cache before any network call; restore exact scroll offset; pages 1-10 still mounted. Weak answer: "we save scroll position" without addressing the multi-page-mount problem.

## (Delineation note)
`infinite-scroll-feed` is the **foundational generic-list** problem in the frontend archetype — applies to any infinite-scrolling UI (search results, chat history, mailbox, file listings), not just social feeds. The full social-feed app (with WebSocket live updates, optimistic posting, ad slots, three-tier code-split) is `news-feed-client`; `news-feed-client` assumes these foundations rather than re-deriving them.

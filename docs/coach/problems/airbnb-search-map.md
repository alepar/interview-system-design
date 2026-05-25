---
slug: airbnb-search-map
archetype: frontend
sources:
  airbnb_search_ranking_maps: medium.com/airbnb-engineering/improving-search-ranking-for-maps-13b03f2c2cca
  airbnb_location_retrieval: medium.com/airbnb-engineering/transforming-location-retrieval-at-airbnb-a-journey-from-heuristics-to-reinforcement-learning-d33ffc4ddb8f
  greatfrontend_airbnb: greatfrontend.com/questions/system-design/travel-booking-airbnb
  mdn_history_api: developer.mozilla.org/en-US/docs/Web/API/History_API/Working_with_the_History_API
---

# Airbnb search map — synchronized map + listings-grid + viewport-based query + marker clustering + hover-link + history.replaceState

## Bar anchors
- **Mid-level (L4/E4):** Renders map + list side-by-side; refetches on every pan. No clustering; no hover-link.
- **Senior (L5/E5):** Names viewport-based query + marker clustering. May or may not articulate two-view ranking, neural location retrieval, history.replaceState vs pushState.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **User has shipped this at Airbnb** — surface as reference; allocate light write-up. Bar: (a) **two views over same ranked candidate set** [Airbnb Engineering]: map-pins and list-cards; listing-card ranking strategy (sort by P(booking)) does NOT translate to maps because pins have no attention-decay-by-position — they require separate map-aware ranking handling spatial uniformity; (b) **neural location retrieval** [Airbnb 2024]: 2-layer NN outputs 4 floats defining lat/lng offsets from center coordinates of searched destination representing relevant map area; balances 'wide variety' vs 'still relevant'; avoids fetching unbounded listing counts for every pan; (c) **virtualized grid sync with markers**: react-window FixedSizeList/Grid renders ~10-50 visible of N; pure DOM cards beyond ~100 visible regress LCP/INP; canvas/WebGL marker layer for thousands; (d) **URL state via history.replaceState** (not pushState) so panning doesn't pollute back-stack but page remains shareable/bookmarkable; (e) **hover-link bidirectional sync** over shared selectedListingId in app state; debounce viewport-bbox refetch on pan/zoom (~300-500ms).

## Canonical decomposition

### Requirements (R)
**Functional:**
- Map + listings grid synced via shared selectedListingId
- Viewport-bounded listing query (debounced)
- Marker clustering past N listings
- Hover-link: list item → highlight pin; pin → scroll grid into view
- URL state encoding (lat/lng/zoom + filters) for share/bookmark
- Mobile bottom-sheet drawer for list

**Non-functional:**
- Airbnb ~7M+ listings; per query ~300 results in viewport, clustered to ~50 visible markers
- Map tiles via Mapbox or Google: vector tiles ~50 KB/tile, ~16 visible
- Query latency ≤500ms p95
- INP ≤200ms on filter change
- Listing card pure-DOM ceiling: ~100 visible before LCP/INP regression
- Thousands of markers requires canvas/WebGL

### Architecture (A)
Map layer (Mapbox GL JS / MapLibre) + Grid layer (react-window virtualized) + Shared state store (selectedListingId, viewport, filters) + URL synchronizer.

### Data model (D)
- **Listing**: `{id, lat, lng, price, title, photos[], aspectRatios[]}`
- **Viewport**: `{north, south, east, west, zoom}`
- **URL state**: `?lat=X&lng=Y&zoom=Z&filters=...`

### Interface (I)
- API: `GET /listings?bbox=...&filters=...` returns clustered + per-listing data
- Cluster expand: `GET /listings?bbox=<cluster-bbox>&zoom=...` zoom-in

### Optimization (O)
**Two-view ranking** (Airbnb's published insight): list-card ranking (sort by P(booking)) does NOT translate to maps because pins have no attention-decay-by-position. Separate map-aware ranker handles spatial uniformity.

**Neural location retrieval** (Airbnb 2024): 2-layer NN outputs 4 floats defining lat/lng offsets representing relevant map area for destination query. Balances "wide variety" vs "still relevant"; avoids fetching unbounded listing counts for every pan.

**Vector tile rendering** with WebGL (Mapbox GL JS / MapLibre). Per Google docs: "the vector map is composed of vector-based tiles, which are drawn at load time on the client-side using WebGL."

**Marker clustering** via Supercluster (KD-tree); client-side OR server-side cluster precomputation. Bi-directional hover-link: hover list item → highlight pin; hover pin → scroll list to item. **Stable IDs across pan**: pins persist when listing remains in bbox; fade out when leaving; never rebuild whole marker layer on each query.

**URL state via history.replaceState** (not pushState) so panning doesn't pollute back-stack but page remains shareable/bookmarkable. Restoring scroll/viewport on back-nav requires storing additional state on the history entry.

**Hover-link bidirectional sync** over shared `selectedListingId` in app state; debounce viewport-bbox refetch on pan/zoom (~300-500ms) so mid-gesture intermediate viewports don't fire network requests.

**Virtualized grid**: react-window FixedSizeList/Grid renders ~10-50 visible of N. Pure DOM cards beyond ~100 visible regress LCP/INP; canvas/WebGL marker layer for thousands.

**Mobile reflow**: bottom-sheet drawer for list.

## Known failure modes
1. **Query flood on rapid pan**. Production answer: 300-500ms debounce on viewport-bbox refetch + AbortController cancellation.
2. **Marker-layer rebuild jank** on every query. Production answer: diff-based update (add new, remove gone, keep stable IDs).
3. **Hover-list-to-pin scroll fights with manual scroll**. Production answer: only scroll if pin's listing card is out of view.
4. **Backend latency causes stale results painted over fresh viewport**. Production answer: sequence-number guard on query responses.

## Notes for the coach
- **Confirmed shipped at Airbnb.** GreatFrontEnd "Travel booking website (Airbnb)" canonical. Plausibly Booking.com, Vrbo.
- **Surface as reference only** — user's prior shipping experience. Allocate write-up time to deep-cuts elsewhere (`figma-canvas-client`, `chatgpt-claude-chat-ui`).
- **The two-view ranking insight is the canonical Staff+ unlock specific to Airbnb's published research.** Map-pins ≠ list-cards from a UX-attention standpoint.
- **Adversarial probe: "user pans 50 times in 5 seconds — how many network requests?"** Strong answer: 300-500ms debounce on viewport refetch + AbortController cancels in-flight; expected ~3-5 requests total (not 50). Sequence-number guard prevents stale results. Weak answer: "we debounce" without committing to a specific window or addressing in-flight cancellation.

---
slug: pinterest-board-client
archetype: frontend
sources:
  pinterest_gestalt: gestalt.pinterest.systems/web/image
  sitepoint_masonry: sitepoint.com/css-masonry-layout-native-grid/
---

# Pinterest board client — masonry layout + image-aspect-ratio prediction + CLS mitigation + BlurHash placeholders

## Bar anchors
- **Mid-level (L4/E4):** Uses CSS columns or a masonry library; doesn't address layout shift.
- **Senior (L5/E5):** Names masonry layout + lazy-loading. May or may not articulate aspect-ratio prediction, native CSS masonry vs JS library, or column-recalc strategy.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Acknowledges **CSS Grid masonry still draft-spec** + Safari support lags — pick JS-driven today (CSS Grid `grid-auto-flow: dense` + pre-computed row-span from each pin's aspect ratio). Articulates **layout-shift mitigation**: every pin's aspect ratio must be known BEFORE its image loads; server returns `{width, height, blur_hash}` per pin; client reserves box via `aspect-ratio: 2/3`. Names **column-recalc strategy**: on resize, swap CSS variable `--column-count` without rebuilding DOM. Names **virtualization across non-uniform heights**: `@tanstack/react-virtual` with dynamic measurement or precomputed-positions approach with running offset table. Cites **native CSS masonry** (`grid-template-rows: masonry`) eliminates second JS layout pass — browser places items correctly on first paint.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Variable-height pins in 3-7 columns depending on viewport
- Infinite scroll with image lazy-load
- Hover preview / quick actions on pin
- Click → pin-detail navigation with scroll-restoration

**Non-functional:**
- Pinterest median 200 pins/session; p99 5,000
- Per pin ~2 KB metadata + 30-80 KB image (lazy-loaded)
- 3-column mobile, 5-column tablet, 7+ column desktop
- CLS target **≤0.05** (stricter than feed because masonry is layout-dense)
- LCP ≤2.0s (first 6-10 hero pins inlined/preloaded)
- Memory: ~500 pin DOM nodes max

### Architecture (A)
Masonry container + Pin children + Lazy-loaded images via IntersectionObserver.

### Data model (D)
- **Pin**: `{id, src, width, height, blur_hash, title, link}` (aspect ratio derived from width/height)
- **Layout state**: `{columnCount, columnHeights[], pinPositions[]}`

### Interface (I)
- API: `GET /pins?cursor=...&columns=N` returns pins with `{width, height, blur_hash}` metadata
- Client computes per-pin row-span from aspect ratio

### Optimization (O)
**BlurHash / LQIP placeholders**: server returns 20-char blur-hash string; client decodes to 32×32 canvas as instant placeholder.

**Image aspect-ratio prediction**: server-precomputed; for UGC where dimensions unknown until upload, refuse upload without `width/height` metadata. Client reserves layout via `aspect-ratio: <w/h>` CSS.

**Column-balancing algorithm**: greedy shortest-column-next assignment for streaming pins. Do NOT relayout when a column-3 pin changes height because user clicked "see more."

**Native CSS masonry** (where supported): `grid-template-rows: masonry` eliminates second JS layout pass.

**JS-based masonry library guidance**: accept per-item aspect ratios; lay out via CSS variables + percentages; recalculate only when column count changes.

**IntersectionObserver lazy-load** with `rootMargin: 200px` to start fetching just before viewport entry; combine with explicit width/height so reserved space doesn't shift.

**Scroll-restoration through masonry**: persist `{pinId, rowOffset}` and re-anchor since masonry layout depends on viewport width which may have changed.

## Known failure modes
1. **Layout thrash** when JS masonry library reads `offsetHeight` (sync layout) in a loop. Production answer: batch reads via rAF.
2. **CLS spike** when UGC pin's predicted aspect is wrong by 30%. Production answer: server validates dimensions on upload; reject mismatched metadata.
3. **Memory bloat** from never-evicted off-screen DOM. Production answer: virtualization with `@tanstack/react-virtual` dynamic measurement.
4. **Slow column-rebalance** on rotation (mobile portrait↔landscape). Production answer: debounce via `ResizeObserver`; only recompute positions, don't rebuild DOM.

## Notes for the coach
- **Plausibly-asked at Pinterest** (Gestalt design system blog), Etsy, Tumblr, Instagram Explore.
- **The aspect-ratio prediction is the canonical Staff+ unlock for CLS.** Server-precomputed dimensions in API + client reserves layout space is the only way to hit CLS ≤0.05 on a masonry layout.
- **Native CSS masonry vs JS library is the depth probe.** Staff+ candidates articulate the spec landscape and pick JS today + native when Safari ships.
- **Adversarial probe: "user uploads a 100x800 pin to a 5-column board — what's the worst case if we don't know aspect ratio?"** Strong answer: client renders square placeholder; image loads as 100x800; massive CLS as 800px-tall pin shifts everything below; mitigate via mandatory upload-time dimension capture. Weak answer: "we use a library" without addressing the UGC dimension capture.

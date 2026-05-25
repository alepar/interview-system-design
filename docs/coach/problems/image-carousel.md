---
slug: image-carousel
archetype: frontend
sources:
  greatfrontend_carousel: greatfrontend.com/questions/system-design/image-carousel
  aria_carousel: w3.org/WAI/ARIA/apg/patterns/carousel/
  web_dev_lcp: web.dev/articles/optimize-lcp
  web_dev_lazy: web.dev/articles/browser-level-image-lazy-loading
  web_dev_responsive: web.dev/articles/serve-responsive-images
---

# Image carousel — swipeable accessible component with LCP/CLS discipline + ARIA APG pattern

## Bar anchors
- **Mid-level (L4/E4):** Builds working carousel with hardcoded slides + arrow buttons. No LCP / CLS awareness. No accessibility beyond basic alt text.
- **Senior (L5/E5):** Names lazy loading + responsive images. Discusses keyboard nav. May or may not address ARIA APG pattern, prefetch policy, or gesture FSM.
- **Staff+ (L6/E6+):** Drives the **RADIO framework** explicitly. Articulates **prefetch policy** (eager N+1, `requestIdleCallback` N+2, never N-2/N+3; bandwidth budget ≤300 KB above-the-fold). Names **CLS prevention** via `aspect-ratio` CSS or width/height attrs. Names **gesture FSM** (5 states: idle/dragging/settling/animating/cancelled), passive `touchstart`, `transform: translate3d` GPU promotion. Cites **ARIA APG carousel pattern**: `role="group"` + `aria-roledescription="carousel"`, slides `aria-roledescription="slide"`, `aria-current="true"`; **auto-rotation MUST halt on keyboard focus OR mouse hover**; **rotation control FIRST in Tab sequence**; `aria-live="off"` while rotating, `"polite"` only when paused. Cites the **LCP anti-pattern**: never lazy-load LCP slide; use `fetchpriority="high"` on hero img.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Display ordered list of images, one visible at a time
- Prev/next via tap, swipe, keyboard, arrows
- Auto-rotation optional, with pause/play control
- Indicators showing current position
- Accessibility level WCAG 2.2 AA

**Non-functional:**
- LCP ≤2.5s (hero slide is LCP candidate); INP ≤200ms on swipe; CLS ≤0.1
- Bandwidth budget ≤300 KB above-the-fold; AVIF/WebP/JPEG fallback chain
- Memory: retain decoded bitmaps for ≤5 slides (mobile Safari ~250 MB tab ceiling)
- Browser-level `loading="lazy"` pre-fetches at ~1250px (4G) / ~2500px (3G)

### Architecture (A)
**Components**: Carousel container + Slide children + Indicators + Controls (Prev/Next/Play-Pause).

**State**: `{activeIndex, isPlaying, gestureState, autoplayTimer}`.

**Layers**: Render (DOM + CSS) / Gesture FSM / Prefetch scheduler / Accessibility (ARIA + live region).

### Data model (D)
- **Slide**: `{src, alt, srcset, sizes, aspectRatio, type: 'image'|'video'}`
- **Carousel state**: `{activeIndex, isPlaying, direction, gestureState}`

### Interface (I)
**Public props**: `slides[]`, `autoPlayMs`, `loop`, `defaultIndex`, `onChange`, `onSlideClick`.

**ARIA contract**: root `role="group"` + `aria-roledescription="carousel"`; slide wrapper `role="group"` + `aria-roledescription="slide"`; `aria-live="off"` while autoplay, `"polite"` when paused.

### Optimization (O)
**Prefetch & decode pipeline**: `<link rel="preload" as="image" imagesrcset=...>` for slide 1; `<img loading="lazy" decoding="async">` for rest; `img.decode()` Promise so swipe→render never janky.

**Responsive images**: `srcset` width descriptors + `sizes`; `<picture>` `<source type="image/avif">` → `<source type="image/webp">` → JPEG fallback.

**LCP discipline**: never lazy-load LCP slide; `fetchpriority="high"` on hero. Always set `width`+`height` or `aspect-ratio` (without dimensions, browsers default to 0×0 and may load every image if gallery initially appears in-viewport).

**Gesture FSM**: 5-state (idle / dragging / settling / animating / cancelled); passive `touchstart`; `transform: translate3d` for GPU; cleanup `touchmove` on `document` in React `useEffect` cleanup.

**Accessibility**: keyboard arrows + Home/End; `aria-live="polite"` "Slide 4 of 12" on change; focus restoration on next/prev click; `prefers-reduced-motion` disables autoplay.

**Web-perf budgets**: inline first slide HTML so it's LCP candidate; ship carousel JS as deferred chunk ≤12 KB gzip; `content-visibility: auto` on offscreen slides.

## Known failure modes
1. **CLS regression** when placeholder reserves wrong aspect ratio. Production answer: server returns `{width, height, blur_hash}` in API; client computes `aspect-ratio` from metadata.
2. **Memory leak** when gesture FSM `touchmove` listener on `document` never removed on unmount. Production answer: React `useEffect` cleanup discipline; verify with Chrome DevTools Memory tab.
3. **Autoplay race** — `setInterval` keeps advancing after tab hidden. Production answer: pause on `visibilitychange` event.
4. **iOS Safari bounce-scroll** hijacks swipe; carousel never sees `touchend`. Production answer: hybrid touch+pointer events; explicit `touch-action: pan-y` CSS on swipe surface.

## Notes for the coach
- **Asked-confirmed at Airbnb** (product gallery), Apple, Amazon per candidate reports. GreatFrontEnd canonical (Medium / 30-min).
- **The LCP-anti-pattern is the canonical Staff+ unlock.** Candidates who default to `loading="lazy"` for all images miss that the hero/first slide is the LCP candidate.
- **ARIA APG carousel pattern is the depth probe.** Mid-senior candidates miss "rotation halts on focus OR hover" and "rotation control FIRST in Tab"; Staff+ candidates name them as explicit APG requirements.
- **Adversarial probe: "user has 'reduced motion' OS preference — what changes?"** Strong answer: disable autoplay; instant transitions (no animations); explicit user-controlled next/prev only. Weak answer: "we add a setting" without addressing OS-level signal.

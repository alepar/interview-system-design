---
slug: google-maps-client
archetype: frontend
sources:
  google_maps_coordinates: developers.google.com/maps/documentation/javascript/coordinates
  mapbox_vector_tile_spec: github.com/mapbox/vector-tile-spec
  mapbox_gl_architecture: github.com/mapbox/mapbox-gl-js/blob/main/ARCHITECTURE.md
  supercluster: blog.mapbox.com/clustering-millions-of-points-on-a-map-with-supercluster-272046ec5c97
  deckgl_perf: deck.gl/docs/developer-guide/performance
  google_places_session_tokens: developers.google.com/maps/documentation/places/web-service/using-session-tokens
---

# Google Maps client — tile pyramid + vector tiles (PBF + WebGL) + Web Worker decode + Supercluster + deck.gl + Service Worker tile caching

## Bar anchors
- **Mid-level (L4/E4):** Renders map via `<img>` tiles or iframe Google embed. No interactive layers, no marker clustering.
- **Senior (L5/E5):** Names tile pyramid + marker clustering. Discusses lazy loading. May or may not articulate vector tiles, Web Worker decode, or session tokens for Places billing.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Canonical **tile-based geo client with WebGL rendering**. Bar: (a) **tile pyramid**: 256×256 px tiles; each zoom doubles in x+y; zoom 0 = 1 tile world, zoom N = 2^N per side; client fetches only tiles intersecting viewport bbox; (b) **vector tiles** (Mapbox MVT spec): Protocol Buffers (.mvt) with Tile/Layer/Feature messages; **extent typically 4096**; client decodes geometry commands (MoveTo/LineTo/ClosePath) and renders via WebGL; same source supports dynamic styling without re-fetch; (c) **Mapbox GL JS architecture**: Web Workers parse PBF into Bucket objects holding vertex/index buffers ready for GPU; transfer back to main thread which does only WebGL draw calls in Painter#renderPass — keeps main thread responsive; (d) **marker clustering** via Supercluster (KD-tree hierarchical clusterer) precomputes clusters per zoom level — handles millions of points in-browser; (e) **deck.gl** WebGL2 ScatterplotLayer: ~1M points at 60fps on 2015 MBP; degrades 10-20fps at 10M; Chrome ~1GB per-allocation cap forces sharding 10-100M points; (f) **Places autocomplete session tokens** (UUIDv4): group keystroke predictions + final selection into single billed session.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Multiple layer types (base, roads, satellite, transit, custom)
- Pan/zoom with momentum at 60fps
- Marker clustering for high-density datasets
- Place search with autocomplete
- Routing UI (origin + destination + alternatives)
- StreetView integration

**Non-functional:**
- Tile pyramid: zoom N = 2^N tiles/side; zoom 0 = 1 tile world
- Vector tile extent typically 4096 (1/4096th of square dimensions per coordinate unit)
- deck.gl: 1M points @ 60fps / 10M @ 10-20fps / Chrome 1GB per-allocation cap
- Supercluster: millions of points in-browser; KD-tree based
- Places session token: UUIDv4; debounce 150ms + minChar threshold
- rAF budget 16.67ms/frame for smooth pan/zoom

### Architecture (A)
**Layers**: Tile loader (cache via Service Worker) / Vector tile parser (Web Worker) / WebGL renderer (main thread) / Marker layer (Supercluster) / Search autocomplete (Places API) / Routes layer / UI overlays.

### Data model (D)
- **Tile**: `{z, x, y, layers: [{features: [...]}]}`
- **Bucket** (Mapbox): GPU-ready vertex + index buffers per layer per tile
- **Marker**: `{lat, lng, id, metadata}` clustered per zoom level
- **Route**: polyline with elevation profile + alternatives

### Interface (I)
- Map API: `map.setCenter()`, `map.setZoom()`, `map.addLayer()`
- Tile URL template: `/tiles/{z}/{x}/{y}.pbf` or `.png`
- Places autocomplete: `places.queryAutocomplete({sessionToken, input})`

### Optimization (O)
**Tile-based rendering**: viewport bbox → tile list → fetch with caching (browser HTTP cache + service worker). 256×256 px tiles; zoom doubling.

**Vector tiles** (Mapbox MVT spec): encoded as Protocol Buffers (.mvt) with Tile/Layer/Feature message types; extent typically 4096 defining tile's internal coordinate units. Geometry commands (MoveTo, LineTo, ClosePath). Less bandwidth than rasters; supports dynamic styling/restyling without re-fetching.

**Mapbox GL JS architecture**: Web Workers parse raw data (e.g., Vector Tiles), perform layout (tessellation), create Bucket objects containing GPU-ready buffers. Rendering happens style-layer by style-layer in `Painter#renderPass()`, which delegates to layer-specific `drawXxxx()` methods, binding layout buffer data and calling `gl.drawElements()`. WorkerTile.parse() performs CPU-intensive tasks of decoding coordinates, handling label placement, generating vertex buffers — keeps main thread responsive.

**Marker clustering via Supercluster**: KD-tree based hierarchical clusterer; precomputes clusters per zoom level so client only renders relevant zoom's clusters; handles millions of points in-browser. 50 visible clusters instead of 10,000 markers at low zoom.

**deck.gl** WebGL2 ScatterplotLayer: ~1M points at 60fps on 2015 MBP; degrades to 10-20fps at 10M; Chrome's ~1GB per-allocation cap forces sharding into multiple layers around 10-100M points.

**Places autocomplete session tokens** (UUIDv4): group keystroke prediction calls + one final 'place details' selection into single billed session. Debounce ~150ms + minChar threshold so each individual keystroke isn't billed separately.

**requestAnimationFrame for smooth pan/zoom**: budget ~16.67ms/frame; rAF auto-pauses on hidden tabs, syncs with display refresh, batches DOM reads/writes.

**Service Worker tile caching**: cache-first for already-fetched raster/vector tiles (immutable per tile coord+style hash); stale-while-revalidate for API responses (search, geocoding). SWR serves cached response instantly then revalidates network in background — perceived-instant pan into previously-visited area.

**Memory mgmt**: evict offscreen tiles past LRU cap.

## Known failure modes
1. **Main-thread freeze on tile decode at high zoom**. Production answer: Web Worker decode (Mapbox GL JS pattern); transfer Bucket buffers to main thread.
2. **Marker pile-up past 1k points crashes DOM**. Production answer: Supercluster KD-tree clustering; deck.gl for >100k.
3. **Bill explosion from per-keystroke Places API calls**. Production answer: session tokens + 150ms debounce + minChar.
4. **Tile cache memory bloat**. Production answer: LRU eviction; Service Worker cache TTL.

## Notes for the coach
- **Asked-confirmed at Google (Maps), Mapbox, Uber (Movement).** Plausibly Airbnb (geo-search), Lyft, DoorDash.
- **The Web Worker tile decode is the canonical Staff+ unlock.** Without it, main thread freezes on pan/zoom; Mapbox GL JS architecture is the canonical reference.
- **Supercluster vs deck.gl is the depth probe for scale.** Supercluster up to millions; deck.gl up to 10M+ with WebGL2 sharding.
- **Adversarial probe: "your map shows 50K markers — what's the rendering strategy?"** Strong answer: Supercluster precomputes clusters per zoom level; visible cluster count typically 50-200 regardless of total; on cluster click, expand or zoom in; for >100K consider deck.gl WebGL2 layer. Weak answer: "we render all markers" — crashes DOM past 1k.

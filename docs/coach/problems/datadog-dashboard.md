---
slug: datadog-dashboard
archetype: frontend
sources:
  datadog_template_vars: docs.datadoghq.com/dashboards/template_variables/
  datadog_rust_tsdb: datadoghq.com/blog/engineering/rust-timeseries-engine/
  datadog_steganography: datadoghq.com/blog/engineering/steganography-at-scale/
  lttb: rajnandan.com/posts/largest-triangle-three-buckets-downsampling/
---

# Datadog dashboard — composable observability: time-series charts + LTTB downsampling + URL state + SSE live-tail + tile graph

## Bar anchors
- **Mid-level (L4/E4):** Renders chart per widget; each widget queries independently; no shared state.
- **Senior (L5/E5):** Names query batching + URL state. May or may not articulate LTTB downsampling, tile-graph composition, or SSE live-tail.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. "Dashboard composition" problem — many widgets coordinating around shared filters. Bar: (a) **widget abstraction** — each widget is `(query, viz, refreshPolicy)`; dashboard is 12-column grid; (b) **query coalescing** — 30 widgets all filtering by `env:prod` should fire one query with multiple group-by keys, not 30 (gateway-layer batcher); (c) **streaming + historical split** — query results land as static dataset; updates arrive over separate channel that appends/replaces points; (d) **share/embed** — read-only URL with all filter state encoded; permissions checked on widget queries server-side; (e) **shared time-range** — single source of truth; widgets subscribe. **LTTB (Largest-Triangle-Three-Buckets)** for server-side downsampling — O(n) one-pass algorithm preserving visual shape including sharp inflections.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Time-series charts with shared time range + faceted filters
- Drag-drop widget layout
- Live-tail logs widget via SSE
- Embed/share via URL state encoding
- Per-tenant permissions on queries

**Non-functional:**
- Per Datadog docs: "15-20 widgets per view" stays performant; beyond degrades
- Each time-series widget: 1-10 series × 100-500 points
- Streaming refresh interval 10s typical, 1s for "live"
- INP ≤200ms on filter change
- Memory: bound rendered points/widget at ~5K; downsample older windows

### Architecture (A)
**Layered**: Dashboard layout engine (12-col grid) / Widget abstraction `(query, viz, refreshPolicy)` / Query batcher / SSE live-tail / URL state encoder / Embed iframe sandbox.

### Data model (D)
- **Dashboard**: `{layout: GridItem[], filters: {time, tags}, templateVars: Map}`
- **Widget**: `{id, query, viz, refreshPolicy, size}`
- **TimeSeries**: `{series: [{tags, points: [[ts, value]]}]}` (LTTB-downsampled server-side)
- **URL state**: `from_ts=X&to_ts=Y&live=true&tpl_var_<NAME>=<VALUE>`

### Interface (I)
- API: `POST /query/batch` with `{queries: [...], time_range, filters}` → batched response
- SSE: `/logs/tail?filter=...` with `data: <payload>\n\n` framing
- URL state: query params per Datadog format

### Optimization (O)
**Server-side downsampling via LTTB** (Largest-Triangle-Three-Buckets): O(n) one-pass algorithm; divides data into buckets; selects point per bucket forming largest triangle area with neighboring points; preserves visual shape including sharp inflections. Computed server-side per widget time-window.

**Datadog URL state encoding**: time range as `from_ts/to_ts` (Unix ms) + `live=true` for rolling windows; template vars as `tpl_var_<NAME>=<VALUE>`. Embeddable widgets accept same template vars → iframe-embedding with dynamic filters.

**Tile-graph dashboard composition**: each widget owns query but inherits time-range + template-var context from dashboard. Drag-drop layout serializes to grid descriptor stored server-side. **Per-tile fetch with parallel HTTP/2 multiplexing** avoids head-of-line blocking when 30+ tiles render.

**Live-tail logs via SSE**: unidirectional server→client over single long-lived HTTP/1.1 or HTTP/2 connection; SSE wire format `data: <payload>\n\n`; pair with **virtualized list** rendering ~20 visible rows out of thousands buffered.

**Datadog backend** (Rust LSM tree): new real-time timeseries DB is LSM tree in Rust for write-heavy workloads. Dashboard queries hit query engine which returns already-downsampled points per widget time-window.

**Steganographic share URLs**: Datadog embeds full share URL of widget steganographically into widget's PNG screenshot — pasting image into Slack/Jira preserves deep link to live dashboard view.

**Canvas charts at scale**: same canvas/rAF story as `stock-trading-dashboard` for high-frequency updates.

## Known failure modes
1. **Query-cascade on filter change** — 30 widgets fire 30 requests. Production answer: batch via 50ms debounce; gateway-layer batcher collects + fans out one batched request.
2. **Chart-library memory leak** from instances not torn down on widget unmount. Production answer: explicit teardown in cleanup; verify with DevTools Memory.
3. **Time-range drift between widgets** if each holds local state. Production answer: single shared store; widgets subscribe.
4. **Embed iframe XSS**. Production answer: `sandbox="allow-scripts allow-same-origin"` + strict CSP.
5. **Widget-resize triggers full chart re-mount**, losing zoom/pan. Production answer: observe size with `ResizeObserver`; call chart's `resize()` API.

## Notes for the coach
- **Plausibly-asked at Datadog, Grafana Labs, New Relic, Sentry, Honeycomb, Splunk.** Datadog Engineering blog publishes architecture.
- **LTTB downsampling is the canonical Staff+ unlock for time-series at scale.** Server returns ~500 visually-meaningful points instead of 100K raw.
- **The steganographic share URL is the deep-cut.** Most candidates miss that you can embed metadata in PNGs to make screenshots deep-linkable.
- **Adversarial probe: "user opens dashboard with 50 widgets — how many network requests in first 100ms?"** Strong answer: ONE batched query with 50 sub-queries; gateway batcher collects all per-widget queries on initial mount within 50ms debounce; HTTP/2 multiplexing for response. Weak answer: "50 requests in parallel" — but HTTP/2 head-of-line blocking still applies to a single slow query.

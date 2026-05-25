---
slug: google-maps-routing
archetype: geo-proximity
sources:
  osrm: wiki.openstreetmap.org/wiki/Open_Source_Routing_Machine
  osrm_running: github.com/Project-OSRM/osrm-backend/wiki/Running-OSRM
  ch_grokipedia: grokipedia.com/page/Contraction_hierarchies
  deepmind_eta: deepmind.google/discover/blog/traffic-prediction-with-advanced-graph-neural-networks/
  codelit: codelit.io/blog/google-maps-system-design
  system_design_handbook: systemdesignhandbook.com/guides/google-maps-system-design/
  osrm_algorithms: deepwiki.com/Project-OSRM/osrm-backend/3.1-routing-algorithms
  hn_detour: news.ycombinator.com/item?id=20295196
---

# Google Maps routing — Contraction Hierarchies (CH) preprocess continental road network for ~4 orders of magnitude speedup over plain Dijkstra (OSRM ~163µs median query on 87M-vertex North America) + real-time traffic as edge-weight multipliers on top of static CH hierarchy (metric customization completes in seconds even on continental) + Supersegments as ETA unit (2-segment to hundreds-of-nodes) + DeepMind GNN ETA model (road segments as nodes + intersections as edges; trained with L2/L1/Huber/NLL loss combo; MetaGradients adapt learning rate across heterogeneous graph sizes) + 51% improvement Taichung / 43% Sydney / 37% Osaka over ~97% baseline + S2 cell hierarchy + ~2B daily navigations + probe data ~30+ TB/year + mega-segment caching limits recompute blast radius

## Bar anchors
- **Mid-level (L4/E4):** Dijkstra on full road graph per request; no preprocessing; no traffic overlay.
- **Senior (L5/E5):** Names A* + traffic data ingest. May or may not articulate CH preprocessing, GNN ETA, Supersegments, or mega-segment caching.
- **Staff+ (L6/E6+):** Names (a) **Contraction Hierarchies** preprocess road network so query-time work collapses to bidirectional upward-only search; ~4 orders of magnitude speedup over plain Dijkstra on continental networks; (b) **OSRM public reference**: ~163µs median query on 87M-vertex North America graph; sub-1ms on Europe; (c) **Real-time traffic as edge-weight multipliers** on static CH hierarchy — NOT full re-preprocess; metric customization completes in seconds even on continental; (d) **Supersegments**: multiple adjacent road segments sharing significant traffic volume, ranging 2-segment to hundreds-of-nodes — unit for ETA prediction + partial recomputation; (e) **DeepMind GNN ETA**: road segments as nodes + intersections as edges; trained with L2/L1/Huber/NLL loss combo; MetaGradients dynamically adapt learning rate across heterogeneous graph sizes; (f) **GNN ETA improved 51% Taichung / 43% Sydney / 37% Osaka** over baseline ~97% accuracy; (g) **Scale**: ~2B daily navigations; estimated ~1.7M RPS tile fetches + ~70K RPS routing at peak; (h) **S2 spatial indexing**: cube + Hilbert curve → 64-bit cell IDs; vector tiles from quadtree pyramid; ~20-30 tiles per viewport behind CDN; (i) **Probe data ("Floating Car Data")** from user devices: map-matched via HMM Newson-Krumm, aggregated 1-5 min windows; ~30+ TB/year raw; (j) **Mega-segments cache precomputed exit-to-exit paths**; Dijkstra re-runs on mega-segment graph when edges drift past threshold — limits recompute blast radius; (k) **OSRM migrating from CH to MLD (Multi-Level Dijkstra)** for live-traffic flexibility.

## Canonical decomposition

### Requirements
**Functional:**
- Point-to-point routing with current traffic
- ETA prediction
- Vector + satellite tile serving
- Map updates (new roads, closures)

**Non-functional:**
- ~2B daily navigations
- CH ~163µs median query on continental graph
- Metric customization <1s on continental
- GNN ETA 51% improvement in tested cities

### Core entities
- **RoadGraph:** nodes = intersections, edges = road segments
- **CHGraph:** preprocessed contraction hierarchy
- **Supersegment:** multi-segment unit for ETA prediction
- **TrafficObservation:** {segment_id, observed_speed, ts} from probe data

### API
- `GET /directions?origin=&destination=&mode=` → polyline + ETA + steps
- `GET /tile/{z}/{x}/{y}.pbf` → vector tile

### HLD
Offline preprocessing: road graph → Contraction Hierarchies preprocess (hours-to-days for continental graph). Produces upward-only contracted graph allowing query-time bidirectional search to terminate in upward edges only.

Real-time traffic ingest: probe data ("Floating Car Data") from user devices map-matched to road segments via HMM Newson-Krumm. Aggregated in 1-5 min windows. Updates per-edge weight multipliers. Metric customization re-applies weights to CH (<1s on continental).

Routing query: client → routing service → CH bidirectional search → returns polyline + Supersegment IDs.

ETA: per-Supersegment ETA from DeepMind GNN model (road segments as nodes + intersections as edges). Combined across route polyline.

Tile serving: pre-rendered vector tiles via S2 quadtree pyramid → CDN. ~20-30 tiles per viewport.

Mega-segment caching: precomputed exit-to-exit paths cached. Dijkstra re-runs on mega-segment graph only when edge weights drift past threshold percentage — limits recompute blast radius.

### Deep dives
1. **CH preprocessing + metric customization + alternatives.** CH gives ~4 orders of magnitude speedup. Real-time traffic as edge-weight multipliers on static hierarchy — no full re-preprocess; customization <1s. Alternatives: ALT (A* with Landmarks + Triangle inequality), CCH (Customizable CH), MLD (Multi-Level Dijkstra). OSRM migrating from CH to MLD for live-traffic flexibility.
2. **Supersegments + GNN ETA.** Supersegment = adjacent road segments sharing traffic volume. DeepMind GNN model: segments as nodes + intersections as edges. L2/L1/Huber/NLL loss combo. MetaGradients for heterogeneous graph sizes. 51% Taichung / 43% Sydney / 37% Osaka improvement over baseline ~97% accuracy.
3. **S2 spatial index + probe data + map-matching + mega-segment caching.** S2 cube + Hilbert curve → 64-bit cell IDs; vector tiles from quadtree pyramid. Probe data map-matched via HMM Newson-Krumm. Aggregated 1-5 min windows. Mega-segments cache precomputed exit-to-exit paths; Dijkstra re-runs on mega-segment graph when edges drift past threshold — limits recompute blast radius.

## Known failure modes
1. *Closed-road / detour failures* — app behavior lags physical signage; digital authority feeds slow to propagate; verification requires threshold of user reports. Famous case: drivers followed detour onto dirt track that "faded away to nothing".
2. *Live-traffic stale on incident edge* — probe data lags actual incident by minutes. Production answer: Waze CCP partner feeds for immediate authoritative input.
3. *Mega-segment cache invalidation on viral traffic event* — many mega-segments cross threshold simultaneously. Production answer: priority queue; rate-limit Dijkstra re-runs per host.

## Notes for the coach
- **Asked-plausibly at Google Maps, Apple Maps, HERE, TomTom.** Geisberger CH paper + DeepMind GNN ETA blog + OSRM wiki + Newson-Krumm paper are canon.
- **Cross-coverage** with `waze-traffic-update` (this archetype; crowdsourced traffic alternative). With `last-mile-routing` (this archetype; VRP variant). With `h3-s2-spatial-index` (this archetype; S2 primitive).
- **The CH + metric-customization-in-seconds + Supersegment GNN ETA combo is the canonical Staff+ unlock.** Mid-senior candidates name Dijkstra; Staff+ candidates name CH + edge-weight overlay + GNN.
- **Adversarial probe: "Major accident on I-95, all queries currently route through it. How does the system reroute in real-time?"** Strong answer: probe data detects speed drop on affected Supersegments (5-15s lag); per-segment weight multipliers updated; mega-segment cache invalidated if drift exceeds threshold; CH metric customization re-applies new weights to hierarchy (<1s on continental); subsequent queries use new weights. For users currently mid-route, client polls every minute for re-route check; if delta > N minutes, surfaces re-route prompt. Weak answer: "re-run Dijkstra" without naming the CH metric-customization layer.

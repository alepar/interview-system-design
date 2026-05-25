---
slug: snap-geofilter-fanout
archetype: geo-proximity
sources:
  snap_newsroom: newsroom.snap.com/on-demand-geofilters
  snap_terms: snap.com/terms/create-geofilter
  ad_guide: collectivemeasures.com/insights/guide-snapchat-branded-geofilters
  qa_pipeline: ignitesocialmedia.com/content-creation/how-to-submit-a-custom-snapchat-on-demand-geofilter/
---

# Snapchat geofilter delivery — On-Demand fences bounded 20,000 sq ft (~1,860 m²) min and 5,000,000 sq ft (~46.5 ha) max + narrow enough for single S2 region-cover or H3 disk + pricing floor $5/20,000 sq ft/hr (economic signal that catalog dominated by many small short-lived geofences) + client-pull delivery (NOT server-push) — clients open camera + query candidate filter set keyed by (current lat/lon, current time) + backend indexes filters by (geo-cell, time-window) — R-tree/H3 + interval-tree composition + GPS jitter at fence edges produces silent under/over-delivery (Snap accepts as product-level truth because filter use is opt-in + visual) + custom filter QA pipeline runs within ~1 day

## Bar anchors
- **Mid-level (L4/E4):** Designs server-push on enter; full geo polygon-in-point check per event.
- **Senior (L5/E5):** Names client-pull + (geo, time) index. May or may not articulate the fence-size bounds, pricing-economic catalog shape, GPS-jitter tolerance, or QA pipeline.
- **Staff+ (L6/E6+):** Names (a) **Fence bounds** 20,000-5,000,000 sq ft per fence — narrow enough for single S2 region-cover or H3 disk; (b) **Pricing floor $5/20,000 sq ft/hr** — economic signal that filter catalogs dominated by many small short-lived geofences (event-scale), not few large ones; (c) **Client-pull delivery** (NOT server-push): clients open camera + query candidate filter set keyed by (current lat/lon, current time). Backend indexes filters by (geo-cell, time-window) — classic R-tree/H3 + interval-tree composition; (d) **GPS jitter at fence edges** produces silent under-delivery (user inside doesn't see filter) + silent over-delivery (user outside sees it). Snap accepts as product-level truth because filter use is opt-in + visual; (e) **Custom filter QA pipeline** runs within ~1 day — implies moderation queue (not auto-publish) feeding geo-index; sponsored filters with tight (geo, time) bounds need eventual-consistency tolerance of hours.

## Canonical decomposition

### Requirements
**Functional:**
- Advertiser/user creates custom geofilter (geo polygon + time window + image)
- QA review of submitted filter
- Client retrieves candidate filters when opening camera
- Filter overlay applied client-side

**Non-functional:**
- Fence bounds 20K-5M sq ft (~1,860 m² - 46.5 ha)
- Pricing floor $5/20K sq ft/hr
- QA pipeline ~1 day
- Eventual-consistency tolerance of hours for sponsored

### Core entities
- **Filter:** filter_id, polygon, start_time, end_time, image_url, advertiser_id, status ∈ {pending_qa, active, expired}
- **GeoIndex:** (s2_cell or h3_cell, time_window) → filter_ids[]
- **CameraQuery:** {lat, lon, ts} → candidate filter_ids[]

### API
- `POST /filter` body={polygon, start_time, end_time, image} (advertiser submission)
- Internal: QA workflow → status update
- `GET /filters?lat=&lon=&ts=` (client camera query)

### HLD
Filter creation: advertiser/user submits via Snap interface. Submission lands in QA queue.

QA pipeline: moderator reviews ~1 day. On approval, filter status → active. Geo-index updated: polygon → S2 region-cover (or H3 disk for compact circles) generates cell list; (cell, time-window) → filter_id appended to inverted index.

Client camera query: client opens camera → POSTs (lat, lon, current_time). Server computes containing S2 cell at appropriate resolution → index lookup returns filter_ids whose (cell, time-window) matches → filter additional candidates by point-in-polygon test (server-side or client-side). Returns image URLs + polygon data.

Client overlay: client renders filter image over camera; GPS-jitter at edges accepted as visible silent under/over-delivery.

### Deep dives
1. **Fence bounds + client-pull architecture.** 20K-5M sq ft per fence — narrow enough for single S2 region-cover or H3 disk. Client-pull: client queries (lat/lon, current time) → backend returns candidate filter list. Backend indexes by (geo-cell, time-window) — R-tree/H3 + interval-tree composition.
2. **Pricing economics + catalog shape.** Pricing floor $5 for smallest fence-hour. Implies catalog dominated by many small short-lived fences (event-scale). Architectural impact: storage optimized for many small fences with short TTL, not few large ones.
3. **GPS-jitter tolerance + QA pipeline.** GPS jitter at edges → silent under/over-delivery. Snap accepts as product truth (visual + opt-in). QA pipeline ~1 day — sponsored filters with tight bounds need eventual-consistency tolerance.

## Known failure modes
1. *GPS-jitter delivery errors* — accepted as product truth. Mitigation: visual + opt-in.
2. *QA pipeline 1-day delay* — sponsored filter with tight time bounds may publish post-event. Production answer: surface estimated publish time to advertiser; recommend booking with buffer.
3. *Catalog growth from many small fences* — index size scales with concurrent fence count, not user count. Production answer: TTL on expired fences; lazy delete.

## Notes for the coach
- **Plausibly-asked at Snap.** Snap newsroom + community geofilter T&Cs + ad-tech guides are public.
- **Cross-coverage** with `snap-map` (this archetype; same Snap product surface). With fan-out #2 `geo-weather-alert-fanout` (geo+time composite indexing).
- **The client-pull + (geo, time) composite-index architecture is the canonical Staff+ unlock.** Mid-senior candidates default to server-push on user enter; Staff+ candidates name client-pull because filter is camera-triggered + composite (geo, time) index because both axes filter.
- **Adversarial probe: "Make geofilters server-push so users don't have to open camera to discover."** Strong answer: server-push would require per-user fence subscription for ALL active filters in catalog (hundreds of thousands at any given moment in major metros); rolling-window registration per user (Pilgrim-style) hits iOS 20-fence cap; battery cost on user devices for continuous monitoring; filter discoverability through map UI already exists for users who want it. Client-pull on camera-open is correct because trigger = camera-use, not enter-fence. Weak answer: "we'd add WebSockets" without naming the user-subscription matrix scale problem.

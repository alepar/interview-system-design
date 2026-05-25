---
slug: foursquare-checkin
archetype: geo-proximity
sources:
  places_api: foursquare.com/products/places-api/
  pilgrim_announce: medium.com/foursquare-direct/on-announcing-foursquares-pilgrim-sdk-cb3f6ab9cfa8
  snap_to_place: medium.com/foursquare-direct/phones-lambdas-and-the-joy-of-snap-to-place-technology-2875244100dd
  snap_to_place_blog: location.foursquare.com/resources/blog/capabilities/phones-lambdas-and-the-joy-of-snap-to-place-technology/
  movement_faq: docs.foursquare.com/developer/docs/movement-sdk-faqs
  signal_cloud: medium.com/foursquare-direct/unlocking-the-power-of-place-for-marketers-and-developers-introducing-pilgrim-sdk-by-foursquare-ee879c502088
  privacy: foursquare.com/resources/blog/leadership/consumer-privacy-and-location-data-a-q-and-a-with-our-chief-legal-officer/
---

# Foursquare check-in / FSQ Places — 100M+ POIs across 200+ countries from 16B+ human-verified check-ins + 1B+ photos/tips/reviews + Pilgrim SDK (rebranded Movement SDK Jan 31 2023) always-on passive location engine bundling places DB + stop detection + snap-to-place + Snap-to-Place gradient-boosted decision tree trained on ~12B labeled check-ins + 5× more accurate than polygon methods inside dense indoor spaces + lambda parameter (0-1) reweights training to favor unpopular venues (12% lift in distinct venue detection) + <0.5% daily battery drain via idle-when-stationary + single iOS region-monitoring geofence to wake on motion + probabilistic "signal cloud" represents venue as time-varying shape

## Bar anchors
- **Mid-level (L4/E4):** Polygon-based geofencing on server; no on-device detection; no supervised model.
- **Senior (L5/E5):** Names on-device + GBDT. May or may not articulate lambda parameter, signal cloud, <0.5% battery, or supervised-data competitive moat.
- **Staff+ (L6/E6+):** Names (a) **FSQ Places** ships 100M+ POIs / 200+ countries / 16B+ check-ins / 1B+ photos/tips/reviews; (b) **Pilgrim SDK** (rebranded Movement SDK Jan 31 2023) always-on passive on-device engine; bundles places DB + stop detection + snap-to-place; functions as "super-powered GPS" returning place names/categories not just coordinates; (c) **Snap-to-Place** is gradient-boosted decision tree trained on ~12B labeled check-ins; features lat/long + WiFi triangulation + GPS distortion + Bluetooth + accelerometer + barometer + compass + cell-tower + timestamp + time-of-day popularity ratios; (d) **5× more accurate than polygons** inside dense indoor spaces (malls, multi-tenant buildings); (e) **lambda parameter (0-1)** reweights training to favor unpopular venues; **12% lift in distinct venue detection at minimal accuracy cost** — addresses Zipf's law in check-in distribution; (f) **<0.5% daily battery drain** by entering idle when stationary + single iOS region-monitoring geofence to wake on motion; (g) **probabilistic "signal cloud"** represents each venue as time-varying shape (coffee-shop expands 7-11am) rather than fixed polygon; (h) **background-location consent** dominant failure mode for adoption — SDK contractually requires explicit user opt-in per GDPR/CCPA; (i) **competitive teardown vs Google**: "human-verified check-in lineage" — 16B labeled check-ins are training data Google's unsupervised approach cannot match; (j) **monetization**: sells raw places data + Movement events to ad-tech attribution + last-mile dispatch.

## Canonical decomposition

### Requirements
**Functional:**
- Always-on background place detection (on-device)
- Stop detection (vs traffic-stop disambiguation)
- Snap-to-place returns venue ID
- Geofence enter/exit notifications
- Bulk places API (raw POI data for partners)

**Non-functional:**
- 100M+ POIs / 200+ countries
- 16B+ check-ins (supervised training data)
- <0.5% daily battery drain
- 5× more accurate than polygons indoors

### Core entities
- **POI:** poi_id, name, lat/lon, categories[], signal_cloud (time-varying shape)
- **CheckIn:** user_id, poi_id, timestamp (supervised label)
- **Geofence:** custom polygon or venue-keyed
- **SnapToPlaceModel:** GBDT trained on 12B check-ins

### API
- SDK: `CurrentLocation` callback → {current_venue, matched_geofences[]}
- Places API: `GET /places/search?ll=` (bulk places data)
- Geofence API: `POST /geofences` (custom polygon or venue-keyed)

### HLD
On-device (Pilgrim SDK): always-on passive detector. Idle when stationary; single iOS region-monitoring geofence to wake on motion. On motion, GPS samples → stop detection (distinguishes visit from traffic-stop) → Snap-to-Place GBDT predicts venue from {lat/long, WiFi, Bluetooth, accel, baro, compass, cell-tower, timestamp, time-of-day popularity ratios}. Lambda parameter (0-1) configured at training to reweight unpopular venues. Returns CurrentLocation with current venue + matched geofences.

Server-side: aggregates check-ins to update Snap-to-Place training data + signal-cloud per-venue time-varying shape. Bulk Places API for partners (ad-tech attribution, last-mile dispatch).

Privacy: explicit user opt-in per GDPR/CCPA. Partners must demonstrate user benefit. Anonymization for aggregated analytics.

### Deep dives
1. **Pilgrim SDK + 5×-better-than-polygon snap-to-place.** Always-on passive on-device engine. Places DB + stop detection + snap-to-place bundled. 5× more accurate than polygons inside dense indoor spaces (malls). Returns place names/categories not just coordinates.
2. **Gradient-boosted Snap-to-Place + lambda parameter.** GBDT trained on ~12B labeled check-ins. Features: lat/long + WiFi + GPS distortion + Bluetooth + accel + baro + compass + cell-tower + timestamp + time-of-day popularity ratios. Lambda (0-1) reweights to favor unpopular venues — 12% lift in distinct venue detection at minimal accuracy cost.
3. **<0.5% battery + signal cloud + competitive moat.** <0.5% daily battery via idle when stationary + single iOS region-monitoring geofence to wake on motion. Probabilistic signal cloud represents each venue as time-varying shape. Competitive moat vs Google: 16B human-verified check-ins is supervised data Google's unsupervised approach cannot match.

## Known failure modes
1. *Background-location consent revocation* — GDPR/CCPA gating. Production answer: explicit opt-in language; partners must demonstrate user benefit.
2. *Duplicate POI handling across providers* — Foursquare vs Google vs SafeGraph. Production answer: Placekey as cross-vendor standard identifier.
3. *Indoor positioning accuracy without dense WiFi/Bluetooth landmarks*. Production answer: signal cloud probabilistic model evolves with new check-ins.

## Notes for the coach
- **Asked-plausibly at Foursquare.** Pilgrim SDK + Snap-to-Place + Placemaker docs are canon.
- **Cross-coverage** with `yelp-search` + `google-places` (this archetype; competing place-search platforms). With `geofence-notifications` (this archetype; Pilgrim is the SDK).
- **The lambda parameter (favor unpopular venues) + 12% lift is the canonical Staff+ unlock.** Mid-senior candidates assume uniform-weight training; Staff+ candidates name the explicit Zipf-correction.
- **Adversarial probe: "Apple announces Find My Network competes with Pilgrim. What's Foursquare's response?"** Strong answer: differentiate on supervised-data moat (16B human-verified check-ins) — Apple's Find My is unsupervised crowdsource positioning; Foursquare returns venue + category, Apple returns lat/lon; Pilgrim runs continuously on-device for ambient place-detection, Find My fires on lost-device event. Foursquare doubles down on partner monetization (ad-tech, last-mile) where venue-knowledge > raw position. Weak answer: "we have more places" without the supervised-data + venue-knowledge framing.

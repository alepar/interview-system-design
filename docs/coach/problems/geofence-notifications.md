---
slug: geofence-notifications
archetype: geo-proximity
sources:
  apple_region: developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/RegionMonitoring/RegionMonitoring.html
  android_geofence: developer.android.com/develop/sensors-and-location/location/geofencing
  pilgrim_sdk: docs.foursquare.com/developer/docs/movement-sdk-overview
  pilgrim_geofences: developer.foursquare.com/docs/pilgrim-sdk/geofences
  false_exit: github.com/transistorsoft/react-native-background-geolocation/issues/892
---

# Server-side geofence enter/exit notification at scale — Apple Core Location caps single app at 20 simultaneously monitored regions (forces server-side fence rotation) + iOS region monitoring 20-second dwell hysteresis (user must cross boundary + move away minimum distance + remain ≥20s — eliminates GPS-jitter false positives but adds latency) + Android background batched + lagged (avg 2-3 min, up to 6 min stationary, post-Android-8.0 battery) + Android recommends min radius 100-150m outdoor (smaller exceeds sensor accuracy + thrashing enter/exit) + rolling-window fence registration (N nearest, swap as user moves) + Foursquare Pilgrim always-on passive on-device with 100M-place catalog + dwell-trigger pattern (GEOFENCE_TRANSITION_DWELL Android) + high-accuracy-error sample filtering (discard if horizontalAccuracy > fenceRadius)

## Bar anchors
- **Mid-level (L4/E4):** Designs server-side polygon-in-point check on every location upload; no OS caps; no dwell hysteresis.
- **Senior (L5/E5):** Names iOS region monitoring + Android batching. May or may not articulate 20-fence cap, 20s dwell, rolling-window registration, or Pilgrim on-device.
- **Staff+ (L6/E6+):** Names (a) **iOS 20-fence cap per app** — forces server-side rotation: "register only those regions in the user's immediate vicinity; remove regions that are now farther away and add regions coming up on the user's path"; (b) **iOS 20-second dwell hysteresis**: user must cross boundary + move away minimum distance + remain ≥20 seconds before notification fires — eliminates GPS-jitter false positives but adds latency; (c) **Android background batching**: average 2-3 min delivery, up to 6 min stationary (post-Android-8.0 battery preservation); (d) **Android minimum radius 100-150m for outdoor** GPS/Wi-Fi triangulation — smaller exceeds sensor accuracy + produces thrashing enter/exit; (e) **Rolling-window fence registration** is standard mitigation for OS cap; swap out far fences as user moves; (f) **Foursquare Pilgrim** always-on passive on-device detector with ~100M-place catalog; CurrentLocation object includes current venue + matched geofences without network round-trip on every location update; (g) **Pilgrim 2.2+ adds arbitrary polygon + lat/lon-point fences** alongside venue-keyed fences via Geofence API — bypasses Foursquare POI catalog for custom shapes; (h) **High-accuracy-error samples cause false EXIT**: filter rule = discard samples with `horizontalAccuracy > fenceRadius`; reported case of 17km-accuracy samples triggering false exits; (i) **Dwell-trigger** (`GEOFENCE_TRANSITION_DWELL` Android) only fires after loitering delay — preferred over raw ENTER for high-traffic boundaries (e.g., road through a fence).

## Canonical decomposition

### Requirements
**Functional:**
- Register geofences (server-side catalog)
- Push notification on enter/exit/dwell per fence
- Per-user fence subscription
- Battery-bounded background detection

**Non-functional:**
- iOS 20 fences/app cap
- iOS 20s dwell hysteresis
- Android avg 2-3 min delivery / 6 min stationary
- Android min radius 100-150m outdoor

### Core entities
- **Fence:** fence_id, polygon_or_circle, owner_app, metadata
- **Subscription:** user_id, fence_id, notification_pref
- **UserState:** {current_location, registered_fence_ids[]} (rolling window)
- **CurrentLocationEvent:** {user_id, location, accuracy, current_venue?, matched_fences[]}

### API
- `POST /fence` body={polygon, metadata} (catalog admin)
- `POST /subscribe` body={fence_id, user_id}
- Server push: `POST /fence_event` body={user_id, fence_id, type ∈ {enter, exit, dwell}}

### HLD
Catalog: fences stored server-side with spatial index (R-tree, S2 region-cover, or H3 disk). Per-user subscription matrix maps user → subscribed fences.

Per-user rolling-window registration: server computes N nearest fences in user's vicinity (e.g., N=20 to match iOS cap). Pushes that fence set to client. Client registers with OS region-monitoring API (iOS) or FusedLocationProvider geofencing API (Android).

OS-level detection: device wakes when crossing boundary (iOS) or batches background events (Android avg 2-3 min). Notifies app. App posts fence event to server.

Server-side: receives fence event → validates against user subscription → pushes notification via APNs/FCM.

As user moves, server recomputes nearest-N fences + swaps via unregister-old + register-new. Sample filtering: discard incoming samples with `horizontalAccuracy > fenceRadius` to prevent false EXIT.

For battery-bounded continuous detection (Pilgrim-style alternative): SDK runs always-on passive on-device with 100M-place catalog + custom polygon registry; CurrentLocation callback returns matched fences without network round-trip.

### Deep dives
1. **OS limits + rolling-window registration.** iOS 20-fence cap forces server-side rotation. Android background batching 2-3 min avg. Min radius 100-150m outdoor. Rolling-window: register N nearest fences; swap as user moves.
2. **Hysteresis + dwell-trigger + sample filtering.** iOS 20-second dwell eliminates GPS jitter (cross + move away + ≥20s). Android `DWELL` for high-traffic boundaries. Filter samples where `horizontalAccuracy > fenceRadius` — prevents 17km-accuracy false exits.
3. **Pilgrim on-device 100M-place catalog + Geofence API.** Foursquare Pilgrim runs passive on-device with bundled places DB. CurrentLocation returns venue + matched geofences without network round-trip. Pilgrim 2.2+ adds arbitrary polygon + lat/lon fences via Geofence API.

## Known failure modes
1. *Thrashing enter/exit on small fence* — sensor accuracy < radius. Production answer: min 100-150m; dwell-trigger.
2. *False EXIT from high-accuracy-error sample* (17km accuracy). Production answer: filter if `horizontalAccuracy > fenceRadius`.
3. *iOS 20-fence cap exceeded* by catalog. Production answer: rolling-window swap; server-side fence rotation per user location.

## Notes for the coach
- **Asked-plausibly at Foursquare, Radar, retail-tech (Macy's, Starbucks, Target). Plausibly Apple, Google.** iOS/Android developer docs + Foursquare Pilgrim docs are canon.
- **Cross-coverage** with `foursquare-checkin` (this archetype; Pilgrim is the SDK). With `find-my-friends` (this archetype; iOS region-monitoring primitive shared).
- **The OS-imposed limits (iOS 20 fences + 20s dwell + Android 2-3 min batching) as architectural constraints is the canonical Staff+ unlock.** Mid-senior candidates assume unlimited fences + instant detection; Staff+ candidates name the explicit OS limits as hard constraints.
- **Adversarial probe: "Retail brand wants 10K geofences for store catalog, instant detection. How do you ship it?"** Strong answer: can't register 10K fences directly (iOS 20-cap); server-side rolling-window registers ~20 nearest as user moves; for instant detection (not 2-3min Android avg), use Pilgrim-style always-on passive on-device with bundled places DB; for arbitrary custom shapes use Pilgrim Geofence API. Trade: Pilgrim consumes battery (cap <0.5%/day) and requires user opt-in for Always permission. Weak answer: "register all 10K" without naming OS caps.

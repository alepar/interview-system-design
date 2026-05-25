---
slug: life360
archetype: geo-proximity
sources:
  wikipedia: en.wikipedia.org/wiki/Life360
  gen_z: life360.com/blog/gen-z-location-sharing-study
  crash_detection: support.life360.com/hc/en-us/articles/23053468035095-Crash-Detection-Location-Sharing
  arity: arity.com/move/life360-and-arity-saving-lives-one-detected-crash-at-a-time/
  gizmodo: gizmodo.com/life360-the-company-buying-tile-is-purportedly-sellin-1848171116
  9to5mac: 9to5mac.com/2023/01/09/emergency-sos-crash-detection-false-positives/
  locachange: locachange.com/location-changer/life360-data-analysis/
---

# Life360 — ~83.7M MAU (Q1 2025) + processes "billions of data points daily" (60B+ driving points in 2025 Distracted Driving Report) + Crash Detection requires `Always` location permission (fuses continuous accelerometer + GPS speed) + triggers on vehicle speed ≥25 mph + impact-shape signature + Drive Detection + Crash powered by Arity (Allstate subsidiary, brings to 30M+ MAU, 60% drivers eligible for insurance quotes) + historical monetization $16M/2020 (~20% revenue) from selling precise location to ~12 brokers + $6M Arity partnership + 2024 first-party ad platform pivot targeting 40M US MAU + Tile acquisition ($205-250M, Nov 2021) extends to BLE-beacon asset tracking + documented false-positive crashes (roller-coasters, dropped phones, ~700 false 911s/yr at one sheriff dispatch)

## Bar anchors
- **Mid-level (L4/E4):** Periodic location upload; no Crash Detection; no asset tracking.
- **Senior (L5/E5):** Names continuous ping + Crash Detection. May or may not articulate Arity partnership, false-positive cascade, ad-platform pivot, or Tile acquisition.
- **Staff+ (L6/E6+):** Names (a) **~83.7M MAU (Q1 2025)** up from 48.6M (2022) / 50M (Q2 2023); top-15 US iOS app by DAU; opened ~5×/day per user; (b) **Processes billions of data points daily** — 2025 Distracted Driving Report from 60B+ driving data points; (c) **Crash Detection requires `Always` location permission** (not `While Using`) — fuses continuous accelerometer + GPS speed; triggers on vehicle speed ≥25 mph + impact-shape sensor signature; (d) **Drive Detection + Crash powered by Arity** (Allstate subsidiary); brings Arity Crash Detection to 30M+ MAU; feeds insurance underwriting; up to 60% drivers eligible for Arity quotes; (e) **Historical monetization**: $16M in 2020 (~20% revenue) from selling precise location to ~12 brokers + $6M Arity partnership; stopped selling "precise" data; pivoted 2024 to first-party ad platform targeting 40M US MAU; (f) **Tile acquisition** ($205-250M, Nov 2021) extends from family-graph location to asset/BLE-beacon tracking; analogous to Apple Find My Network but built on non-Apple crowdsource fleet (Life360 + Tile app users); (g) **False-positive crashes**: roller-coasters, skydiving, sudden stops, dropped phones; ~700 false 911s/yr at one sheriff dispatch (Life360 + iPhone combined); confirm-okay flow added; (h) **Continuous-ping model**: pings every few seconds per family member with GPS + Wi-Fi + cell triangulation — battery trade for freshness; user complaints labeled "stalkerware" + class-action litigation; (i) **Tier-gated emergency primitives**: Emergency Dispatch (auto-routes to local PSAP) on Gold/Platinum subscriptions; free tier gets reduced-fidelity Crash Detection.

## Canonical decomposition

### Requirements
**Functional:**
- Family-graph location sharing (Circles)
- Crash Detection + Emergency Dispatch
- Drive Detection (speeding, hard-brake, rapid-accel, phone-usage)
- Tile asset tracking
- SOS alert from member

**Non-functional:**
- ~83.7M MAU; billions of data points daily
- Crash trigger ≥25 mph + impact-shape signature
- Always permission required for Crash Detection
- Continuous-ping every few seconds

### Core entities
- **Circle:** circle_id, members[] (family group)
- **MemberLocation:** {member_id, lat/lon, ts, speed, accelerometer_snapshot}
- **CrashEvent:** {member_id, location, speed_at_impact, signature_class}
- **TileBeacon:** {tile_id, owner_circle, last_seen_by, last_lat/lon}

### API
- Internal: `POST /location_ping` (continuous, every few seconds)
- Internal: `POST /crash_detected` (auto + confirm-okay flow)
- Internal: `POST /sos` (member-initiated)
- `GET /circle/:id/locations` (family view)

### HLD
Location ingest: clients post location continuously (every few seconds) when Always permission granted. Server fuses GPS + Wi-Fi + cell triangulation per ping. Per-member location stored with timestamp + speed + accelerometer snapshot.

Crash Detection: client-side detector watches accelerometer + GPS speed. Triggers on ≥25 mph + impact-shape signature. On trigger, posts to server + opens confirm-okay countdown on device. If user doesn't confirm okay, escalates to Emergency Dispatch (Gold/Platinum tier) → local PSAP via Arity partnership.

Drive Detection (Arity): per-trip ML model classifies speeding, hard-brake, rapid-accel, phone-usage events. Feeds insurance underwriting (60% Life360 drivers eligible for Arity quotes).

Tile asset tracking: Tile beacons advertise BLE; nearby Life360 + Tile users sniff + upload {tile_id, lat/lon, ts}. Owner queries last-known location.

Ad platform (2024 pivot): first-party targeting based on family-graph + location patterns + driving behavior; replaces $16M/yr location-data sales.

### Deep dives
1. **Continuous-ping + Always permission + battery trade.** Pings every few seconds per family member with GPS + Wi-Fi + cell triangulation. Always permission required for Crash Detection. Battery trade for freshness drives "stalkerware" complaints + class-action litigation. Family-graph (smaller, fixed groups) tolerates the model where social-graph (Snap Map billion-edge) would not.
2. **Arity Crash Detection + Drive Detection + insurance flywheel.** Crash triggers ≥25 mph + impact-shape signature. Arity (Allstate subsidiary) powers Drive Detection + Crash to 30M+ MAU. Feeds insurance underwriting; 60% drivers eligible for Arity quotes. Tier-gated: Emergency Dispatch (auto-routes to PSAP) on Gold/Platinum only.
3. **Tile acquisition + ad-platform pivot + false-positive cascade.** Tile $205-250M extends to BLE-beacon asset tracking. 2024 ad-platform pivot replaces $16M/yr location-data sales. False-positive crashes: roller-coasters, dropped phones; ~700 false 911s/yr at one dispatch. Confirm-okay flow added.

## Known failure modes
1. *False-positive crash from roller-coaster / dropped phone* → wasted 911 dispatch. Production answer: confirm-okay flow before escalation; ML model to suppress signature classes.
2. *"Stalkerware" perception* from continuous-ping model. Production answer: explicit consent flow; class-action settlement; transparency reports.
3. *Battery drain on Always permission* — user revokes → Crash Detection fails silently. Production answer: surface in UI "Crash Detection requires Always permission."

## Notes for the coach
- **Plausibly-asked at Life360, Apple (Find My), Google (Find Hub).** Life360 support docs + Arity case study + Gizmodo/Markup reporting are public.
- **Cross-coverage** with `find-my-friends` + `snap-map` (this archetype; competing models). With `bluetooth-beacon-proximity` (Tile uses BLE).
- **The continuous-ping family-tracker + Arity insurance flywheel + ad-platform pivot is the canonical Staff+ unlock.** Mid-senior candidates focus on location-sharing tech; Staff+ candidates name the business-model + insurance-flywheel + monetization-evolution.
- **Adversarial probe: "User says crash detection fired on a roller-coaster. How do you fix?"** Strong answer: add signature-class classifier in ML model — roller-coaster has characteristic vertical + lateral G-pattern + constant-period oscillation NOT matched by impact-shape; train on confirmed crash + confirmed non-crash labeled data; add geo-context (if location is amusement park, suppress); confirm-okay countdown widens user's window to cancel; per-user thresholds based on history (frequent skydivers get higher threshold). Weak answer: "raise the threshold" without naming signature classification.

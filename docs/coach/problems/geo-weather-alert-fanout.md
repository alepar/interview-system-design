---
slug: geo-weather-alert-fanout
archetype: fan-out
sources:
  cap_v12: docs.oasis-open.org/emergency/cap/v1.2/CAP-v1.2-os.html
  wea_geo: fema.gov/emergency-managers/practitioners/integrated-public-alert-warning-system/public/wireless-emergency-alerts/geographic-accuracy-wea
  fcc_wea: fcc.gov/consumers/guides/wireless-emergency-alerts
  cmu_wea: sei.cmu.edu/blog/national-deployment-of-the-wireless-emergency-alerts-system/
  ipaws: fema.gov/emergency-managers/practitioners/integrated-public-alert-warning-system
  shakealert_latency: usgs.gov/data/data-release-latency-testing-wireless-emergency-alerts-intended-shakealert-earthquake-early-warning-system-west
  japan_eew: earthquakenearme.com/en/blog/japan/earthquake-early-warning-system
  nws_polygon: weather.gov/media/pah/WeatherEducation/stormbased.pdf
  ipaws_genasys: genasys.com/blog/ipaws-wea-fema-the-genasys-solution/
---

# Geo weather/emergency alert fan-out — CAP v1.2 OASIS XML envelope (Alert→Info→Area, 3 severity axes × 5-value scales) + WEA cellular cell-broadcast (one-to-many not unicast SMS, FIPS county-level base) + WEA enhanced 100% inside polygon / 0% >528ft (1/10 mile) outside via WEA 3.0 handset GPS filtering + 3 priority tiers (Presidential / AMBER / Imminent Threat) + 90-char text limit + FEMA IPAWS-OPEN central broker (single CAP-in → multi-channel out: EAS, CMAS/WEA, NOAA Weather Radio, IPAWS-API) + ShakeAlert app <5s vs WEA-IPAWS 6-12s+ + Japan JMA EEW 4,235 seismometers / 5-8s total / 100M+ subscribers + NWS storm-based polygon warnings since 2007

## Bar anchors
- **Mid-level (L4/E4):** Designs IP-based push with lat/lng filter at server.
- **Senior (L5/E5):** Names cell-broadcast + CAP. May or may not articulate handset-side polygon eval, 3 priority tiers, IPAWS multi-channel routing, or app-vs-WEA latency trade.
- **Staff+ (L6/E6+):** Names (a) **CAP v1.2** OASIS XML envelope: Alert → Info (per-language) → Area (per-polygon); 3 severity axes (Urgency / Severity / Certainty) on 5-value enumerated scales; polygon WGS-84 lat/long pairs (min 4 points, first=last); Circle = centerpoint + radius km; Geocode = SAME/FIPS/ZIP for legacy interop; (b) **WEA cellular cell-broadcast** — one-to-many not unicast SMS; FIPS county-level base granularity; enhanced 100% inside polygon / 0% >528ft outside via WEA 3.0 handset GPS filtering; (c) **3 priority tiers**: Presidential (cannot opt-out), AMBER, Imminent Threats; **90-character text limit**; (d) **FEMA IPAWS-OPEN central broker**: alerting authorities post signed CAP messages; IPAWS fans out to EAS broadcast, CMAS/WEA cellular, NOAA Weather Radio, IPAWS-API consumers — single CAP-in → multi-channel out; (e) **ShakeAlert latency**: app-over-cellular/WiFi typically <5s; WEA-via-IPAWS median 6-12s, can exceed 10s — WEA earthquake alerts often arrive AFTER strong shaking at epicenter but before shaking at distant cities; (f) **Japan JMA EEW**: 4,235 seismometers; magnitude/location calc within ~1s of P-wave detection; cellular cell-broadcast warnings in 5-8s total to 100M+ subscribers; (g) **NWS storm-based polygon warnings** since Oct 2007: warned area defined by lat/long polygon (not per-county); flows NWS office → IPAWS → tagged for WEA → carriers broadcast → handsets evaluate location locally; (h) **WEA 3.0 polygon-on-handset** — majority of handsets don't yet support 3.0; real-world deployment assumes tower-overshoot fallback + significant false-positive geography.

## Canonical decomposition

### Requirements
**Functional:**
- Authoring tool produces CAP v1.2 message
- IPAWS broker fans out to multi-channel
- WEA cellular cell-broadcast to FIPS county / polygon
- App-based geo-targeted push (faster than WEA)
- 3 priority tiers; 90-char text for WEA

**Non-functional:**
- ShakeAlert: app <5s; WEA-IPAWS 6-12s+
- Japan EEW: 4,235 seismometers / 5-8s / 100M+ subscribers
- Polygon WGS-84 min 4 points (first=last)

### Core entities
- **CAPMessage:** XML envelope with `<info>` per language + `<area>` per polygon
- **Polygon:** WGS-84 lat/long pairs, first=last
- **SeverityAxes:** {urgency, severity, certainty} on 5-value enumerated scales
- **DeliveryChannel:** {EAS, CMAS_WEA, NOAA_WR, IPAWS_API_consumer}

### API
- IPAWS: `POST /cap` body=<signed CAP XML> (alerting authority)
- IPAWS-API: `GET /alerts?bbox=<...>` (third-party consumer)
- App: APNs/FCM push to geo-targeted device tokens

### HLD
Authoring: alerting authority (NWS / state / local) composes CAP v1.2 XML with polygon + severity + 90-char headline; signs.

IPAWS-OPEN broker: validates against CAP XSD + authority allowlist; fans out to multiple channels:
- **EAS broadcast** (radio/TV)
- **CMAS/WEA cellular** (cell-broadcast to participating carriers)
- **NOAA Weather Radio**
- **IPAWS-API consumers** (apps, third-party)

Cellular cell-broadcast: carriers broadcast CAP from cells covering polygon (FIPS county-level base). Handsets with WEA 3.0 use GPS to filter against polygon. Pre-WEA-3.0 handsets receive tower-broadcast unconditionally.

App-based path (Genasys, FEMA app, ShakeAlert app): IPAWS-API consumer fetches CAP → server-side geo-match against user-registered location → APNs/FCM push. <5s typical (faster than WEA-IPAWS 6-12s).

### Deep dives
1. **CAP v1.2 envelope + WEA cell-broadcast vs IP push.** Standardized XML across NWS/FEMA/WMO. Polygon/Circle/Geocode. 3 severity axes × 5-value scales. WEA cell-broadcast one-to-many — every WEA-capable phone camped on participating tower receives without IP-level addressing. Overshoot inherent because tower coverage doesn't align with polygons.
2. **Handset-side polygon evaluation + 3 tiers + 90-char.** Cell broadcast includes polygon; handset GPS decides display. Regulatory 100% inside / 0% >528ft outside. 3 tiers: Presidential (no opt-out), AMBER, Imminent. 90-char carries topic + area + expiry + action + sender. WEA 3.0 majority not yet supported → fallback to tower-overshoot.
3. **FEMA IPAWS-OPEN central broker.** Single CAP-in → multi-channel out (EAS / CMAS/WEA / NOAA / IPAWS-API). ShakeAlert: app <5s vs WEA-IPAWS 6-12s+; WEA earthquake alerts arrive after shaking at epicenter but before at distant cities. Japan JMA EEW: 5-8s total to 100M+ via cell-broadcast.

## Known failure modes
1. *Tower overshoot* — WEA broadcast beyond polygon. Production answer: WEA 3.0 handset GPS filtering; majority don't yet support; real-world accepts overshoot.
2. *Latency for earthquake alerts* — WEA-IPAWS 6-12s often after shaking at epicenter. Production answer: app-based <5s for nearer detection; WEA covers distant cities.
3. *CAP message complexity* — 3 severity axes + polygon + geocode must align. Production answer: pre-flight XSD validation; tooling for editor authoring.

## Notes for the coach
- **Asked-plausibly at government / weather / public-safety vendors (Everbridge, OnSolve, Genasys).** OASIS CAP + FEMA/FCC WEA docs + USGS ShakeAlert latency + JMA EEW + NWS docs are public.
- **Cross-coverage** with `breaking-news-fanout` (priority push channels). With messaging `push-notification` (parallel IP-based delivery).
- **The single-CAP-in → multi-channel-out via IPAWS + cell-broadcast vs IP-push trade is the canonical Staff+ unlock.** Mid-senior candidates draw "send push to all in radius"; Staff+ candidates name CAP envelope + cell-broadcast substrate + handset-side polygon evaluation.
- **Adversarial probe: "Magnitude 7 earthquake on San Andreas. 20M Bay Area residents. How fast does an alert reach them?"** Strong answer: ShakeAlert dedicated app via cellular/WiFi <5s for distant cities (Bay Area would be inside shaking radius — alert arrives after shaking starts there); WEA-via-IPAWS 6-12s median (after-shaking at epicenter but before at distant cities like Sacramento); JMA-style 4,235 seismometers + per-region cell-broadcast yields 5-8s total. Production answer: dual-substrate — app for foreground users + WEA cell-broadcast for everyone else. Weak answer: "send a push" without addressing the after-shaking-at-epicenter latency.

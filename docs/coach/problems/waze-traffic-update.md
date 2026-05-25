---
slug: waze-traffic-update
archetype: geo-proximity
sources:
  idealink: idealink.tech/blog/how-to-develop-app-like-waze-ultimate-guide
  waze_search: support.google.com/waze/answer/11942300
  ccp_factsheet: web-assets.waze.com/partners/ccp/WAZE-CCP-Factsheet.pdf
  cifs: support.google.com/waze/partners/answer/10618035
  verification: sciencedirect.com/science/article/pii/S2590198219300193
  emergency_detection: arxiv.org/pdf/2011.05440
  poa_selfish: arxiv.org/pdf/2501.03055
  algorithm_watch: algorithmwatch.org/en/navigation-systems-small-towns/
  harvard_crowdsourcing: d3.harvard.edu/platform-rctom/submission/how-crowdsourcing-is-changing-the-waze-we-drive/
---

# Waze traffic update — ~140-180M MAU contributing GPS speed + active incident reports + A* shortest-path with continuously-updated edge weights from historical + live reports + Connected Citizens Program (CCP) bidirectional partner feed (city/DOT pushes closures + receives traffic telemetry, WARP ingests into cloud warehouses) + CIFS (Closure and Incident Feed Specification) as canonical partner schema + report verification documented (33% confirmed primary, 5% false alarm, 23% false disabled-vehicle in academic study) + DBSCAN clustering + Bayesian/ML classifiers to deduplicate co-located reports + selfish-routing Price of Anarchy = 4 (linear latency) / (d+1)^(d+1) (polynomial degree d) + documented "wreaking havoc on small towns" externality + crowdsourced base map via Map Editor community

## Bar anchors
- **Mid-level (L4/E4):** Simple routing service; no crowdsourced reports; no partner integration.
- **Senior (L5/E5):** Names A* + crowdsourced reports. May or may not articulate CCP partner feeds, CIFS schema, report-verification ML, or selfish-routing externality.
- **Staff+ (L6/E6+):** Names (a) **~140-180M MAU** contributing GPS speed + active incident reports (accidents, police, hazards, jams, potholes); smaller user base than Google Maps but far higher participation rate per user; (b) **A* shortest-path with continuously-updated edge weights** from historical + live reports; alternative routes ranked by road/area restrictions → user prefs → road type → ETA → length; (c) **Connected Citizens Program (CCP)**: bidirectional partner feed — city/DOT pushes closures + incidents, Waze returns aggregated traffic/jam telemetry; **WARP** (Waze Analytics Relational-database Platform) ingests CCP feeds into cloud warehouses; (d) **CIFS** (Closure and Incident Feed Specification) as canonical partner submission schema; partners with ESRI/WZDx/Datex2 feeds undergo manual review — decouples crowdsourced from authoritative; (e) **Report verification documented**: of 40 Waze crash reports vs video ground truth, only 13 (33%) confirmed primary; 2 (5%) false alarms; disabled-vehicle: 23% false alarms; (f) **DBSCAN clustering + Bayesian/ML classifiers** dedupe co-located reports + predict actual incident; predictors: time-of-day, road type, report rating, crash type; (g) **Selfish-routing failure**: shortest-time-for-me worsens system congestion vs social optimum. **Price of Anarchy = 4 for linear latency / (d+1)^(d+1) for polynomial degree d**; selective information disclosure proposed to bring <2; (h) **"Wreaking havoc on small towns"** — Waze rerouting commuter traffic through residential streets not engineered for volume; (i) **Crowdsourced base map** via volunteer Map Editor community (distinct from Google Maps's authoritative-source base map) → higher base-graph mutation rate + moderation workflow.

## Canonical decomposition

### Requirements
**Functional:**
- Routing with live traffic + crowdsourced incidents
- Active incident reporting (accident, police, hazard, jam)
- CCP partner feed (city/DOT)
- Map Editor community workflow

**Non-functional:**
- ~140-180M MAU
- A* with continuously-updated edge weights
- 33% confirmed-primary report rate (5% false alarm)
- Price of Anarchy = 4 linear / (d+1)^(d+1) polynomial

### Core entities
- **RoadGraph:** crowdsourced base + authoritative CCP overlay
- **IncidentReport:** {user_id, location, type, ts, rating}
- **CCPFeed:** {agency_id, closures[], incidents[]} (CIFS schema)
- **EdgeWeight:** {road_id, current_speed, historical_pattern}

### API
- `GET /route?origin=&destination=` → polyline + ETA
- Client app: `POST /incident` body={location, type}
- Partner: `POST /ccp` body=<CIFS payload>
- Map Editor: `POST /map_edit` body=<edit_op>

### HLD
Routing: A* over road graph with edge weights = current speed (from probe data + live reports + CCP). Alternative routes ranked by road/area restrictions → user prefs → road type → ETA → length.

Probe data + reports: client app continuously uploads GPS speed; active incident reports via UI. DBSCAN clusters co-located reports into candidate incidents. Bayesian/ML classifier predicts real-vs-false using predictors (time-of-day, road type, report rating, crash type).

CCP partner feed: agencies POST CIFS-formatted closures + incidents. WARP ingests + validates. ESRI/WZDx/Datex2 partner feeds undergo manual review. Decouples authoritative data from crowdsourced.

Map Editor community: volunteer moderation workflow for base-map edits. Higher mutation rate than Google Maps's authoritative-source base.

### Deep dives
1. **A* + CCP partner feeds + CIFS schema.** A* shortest-path with continuously-updated edge weights from historical + live reports. CCP: bidirectional partner feed — agencies push, Waze returns aggregated telemetry. CIFS canonical schema. Decouples crowdsourced reports from authoritative agency data.
2. **Report verification + DBSCAN + Bayesian fusion.** Academic ground truth: 33% confirmed / 5% false. Workflow: DBSCAN clusters co-located reports → Bayesian/ML classifies real vs false. Predictors: time-of-day, road type, report rating, crash type.
3. **Selfish-routing externality + Price of Anarchy.** PoA = 4 for linear latency / (d+1)^(d+1) for polynomial degree d. Selective information disclosure proposed to bring <2. Documented "wreaking havoc on small towns" → AlgorithmWatch coverage. Architectural failure with no per-user tech fix.

## Known failure modes
1. *False/stale incident reports* — 5% false-alarm rate. Production answer: DBSCAN + ML classifier + report-rating up/down via downstream users.
2. *Selfish routing worsens congestion* — Price of Anarchy. Production answer: selective info disclosure (acceptable PoA <2) but commercial-incentive misaligned.
3. *Crowdsourced map vandalism* — Map Editor community moderation workflow. Production answer: edit-velocity rate-limits + review queue.

## Notes for the coach
- **Asked-plausibly at Waze, Google Maps, smaller traffic platforms.** Waze docs + CCP factsheet + academic papers on verification + Price-of-Anarchy literature are public.
- **Cross-coverage** with `google-maps-routing` (this archetype; centralized authoritative alternative). With fan-out #2 `geo-weather-alert-fanout` (CAP-style partner feed analog).
- **The selfish-routing externality + Price of Anarchy is the canonical Staff+ unlock differentiating Waze from Google Maps.** Mid-senior candidates focus on crowdsourcing; Staff+ candidates name the social-cost externality + selective-disclosure mitigation.
- **Adversarial probe: "False crash report claims I-95 closed. How does the system reject it?"** Strong answer: DBSCAN clusters → single report is outlier (no co-located reports → low confidence); Bayesian classifier weighs predictors (time-of-day, road type matches accident-prone profile? user rating?); thresholds prevent single-report incident from updating edge weights; downstream user "Not There" votes increase report rating; high-confidence override requires N corroborating reports OR CCP authoritative feed. Weak answer: "we trust the report" without naming the dedup + classifier + corroboration steps.

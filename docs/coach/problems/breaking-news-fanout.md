---
slug: breaking-news-fanout
archetype: fan-out
sources:
  bbc_25T: process-one.net/blog/breaking-25-trillion-notifications-for-the-bbc/
  fcm_throttling: firebase.google.com/docs/cloud-messaging/throttling-and-quotas
  fcm_delivery: firebase.google.com/docs/cloud-messaging/understand-delivery
  fema_wea_geo: fema.gov/emergency-managers/practitioners/integrated-public-alert-warning-system/public/wireless-emergency-alerts/geographic-accuracy-wea
  cmu_wea: sei.cmu.edu/blog/national-deployment-of-the-wireless-emergency-alerts-system/
  cap_v12: vlab.noaa.gov/web/nws-common-alerting-protocol/cap-documentation
---

# Breaking news push fan-out — BBC ProcessOne 2.5M notifs/min baseline / 150M peak day / 25T cumulative + fine-grained topic subscriptions per sport/team + event-type with server-side dedup across overlapping topics + speed as competitive differentiator + FCM 1,000 concurrent fanouts/project hard cap + 10K QPS topic-send + 28-day TTL max + WEA cellular cell-broadcast at FIPS county-level base + 100%/0% inside/528ft polygon via WEA 3.0 GPS filtering + CAP v1.2 polygon + 3 priority tiers + 90-char text + IPAWS multi-channel out

## Bar anchors
- **Mid-level (L4/E4):** Designs FCM/APNs send-to-all without topic dedup or TTL.
- **Senior (L5/E5):** Names topic subscriptions + rate-limits. May or may not articulate FCM concurrent-fanout caps, TTL settings, WEA cell-broadcast, or CAP envelope.
- **Staff+ (L6/E6+):** Names (a) **BBC ProcessOne scale**: 2.5M notifs/min baseline, 150M peak day, 25T cumulative over 5 years; (b) **fine-grained topic subscriptions** per sport/team + event-type with **server-side dedup so user subscribed to overlapping topics gets ONE notification**; (c) **speed as competitive differentiator** ("most impact = first push"); (d) **FCM concurrent cap**: 1,000 fanouts/project; ~10K QPS topic-send (not guaranteed); 2,000 topic subs/app instance max; 3K QPS topic-subscription rate; **TTL** up to 28 days (default 4 weeks); for breaking news set SHORT TTL (minutes); (e) **WEA cellular cell-broadcast** — one-to-many not unicast SMS; FIPS county-level base; **enhanced 100% inside polygon / 0% >528ft outside** via WEA 3.0 GPS filtering; (f) **3 priority tiers**: Presidential (cannot opt-out), AMBER, Imminent Threats; **90-character text limit**; (g) **CAP v1.2 OASIS** XML envelope with polygon + SAME/UGC area codes; (h) **FEMA IPAWS-OPEN central broker**: single CAP-in → multi-channel out (EAS broadcast, CMAS/WEA cellular, NOAA Weather Radio, IPAWS-API consumers).

## Canonical decomposition

### Requirements
**Functional:**
- Editorial publish → push fan-out
- Topic subscriptions (sport/team/event-type granularity)
- Geo-targeted broadcast (CAP-formatted)
- Multi-channel routing (push / EAS / cell-broadcast)

**Non-functional:**
- 2.5M notifs/min baseline; 150M peak day
- FCM: 1K concurrent fanouts/project; ~10K QPS topic-send; 28-day TTL max
- WEA: 90-char text; FIPS county base; WEA 3.0 polygon

### Core entities
- **Topic:** topic_id (e.g., "sport:soccer:team:liverpool:event:goal"), description
- **Subscription:** device_token, topic_id
- **Alert:** alert_id, payload, ttl, priority, target_topics[] / target_polygon
- **CAPMessage:** XML envelope with Info{Area{polygon, geocode}}

### API
- `POST /alerts` body={payload, topics[]|polygon, priority, ttl}
- Internal: `subscribe(device, topic)`
- IPAWS: `POST /cap` body=<signed CAP XML>

### HLD
Editorial path: editor publishes → Alert Service computes target subscriber set: union of all overlapping topics → dedup so each device gets ONE notification per logical event. Splits across FCM projects (multi-project sharding to bypass 1K concurrent-fanout cap). Submits via per-project worker pool with rate-limit-aware backpressure.

Topic resolution: Subscription store keyed by topic_id; FCM topic API or self-managed list. For fine-grained sport/team/event-type topics, server-side dedup at fan-out time (set-merge on subscription lists per overlapping topic).

WEA path: editor authors CAP v1.2 XML → signs → POSTs to IPAWS-OPEN. IPAWS validates + fans out to EAS broadcast, CMAS/WEA cellular, NOAA Weather Radio, IPAWS-API consumers. Cellular cell-broadcast at FIPS county-level base; phones with WEA 3.0 use GPS to filter against polygon.

### Deep dives
1. **BBC ProcessOne 25T-notification scale + topic-subscription dedup.** Fine-grained per-sport-per-team-per-event-type topics. Server-side dedup: user subscribed to overlapping topics gets ONE per logical event. Speed as differentiator — sub-second budget from headline-publish to APNs/FCM submission.
2. **FCM limits + TTL.** Concurrent cap 1K/project; ~10K QPS topic-send; 2K topic subs/app instance; 3K QPS topic-sub rate. TTL up to 28 days max (default 4 weeks); for breaking news set SHORT TTL (minutes) so stale alerts don't surface on offline-device reconnect.
3. **WEA cell-broadcast + CAP v1.2.** Cellular cell-broadcast (not unicast) — every WEA-capable phone camped on participating tower receives. **Overshoot inherent** because tower coverage doesn't align with polygons. WEA 3.0 polygon-on-handset GPS filter; majority handsets don't yet support. 3 tiers / 90-char text. CAP v1.2 standardized XML envelope across NWS/FEMA/WMO — single editorial push → IPAWS → multi-channel.

## Known failure modes
1. *Stale notification on offline-device reconnect* — push delivered hours after relevance. Production answer: short TTL (minutes) for breaking news; FCM/APNs honor TTL.
2. *Cell-broadcast overshoot* — towers extend beyond polygon. Production answer: WEA 3.0 GPS filtering; majority don't yet support; accept overshoot.
3. *FCM concurrent-fanout cap saturation on viral event* — 1K cap/project. Production answer: multi-project sharding; pre-event capacity warmup; priority queue.

## Notes for the coach
- **Asked-plausibly at BBC, NYT, WSJ, news platforms.** ProcessOne blog + FCM docs + FEMA/FCC WEA docs + CAP spec are public.
- **Cross-coverage** with messaging `push-notification` (APNs/FCM gateway). With `geo-weather-alert-fanout` (cell-broadcast substrate).
- **The single-CAP-in → multi-channel-out via IPAWS is the canonical Staff+ unlock for the alerts variant.** For the news variant, the dedup-across-overlapping-topics is the unlock.
- **Adversarial probe: "Liverpool wins the Premier League at midnight. 50M subscribers across overlapping topics (sport:soccer, team:liverpool, league:epl, event:championship). How many pushes go out?"** Strong answer: server-side dedup = 50M unique device-token pushes (NOT 200M); rate-limited via multi-project FCM sharding to bypass 1K concurrent-fanout cap; short TTL so reconnects past 1h don't fire stale. Weak answer: "we'd queue them" without naming the dedup-at-fan-out step.

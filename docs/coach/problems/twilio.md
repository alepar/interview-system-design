---
slug: twilio
archetype: infra-primitives
sources:
  twilio_messaging_api: twilio.com/en-us/messaging/apis/programmable-messaging-api
  twilio_docs: twilio.com/docs
  a2p_10dlc_carrier_tiers: CTIA + US carrier A2P 10DLC best-practice publications
---

# Twilio — programmable messaging gateway + SIP voice termination

## Bar anchors
- **Mid-level (L4/E4):** Treats Twilio as "REST API that sends SMS." Doesn't address carrier connection state, throughput tiers, or fraud detection.
- **Senior (L5/E5):** Names SMPP for SMS, SIP for voice, multi-carrier routing. Discusses opt-in / opt-out. May or may not address A2P 10DLC throughput tiers, SMS-pumping fraud, or the signaling/media plane split for voice.
- **Staff+ (L6/E6+):** Drives proactively. Articulates (a) **SMPP gateway architecture** — receives MO SMS from carriers over dedicated SMPP connections; outbound MT flows through destination's carrier; per-route average depth 4 providers; (b) **A2P 10DLC throughput tiers** — T-Mobile 4,500-6,000 MPM; Verizon 1,500-3,000 MPM; AT&T 1,200-2,400 MPM; per-carrier shaping queues; trust-score gating; (c) **SIP gateway for voice** with **signaling/media plane split** — SIP servers stateful (INVITE/ACK/BYE); media servers stateless RTP/SRTP forwarding; scale independently; (d) **SMS pumping fraud detection** (premium-rate-number triggering attack); (e) **automatic rerouting every 75s** (Twilio's published Super Network capability). Stretch (Sr Staff bar): articulates **Messaging Services bundling** (senders + routes + compliance lists); per-account idempotency keys for retry safety.

## Canonical decomposition

### Requirements
**Functional:**
- REST API for SMS + voice; webhook callbacks for inbound + status
- Route through thousands of carrier connections globally (180+ countries)
- Compliance: 10DLC (US), DLT (India), short codes, alphanumeric senders, opt-out keywords
- Fraud detection: SMS pumping (premium-rate triggering)
- Voice: SIP termination to PSTN with TwiML orchestration
- Phone number portability (2-4 week simple, 6-8 complex)

**Non-functional (with numbers):**
- 193B+ messages/year through platform
- 99.95% SLA; 180+ countries; 4,800+ carrier connections
- A2P 10DLC: T-Mobile 4,500-6,000 MPM; Verizon 1,500-3,000 MPM; AT&T 1,200-2,400 MPM
- Automatic rerouting every 75s for outage avoidance
- SMS payload: 160 chars GSM-7 / 70 UCS-2

### Core entities
- **Account:** customer account; opt-out list; messaging-services memberships; rate-limit policy
- **MessagingService:** bundle of senders + routes + compliance; sender-selection logic
- **CarrierRoute:** per-(destination, carrier) SMPP connection; throughput cap; DLR feedback channel
- **MessageEnvelope:** (message_sid, account, sender, recipient, body, status, idempotency_key)
- **DLR:** delivery receipt from carrier; matched to message_sid; updates status

### API
- SMS: `POST /Messages` body=(To, From, Body) → MessageSid + status webhook eventually
- Voice: `POST /Calls` body=(To, From, Url) → Call orchestrated via TwiML at Url
- SIP: customer's IP-PBX sends INVITE to `sip:{account}.sip.twilio.com`
- Webhooks: customer registers callback URLs for inbound + status

### HLD
**API edge** terminates customer REST requests; validates account + idempotency_key (dedup retries); enqueues for routing. **Routing service** does number-lookup (HLR/LRN to identify destination carrier); picks an SMPP route to that carrier from the **carrier-route pool** (4,800+ connections, multi-provider — Twilio may not have direct interconnect; goes through intermediaries); sends SMPP `SUBMIT_SM`; on response, returns MessageSid to customer. **Per-carrier shaping queues** rate-limit per A2P 10DLC tier (and per brand for US). Customer's **opt-out list** is checked synchronously before send — sending to opted-out recipient is a compliance violation (rejects with explicit reason). **DLR pipeline**: carriers send back DELIVER_SM with delivery status; routing service matches by MessageSid; updates status; fires customer's status webhook. **Voice plane**: SIP gateway terminates SIP INVITEs from customer IP-PBX (auth via digest, IP allowlist, or X.509 client cert); routes call via TwiML callback (REST callback orchestrates the call — `<Dial>`, `<Say>`, `<Gather>` verbs); media servers handle RTP/SRTP packet forwarding to PSTN via carrier interconnects. **Signaling (SIP) and media (RTP)** scale independently.

### Deep dives
1. **SMPP gateway + carrier route optimization.** Customer `POST /Messages` → API edge → routing service → SMPP `SUBMIT_SM` to destination carrier (via 4-deep average route through intermediaries). Carrier returns SMPP response with message_id. **DLR matching**: carrier eventually returns DELIVER_SM with delivery status; routing service matches by stored mapping (Twilio's internal_msg_id ↔ carrier_msg_id); updates message status; fires customer webhook. **Route selection** = real-time optimization across (cost × delivery rate × latency); analogous to BGP routing. **Auto-rerouting every 75s**: per-route delivery-rate SLI; on degradation, auto-failover to alternate route; per-corridor canary test messages to detect silent blackholes early.

2. **A2P 10DLC throughput gating + multi-carrier shaping.** US A2P messaging is rate-limited per-(destination-carrier, brand, campaign). Per-carrier shaping queues are mandatory: separate outbound queue per destination-carrier; rate-limit each per the carrier's tier (T-Mobile 4,500-6,000 MPM; Verizon 1,500-3,000 MPM; AT&T 1,200-2,400 MPM defaults). Spillover to alternate brands (a customer with multiple registered brands can balance). Trust-score gating: brands with high spam complaints get throttled; brands with clean reputation get higher tiers. Carriers monitor differently: Verizon per-second, AT&T per-campaign-per-minute, T-Mobile per-brand-per-day — Twilio aggregates and presents a unified rate-limit API.

3. **SIP gateway for voice — signaling/media plane split.** Customer's IP-PBX sends `INVITE` to Twilio's SIP Domain (e.g., `customer.sip.twilio.com`); SIP gateway validates auth; routes call via TwiML. **Signaling plane** = SIP servers (stateful — track INVITE/ACK/BYE exchanges); CPU-bound on signaling rate. **Media plane** = media servers handling RTP/SRTP packet forwarding (high bw, low CPU). The two planes scale independently. **DTMF detection** for IVR: media servers detect DTMF tones in RTP stream, signal back to TwiML interpreter. **E911 routing**: emergency calls route to nearest PSAP (Public Safety Answering Point) via E911 SIP trunks; Twilio's E911 product handles the lookup + routing.

## Known failure modes
1. **Carrier route blackhole** (carrier silently drops messages; customer's delivery rate plummets; reputation suffers). Production answer: per-route DLR-rate SLI; auto-failover within 75s; per-corridor canary test messages; for affected brands, reputation impact mitigation.

2. **A2P throughput saturation under viral spike** (customer's OTP fan-out exceeds destination carrier's MPM cap; messages queue at Twilio; latency spikes). Production answer: rate-limit at API edge with informative 429 + Retry-After; multi-brand pooling for high-volume customers; priority queue for time-sensitive (OTP) vs deferrable (marketing); for emergency OTP, bypass shaping queue with explicit per-account budget.

3. **Number-porting losing-carrier delays** (losing carrier delays LOA; customer's service breaks during port). Production answer: portability-check API to estimate timeline up front; status-tracking dashboard; escalation path with losing-carrier account team; for time-sensitive ports, expedited (subject to losing-carrier policy).

## Notes for the coach
- **Asked-confirmed at Twilio** (their interview loops include programmable-messaging design). **Plausibly-asked** at any CPaaS (Vonage, Sinch, MessageBird, Plivo) and companies running internal SMS for OTPs (banks, ride-share).
- **The A2P 10DLC throughput numbers are the canonical anchor for US SMS.** Candidates who quote T-Mobile 4,500-6,000 / Verizon 1,500-3,000 / AT&T 1,200-2,400 MPM demonstrate carrier-tier awareness; candidates who say "we rate-limit" without per-carrier specificity miss the regulatory layer.
- **The signaling/media plane split is the Staff+ depth probe for voice.** Candidates who articulate "SIP servers stateful + media servers stateless, scale independently" demonstrate VoIP literacy.
- **Adversarial probe: "we're under SMS-pumping attack — 10M premium-rate OTPs in one hour. What now?"** Strong answer: rate-limit at API edge per account; ML detection of destination-prefix clustering + sudden volume; per-account budget cap with alert; Twilio Verify product as an anti-pumping wrapper. Weak answer: "we block fraud" without the specific detection mechanism.

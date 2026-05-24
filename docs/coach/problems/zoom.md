---
slug: zoom
archetype: realtime-messaging
sources:
  zoom_geographic_routing: zoom.us/docs (Zoom Tech Blog) "How Zoom Optimizes Connections via Geographic-Aware Routing"
  scallop_paper: arxiv.org/abs/2503.11649 (Scallop SDN measurement of Zoom)
  webrtc_rfc8825: datatracker.ietf.org/doc/rfc8825
---

# Zoom — multi-party video conferencing with distributed SFU (MMR) at 1000-participant calls

## Bar anchors
- **Mid-level (L4/E4):** Treats video conferencing as "WebRTC for everyone." Doesn't differentiate SFU vs MCU vs mesh. No capacity model.
- **Senior (L5/E5):** Names SFU, simulcast, NAT traversal via STUN/TURN, opt-in E2EE. May or may not address the Multimedia Router (MMR) distributed-SFU pattern, FEC for packet-loss tolerance, or per-meeting sharding.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the **Multimedia Router (MMR) distinction**: Zoom's "distributed SFU" where each client has one uplink + multiple downlinks, but bandwidth pressure spreads across the fleet via shortest-path routing between any two clients (rather than one big server per meeting). Cites Scallop paper (arxiv 2503.11649) verifying Zoom *"forwards exact RTP copies with rewritten headers"* — SDN-like behavior. Articulates **simulcast vs SVC** trade-off (simulcast = sender encodes N independent layers; SVC = sender encodes one stream with temporal/spatial layers droppable inline). Names **packet-loss tolerance up to 20-30%** via FEC + retransmit; **jitter buffer sizing** per receiver. Articulates **NAT traversal at enterprise scale** (TCP fallback over 443, HTTP-CONNECT through proxies; no ICE because clients always connect to router). Stretch (Sr Staff bar): articulates **E2EE trade-off** (opt-in 2020; disables cloud recording and dial-in because mixers need plaintext access).

## Canonical decomposition

### Requirements
**Functional:**
- Up to 1000 interactive participants per meeting (vs Teams 300, Meet 500)
- Sub-200ms one-way audio latency; 200-300ms video
- Adaptive video across 5+ resolutions (180p / 360p / 720p / 1080p)
- Screen-share, breakout rooms, waiting room, recording
- Opt-in E2EE (2020+) — trade-off: disables cloud recording and dial-in
- Work behind enterprise NAT/firewalls

**Non-functional (with numbers):**
- 1000 participants/meeting max interactive
- One-way audio: 150-200ms; video: 200-300ms
- Packet-loss tolerance: graceful up to 30% via FEC + retransmit
- Per-call bandwidth: 600 kbps (HD video) to 3 Mbps (1080p + screen share)
- Codecs: Opus / Zoom proprietary; H.264 / H.265, AV1 on supported clients

### Core entities
- **Meeting:** meeting_id, participants[], host, recording_enabled, e2ee_enabled
- **MMRNode:** distributed SFU node; holds per-meeting state replicated across nodes
- **Participant:** client_id, uplink_stream, downlink_simulcast_layer_selection[], rtcp_reports
- **SimulcastStream:** per-sender 2-3 quality layers; SFU picks per-receiver
- **JitterBuffer:** per-receiver adaptive buffer; PLC for lost packets

### API
- Signaling: client connects to Zoom signaling, joins meeting via meeting_id; receives MMR endpoint
- Media: client opens UDP socket to MMR node (or TCP 443 fallback); RTP/SRTP
- Internal: MMR-to-MMR routing for cross-node participant streams

### HLD
**Signaling layer** terminates client signaling; assigns participant to nearest MMR node in the meeting's MMR cluster. **MMR (Multimedia Router) cluster** is a distributed SFU: per-meeting state replicated across multiple MMR nodes (so any node can route any participant's stream); **shortest-path routing** between any two participants — if A and B are both connected to MMR-east, traffic stays local; if A is on MMR-east and B on MMR-west, MMR-to-MMR forward. **Simulcast**: sender encodes 2-3 layers (e.g., 180p/360p/720p); SFU picks per-receiver based on RTCP feedback (slow receiver gets low layer; fast receiver gets high layer). **Audio mixing**: typically pure forward (each participant hears all others as separate streams; client mixes locally for spatial UI); for 1000-participant calls, server-side audio level prioritization (only top-N loudest streams forwarded). **NAT traversal**: STUN to discover NAT mapping; if UDP blocked, TCP fallback over 443; HTTP-CONNECT through proxies. **E2EE (opt-in)**: per-meeting symmetric key generated client-side; participants encrypt frames; MMR forwards opaque payload; disables cloud recording (which needs plaintext) and dial-in (PSTN gateway needs to mix).

### Deep dives
1. **SFU vs MCU vs P2P-mesh — distributed SFU as Zoom's choice.** **Mesh** breaks past 4-5 (uplink saturates). **MCU** centralizes mixing (high CPU; kills per-participant volume + layer selection). **SFU** forwards per-stream (preserves per-receiver control). Zoom adds the **distributed SFU** twist: instead of one SFU per meeting, MMR fleet replicates meeting state; shortest-path routing distributes bandwidth pressure across the fleet. Result: a 1000-participant meeting doesn't bottleneck on one MMR node's capacity; the load spreads. Scallop arxiv (2503.11649) measured Zoom and confirmed *"forwards exact RTP copies with rewritten headers"* — SDN-like behavior.

2. **Simulcast vs SVC.** **Simulcast**: sender encodes N independent streams (e.g., 180p + 360p + 720p); SFU picks one per receiver based on RTCP. Trade: more sender CPU (3× encoding); but simpler SFU logic (just pick a stream). **SVC** (Scalable Video Coding, H.264 SVC or AV1 SVC): sender encodes one stream with temporal layers (drop every-other-frame) + spatial layers (lower-resolution subset embedded in higher); SFU drops layers inline. Trade: less sender CPU; but SVC requires codec support (limited; AV1 SVC is recent). Zoom uses simulcast historically; AV1 SVC where client support exists. Staff+ commit: which works on which clients; how SFU drops layers for slow receivers based on RTCP receiver reports + REMB / transport-cc feedback.

3. **Packet-loss tolerance via FEC + retransmit.** Live conferencing tolerates 5-30% packet loss with degraded but acceptable quality. **FEC (forward error correction)**: sender includes redundant packets (e.g., XOR of N data packets); receiver can reconstruct lost packets without retransmission (saves latency). **NACK (negative ack) retransmit**: receiver detects gap, requests retransmit; works within jitter-buffer window. **PLC (packet loss concealment)**: for unrecoverable losses, audio decoder generates synthetic samples (NetEQ-class); video decoder shows previous frame (brief freeze). Trade: FEC adds bandwidth overhead (typically 10-30% redundancy); for high-loss links, more FEC; for clean links, NACK-only.

## Known failure modes
1. **Bandwidth collapse on weak link** (one participant on slow WiFi; sender encodes at full rate; receiver can't keep up). Production answer: RTCP receiver reports → SFU drops simulcast layers for that receiver; sender bitrate adapts via REMB / transport-cc feedback; weak receiver gets 180p while others get 1080p.

2. **NAT timeout in long meetings** (1-hour meeting; enterprise NAT drops UDP binding mid-call). Production answer: keepalive UDP heartbeats (every 30s); TCP fallback on UDP path failure; re-discover NAT mapping via STUN periodically.

3. **Hot meeting (10K all-hands)** — exceeds 1000-participant cap. Production answer: per-meeting sharding (multiple MMR clusters for the same logical meeting; webinar mode is one-way broadcast at extreme cap); mute-by-default for large meetings; webinar mode caps interactive participants while supporting tens-of-thousands of view-only attendees.

## Notes for the coach
- **Asked-confirmed at Zoom, Google Meet, Meta** (RTC roles). Hello Interview, DesignGurus, AlgoMaster carry "Design Zoom" canonically.
- **The Multimedia Router (distributed SFU) is the Staff+ Zoom-specific anchor.** Candidates who articulate the cross-node shortest-path routing demonstrate Zoom-specific design knowledge; candidates who default to "one SFU per meeting" miss the distinctive architecture.
- **The simulcast-vs-SVC trade-off is the depth probe.** Candidates who can articulate per-client codec support + the encoding-vs-routing CPU trade demonstrate WebRTC literacy.
- **Adversarial probe: "E2EE is on — how do you record this meeting to cloud?"** Strong answer: you can't with true E2EE; that's the Zoom-published trade-off (opt-in E2EE disables cloud recording + dial-in); for recording, you must accept Zoom-mediated mixing with plaintext access. Weak answer: "we record encrypted then decrypt later" — but the keys are participant-only.

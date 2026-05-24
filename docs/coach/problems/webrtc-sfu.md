---
slug: webrtc-sfu
archetype: realtime-messaging
sources:
  webrtc_rfc8825: datatracker.ietf.org/doc/rfc8825
  ice_rfc8839: datatracker.ietf.org/doc/rfc8839
  stun_rfc5389: datatracker.ietf.org/doc/rfc5389
  turn_rfc5766: datatracker.ietf.org/doc/rfc5766
  dtls_srtp_rfc5764: datatracker.ietf.org/doc/rfc5764
  twcc: datatracker.ietf.org/doc/draft-ietf-rmcat-gcc
---

# WebRTC SFU — primitive: ICE/STUN/TURN, DTLS-SRTP, simulcast, TWCC, jitter buffer

## Bar anchors
- **Mid-level (L4/E4):** Treats SFU as a "media server." Doesn't name ICE/STUN/TURN, DTLS-SRTP, or any congestion control.
- **Senior (L5/E5):** Names ICE/STUN/TURN, simulcast, jitter buffer. Discusses NAT traversal. May or may not articulate full WebRTC stack (DTLS handshake → SRTP keys), TWCC/GCC, or NetEQ-class adaptation.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the **full WebRTC stack** end-to-end: (a) **ICE candidate gathering** (host, srflx via STUN, relay via TURN); (b) **STUN binding requests** to discover NAT-mapped address; (c) **TURN relay allocation** when direct path fails; (d) **DTLS handshake** over established connection; (e) **SRTP keys** extracted from DTLS (per RFC 5764); (f) **SDP offer-answer** with media negotiation. Names **TWCC/GCC** (Google Congestion Control): receiver feeds back per-packet arrival times; sender estimates available bandwidth; SFU may forward feedback for end-to-end estimation. Articulates **simulcast vs SVC** at the SFU level. Names **NetEQ-class jitter buffer**: adaptive buffer sizing per receiver; PLC (packet loss concealment); time-stretching to compensate for clock drift between sender and receiver. Stretch (Sr Staff bar): articulates per-SFU node capacity model (~1000 active streams, ~10 Gbps aggregate); ICE candidate-gathering latency budget (100-500ms).

## Canonical decomposition

### Requirements
**Functional:**
- Ingest RTP streams from N clients
- Forward to up to M client-receivers with per-receiver simulcast layer selection
- ICE/STUN/TURN connection establishment
- DTLS-SRTP encryption with per-packet AES-GCM-128
- TWCC/GCC congestion control with receiver feedback
- NetEQ-class jitter buffer on receivers

**Non-functional (with numbers):**
- Per-SFU node: ~1000 active streams (mix of senders + receivers)
- Aggregate bw per node: ~10 Gbps
- ICE candidate gathering: 100-500ms typical
- STUN binding: 30-100ms
- TURN relay allocation: 50-200ms
- TWCC feedback: every 100ms typical

### Core entities
- **PeerConnection:** per-client WebRTC connection; holds ICE state, DTLS keys, SRTP context
- **Track:** audio or video; one or more simulcast layers
- **SimulcastLayer:** (sender, layer_id, resolution, bitrate); SFU forwards per-receiver choice
- **JitterBuffer:** per-receiver adaptive buffer; PLC + time-stretch
- **CongestionController:** GCC/TWCC; estimates bandwidth from receiver feedback
- **Candidate:** ICE candidate (host | srflx | relay) with priority + foundation

### API
- Signaling (out-of-band, app-specific): offer SDP / answer SDP / ICE candidates exchanged via WebSocket
- Media: ICE-negotiated UDP socket; DTLS handshake; SRTP packets
- Internal: SFU maintains per-PeerConnection state; routes RTP packets between PeerConnections per subscription rules

### HLD
Client builds **PeerConnection** to SFU; both gather ICE candidates (host = local IP; srflx = STUN-discovered public IP; relay = TURN-allocated relay address); pair candidates; run connectivity checks; nominate best pair. Over the nominated transport (UDP or TCP-over-443), do **DTLS handshake**; extract **SRTP keys** per RFC 5764. Then exchange **SDP** (offer-answer) describing media tracks (audio + video, simulcast layers, codec parameters). Once setup: client encrypts RTP packets with SRTP, sends to SFU; SFU decrypts, decides routing (which receivers want this track at which simulcast layer based on their bandwidth + view-state), re-encrypts to receivers, forwards. **Congestion control**: per receiver, **TWCC** feedback (every 100ms) carries per-packet arrival times; sender (and SFU if forwarding feedback end-to-end) estimates bandwidth; sender adjusts bitrate via simulcast layer drop or codec rate adaptation. **Jitter buffer** at receiver: adaptive size (longer for high-jitter networks); PLC fills lost packets; time-stretching compensates for clock-drift between sender's and receiver's audio clocks.

### Deep dives
1. **ICE/STUN/TURN — candidate gathering, pairing, connectivity checks.** **ICE** orchestrates connection establishment across NAT. Phase 1 = **candidate gathering**: client collects local interfaces (host candidates), queries STUN servers for public NAT-mapped addresses (srflx candidates), allocates TURN relays as fallback (relay candidates). Phase 2 = **pairing**: client + remote endpoint exchange candidate lists via signaling; pair every local-remote candidate combination; assign priority (host > srflx > relay). Phase 3 = **connectivity checks**: send STUN binding requests across each candidate pair; first to succeed (or highest-priority succeeding) is **nominated**. Phase 4 = **nomination + use**: media flows over nominated candidate pair. **TURN relay** is required when both endpoints are behind symmetric NAT (cannot punch through); TURN server relays UDP packets; expensive (server pays bw cost) but always works. Trade: ICE adds 100-500ms to connection setup; some products (Discord) skip ICE and always connect via media relay to save the setup time.

2. **DTLS-SRTP — secure media transport.** **DTLS** (Datagram TLS) handshake over the ICE-established transport: standard TLS handshake adapted for UDP (loss-tolerant). Cipher suite negotiated; symmetric session keys derived. **SRTP keys** extracted from DTLS keying material per RFC 5764 (DTLS-SRTP); per-direction (send/receive) keys with rotation policy. Per RTP packet: encrypt payload with **AES-GCM-128** (authenticated encryption); SRTP header has packet sequence number for replay protection. SRTCP for control messages (RTCP) encrypted similarly. Key rotation: typically per-call or every N packets; supports forward secrecy if DTLS handshake renegotiated.

3. **TWCC/GCC congestion control + simulcast at the SFU.** **TWCC** (Transport-Wide Congestion Control): receiver records arrival-time of every RTP packet; sends back periodically as TWCC feedback. Sender (or SFU if forwarding end-to-end) runs **GCC** (Google Congestion Control) algorithm: estimates available bandwidth based on packet inter-arrival times (queue buildup = bw limit); produces target bitrate. Sender adjusts: (a) codec rate adaptation (encoder bitrate), (b) simulcast layer drop (stop encoding/sending higher layers). At SFU: per-receiver bandwidth estimate drives which simulcast layer to forward to that receiver. **Simulcast layer selection**: SFU peeks at packet header (layer ID in RTP header extension); forwards or drops without decrypting payload. **Stretch: SVC at SFU**: with SVC, SFU drops temporal layers (every-other-frame) inline; even more granular than simulcast layer selection.

## Known failure modes
1. **NAT/firewall blocking UDP entirely** (some enterprise networks). Production answer: TCP fallback via TURN-over-TCP or HTTP CONNECT proxy; sacrifices a bit of latency vs UDP but functional. ICE handles fallback automatically (TURN relay candidate over TCP).

2. **Asymmetric bandwidth** (one receiver has 500 kbps, sender encodes at 5 Mbps). Production answer: simulcast layer selection at SFU avoids forcing sender to re-encode globally; sender encodes 3 layers (low/mid/high), SFU forwards low layer to slow receiver and high to fast receivers; sender is unaware of per-receiver decisions.

3. **Clock drift between sender and receiver** (sender's audio clock at 48,001 Hz; receiver expects 48,000 Hz; over 1 hour, ~75 seconds drift). Production answer: NetEQ time-stretching compensates by stretching/compressing playback slightly; eventual packet drop on overflow if drift is too aggressive.

## Notes for the coach
- **Asked-confirmed at AI labs** for `multimodal-realtime-serving` prep + WebRTC-heavy companies (Zoom, Meet, Daily.co, Twilio Video, LiveKit). The substrate primitive.
- **Cross-coverage with AI-infra `multimodal-realtime-serving`** is the highest-value cross-coverage in the catalog: WebRTC stack is the substrate for GPT-4o Realtime-class voice streaming. 60-70% of the substrate transfers — name the layers, then layer the inference pipeline (STT → LLM → TTS) on top.
- **The full-stack walk-through (ICE → DTLS → SRTP → SDP → RTP → TWCC → NetEQ) is the Staff+ unlock.** Candidates who name each layer and its role demonstrate WebRTC literacy; candidates who say "it just works" miss the substrate.
- **Adversarial probe: "show me how the SFU drops a simulcast layer for a slow receiver — packet by packet."** Strong answer: SFU peeks at layer-ID in RTP header extension; for slow receiver, drops packets where layer-ID > target_layer; forwards rest. Weak answer: "the SFU decodes and re-encodes" — that's a transcoder, not an SFU.

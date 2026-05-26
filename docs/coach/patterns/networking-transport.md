# Networking and Transport

Source: `staff-engineer-study-guide.md`.

## DNS

**Definition.** The Domain Name System maps hostnames to IPs; key design levers are anycast (same IP announced from multiple PoPs, traffic routed to nearest) and TTL (how long resolvers cache answers).

**Canonical use.** Set short TTLs (30–60 s) during a migration and use anycast to route users to the geographically closest datacenter without per-request DNS overhead.

**Production systems.** Cloudflare DNS (anycast), AWS Route 53 (latency-based routing).

**Alternatives.** GeoDNS for coarser geo-routing; service registry (Consul) for internal service discovery.

## TCP vs UDP and QUIC

**Definition.** TCP provides reliable, ordered, connection-oriented delivery; UDP is connectionless and unreliable but lower overhead; QUIC multiplexes streams over UDP with built-in TLS and eliminates head-of-line blocking.

**Canonical use.** Use QUIC (HTTP/3) for latency-sensitive apps on lossy mobile networks; use UDP for real-time gaming or video where a dropped frame is preferable to a stalled retransmit.

**Production systems.** Google QUIC (all Google properties), Cloudflare HTTP/3, WebRTC (UDP).

**Alternatives.** TCP with aggressive timeout tuning; raw UDP with application-layer reliability (e.g., ENet in games).

## WebSocket vs Long Polling vs SSE

**Definition.** WebSocket is a full-duplex persistent TCP connection; Long Polling holds an HTTP request open until the server has data; SSE (Server-Sent Events) is a unidirectional server-to-client HTTP stream.

**Canonical use.** Use WebSocket for bidirectional real-time features (chat, collaborative editing); use SSE for unidirectional server-push (live score feeds, notifications) when clients don't need to send data.

**Production systems.** Slack (WebSocket), GitHub live updates (SSE), older Twitter Streaming API (Long Polling).

**Alternatives.** gRPC bidirectional streaming as a WebSocket alternative in internal services; polling for low-frequency updates where simplicity outweighs latency.

## Push Notification Gateways

**Definition.** APNs (iOS) and FCM (Android, Web) are HTTP/2-based mobile push gateways: senders open persistent connections that multiplex many concurrent streams (~1000/connection on APNs), so fan-out workers maintain a connection pool rather than connection-per-request.

**Canonical use.** Use a `collapse-id` (APNs) / `collapse_key` (FCM) so a chat with many unread messages supersedes to one delivery; set `apns-priority=10` for user-visible wakes and `5` for power-considerate silent push; set TTL/`apns-expiration` to drop offline ephemerals (typing) vs store-and-forward user messages (~24h).

**Production systems.** Apple APNs, Firebase Cloud Messaging (FCM), AWS SNS (multiplexes APNs+FCM), OneSignal, Pusher.

**Alternatives.** WebSocket-based direct push when the app can stay foregrounded (no gateway dependency, no per-device cap); SMS as last-resort fallback (carrier delivery semantics, no in-band cancellation); Apple Critical Alerts / Time Sensitive envelopes for bypassing Focus modes. Per-device throttling (~1 push/min sustained at normal priority) forces senders to pre-aggregate or use higher-priority tiers.

## WebRTC and SFU vs MCU

**Definition.** WebRTC is a browser-native protocol for real-time peer-to-peer audio/video/data; an SFU (Selective Forwarding Unit) routes media streams without transcoding, while an MCU (Multipoint Control Unit) mixes all streams into one composite.

**Canonical use.** Use an SFU for group video calls to avoid N×M peer connections from each participant while keeping server CPU low; use an MCU only when clients have constrained bandwidth and cannot receive multiple streams.

**Production systems.** Zoom (proprietary SFU), Twilio (SFU-based), Google Meet (SFU).

**Alternatives.** HLS/DASH for non-interactive live video at massive scale; full peer-to-peer mesh (feasible only for ≤4 participants).

## WebRTC: Simulcast vs SVC

**Definition.** For multi-quality video forwarding via an SFU: **Simulcast** sends N independent encodings of the same source (low/mid/high); the SFU picks which layer to forward per subscriber. **SVC (Scalable Video Coding)** sends one encoding with embedded temporal/spatial layers (AV1 SVC is the practical target); the SFU drops upper layers per subscriber inline by peeking at RTP header extensions.

**Canonical use.** Use simulcast when senders have CPU headroom and codec support for SVC is uneven across clients (the common case); use SVC when downlink heterogeneity is large and you can budget the encoder/decoder support (AV1 SVC).

**Production systems.** Zoom (simulcast), Twitch IVS (HEVC simulcast), Google Meet (AV1 SVC), Jitsi SFU.

**Alternatives.** Transcoding at the SFU (CPU-prohibitive at scale — turns the SFU into an MCU); single-layer encode with no adaptation (kills slow receivers).

## WebRTC Congestion Control: TWCC and GCC

**Definition.** **Transport-Wide Congestion Control (TWCC)** is an RTP feedback message: receiver records per-packet arrival times and sends them back (~every 100ms), letting the sender estimate per-packet RTT and loss. **Google Congestion Control (GCC)** is the canonical algorithm that consumes TWCC feedback to drive sender bitrate adaptation: a delay-based estimator (queue buildup ⇒ bandwidth limit) plus a loss-based safety net.

**Canonical use.** Run GCC over TWCC feedback so the sender drops simulcast layers or rate-adapts the encoder before the link saturates; SFUs may forward feedback end-to-end so the sender sees the slowest receiver in the path.

**Production systems.** Chromium / libwebrtc (GCC reference), Zoom (custom GCC-derived variant), Jitsi, LiveKit.

**Alternatives.** SCReAM (RFC 8298, simpler self-clocked control); pure loss-based control (poor under low-loss + high-delay paths like cellular).

## NetEQ Jitter Buffer and Adaptive Playout

**Definition.** Real-time audio playout requires absorbing network jitter without adding too much latency. NetEQ (WebRTC's audio jitter buffer) does adaptive playout: it time-stretches audio when packets arrive late, compresses when they arrive ahead, and synthesizes comfort noise / PLC samples for lost packets.

**Canonical use.** Size the buffer adaptively per receiver — deeper under jitter, shallower under clean links — and let PLC + time-stretching cover small drops without rebuffering; this is also how clock drift between sender and receiver (e.g., 48001 vs 48000 Hz audio clocks) is silently absorbed.

**Production systems.** WebRTC / libwebrtc (NetEQ), Discord, Zoom, Google Meet.

**Alternatives.** Fixed-size jitter buffer (simpler, but worse mouth-to-ear latency under variable conditions); no PLC (audible dropouts on any loss).

## HTTP/1.1 vs HTTP/2 vs HTTP/3 — REST vs gRPC vs GraphQL

**Definition.** HTTP/1.1 is text-based with head-of-line blocking; HTTP/2 adds binary framing and stream multiplexing over one TCP connection; HTTP/3 runs over QUIC; gRPC uses HTTP/2 with protobuf; GraphQL is a query language over HTTP.

**Canonical use.** Use gRPC for internal service-to-service calls where schema enforcement and low overhead matter; use GraphQL for client-facing APIs where mobile clients need flexible field selection to reduce over-fetching.

**Production systems.** Google internal APIs (gRPC), GitHub (GraphQL v4), Facebook API (GraphQL origin).

**Alternatives.** REST with JSON for broad compatibility; Thrift (Meta's internal RPC) as an alternative to protobuf.

## TLS Termination and mTLS

**Definition.** TLS termination decrypts HTTPS at a proxy (load balancer or API gateway) so backend traffic is plaintext; mTLS (mutual TLS) requires both sides to present certificates, authenticating client identity.

**Canonical use.** Terminate TLS at the load balancer to offload CPU from app servers, then use mTLS between internal microservices for zero-trust service authentication.

**Production systems.** AWS ALB (TLS termination), Istio/Envoy (mTLS service mesh), Google BeyondCorp.

**Alternatives.** Application-layer auth tokens (JWT, API keys) instead of mTLS for simpler service auth; end-to-end TLS when data sensitivity requires it all the way to the backend.

## Signal Protocol: Double Ratchet + X3DH

**Definition.** End-to-end-encrypted 1:1 messaging. **X3DH** (Extended Triple Diffie-Hellman) is the initial key agreement: the initiator combines its identity + ephemeral keys with the recipient's published identity + signed pre-key + (optional) one-time pre-key, so the recipient can be offline at session start. **Double Ratchet** then advances state per message: a DH ratchet (new ephemeral DH on each round-trip → post-compromise security) combined with a symmetric-key ratchet (KDF chain → per-message keys → forward secrecy).

**Canonical use.** Use Signal Protocol whenever the server must be a public-key directory plus opaque ciphertext relay — never trusted with plaintext — for asynchronous 1:1 messaging with FS + PCS guarantees.

**Production systems.** Signal, WhatsApp, Facebook Messenger (Secret Conversations + default E2E rollout), Google Messages RCS E2E, Skype private conversations.

**Alternatives.** Pure asymmetric encryption (no per-message forward secrecy); MLS (better for large groups; see below); PQXDH (Signal's hybrid Kyber-768 extension for harvest-now-decrypt-later resistance).

## MLS (Messaging Layer Security) Group Key

**Definition.** IETF-standardized E2E group messaging (RFC 9420, July 2023). **TreeKEM** arranges members as leaves of a binary tree of HPKE keypairs; adding, removing, or rotating one member updates only the path from that leaf to the root, so member-change costs O(log N) ciphertexts instead of O(N) (Sender Keys) or O(N²) (pairwise Double Ratchet). Provides Forward Secrecy + Post-Compromise Security at group scale; a Delivery Service total-orders Commits without ever seeing plaintext.

**Canonical use.** Use MLS for groups up to ~50K members where Sender Keys' linear re-keying cost dominates (10K-member group: ~14 ciphertexts vs ~10K for Sender Keys); keep Sender Keys for very small groups where MLS state-machine overhead isn't justified.

**Production systems.** Discord DAVE (voice channels, enforced March 2026), Cisco Webex, RingCentral, AWS Wickr; Meta piloting MLS for large WhatsApp groups.

**Alternatives.** Pairwise Signal Double Ratchet for every pair in a group (O(N²) keys); Sender Keys (O(N) per member-remove); centralized re-keying (loses E2E entirely).

## CDN — Push vs Pull

**Definition.** A CDN (Content Delivery Network) caches content at edge PoPs close to users; push CDNs require the origin to proactively upload content, while pull CDNs fetch and cache content on first request then serve from edge thereafter.

**Canonical use.** Use pull CDN for large, unpredictably popular assets (images, JS bundles) and push CDN for time-critical content (large video files, software releases) where cache-miss latency on first access is unacceptable.

**Production systems.** Cloudflare (pull and push), Akamai, AWS CloudFront.

**Alternatives.** Reverse-proxy caching (Varnish, Nginx) for single-region deployments; P2P content distribution (BitTorrent) for extreme scale.

## Reverse Proxy and API Gateway

**Definition.** A reverse proxy sits in front of backend servers to handle SSL termination, compression, and caching; an API gateway extends this with auth, rate limiting, request/response transformation, and routing across microservices.

**Canonical use.** Place an API gateway at the edge to enforce authentication and per-client rate limits in one place, so individual microservices don't each implement these cross-cutting concerns.

**Production systems.** AWS API Gateway, Kong, Nginx (reverse proxy), Envoy.

**Alternatives.** Service mesh sidecars (Istio) for east-west traffic; direct load balancer without a gateway for simpler monolithic deployments.

# Networking and Transport

Pattern reference for `/study-patterns 3B`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3B.

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

## WebRTC and SFU vs MCU

**Definition.** WebRTC is a browser-native protocol for real-time peer-to-peer audio/video/data; an SFU (Selective Forwarding Unit) routes media streams without transcoding, while an MCU (Multipoint Control Unit) mixes all streams into one composite.

**Canonical use.** Use an SFU for group video calls to avoid N×M peer connections from each participant while keeping server CPU low; use an MCU only when clients have constrained bandwidth and cannot receive multiple streams.

**Production systems.** Zoom (proprietary SFU), Twilio (SFU-based), Google Meet (SFU).

**Alternatives.** HLS/DASH for non-interactive live video at massive scale; full peer-to-peer mesh (feasible only for ≤4 participants).

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

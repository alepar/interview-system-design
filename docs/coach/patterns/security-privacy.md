# Security and Privacy

Source: `staff-engineer-study-guide.md`.

## AuthN / AuthZ: OAuth 2.0, OIDC, JWT, Session Cookies

**Definition.** Authentication (AuthN) verifies identity; Authorization (AuthZ) controls access; OAuth 2.0 is a delegated authorization framework; OIDC adds an identity layer on top of OAuth 2.0; JWTs are self-contained signed tokens; session cookies store an opaque server-side session reference.

**Canonical use.** Use OIDC + JWT for stateless microservice-to-microservice AuthN (token verified locally without a DB roundtrip), and session cookies for browser-facing apps where you need instant server-side revocation.

**Production systems.** Auth0 / Okta (managed OIDC IdP), AWS Cognito (user pools with OAuth 2.0 + JWT issuance).

**Alternatives.** API keys (simpler, no delegation, hard to rotate); mTLS (mutual TLS for service-to-service, certificate-based identity without tokens).

## Rate Limiting, DDoS Protection, and WAF

**Definition.** Rate limiting caps request volume per client/IP/API key using algorithms like token bucket or sliding window; DDoS protection absorbs or deflects volumetric attacks at the network edge; a Web Application Firewall (WAF) filters malicious HTTP payloads (SQLi, XSS, OWASP Top 10).

**Canonical use.** Apply rate limiting at the API gateway to protect backend services from abuse, and place a WAF + DDoS scrubbing layer (e.g., Cloudflare, AWS Shield) in front of all public endpoints.

**Production systems.** AWS WAF + Shield Advanced, Cloudflare (DDoS + WAF + rate limiting as a managed edge service).

**Alternatives.** Nginx/Envoy built-in rate limiting (simpler, no external dependency); iptables / BPF-level packet filtering for volumetric L3/L4 attacks.

## Rate-Limiting Algorithms

**Definition.** Algorithms for enforcing per-client request rate: **token bucket** (refill at rate R, allow burst up to capacity B; simple, allows controlled bursts), **leaky bucket** (queue with constant drain rate; smooths bursts but adds queueing latency), **fixed window** (counter per N-second window; simplest but allows 2× burst at the window boundary), **sliding window log** (timestamp log per client; precise but O(N) memory), **sliding window counter** (weighted blend of two adjacent fixed-window counters; precision-vs-memory compromise), **GCRA** (Generic Cell Rate Algorithm; single-timestamp state, mathematically equivalent to leaky bucket, the algorithm Stripe and Cloudflare use in production).

**Canonical use.** Token bucket or GCRA at the API gateway for per-API-key limits with bursts (Stripe-style); leaky bucket where downstream cannot absorb bursts; sliding-window counter for short windows where fixed-window boundary spikes are a real concern (login endpoints, password reset).

**Production systems.** Stripe (GCRA, single Redis key per limit), Cloudflare (GCRA at the edge, sub-millisecond), Envoy global rate-limit service (token bucket via gRPC service), Redis Cell module (GCRA primitive).

**Alternatives.** Distributed counter with periodic sync (looser limits but lower coordination cost); concurrency limits / semaphores (cap in-flight requests rather than rate; the right tool when downstream has bounded parallelism, not bounded throughput).

## Bot Mitigation and Behavioral Biometrics

**Definition.** Layered defense against automated traffic combining **static signals** (IP/ASN reputation, TLS fingerprinting via JA3/JA4, HTTP header heuristics) with **dynamic signals** (invisible CAPTCHA / Turnstile / hCaptcha, device fingerprinting via Canvas/Audio/WebGL, behavioral biometrics like mouse curves and keystroke dynamics) to produce a risk score; admission is **tiered** — silent challenge for low risk, interactive CAPTCHA at medium risk, hard block at high risk.

**Canonical use.** Place as a checkpoint in front of the origin on hype/contention endpoints (sneaker drops, flash sales, ticket onsales) where bots are the dominant adversary (10–40%+ of traffic, up to 97% on hyped releases) and pure rate limiting cannot distinguish a distributed botnet from real users.

**Production systems.** Cloudflare Bot Management + Turnstile (managed edge, JA4 + ML scoring), hCaptcha (privacy-preserving enterprise CAPTCHA), Arkose Labs (interactive challenges for high-friction tiers), Akamai Bot Manager (CDN-integrated detection).

**Alternatives.** Pure rate limiting (cheap, but weak against rotating-IP residential botnets); proof-of-work CAPTCHAs like mCaptcha or Anubis (no third-party dependency, imposes compute cost on attackers but degrades UX on low-end devices).

## Encryption at Rest and in Transit; Envelope Encryption with KMS

**Definition.** Encryption in transit uses TLS to protect data moving between components; encryption at rest uses AES-256 (or similar) to protect stored data; envelope encryption wraps a per-resource data encryption key (DEK) with a key-encryption key (KEK) managed by a KMS, so rotating the KEK doesn't require re-encrypting all data.

**Canonical use.** Use envelope encryption so the KMS holds only KEKs (never bulk data), enabling key rotation and per-tenant key isolation without mass re-encryption on key compromise.

**Production systems.** AWS KMS (envelope encryption, integrates with S3/RDS/EBS), Google Cloud KMS + CMEK (customer-managed encryption keys).

**Alternatives.** Application-level encryption with a local keystore (removes KMS dependency, adds key management burden); HashiCorp Vault (self-hosted secrets + dynamic credentials).

## PII Handling, k-Anonymity, and Differential Privacy

**Definition.** PII (Personally Identifiable Information) handling encompasses data minimization, pseudonymization, and access controls; k-anonymity ensures each record is indistinguishable from at least k−1 others across quasi-identifiers; differential privacy adds calibrated noise to query results so individual membership cannot be inferred.

**Canonical use.** Apply differential privacy for aggregate analytics exports (e.g., ad reporting) where raw PII cannot leave the system, and k-anonymity for de-identified dataset releases in healthcare or research.

**Production systems.** Apple's differential privacy pipeline (emoji/typing usage telemetry), Google's RAPPOR (browser telemetry), Meta's Tulip (internal privacy-preserving analytics).

**Alternatives.** Synthetic data generation (no real PII, but may not preserve statistical properties); data masking / tokenization (reversible substitution for dev/test environments).

## End-to-End Encryption and the Signal Protocol

**Definition.** End-to-end encryption (E2EE) ensures only the communicating endpoints can decrypt messages, with the server relaying ciphertext it cannot read; the Signal protocol implements E2EE using the Double Ratchet algorithm (combining Diffie-Hellman ratchet + symmetric ratchet) for perfect forward secrecy and break-in recovery.

**Canonical use.** Invoke the Signal protocol when designing a messaging system requiring that even a server compromise cannot expose past or future message plaintext.

**Production systems.** WhatsApp (Signal protocol end-to-end), Signal messenger (reference implementation), iMessage (partial E2EE with Apple-held backup keys).

**Alternatives.** TLS-only encryption (server can read plaintext — not E2EE); PGP (E2EE for email, but no forward secrecy and complex key management).

## Audit Logging

**Definition.** Audit logging records a tamper-evident, append-only trail of who performed what action on which resource and when, sufficient to reconstruct the sequence of events for compliance, forensics, or debugging.

**Canonical use.** Write audit logs to an immutable sink (separate from application logs) with every privileged action — data access, permission change, configuration mutation — and retain them for the compliance-mandated period (often 1–7 years).

**Production systems.** AWS CloudTrail (API-level audit log for all AWS calls), Google Cloud Audit Logs (Admin Activity + Data Access logs).

**Alternatives.** Database-level triggers for row-level audit (fine-grained but couples audit to DB schema); append-only ledger databases (Amazon QLDB) for cryptographically verifiable logs.

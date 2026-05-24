# Security and Privacy

Pattern reference for `/study-patterns 3L`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3L.

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

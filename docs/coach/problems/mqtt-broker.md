---
slug: mqtt-broker
archetype: realtime-messaging
sources:
  mqtt_v5_spec: docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html
  aws_iot_core: docs.aws.amazon.com/iot
  hivemq_emqx_benchmarks: HiveMQ + EMQX broker capacity public benchmarks
---

# MQTT broker — IoT messaging at 1M+ devices with QoS 0/1/2 + persistent sessions

## Bar anchors
- **Mid-level (L4/E4):** Treats IoT as "tiny chat." Doesn't differentiate QoS levels or address intermittent connectivity.
- **Senior (L5/E5):** Names MQTT, QoS levels, retained messages. Discusses last-will-and-testament. May or may not address per-tenant isolation, persistent-session storage, or QoS 2 handshake state under failover.
- **Staff+ (L6/E6+):** Drives proactively. Articulates (a) **QoS levels** — 0 (at-most-once, fire-and-forget), 1 (at-least-once, broker stores until acked), 2 (exactly-once via 4-step PUBLISH→PUBREC→PUBREL→PUBCOMP handshake, expensive); (b) **retained messages** (last message per topic held for new subscribers); (c) **last-will-and-testament (LWT)** (broker publishes pre-specified message on ungraceful disconnect); (d) **persistent sessions** for intermittent connectivity (broker stores subs + queued QoS 1+2 messages across disconnects; MQTT v5 session expiry interval); (e) **per-device authentication + per-topic ACLs** — billions of devices need unique credentials (X.509 typical); ACLs scoped to tenant prefix; (f) **multi-tenant isolation** in shared infrastructure (AWS IoT Core class). Stretch (Sr Staff bar): articulates **QoS 2 handshake state under broker failover** (state must persist to shared store; or accept degrade-to-QoS-1).

## Canonical decomposition

### Requirements
**Functional:**
- MQTT v3.1.1 + v5 protocol support
- QoS 0/1/2 publish/subscribe
- Retained messages, last-will-and-testament
- Persistent sessions for intermittent connectivity
- Topic hierarchy + wildcards (`+` single level, `#` multi-level)
- Per-device authentication (X.509 certs) + per-topic ACLs
- Multi-tenant isolation in shared fabric

**Non-functional (with numbers):**
- 1M+ concurrent devices per broker node (HiveMQ, EMQX high-end)
- AWS IoT Core: millions of devices per account
- QoS 0 throughput: 1M+ msgs/sec per broker node
- QoS 1: 100K+ msgs/sec; QoS 2: 10K+ msgs/sec (expensive due to 4-step handshake)
- MQTT v5: shared subscriptions (load-balance among consumer group); session expiry interval

### Core entities
- **Device:** device_id, tenant_id, X.509 cert thumbprint, policy_id, session_state
- **Topic:** hierarchical string; wildcards in subscriptions only; ACLs scoped to tenant
- **Session:** (device_id, subscriptions[], queued_messages[QoS1+2], expiry_interval)
- **RetainedMessage:** per-topic; last published; held for new subscribers
- **Policy:** ACL rules (publish to which topics, subscribe to which); attached to cert

### API
- MQTT over TCP (port 1883) or TLS (8883): CONNECT, PUBLISH, SUBSCRIBE, UNSUBSCRIBE, PING, DISCONNECT
- MQTT over WebSocket: `wss://broker:8884/mqtt`
- HTTP API for device provisioning (cert issuance, policy attachment)
- AWS IoT Core REST API for device shadow, jobs, rules engine integration

### HLD
**Broker fleet** is multi-tenant: shared infrastructure serving millions of devices across thousands of tenants. **Connection layer** accepts MQTT CONNECT over TCP/TLS or WebSocket; authenticates via X.509 client cert (cert thumbprint maps to policy); validates the device's claimed `client_id` against cert identity. **Subscription manager** holds per-broker subscription state; on PUBLISH, broker matches topic against all subscriptions (wildcard match); fans out to matching subscribers. **Persistent session storage** (Redis or sharded DB): per-device session state (subscriptions list + queued QoS 1+2 messages); session expiry interval (MQTT v5) controls retention after disconnect. **Retained-message store**: per-topic last-published; served to new subscribers on SUBSCRIBE. **LWT engine**: at CONNECT, client may specify "if I disconnect ungracefully, publish this message to topic T"; broker publishes on detected disconnect (TCP RST or keepalive timeout). **Multi-tenant isolation**: per-tenant rate limits (msgs/sec, bytes/sec); per-tenant quotas (connection count, retention storage); topic-namespace enforcement (device's cert binds to tenant prefix; broker rejects publishes/subscribes outside namespace).

### Deep dives
1. **MQTT QoS levels + delivery semantics.** **QoS 0** (at-most-once): publish + forget; no broker storage; lowest overhead; suitable for high-frequency telemetry where occasional loss is OK. **QoS 1** (at-least-once): publisher sends + broker acks (PUBACK) + broker stores until subscriber acks; subscriber may receive duplicate (on retransmission); requires application-level dedup. **QoS 2** (exactly-once): 4-step handshake — PUBLISH (publisher to broker) → PUBREC (broker to publisher) → PUBREL (publisher to broker) → PUBCOMP (broker to publisher); broker tracks message-IDs to dedup; mirror exchange between broker and subscriber. **Expensive** (4× round-trips, 4× state). Most production IoT uses QoS 1 + application-level dedup; QoS 2 reserved for billing-critical signals only. Staff+ commit: QoS choice per use case; storage cost of QoS 1+2; what happens during broker restart (QoS 1+2 messages must persist; QoS 0 lost).

2. **Persistent sessions for intermittent IoT connectivity.** IoT devices have intermittent connectivity (cellular signal loss, WiFi roaming, power cycles). **Persistent session** flag at CONNECT: broker stores subscription list + queued QoS 1+2 messages for the client across disconnects; on reconnect, broker delivers queued messages. **Session expiry interval** (MQTT v5): controls how long broker retains session state if client doesn't reconnect (e.g., 24h default; permanent for critical devices). **Last-will-and-testament (LWT)**: at CONNECT, client specifies "if I disconnect ungracefully, publish this message to topic T"; broker publishes LWT on detected disconnect (TCP RST or keepalive timeout); useful for fleet-health monitoring. Staff+ commit: session expiry policy per device class; LWT for downtime monitoring; storage cost of long-retained sessions (broker memory grows with disconnected-but-not-expired sessions).

3. **Per-tenant isolation in shared infrastructure (AWS IoT Core class).** Single shared broker fabric serving millions of tenants. **Authentication**: per-device X.509 certificate (typical); JWT/OAuth tokens (less common). **Authorization**: per-device policy attached to certificate; ACLs control which topics the device can publish/subscribe (typically scoped to `tenant/{tenant_id}/...`). **Isolation primitives**: per-tenant rate limits (msgs/sec, bytes/sec); per-tenant quotas (connection count, message retention storage); per-tenant noisy-neighbor protection (one tenant's flood doesn't degrade others — credit/token-bucket per tenant). **Topic-namespace enforcement**: device's cert binds it to a tenant prefix; broker rejects publishes/subscribes outside the namespace. Staff+ commit: cert-based auth; ACL model; per-tenant rate-limit; what happens during tenant-level abuse (auto-throttle + alert + escalation).

## Known failure modes
1. **Connection storm after broker restart.** Million-device fleet all reconnects within seconds after broker restart; connection-accept throughput saturates. Production answer: jittered reconnect (devices randomize 0-60s before reconnecting); broker connection-rate-limit on accept; pre-warm replacement broker nodes before restart; gradual rolling deploy.

2. **Retained-message accumulation.** Each topic can have a retained message; over time, many topics accumulate retained messages; broker memory grows. Production answer: per-topic retained-message TTL; periodic GC of stale retained messages; topic-creation rate-limit.

3. **QoS 2 handshake state under broker failover.** QoS 2 requires 4-step handshake state per in-flight message; broker failover loses this state; messages may be duplicate-delivered or lost. Production answer: persist QoS 2 state to a shared store (Redis, replicated DB); on failover, new broker picks up state and completes handshakes; or accept QoS 2 may degrade to QoS 1 during failover (with explicit per-tenant configuration).

## Notes for the coach
- **Plausibly-asked at AWS (IoT Core), HiveMQ, EMQX, Tesla, automotive IoT companies.** MQTT specification [OASIS MQTT v5] is primary; AWS IoT Core docs cover the managed-service architecture.
- **The QoS 0/1/2 distinction is the Staff+ baseline.** Candidates who quote per-QoS throughput (1M / 100K / 10K msgs/sec) demonstrate operational awareness; candidates who say "we use QoS 2 for reliability" without acknowledging the 4× cost miss the design space.
- **The persistent-session-for-intermittent-connectivity framing is the IoT-specific unlock.** Candidates who articulate "device offline for hours, broker queues, delivers on reconnect" demonstrate the IoT framing; candidates who treat IoT like chat (always-on connections) miss the operational reality.
- **Adversarial probe: "one tenant's noisy device floods the broker — what protects other tenants?"** Strong answer: per-tenant credit/token-bucket; auto-throttle on abuse; tenant-level alert + escalation; pre-emptive cap from cert policy. Weak answer: "we add capacity" without per-tenant fairness.

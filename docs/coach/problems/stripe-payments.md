---
slug: stripe-payments
archetype: concurrent-resource
sources:
  codetodeploy_stripe: medium.com/codetodeploy/the-stripe-system-design-question-that-separates-senior-from-staff-engineers-b39f1f1a05cf
  stripe_idempotency: stripe.com/blog/idempotency
  exponent_stripe: tryexponent.com/questions?company=stripe
  sagas_paper: dl.acm.org/doi/10.1145/38713.38742
---

# Stripe payments (exactly-once payment execution + double-entry ledger)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic flow: client sends a charge request, server calls the bank API, records the result in a DB. May mention idempotency-key at category level but doesn't articulate the stored-fingerprint pattern or what happens on key reuse with different bodies. Discusses webhooks at category level. Doesn't address ledger atomicity, reconciliation, or banking-network race conditions unprompted.
- **Senior (L5/E5):** Names idempotency-key as a client-generated UUID; describes server storing `key → response` for replay. Identifies double-entry ledger (debit one account, credit another) as the accounting pattern. Discusses webhook delivery with retries + exponential backoff. Knows about reconciliation at category level. May or may not articulate the request-fingerprint check for idempotency-key reuse with different bodies.
- **Staff+ (L6/E6+):** Drives proactively. Names the **idempotency-key + request-fingerprint pattern**: client sends `Idempotency-Key` header (random UUID); server hashes the request body and stores `(key, body_hash) → (status, response, timestamp)` in a fast KV (Redis with persistence; or transactional KV like FoundationDB); TTL typically 24h-7d; replays return the cached response; mismatched body for same key returns HTTP 422 (signals client bug, not silent success). Articulates **double-entry ledger atomicity**: every transaction = 2 journal entries that must commit atomically (debit user balance $100, credit merchant balance $100); partial commit produces drift that's detectable via cross-foot (sum of debits = sum of credits per period) but expensive to repair. Names the **storage requirement**: serializable cross-shard transactions (Postgres SERIALIZABLE, FoundationDB, Spanner-class) for the ledger; eventually-consistent stores are insufficient because temporary imbalance is unacceptable. Discusses **webhook delivery semantics**: at-least-once delivery via Kafka-style outbox pattern; exponential backoff + jitter over hours/days; HMAC signing for receiver authentication; idempotent receiver responsibility (merchant must handle duplicate webhooks). Names **decimal/precision rules**: never floating-point; use fixed-precision decimals (or cents-as-integers); per-currency rounding rules; multi-currency conversions with rate-as-of-time. Names **reconciliation against banking-network state**: even with idempotency, the bank's record of the payment may diverge from Stripe's (network blip, race condition, fraud reversal); periodic reconciliation job compares Stripe's ledger to bank statements; alert + manual investigation on drift. Stretch (Sr Staff bar): articulates the **Saga pattern** for multi-step orchestrations spanning multiple external services (each step has a compensating action); explicit acknowledgement that "exactly-once" is shorthand for "at-least-once + idempotency at every layer."

## Canonical decomposition

### Requirements
**Functional:**
- Process a payment: charge user's payment method, credit merchant's balance, record the transaction
- Exactly-once execution despite network retries, client crashes, server crashes
- Multi-currency support with per-currency rounding rules + exchange rates
- Webhook notification to merchant on payment completion (with retries)
- Refund + chargeback flow (compensating transactions)
- Reconciliation against banking-network state of record
- Per-merchant API key authentication + rate limits

**Non-functional (with numbers):**
- Billions of requests/year (Stripe published scale; CodeToDeploy framing as the canonical exactly-once-as-a-state-machine problem)
- p99 latency <500ms for the synchronous charge response (excluding async webhook)
- 99.99% payment success rate (excluding intentional rejections like insufficient funds)
- Zero ledger drift tolerated: sum of debits = sum of credits per period, always
- Idempotency-key TTL: 24h default, configurable up to 7 days
- Webhook delivery: at-least-once, retries over hours-to-days with exponential backoff
- Reconciliation cadence: continuous streaming + daily batch authoritative check

### Core entities
- **Charge:** charge_id (server-generated), idempotency_key (client-provided), amount, currency, payment_method, merchant_id, status (pending | succeeded | failed | refunded)
- **Idempotency record:** (idempotency_key, body_hash) → (status, response, created_at); TTL-bound
- **Ledger entry:** transaction_id, account_id, amount (signed), currency, type (debit | credit), timestamp; double-entry — every transaction creates ≥2 entries that sum to zero
- **Webhook event:** event_id, merchant_id, type (charge.succeeded, etc), payload (signed), delivery_attempts, next_retry_at, dead_letter (boolean)
- **Reconciliation record:** stripe_transaction_id, bank_transaction_id, stripe_status, bank_status, drift_detected_at, resolution

### API
- `POST /v1/charges` body={amount, currency, source, customer, description} headers={Idempotency-Key: <uuid>} → 200 with charge details (cached on idempotency-key replay) or 422 with mismatched-body error or 4xx/5xx on real failure
- `POST /v1/refunds` body={charge_id, amount} headers={Idempotency-Key} → refund record
- `POST /v1/webhook_endpoints` body={url, events_subscribed, signing_secret} → endpoint config
- `GET /v1/balance` → merchant's current balance (derived from ledger)
- Webhook receiver: POST to merchant's URL with payload + `Stripe-Signature` HMAC header

### HLD
The payment flow has three independent state machines that must compose into exactly-once semantics:

**1. Idempotency layer (front of charge endpoint).** On request, the gateway extracts `Idempotency-Key` and computes `body_hash`. It looks up `(key, body_hash)` in the **idempotency store** (Redis with persistence, or FoundationDB-class transactional KV; TTL 24h default). Three outcomes: (a) miss → record an "in-flight" entry + proceed to ledger; (b) hit with matching status="succeeded" → return cached response immediately (this is the replay path); (c) hit with mismatched body_hash → HTTP 422 (client bug, key reuse with different content — surfacing this is non-negotiable; silently treating it as success leads to subtle correctness violations). If the store is down: fail closed (return 503 + Retry-After) because admitting writes without idempotency risks double-charging.

**2. Ledger layer (double-entry atomic write).** The charge produces 2+ ledger entries: debit user_balance $100, credit merchant_balance $100. These must commit atomically in a single serializable transaction (Postgres SERIALIZABLE, FoundationDB, Spanner). For cross-shard accounts (user in shard A, merchant in shard B), use cross-shard transactions (FoundationDB, Spanner) or fall back to the **outbox pattern** (atomically write the charge + outbox entry in shard A, async-process the outbox to credit merchant in shard B, accept brief consistency window). Once the ledger commits, the charge state moves to "succeeded" in the idempotency record.

**3. Webhook delivery (at-least-once outbox).** When the charge succeeds, an event is written to an **outbox table** in the same transaction as the ledger commit (atomic with the ledger). A worker tails the outbox, publishes the event to a Kafka topic (or directly POSTs to the merchant's webhook URL with HMAC signature). Failed deliveries retry with exponential backoff + jitter for hours-to-days; after exhausting retries, the event goes to a dead-letter queue for ops review. Merchants must handle duplicate webhooks (use event_id as the dedup key).

**Reconciliation pipeline** runs continuously: a streaming process consumes the ledger event log, periodically checks cross-foot (sum of debits == sum of credits per period). Daily batch job reconciles Stripe's ledger against bank statements (or the bank's API response history); detects discrepancies (charge succeeded in Stripe but bank shows no record, or vice versa); alerts ops + opens a reconciliation case for human resolution.

**Banking-network race protection**: when Stripe calls the bank API to authorize a charge, the response may time out before Stripe knows the outcome. Naive retry doubles the charge. Production answer: the bank API call itself uses an **idempotency-key at the bank-API level** (most modern bank APIs support this — Stripe sends a UUID; bank dedups on its side); if no idempotency support, Stripe records the in-flight call + checks status before retrying.

### Deep dives
1. **Idempotency-key + request-fingerprint with TTL.** The idempotency store maps `(idempotency_key, body_hash) → (status, response, timestamp)`. On request: compute body_hash (SHA256 of canonicalized body); look up `(key, body_hash)`. **Three responses, three semantics**: (a) miss → record "in-flight" status with TTL + proceed; (b) hit with matching body_hash AND status="succeeded" → return cached response (this is the replay — exact same request, server has already processed); (c) hit with **mismatched body_hash** → HTTP 422 with explicit error ("Idempotency-Key X was previously used with different request body; ensure your client generates a unique key per logical request"). Why c is non-negotiable: if the client accidentally reuses the same key for two different charges (a bug), silently returning the first charge's response masks the second charge — the user thinks they paid for B but only A is recorded. Surfacing the violation forces the client-side bug fix. **TTL choice**: 24h default balances replay window vs storage cost; some integrations need longer (7d) for high-latency webhooks; never less than ~1h (clients may retry hours after the original). Staff+ commit: storage choice (Redis with AOF + replica failover, or FoundationDB for guaranteed durability), TTL policy, what happens during store outage (fail closed — better than risking double-charge), idempotency-key SHA-256-collision possibility (assume negligible at 128-bit space).

2. **Double-entry ledger atomicity + cross-shard transactions.** Double-entry: every accounting transaction produces ≥2 journal entries that sum to zero (debit one account, credit another). Invariant: per-period sum of debits = sum of credits; violation = drift, indicating partial commit or bug. **Atomic commit requirement**: both entries must persist together or neither — partial commit produces drift. For single-shard accounts: trivial via Postgres SERIALIZABLE transaction. For cross-shard accounts (user in shard A, merchant in shard B): three architectures: (a) **distributed transaction** (FoundationDB, Spanner, CockroachDB) — strong but expensive; (b) **outbox pattern** — atomic commit of (debit + outbox event) in shard A, async processing of outbox to issue credit in shard B; produces a brief window where shard A reflects the debit but shard B doesn't yet show the credit; (c) **two-phase commit** — classical, blocking on coordinator failure (Spanner mitigates by replicating the coordinator). **Outbox** is the production sweet spot for most payment systems: simpler than 2PC, eventually-consistent on cross-shard but each shard is internally consistent; the brief window is acceptable because the merchant's balance is computed from ledger entries (a query summing all entries for merchant_id reflects the new credit as soon as it's persisted, regardless of cross-shard order). Staff+ commit: pick architecture with criteria, address the cross-foot reconciliation cadence + drift-detection alert, what happens to outbox-pending entries during shard failure.

3. **Webhook delivery + Saga pattern for multi-step orchestrations.** Webhook delivery is at-least-once: Stripe writes the event to outbox atomically with ledger commit; worker publishes (HTTPS POST to merchant's URL with HMAC signature); retries on 5xx/timeout with exponential backoff (1s, 5s, 30s, 5min, 30min, 2h, 12h, ...) up to a max retention window (default 3 days at Stripe). After exhausting, event moves to a dead-letter queue + alert. Merchant is responsible for handling duplicates (use event_id as dedup key). For multi-step flows (e.g., a marketplace payment: charge user → split → credit multiple merchants → refund on dispute), use the **Saga pattern**: each step has a compensating action; if step N fails, undo steps 1..N-1 in reverse order. Sagas avoid distributed transactions across multiple external services (the bank API has no notion of distributed transaction). Implementation: state machine in a transactional store (each step's success/failure persisted; compensations have their own idempotency keys); on partial failure, the state machine triggers compensations in reverse order. Reference: Garcia-Molina & Salem, SIGMOD 1987. Staff+ commit: webhook retry schedule, dead-letter policy, when to use saga vs distributed transaction.

## Known failure modes
1. **Idempotency-key reuse across different requests (client bug).** Client accidentally reuses the same key for two distinct charges (e.g., uses a non-random source like timestamp truncated to seconds). Without fingerprint check, the server silently returns the first charge's response — masks the second request entirely. Production answer: store body_hash with the key; reject mismatched body with HTTP 422 + explicit error message; log the violation for client-side debugging. The 422 forces the client team to fix their key-generation logic rather than discovering the bug via missing charges months later.

2. **Ledger drift from non-atomic cross-shard commit.** Cross-shard transaction partially commits → user balance debited, merchant balance not yet credited → ledger out of balance until the second commit lands. Discovered via daily cross-foot reconciliation; manual repair required (find the missing credit, post it, document the cause). Production answer: serializable cross-shard transactions where possible (Spanner, FoundationDB); outbox pattern as the second-best with explicit cross-foot reconciliation pipeline; alerting on drift exceeding threshold (e.g., $1 / hour) for immediate investigation.

3. **Bank network race causes double-pay.** Stripe calls bank API to authorize charge; bank confirms but Stripe's connection times out before receiving the response; Stripe retries → bank receives 2nd authorization attempt → potential double-pay. Production answer: use the bank API's own idempotency primitive where supported (Stripe sends a UUID; bank dedups on its side); for banks without idempotency, record the in-flight call before issuing it, then poll bank for status before retrying; reconciliation against bank statements catches any double-pay within hours and triggers automatic refund of the duplicate.

## Notes for the coach
- **This is the Stripe signature Staff system-design prompt** per CodeToDeploy's published framing: "the Staff question that separates Senior from Staff." The Stripe engineering blog on idempotency is the primary reference; the Exponent Stripe question library lists multiple variants ("Design a Bookkeeping Service," "Design distributed LRU cache," "Design APM" — all Stripe Staff prompts).
- **The idempotency-key + request-fingerprint with explicit 422 on mismatch is the unlock.** A candidate who only describes `key → response` without the body_hash check is at Senior bar; the Staff+ candidate names the fingerprint check and articulates why silent success on mismatch is a correctness violation.
- **The honest "exactly-once = at-least-once + idempotency" framing is the bar.** A candidate who claims true exactly-once across multiple systems (bank API + DB + cache + webhook) is missing the bar — those systems don't share a distributed transaction; exactly-once is achieved via at-least-once delivery + idempotent receivers at every layer. The Staff+ candidate articulates this honestly.
- **The Saga pattern for multi-step orchestrations is the L7 differentiation flex.** Most candidates default to "distributed transaction" without considering that the bank API isn't a participant; the Sr Staff candidate names Sagas + compensating actions explicitly.
- **Decimal precision + per-currency rounding is the correctness-bar move.** Floating-point math for money is a hard "no"; surfacing this unprompted demonstrates production-payment-system literacy.
- **No direct AI-infra counterpart** — payment processing is generic; the idempotency + double-entry ledger patterns reappear in AI-billing systems (per-token cost accounting against tenant budget) but the substrate is the same.
- **Don't allow drift into "design Stripe full product" — stay on the payment-processing primitive shape.** If the candidate proposes the entire Stripe product (subscriptions, invoicing, Connect marketplaces), redirect: "let's stay on the core exactly-once payment primitive; subscriptions are a separate design problem."

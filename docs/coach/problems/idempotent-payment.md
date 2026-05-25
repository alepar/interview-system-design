---
slug: idempotent-payment
archetype: concurrent-resource
sources:
  stripe_idempotency_api: docs.stripe.com/api/idempotent_requests
  stripe_idempotency_blog: stripe.com/blog/idempotency
  brandur_idempotency: brandur.org/idempotency-keys
  airbnb_orpheus: medium.com/airbnb-engineering/avoiding-double-payments-in-a-distributed-payments-system-2981f6b070bb
  idempotency_states: blog.dochia.dev/blog/idempotency/
---

# Idempotent Payment (exactly-once under concurrent retries)

## Bar anchors
- **Mid-level (L4/E4):** Charges on each request. Doesn't see that a timeout/double-click/retry double-charges, or how to dedup.
- **Senior (L5/E5):** Client supplies an idempotency key; server stores key→result and returns the stored result on retry. Knows at-least-once delivery + idempotency = effectively-once. May not handle concurrent same-key requests, the state machine, or recovery of a crashed mid-charge.
- **Staff+ (L6/E6+):** Drives proactively. Uses **client-generated idempotency keys** (Stripe: V4 UUID, in a header, on POST only — *must* be client-side, or a retry after timeout generates a new key and bypasses dedup) with a **dedup store** (key → status+body, TTL ~24h). Handles **concurrent same-key requests** with a **DB unique constraint / `INSERT … ON CONFLICT`** so exactly one executes and the rest get **409** (or the stored result) — and models the key as a **state machine** (`started → in_progress → completed`, with recovery for stale `in_progress`). Caches the result even for **failures (incl. 500s)** so retries replay; **validates that retried params match** the original (reject mismatched reuse). Knows **retryable vs non-retryable** (don't cache validation 4xx; do replay committed results), pairs it with **exponential backoff + jitter** on the client, and references **Brandur's Postgres recovery-point** design and **Airbnb Orpheus** (row-lock per key, 3-phase pre/RPC/post, shard by key, 99.999%, Kafka at-least-once → exactly-once). Distinct: **retry-on-conflict ≠ retry-on-network-blip**.

## Canonical decomposition

### Requirements
**Functional:**
- A retried/duplicated payment request charges at most once (effectively-once)
- Concurrent requests with the same key don't both execute
- A crashed mid-charge recovers without double-charging or losing the charge

**Non-functional (with numbers):**
- Idempotency key TTL ~24h (Stripe); key ≤255 chars
- At-least-once delivery + idempotency = exactly-once effect
- Result cached even for failures (incl. 500) for replay
- Airbnb Orpheus: 99.999% consistency at doubled volume

### Core entities
- **Idempotency key:** client-generated UUID identifying the operation
- **Dedup record:** key → {status, recovery_point, cached response, params hash}, TTL
- **State machine:** started → in_progress → completed (+ recovery for stale in_progress)
- **Lock:** row-level lock per key serializing concurrent same-key requests

### API
- `POST /charge` with `Idempotency-Key: {uuid}` → first request executes; retries replay stored result
- concurrent same-key: one wins the `INSERT … ON CONFLICT` / row lock, others 409 or wait
- replayed responses flagged (e.g. `Idempotent-Replayed: true`)

### HLD
The problem: networks are at-least-once, so a charge request may time out *after* the server committed, and the client retries — without dedup, that double-charges. The fix is an **idempotency key**: the **client** generates a unique key (UUID) per logical operation and sends it on the POST; the server keys a **dedup record** by it. On a retry with the same key, the server returns the **stored result** instead of re-executing (Stripe caches status+body, even for 500s, for ~24h; keys ≤255 chars; replayed responses flagged). The key *must* be client-generated — if the server generated it, a retry after a timeout would mint a new key and bypass dedup entirely.

Two hard parts. **Concurrency**: two requests with the same key arriving together must not both execute. A **DB unique constraint** on the key (`INSERT … ON CONFLICT DO NOTHING`, atomic) lets exactly one win the insert and execute; the others get **409 Conflict** (retry once the key reaches `completed`) or block on a **row-level lock** on the key (Airbnb Orpheus). **Recovery**: model the key as a **state machine** — `started → in_progress → completed` (Brandur's `recovery_point` column) — split around the external charge so a retry resumes just before the last failed step; a stale `in_progress` (original processor likely dead) is reclaimed after a timeout and safely re-executed. The result must be cached for **failures too** (so a retry replays the failure, not re-charges), and the server should **validate that retried params match** the original (reject a key reused for a different charge). Classify exceptions **retryable** (5xx/infra — retry with the same key) vs **non-retryable** (4xx validation — don't cache, the client must fix and use a new key). The client retries with **exponential backoff + jitter** to avoid a thundering herd. Orpheus shows the production form: a row-lock per key, a 3-phase pre-RPC / RPC / post-RPC split (no network in pre/post, no DB during the RPC), sharding the idempotency DB by key, turning Kafka's at-least-once into exactly-once, reaching 99.999% consistency.

### Deep dives
1. **Idempotency key + the dedup store (client-generated, why).** The key turns at-least-once into effectively-once: store `key → result` and replay on retry. The non-obvious requirement is **client-side generation** — the key must be stable across the client's retries, so the *client* mints it once per operation; a server-generated key changes on each retry and defeats dedup. The store caches the full result (status + body) — including failures (a 500 retry replays the 500, doesn't re-charge) — with a TTL (~24h) after which the key is pruned and reuse starts fresh. Param-matching guards against a key being accidentally reused for a *different* operation (Stripe errors on mismatch). The framing: the key is the operation's identity; the dedup store is its memoized result.
2. **Concurrency on the same key.** A double-click or a fast retry can send two same-key requests *simultaneously* (before the first completes), so caching-the-result isn't enough — you need mutual exclusion *per key*. The clean mechanism is a **DB unique constraint**: `INSERT` the key row first (`ON CONFLICT DO NOTHING`); exactly one request wins the insert and proceeds, the losers see the conflict and either return 409 (retry when `completed`) or wait. Orpheus uses an explicit **row-level lock per idempotency key** (a lease with expiry). This is where naive idempotency (check-then-act on the key) reintroduces a race — the check and claim must be atomic (the unique insert *is* the atomic claim). The Staff+ point: idempotency under concurrency needs a per-key lock/constraint, not just a result cache.
3. **State machine + crash recovery + retry classification.** The genuinely hard case is a crash *during* the external charge: did it go through? Model the key's progress as a **state machine** (`started → in_progress → completed`, Brandur's recovery_point), splitting local DB writes into atomic phases *around* the foreign charge, so a retry resumes at the recovery point rather than redoing the charge. A stale `in_progress` (locked_at older than a timeout ⇒ original processor dead) is reclaimable and safely retried. Combine with **exception classification**: retryable (5xx/timeout — retry same key) vs non-retryable (4xx validation — don't cache, fix and re-issue) — because retrying a validation error forever is pointless and caching it would wrongly memoize a failure. Plus client **backoff + jitter** so retries don't stampede. This recovery discipline is what makes payments *exactly-once* rather than merely *deduped-on-happy-path*.

## Known failure modes
1. **Double-charge on retry/timeout.** A committed charge times out and the client retries. Production answer: client-generated idempotency key + dedup store replaying the stored result (incl. failures); server-generated keys do NOT work.
2. **Concurrent same-key double-execution.** A double-click sends two requests before the first finishes. Production answer: DB unique constraint / `INSERT … ON CONFLICT` (atomic claim) or row-level lock per key; losers get 409 / wait.
3. **Crash mid-charge (unknown outcome).** Process dies during the external call; was the charge made? Production answer: state machine with a recovery point (resume, don't redo), stale-`in_progress` reclamation after a timeout, retryable-vs-non-retryable classification.

## (Delineation note)
`idempotent-payment` is the exactly-once-under-retries concurrency primitive underlying bookings, coupons, and orders across this archetype. The full payment *processor* (ledger, gateways, settlement) is infra-primitives `stripe-payments` — reference, don't re-derive. Here it's idempotency keys + per-key concurrency control + recovery.

---
slug: coupon-redemption
archetype: concurrent-resource
sources:
  redis_coupon: oneuptime.com/blog/post/2026-03-31-redis-coupon-promo-code-validation/view
  redis_atomic: linkedin.com/pulse/handling-race-conditions-using-redis-atomic-ericson-cepeda-l%C3%B3pez
  airbnb_orpheus: medium.com/airbnb-engineering/avoiding-double-payments-in-a-distributed-payments-system-2981f6b070bb
  race_coupon: blogs.jsmon.sh/what-is-race-condition-in-coupon-redemption-ways-to-exploit-examples-and-impact/
  redis_idempotency: oneuptime.com/blog/post/2026-01-21-redis-idempotency-keys/view
---

# Coupon Redemption (limited-quantity promo codes)

## Bar anchors
- **Mid-level (L4/E4):** Checks `used_count < max` then increments. Doesn't see that check-then-increment is a race (two users both pass the check on the last coupon), or enforce one-per-user.
- **Senior (L5/E5):** Atomic decrement of a remaining count (Redis or conditional DB update), one-per-user via a set/unique constraint, idempotency on retry. Knows the last-coupon race is the crux. May not articulate the atomic check-and-decrement, the hot single-counter contention, or the idempotency-key framework.
- **Staff+ (L6/E6+):** Drives proactively. Identifies the classic **check-then-use race** (between checking `remaining > 0` and decrementing, another request slips in) and makes it **atomic**: a Redis **Lua script** (`if used_count < max then INCR; SADD user`) or a DB **conditional update** `UPDATE coupons SET used_count = used_count + 1 WHERE used_count < max_uses` (0 rows ⇒ lost the race on the last coupon). Enforces **one-per-user** with a `coupon:used:{code}` set (SADD/SISMEMBER) and a DB unique constraint; makes redemption **idempotent** (client idempotency key, dedup store) so retries/double-clicks don't double-redeem. Handles the **hot single counter** ("first 1,000 users" = one hot key) via sharded sub-counters or pre-loading codes split across keys (~5× contention relief). References **Airbnb Orpheus** (idempotency framework: row-level lock per idempotency key, 3-phase pre/RPC/post, sharded by key, 99.999% consistency) as the production pattern for exactly-once redemption. Quotes sub-10ms validation at thousands/sec.

## Canonical decomposition

### Requirements
**Functional:**
- Redeem a coupon; enforce a global quantity limit (first N users) and per-user limit
- Never over-redeem (no N+1th redemption); never double-redeem under retry
- Validate fast (inline at checkout)

**Non-functional (with numbers):**
- Validation <10ms at thousands of concurrent redemptions/sec
- Hot single counter (one popular code) → contention; zero over-redemption
- Idempotency-key TTL (~24h); one-per-user enforced

### Core entities
- **Coupon:** code → {discount, max_uses, used_count, expiry, active}
- **Redemption set:** coupon:used:{code} → set of user IDs (one-per-user)
- **Idempotency key:** per-redeem token to dedup retries
- **Counter:** used_count (or remaining), the contended resource

### API
- `POST /redeem {code, user, idempotencyKey}` → atomic check-and-redeem; 200 / 409 (used up) / 409 (already redeemed)
- Redis Lua: `if SISMEMBER used user then dup; if used_count >= max then soldout; INCR used_count; SADD used user`
- DB guard: `UPDATE coupons SET used_count = used_count+1 WHERE code=? AND used_count < max_uses`

### HLD
The whole problem is one race: **between checking "coupons remain" and consuming one, a concurrent request can slip in**, so two users redeem the last coupon (over-redemption). The fix is to make check-and-decrement **a single atomic operation**. Two equivalent mechanisms: a Redis **Lua script** that atomically does dedup (SISMEMBER on `coupon:used:{code}`) → limit check (`used_count < max`) → increment (INCR) → record-user (SADD), all as one indivisible unit (Redis is single-threaded; the script can't be interleaved); or a DB **conditional update** `UPDATE coupons SET used_count = used_count + 1 WHERE used_count < max_uses` where **0 affected rows** means the coupon hit its limit (you lost the race on the last one). One-per-user is the `coupon:used:{code}` set (a repeat SADD is a no-op / detected by SISMEMBER) plus a DB unique constraint `(coupon, user)` as the durable guarantee.

**Idempotency** layers on top: a client-supplied idempotency key (UUID), tracked in a dedup store, ensures a retried or double-clicked redeem produces the **same result** without a second decrement — exactly the Stripe/Airbnb pattern. Airbnb's **Orpheus** is the reference for getting this right at scale: each redeem acquires a **row-level lock on the idempotency key** (so two requests with the same key never run concurrently), splits work into pre-RPC/RPC/post-RPC phases, shards the idempotency DB by key (high cardinality → even distribution), and reaches 99.999% consistency. The **hot single counter** ("first 1,000 redemptions" = one hot key) is relieved by sharding the remaining-count into N sub-keys (decrement a random shard, sum for display) or pre-loading the codes split across keys (~5× contention relief). Validation runs **inline at checkout** under a <10ms budget at thousands/sec.

### Deep dives
1. **The check-then-use race + atomic fix.** Walk it: `remaining = GET(code)` returns 1 for two concurrent requests; both pass `remaining > 0`; both decrement → −1 (two redemptions of one coupon). This is a textbook logical race — you cannot trust state between check and use unless they're one atomic step. Redis Lua (single-threaded, script-atomic) or a DB conditional `UPDATE … WHERE used_count < max` (the predicate re-evaluated atomically at write time, 0 rows = lost) both collapse check+decrement into one operation. The Staff+ articulation: the limit check must be *part of* the mutation, not a separate read — and the DB unique constraint on `(coupon, user)` is the last line of defense even if the app logic is wrong.
2. **One-per-user + idempotency (distinct concerns).** Two different "don't redeem twice" requirements: **per-user limit** (this user already used this code — a `coupon:used:{code}` set + unique constraint) and **idempotency** (this *request* was retried — same idempotency key returns the same result without re-redeeming). They're orthogonal: idempotency prevents a double-click/retry from counting twice; the per-user set prevents the same user from redeeming via two *different* requests. Airbnb Orpheus shows the rigorous version — a row-level lock per idempotency key serializes same-key requests, with retryable vs non-retryable exception classification and a state machine so a crashed mid-redeem can be safely recovered. Conflating the two (e.g. relying on idempotency for the per-user limit) is a common bug.
3. **Hot-counter contention + fast inline validation.** A wildly popular code ("first 1,000 free") concentrates all decrements on one counter — the same hot-key problem as `flash-sale`/`view-counter`. Relief: shard the remaining-count into N sub-keys (decrement a random shard, reconcile for the global limit) or pre-split the coupon pool across keys (~5× throughput). Meanwhile validation is **inline at checkout** (it gates the order), so it must be fast (<10ms) — hence Redis (sub-ms atomic ops, hash-stored codes) with the DB as the durable backstop, not the hot path. The framing: a limited coupon is a distributed atomic counter with per-user dedup, and at scale it inherits the hot-key and idempotency problems of the broader archetype.

## Known failure modes
1. **Over-redemption (N+1 on the last coupon).** Check-then-decrement race lets two redeem the last one. Production answer: atomic Lua / conditional `UPDATE … WHERE used_count < max` (0 rows = reject); DB unique/limit constraint as backstop.
2. **Double-redemption by one user / on retry.** A user redeems twice, or a retried request counts twice. Production answer: per-user set + unique `(coupon, user)` constraint for the user limit; idempotency key (Orpheus-style row-lock per key) for retries — kept distinct.
3. **Hot-counter contention.** One viral code serializes all decrements. Production answer: shard the counter / pre-split the pool across keys; Redis atomic ops on the hot path, DB durable; reconcile the global limit across shards.

## (Delineation note)
`coupon-redemption` is the limited-codes atomic-counter variant of the archetype — a focused, often 25-min problem. It shares atomic-decrement with `flash-sale` and idempotency with `idempotent-payment` (reference, don't re-derive). Building Redis is infra-primitives; the payment engine is `stripe-payments`.

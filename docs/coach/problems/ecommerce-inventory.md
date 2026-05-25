---
slug: ecommerce-inventory
archetype: concurrent-resource
sources:
  shopify_reservations: shopify.engineering/scaling-inventory-reservations
  occ_efcore: medium.com/@gobranfahd/mastering-concurrency-pessimistic-vs-optimistic-patterns-in-net-ef-core-24dd2b7efe19
  stripe_limited_inventory: docs.stripe.com/payments/checkout/managing-limited-inventory
  woo_reserve_stock: woocommerce.com/products/reserve-stock-for-woocommerce/
  saga_pattern: oneuptime.com/blog/post/2026-02-20-microservices-saga-pattern/
---

# E-commerce Inventory (checkout reservation + deduction at scale)

## Bar anchors
- **Mid-level (L4/E4):** `UPDATE stock SET qty = qty - 1` on order. Doesn't handle two buyers racing for the last unit, reservation during checkout, or release on payment failure.
- **Senior (L5/E5):** Conditional decrement (`WHERE qty >= n`), reserve stock during checkout with a TTL, deduct on payment. Knows oversell must be prevented and reads dominate. May not articulate reserve-on-cart-vs-deduct-on-payment, the row-per-unit/SKIP LOCKED scaling, or saga compensation.
- **Staff+ (L6/E6+):** Drives proactively. Prevents oversell with the **conditional update** `UPDATE stock SET qty = qty - n WHERE id = ? AND qty >= n` (0 rows affected ⇒ insufficient/conflict) or **OCC with a version column**, and reasons about **reserve-on-add-to-cart vs deduct-on-payment**: reserve-on-cart prevents the last-unit race but creates **phantom inventory** (70% cart-abandonment locks real stock), while deduct-on-payment avoids phantom stock but has a **last-unit race** at checkout. Uses **reservation with a TTL** (soft hold, released on timeout) bridging the two. Cites **Shopify's Redis→MySQL migration**: a **row-per-unit** model (one row per inventory unit, reserve = move N rows) with **`SKIP LOCKED`** + **READ COMMITTED** + a composite PK + a bounded 1,000-row pool, sustaining **$5.1M sales/min** at BFCM (the real bottleneck was *connection-pool exhaustion*, not query speed). Handles payment-failure with a **saga / compensating transaction** (release the hold). For flash spikes, references the `flash-sale` Redis-gate pattern.

## Canonical decomposition

### Requirements
**Functional:**
- Reserve/deduct stock at checkout; never oversell the last unit under concurrency
- Hold stock during checkout; release on timeout or payment failure
- Scale to high concurrent checkouts (esp. sale events) across warehouses

**Non-functional (with numbers):**
- Massively read-heavy availability; writes (reservations) the contended path
- Shopify BFCM 2025: $5.1M sales/min at peak; 1,000-row bounded reservation pool per item/location
- Reservation TTL minutes (Stripe Checkout expires_at 30 min–24 h); zero oversell
- Cart abandonment ~70% (phantom-inventory pressure if reserving on cart)

### Core entities
- **Stock / inventory unit:** qty counter, or (Shopify) one row per physical unit
- **Reservation:** a hold on N units during checkout, with a TTL
- **Order:** created on payment success; reservation → permanent deduction
- **Saga:** order → payment → inventory chain with compensations

### API
- `POST /reserve {sku, qty, cart}` → conditional decrement / move N rows; TTL hold
- `POST /checkout` → payment → confirm reservation (permanent deduction) or release (saga compensate)
- conditional: `UPDATE stock SET qty = qty - n WHERE id = ? AND qty >= n` (0 rows ⇒ reject)
- expiry: background job releases timed-out reservations back to available

### HLD
The central decision is **when to commit stock**. **Deduct-on-payment** (reduce stock only on successful payment) avoids locking stock for abandoned carts, but creates a **last-unit race**: two buyers both add the last item and both reach checkout, and one gets a late "sold out." **Reserve-on-add-to-cart** prevents that race by holding stock immediately, but produces **phantom inventory** — with ~70% cart abandonment, large fractions of stock sit locked in dead carts, appearing unavailable when it isn't. The production middle ground is **reservation with a TTL**: a **soft hold** during checkout (Stripe Checkout `expires_at`, 30 min–24 h) that auto-releases on timeout, giving last-unit safety without permanently locking stock to abandoners.

Oversell is prevented with an **atomic conditional update** (`UPDATE … SET qty = qty - n WHERE qty >= n` — 0 affected rows means insufficient stock or a lost race, no oversell) or **OCC** (version column, retry on conflict). At high contention a single stock row becomes a **hot row** (serialized updates). Shopify's published evolution is the reference: they moved reservations from Redis to **MySQL** with a **row-per-unit** model (10 units = 10 rows; reserving 3 = select-and-move 3 rows in one transaction) using **`SKIP LOCKED`** (skip rows locked by concurrent txns rather than wait), **READ COMMITTED** isolation (avoid gap locks), a composite PK (cut 2 row-locks to 1), and a **bounded 1,000-row pool** per item/location — sustaining **$5.1M/min** at Black Friday, where the real bottleneck turned out to be **connection-pool exhaustion** from unrelated checkout work, not reservation queries. Payment failure triggers a **saga**: the order→payment→inventory chain compensates by **releasing the reservation** if a downstream step fails. For extreme flash spikes, the `flash-sale` Redis-gate pattern fronts the DB.

### Deep dives
1. **Reserve-on-cart vs deduct-on-payment vs TTL reservation.** The defining tradeoff. Deduct-on-payment: no phantom stock, but a last-unit race (two buyers, one disappointed at checkout). Reserve-on-cart: no race, but ~70% abandonment locks real inventory (phantom stock — looks sold out when it isn't, lost sales). **TTL reservation** is the synthesis: hold during the active checkout window (minutes) and auto-release on timeout, so you get last-unit safety without permanently sacrificing stock to abandoners. The choice depends on scarcity (reserve aggressively for limited drops, lazily for abundant SKUs) and conversion economics. Naming the phantom-inventory cost of reserve-on-cart is the Staff+ signal.
2. **Oversell prevention + the hot-row problem (Shopify).** The atomic guard is `UPDATE … WHERE qty >= n` (or version OCC) — the DB enforces "don't go below zero" in one statement. But a popular SKU's single stock row is a **hot row**: concurrent updates serialize on its lock, capping throughput. Shopify's answer (a real, documented migration) is the **row-per-unit** model — one row per physical unit, so reserving N is moving N distinct rows, and **`SKIP LOCKED`** lets concurrent transactions grab *different* available rows instead of queuing on one counter — plus READ COMMITTED to avoid gap locks and a composite PK to halve lock count. The punchline (a great interview beat): at $5.1M/min the bottleneck was **connection-pool exhaustion** from other checkout steps, not the reservation query — a reminder to profile the whole path. 
3. **Reservation lifecycle + saga compensation.** A reservation is a state machine: `hold` (TTL) → `confirm` (permanent deduction on payment) or `release` (timeout / payment failure / cancel). Across services (order, payment, inventory, shipping), this is a **saga**: a chain of local transactions where a downstream failure (payment declined, shipping unavailable) triggers **compensating transactions** that release the held inventory and void the order. The hold's TTL is the safety net for crashed/abandoned checkouts (auto-release), and idempotency keys make the confirm/release safe under retries. The framing: inventory is held provisionally, committed only on full success, and every failure path has an explicit compensation that returns the units — otherwise stock leaks.

## Known failure modes
1. **Oversell of the last unit.** Concurrent buys both succeed. Production answer: atomic conditional update (`WHERE qty >= n`) or version OCC; row-per-unit + `SKIP LOCKED` to scale the hot row; DB constraint as the floor.
2. **Phantom inventory / stuck reservations.** Abandoned carts lock stock that never sells. Production answer: TTL on reservations with a background release job; reserve at checkout (not add-to-cart) for scarce items; monitor reserved-but-unsold ratio.
3. **Leaked stock on payment failure.** A failed payment leaves inventory deducted. Production answer: saga with compensating transactions (release the hold on any downstream failure); TTL auto-release as backstop; idempotent confirm/release.

## (Delineation note)
`ecommerce-inventory` is the steady-state checkout-reservation variant of the archetype (vs `flash-sale` extreme spike, `ticketmaster` seat holds, `hotel-booking` date intervals). The read-heavy availability *display* is the caching archetype (`product-catalog`); the payment engine is `stripe-payments`; idempotency depth is `idempotent-payment`. Here it's reservation lifecycle + oversell prevention + hot-row scaling.

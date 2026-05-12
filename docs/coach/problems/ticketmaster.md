---
slug: ticketmaster
archetype: concurrent-resource
sources:
  hello_interview: hellointerview.com/learn/system-design/problem-breakdowns/ticketmaster
---

# Ticketmaster (Event Ticketing with Seat Reservation)

## Bar anchors
- **Mid-level (L4/E4):** Produces an architecture that solves the double-booking problem using at least one valid concurrency strategy — optimistic concurrency control (OCC) with a version column, pessimistic row locking (`SELECT FOR UPDATE`), or a Redis distributed lock (SETNX). Defines the hold-then-book flow with a seat status state machine (available → held → booked). Does not need to lead the idempotency, fairness queue, or split-brain discussion unprompted.
- **Senior (L5/E5):** Proactively compares OCC vs pessimistic locking vs Redis Redlock, names concrete trade-offs (OCC high abort rate under contention; pessimistic locking serializes throughput; Redlock has split-brain risk). Names idempotency on `POST /bookings` using a client-supplied idempotency key. Discusses hold TTL expiry and the race condition between expiry and booking commit. Proposes a virtual waiting room for hot drops without waiting to be asked.
- **Staff+ (L6/E6+):** Drives the entire session. Proactively raises: Redis split-brain failure mode during distributed lock (fencing tokens as mitigation); partial failure during payment (payment succeeds, booking DB write fails — reconciliation job design); multi-region consistency for global events; cost vs availability trade-off for seat inventory (Postgres vs DynamoDB vs Redis-primary). Discusses long-term operational concerns: hold TTL tuning, seat map schema versioning for complex venues, audit trail for disputed bookings.

## Canonical decomposition

### Requirements
**Functional:**
- Browse events and view seat availability in real time
- Place a temporary hold on one or more seats (short TTL)
- Complete a booking by paying for a held seat
- Cancel a booking or allow a hold to expire (seats return to available)
- View booking history for a user

**Non-functional (with numbers):**
- 10,000 concurrent users on a hot drop (Taylor Swift on-sale) hitting the booking endpoint simultaneously
- Hard requirement: zero double-bookings (consistency over availability for seat state)
- Booking flow latency <500ms p95 end-to-end (hold + payment + confirmation)
- Payment exactly-once: no duplicate charges under any failure mode
- Seat inventory reads (event browse) <100ms p95
- 99.99% availability for read (browse) path; 99.9% for write (booking) path

### Core entities
- **Event:** event_id, name, venue_id, date_time, status (on-sale/sold-out/cancelled)
- **Venue:** venue_id, name, capacity, seat_map (JSON layout)
- **Seat:** seat_id, venue_id, section, row, number, status (available/held/booked)
- **Hold:** hold_id, seat_id, user_id, expires_at, created_at
- **Booking:** booking_id, hold_id, seat_id, user_id, payment_id, created_at, status (confirmed/cancelled)
- **Payment:** payment_id, booking_id, amount, provider_ref, status (pending/succeeded/failed)

### API
- `GET /events/:id` → {event, venue, sections[], available_count}
- `GET /events/:id/seats` → {seats[{seat_id, section, row, number, status}]}
- `POST /events/:id/holds` body={seat_ids[]} → {hold_id, seat_ids, expires_at} (max hold TTL: 10 min)
- `POST /bookings` body={hold_id, payment_token, idempotency_key} → {booking_id, confirmation_number}
- `DELETE /holds/:id` → 204 No Content (release hold early)
- `GET /users/:id/bookings` → {bookings[]}

### HLD
Seat inventory lives in a sharded Postgres cluster, sharded by `event_id`. Each `Seat` row carries a `status` column (available/held/booked) and an `version` integer for optimistic concurrency control. The `Hold` table stores the temporary reservation with `expires_at`; a background sweeper job runs every 30 seconds to expire stale holds and reset seat status via a single UPDATE with a WHERE clause on `expires_at < NOW()`.

The hold flow (`POST /events/:id/holds`) opens a Postgres transaction, attempts to UPDATE seats to `held` using OCC (WHERE version = :expected_version) for each requested seat, inserts a Hold record, and commits. If any seat's version has changed (concurrent hold by another user), the transaction aborts and the client receives a 409 Conflict. This guarantees no double-hold without distributed locks. For hot drops where contention is extreme, a Redis SETNX distributed lock (with a 500ms TTL) per `seat_id` reduces database abort rate by serializing access at the cache layer before hitting Postgres.

The booking flow (`POST /bookings`) is idempotent: the server checks an `idempotency_keys` table keyed on `(user_id, idempotency_key)` before processing. If a record exists, it returns the cached response without re-charging. Otherwise it calls the payment provider (Stripe), writes the Payment record, promotes the Hold to a confirmed Booking within a single Postgres transaction, and records the idempotency result. Payment and booking write are coupled in a saga: if the Postgres write fails after Stripe succeeds, a reconciliation job detects the orphaned Stripe charge and triggers a refund.

For hot events, a virtual waiting room sits in front of the booking service: users are issued a signed JWT position token via a Redis sorted set. The booking service only accepts requests from users whose token grants them entry (dequeued in FIFO order). This converts a thundering herd into a metered stream, protecting Postgres from spike load.

### Deep dives
1. **Concurrency strategy comparison** — OCC (optimistic concurrency, version column) works well under low-to-medium contention: no locks, high throughput, but abort rate rises quadratically with concurrency on the same seat. Pessimistic locking (`SELECT FOR UPDATE NOWAIT`) serializes access per seat but serializes all requests for that row, capping throughput. Redis Redlock (distributed lock across 3+ Redis nodes) avoids DB contention but has split-brain risk: if a Redis node dies after a lock is acquired but before release, another process may acquire the same lock. Mitigation: fencing tokens (monotonic lock version checked by DB on write) ensure the later-token write wins safely. For this problem, OCC on Postgres is the recommended primary strategy because seats are isolated rows; contention per seat is bounded; and the abort rate under realistic concurrency is manageable.
2. **Idempotency on payment** — Client generates a UUID `idempotency_key` before calling `POST /bookings`. Server stores `(user_id, idempotency_key, response_body, created_at)` with a 24-hour TTL in a Postgres `idempotency_keys` table. On retry, server returns the stored response without re-calling Stripe. If the server dies after Stripe charge but before writing the idempotency record, a Stripe webhook fires `payment_intent.succeeded`, which the server uses to complete the booking and write the idempotency record. This ensures exactly-once payment under all server-side failure modes.
3. **Hot-drop traffic spike and virtual waiting room** — At Taylor Swift on-sale, 500K users hit the site in the first 30 seconds. The API gateway rate-limits to N requests/sec per IP; surplus requests are queued in a Redis sorted set by arrival time and issued a signed position token (JWT with queue position and timestamp). A dequeue worker releases batches of position tokens every 500ms, metering traffic into the booking service. Users without a valid token receive 429 with a retry-after header. This decouples external spike from internal seat contention and makes the user experience predictable (estimated wait time) rather than random failures.

## Known failure modes
1. **Redis split-brain during distributed lock** — Under a Redis network partition, Redlock may issue the same lock to two processes simultaneously if a node is unreachable. Both processes believe they hold the lock and both attempt the Postgres write. Mitigation: use fencing tokens — the lock grants a monotonically increasing token; the Postgres UPDATE includes `WHERE lock_token = :expected`; the lower-token write loses and retries. Alternatively, rely solely on Postgres OCC (version column) as the single source of truth and treat Redis as a best-effort contention reducer, not a correctness guarantee.
2. **Payment succeeds but booking write fails** — Network timeout or Postgres failure between Stripe charge and the `INSERT INTO bookings` write leaves the user charged with no booking. Mitigation: idempotent Stripe PaymentIntent (charge is created before DB write, idempotency_key matches); a reconciliation job runs every 5 minutes, joining Stripe charges to bookings table; orphaned charges (charge exists, no booking) trigger automatic refund and notification. Additionally, the booking flow uses a Postgres savepoint so the Stripe call happens inside the transaction boundary where feasible (use Stripe async confirm to allow rollback).
3. **Hold expiry race vs booking commit** — A hold expires (swept by background job) at the exact moment a user submits payment. The sweeper resets the seat to `available`; a second user places a hold; the first user's booking commit succeeds anyway (old hold_id still in DB for a brief window). Mitigation: the booking transaction checks `holds.expires_at > NOW()` inside the same atomic Postgres transaction as the status promotion. If the hold is expired, the transaction aborts with a 410 Gone; the user is prompted to re-select seats. Background sweeper uses a two-phase approach: mark hold as `expiring` first, then confirm no booking references it before resetting the seat.

---
slug: hotel-booking
archetype: concurrent-resource
sources:
  bytebytego_hotel: bytebytego.com/courses/system-design-interview/hotel-reservation-system
  pg_exclusion: axellarsson.com/blog/postgres-prevent-overlapping-time-inteval/
  pg_exclusion2: blog.danielclayton.co.uk/posts/overlapping-data-postgres-exclusion-constraints/
  sd_handbook_hotel: systemdesignhandbook.com/guides/design-hotel-booking-system/
  reservation_medium: medium.com/@grewalchahat007/design-a-reservation-system-airbnb-expedia-or-hotel-reservation-6bd6b8218bba
---

# Hotel Booking (concurrent date-range room reservation)

## Bar anchors
- **Mid-level (L4/E4):** Marks a room booked. Doesn't handle the date-range nature (a room is a resource *over a date interval*) or two overlapping bookings of the same room.
- **Senior (L5/E5):** Tracks room availability per date, prevents double-booking via a transaction/constraint, holds during checkout, uses OCC. Knows reservation QPS is modest vs reads. May not articulate per-date inventory decomposition, the DB exclusion constraint for overlaps, or overbooking.
- **Staff+ (L6/E6+):** Drives proactively. Models the **interval contention**: a room is a resource over a **date range**, so two bookings overlapping the same room+dates conflict. Decomposes it into a **per-date inventory table** keyed `(hotel, room_type, date)` with `total_inventory` and `total_reserved` — turning interval contention into per-date counter checks (a reservation increments `total_reserved` for each night, rejected if it would exceed inventory). Prevents overlaps at the DB with a **Postgres GiST exclusion constraint** (`EXCLUDE USING gist (room_id WITH =, daterange(check_in, check_out, '[)') WITH &&)`, btree_gist, partial on non-cancelled) as the hard guarantee. Chooses **OCC over pessimistic locking** because reservation QPS is low (ByteByteGo reference: 5,000 hotels / 1M rooms / ~240k daily reservations / ~3 TPS; funnel 300/30/3 QPS). Supports **10% overbooking** (`reserved + n <= 1.1 × inventory`), a **soft hold** (Redis key + TTL) during checkout → permanent on payment, and **idempotency on reservationID** (PK = idempotency key).

## Canonical decomposition

### Requirements
**Functional:**
- Search availability for a room type over a date range; reserve; confirm on payment
- No two guests book the same room for overlapping dates (strong consistency)
- Hold a room during checkout; release on timeout
- Optional overbooking to offset cancellations

**Non-functional (with numbers):**
- ByteByteGo reference: 5,000 hotels, 1M rooms, ~240k reservations/day, ~3 TPS
- Funnel: ~300 QPS detail views → ~30 QPS confirm page → ~3 QPS reservations (read-heavy)
- Strong consistency on (room, date-range); 10% overbooking factor
- Soft-hold TTL minutes; idempotent on reservationID

### Core entities
- **RoomTypeInventory:** (hotel_id, room_type_id, date) → total_inventory, total_reserved
- **Reservation:** reservationID (PK + idempotency key), room/room_type, check_in, check_out, status
- **Hold:** soft reservation (Redis key + TTL) during checkout
- **Room:** physical room (for room-level exclusion constraint)

### API
- `GET /availability {hotel, room_type, check_in, check_out}` → available (read-heavy, cached)
- `POST /reservations {…, reservationID}` → reserve (OCC per-date or exclusion constraint), idempotent
- `POST /reservations/:id/confirm` → soft-hold → permanent booking on payment
- internal: per night, check `total_reserved + n <= overbook_factor × total_inventory`

### HLD
The distinctive feature is **interval contention**: unlike a single seat or one unit of stock, a room is a resource occupied over a **date range**, and two reservations conflict if they overlap the same room and dates. Two complementary models handle it. (1) **Per-date inventory**: a table keyed `(hotel_id, room_type_id, date)` with `total_inventory` and `total_reserved`; a reservation for a 3-night stay touches 3 date rows, each checked `total_reserved + n <= total_inventory` (or `<= 1.1 × total_inventory` for 10% overbooking) and incremented — decomposing interval contention into per-night counter updates, which OCC (version/conditional update) handles cleanly. (2) **Room-level exclusion**: a Postgres **GiST exclusion constraint** `EXCLUDE USING gist (room_id WITH =, daterange(check_in, check_out, '[)') WITH &&)` makes overlapping bookings of the *same physical room* structurally impossible at the DB layer (with `btree_gist`, `'[)'` for inclusive-start/exclusive-end, and a partial `WHERE status <> 'cancelled'` so cancellations free the range).

Because reservation **QPS is low** (ByteByteGo: ~3 TPS against a 300/30/3 read-heavy funnel), the design favors **OCC or DB constraints over pessimistic locking** (which would deadlock/serialize for no benefit at this volume). Checkout uses a **soft hold** (a Redis key with a short TTL reserves the room/dates while the user pays) converted to a **permanent** SQL booking on payment success, released on timeout. Booking is **idempotent on reservationID** (used as both PK and idempotency key, so a duplicate request fails the unique constraint rather than double-booking). **Overbooking** (10%) is supported by relaxing the availability check, betting on cancellations. Availability search is read-heavy and cached; the reservation write is the contended-but-low-volume path.

### Deep dives
1. **Interval contention: per-date inventory vs exclusion constraint.** The core modeling choice. **Per-date inventory** (`(hotel, room_type, date)` counters) scales well and matches how hotels sell (by room-type, not specific room): a stay increments each night's `total_reserved`, rejected if any night would exceed inventory — interval contention becomes a series of per-night counter checks under OCC. **GiST exclusion constraint** operates at the *physical-room* level and makes overlaps impossible in the DB (`daterange && `), the strongest guarantee, but ties bookings to specific rooms and requires Postgres. Most large systems use per-date room-type inventory for scale and assign physical rooms later; the exclusion constraint shines when you book specific rooms. The Staff+ point: decompose the interval into per-date counters (scalable) or enforce non-overlap declaratively (bulletproof), and know the tradeoff.
2. **Why OCC/constraints, not pessimistic locks, here.** Reservation QPS is genuinely low (~3 TPS in the reference), and conflicts on the same room+dates are rare, so **optimistic** control (version numbers / conditional `UPDATE … WHERE total_reserved + n <= inventory`) is the right fit: no held locks, retry on the rare conflict, reads never blocked. Pessimistic `SELECT FOR UPDATE` would serialize and risk deadlocks across the multiple date rows a multi-night stay touches, for no throughput benefit at this volume. This contrasts with `flash-sale` (extreme contention → atomic Redis), illustrating that the concurrency mechanism should match the contention level. Idempotency on reservationID (PK = idempotency key) is the backstop against duplicate-on-retry.
3. **Soft holds, overbooking, and the read/write split.** Checkout needs a **soft hold** (Redis key + TTL) so a room isn't grabbed by someone else while the user enters payment, converted to a durable booking on success and released on timeout — the same reserve→confirm pattern as `ticketmaster`/`airline-seat-booking`, but at low QPS. **Overbooking** (10%, `reserved + n <= 1.1 × inventory`) deliberately oversells expecting cancellations (like airlines), trading occasional walk-the-guest cost against occupancy. And the system is overwhelmingly **read-heavy** (300/30/3 funnel), so availability search is cached/replicated while the strongly-consistent reservation write is a thin contended path. Naming all three — hold for UX, overbooking for revenue, read/write split for scale — rounds out the design.

## Known failure modes
1. **Double-booked room (overlapping dates).** Two guests book the same room for overlapping nights. Production answer: per-date `total_reserved` check under OCC, or a Postgres GiST `daterange &&` exclusion constraint (partial on non-cancelled) — the DB enforces non-overlap.
2. **Lost hold / grabbed during payment.** A room is taken by another user while the guest pays. Production answer: soft hold (Redis key + TTL) reserving it during checkout, converted to permanent on payment, released on timeout.
3. **Duplicate reservation on retry.** A timed-out reservation request is retried and books twice. Production answer: reservationID as PK + idempotency key; a duplicate fails the unique constraint and returns the existing reservation.

## (Delineation note)
`hotel-booking` is the **interval/date-range** reservation variant of the archetype (vs `ticketmaster` seat holds, `airline-seat-booking` overbooked seats, `flash-sale` instant stock). The read-heavy availability *display* is the caching archetype; payment is `stripe-payments`. Here it's interval contention + OCC/exclusion-constraint + soft hold.

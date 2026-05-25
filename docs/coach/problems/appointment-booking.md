---
slug: appointment-booking
archetype: concurrent-resource
sources:
  calendly_techinterview: techinterview.org/post/3233474486/system-design-design-calendly-scheduling-platform-availability-booking-timezone-integration-conflict-detection-reminders/
  double_booking_itnext: itnext.io/solving-double-booking-at-scale-system-design-patterns-from-top-tech-companies-4c5a3311d8ea
  pg_exclusion: cybertec-postgresql.com/en/exclusion-constraints-in-postgresql-and-a-tricky-problem/
  hi_ticketmaster: hellointerview.com/learn/system-design/problem-breakdowns/ticketmaster
  hi_contention: hellointerview.com/learn/system-design/patterns/dealing-with-contention
---

# Appointment Booking (slot reservation, double-booking prevention)

## Bar anchors
- **Mid-level (L4/E4):** Marks a slot booked when chosen. Doesn't handle two users booking the same slot (read-then-write race) or holds during confirmation.
- **Senior (L5/E5):** Generates slots, prevents double-booking via a unique constraint / conditional update, holds during confirmation, handles timezones. Knows the check-then-confirm race. May not articulate slot generation, the hold TTL, or OCC-vs-constraint tradeoff for modest volume.
- **Staff+ (L6/E6+):** Drives proactively. Names the **root cause** — availability check (read) and confirm (write) aren't atomic, so two users both see the slot free and both confirm. Generates **bookable slots** from availability rules (e.g. 30-min slots over a 30-day window) and reserves with an **atomic hold**: Redis `SET block:{slot} user NX EX 300` (5-min hold; only one holder; auto-release on abandon) converted to a permanent booking on confirm. Backs it with a DB **`UNIQUE(resource, slot)`** constraint (or a Postgres **GiST exclusion constraint** for duration-based appointments) as the hard guarantee. Chooses **OCC / unique-constraint over pessimistic locking** because volume is modest (booking QPS low). Makes confirm **idempotent**. Handles **timezones** (store UTC, render local) and recurring availability. Situates it on the contention spine (atomicity → pessimistic → isolation → OCC → distributed lock).

## Canonical decomposition

### Requirements
**Functional:**
- Show available time slots for a resource (person/room); book one; confirm
- No two users book the same slot (double-booking prevention)
- Hold a slot briefly during confirmation; release on timeout
- Handle timezones and recurring availability

**Non-functional (with numbers):**
- Slot granularity (e.g. 30 min) over a window (e.g. 30 days); hold ~5 min
- Booking QPS modest → OCC/constraints, not pessimistic locks
- Zero double-booking; idempotent confirm

### Core entities
- **Slot:** (resource, start_time) → open | held | booked; held has a TTL
- **Availability rule:** working hours/recurrence → generates bookable slots
- **Hold:** block:{slot} → user (Redis, TTL) during confirmation
- **Booking:** the confirmed reservation (idempotent on a booking key)

### API
- `GET /availability {resource, range}` → open slots (generated from rules)
- `POST /hold {resource, slot, user}` → Redis `SET NX EX` hold; 200 / 409 (taken)
- `POST /confirm {hold, user}` → permanent booking (idempotent) + `UNIQUE(resource, slot)`
- expiry: hold auto-releases on TTL; slot returns to open

### HLD
Availability is **generated**, not stored per slot: from a resource's working hours / recurrence rules, the system produces bookable slots (e.g. 30-minute slots across the next 30 days) on demand, marking those already held/booked as unavailable. The booking flow is **hold → confirm**. The **root cause** of double-booking is that "is this slot free?" (read) and "book it" (write) are separate, so two users both see it free and both confirm. The fix is an **atomic hold**: `SET block:{slot} {user} NX EX 300` — Redis `NX` ensures only one holder, the 5-minute TTL auto-releases if the user abandons (or their app crashes) — converted to a permanent **booking** on confirm. The durable guarantee is a DB **`UNIQUE(resource, slot)`** constraint (so even a race that slips past Redis can't create two bookings), or for *duration-based* appointments a Postgres **GiST exclusion constraint** (`EXCLUDE USING gist (resource WITH =, tsrange(start,end) WITH &&)`) preventing overlapping appointments.

Because booking **QPS is modest** (most calendars aren't Ticketmaster), the design favors **OCC / unique constraints over pessimistic locking** — no held locks, retry on the rare conflict (a 409 "slot just taken, pick another"). Confirm is **idempotent** (a booking key so a retried confirm doesn't double-book). **Timezones** are handled by storing slots in UTC and rendering in the user's local zone (a frequent correctness bug if conflated). Recurring availability (weekly templates) generates the slot space; exceptions (holidays, one-offs) override it. This sits squarely on the **contention spine** (atomicity → pessimistic locking → isolation levels → OCC → distributed lock) — appointment booking is the gentle end (low contention) where a hold + unique constraint suffices.

### Deep dives
1. **The read-then-write double-booking race + atomic hold.** The defining failure: availability check and confirm are not atomic, so concurrent users both see "free" and both book. The hold makes the *claim* atomic (`SET NX` — exactly one wins), and the TTL makes it self-healing (abandoned holds auto-release, no manual cleanup, no permanently-stuck slots). But the hold (in Redis) isn't the source of truth, so a DB **`UNIQUE(resource, slot)`** constraint is the hard guarantee that closes any gap between the cache hold and the durable write. The Staff+ point: separate the *fast atomic claim* (Redis hold for UX) from the *durable invariant* (DB unique/exclusion constraint), and don't rely on the read-check alone.
2. **OCC/constraints vs pessimistic locking at modest volume.** Unlike `flash-sale` (extreme contention → atomic Redis gate) or `ticketmaster` (millions on one event → distributed lock + waiting room), appointment booking is **low-contention**: conflicts on the same slot are rare. So the right tool is **optimistic** — a unique constraint or conditional insert (`INSERT … ON CONFLICT DO NOTHING`, or OCC version) that simply rejects the rare loser with a 409 "pick another slot," reads never blocked. Pessimistic `SELECT FOR UPDATE` would add lock overhead and deadlock risk for no benefit. This is the teaching value: **match the concurrency mechanism to the contention level** — appointment booking demonstrates the low end of the spine where the simplest correct tool wins.
3. **Slot generation, duration overlaps, and timezones.** Two modeling subtleties. (a) **Duration-based** appointments (a 90-min service, not a fixed grid slot) can't use a simple `UNIQUE(resource, slot)` — they need **overlap** detection, which a Postgres GiST exclusion constraint on `tsrange WITH &&` enforces declaratively at the DB. (b) **Timezones**: store everything in UTC, render in the viewer's local zone; conflating display and storage zones causes off-by-hours double-bookings around DST. (c) Availability is generated from **recurrence rules** (weekly templates + exceptions), not stored slot-by-slot, so "available" is computed as the rule's slots minus held/booked. These make appointment booking richer than a flat slot table and are where naive designs break.

## Known failure modes
1. **Double-booking (read-then-write race).** Two users book the same slot. Production answer: atomic hold (`SET NX EX`) + DB `UNIQUE(resource, slot)` (or GiST `tsrange &&` exclusion for durations) as the durable guarantee; reject the loser with 409.
2. **Stuck/abandoned holds.** A held slot never releases because the user vanished. Production answer: TTL on the hold (auto-release, e.g. 5 min); background sweep as backstop; the source of truth is the DB booking, not the hold.
3. **Timezone / DST double-booking.** Slots conflict because zones are conflated. Production answer: store UTC, render local; test around DST transitions; treat duration overlaps with range logic, not string-equal slots.

## (Delineation note)
`appointment-booking` is the **low-contention slot-reservation** variant — the gentle end of the spine (vs `ticketmaster`/`flash-sale` extreme contention). Often a 25-min problem. The distributed-lock primitive is `distributed-lock`; payment is `stripe-payments`. Here it's hold + unique/exclusion constraint + OCC at modest scale.

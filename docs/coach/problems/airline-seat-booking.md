---
slug: airline-seat-booking
archetype: concurrent-resource
sources:
  overbooking_altexsoft: altexsoft.com/blog/overbooking-airlines-bumping/
  dot_bumping: transportation.gov/individuals/aviation-consumer-protection/bumping-oversales
  airline_res_wikipedia: en.wikipedia.org/wiki/Airline_reservations_system
  littlewood_emsr: en.wikipedia.org/wiki/Littlewood's_rule
  pnr_altexsoft: altexsoft.com/blog/airline-reservation-systems-passenger-service-systems/
---

# Airline Seat Booking (seat-map reservation + deliberate overbooking)

## Bar anchors
- **Mid-level (L4/E4):** Marks a seat booked when chosen. Doesn't handle two passengers picking the same seat, holds during payment, or that airlines *intentionally* oversell.
- **Senior (L5/E5):** Holds a selected seat during checkout (reserve → confirm), prevents two passengers booking the same seat via a lock/constraint, uses a PNR. Knows availability is read-heavy. May not articulate the inverse-of-ticketmaster overbooking goal, nested fare-class inventory, or protection levels.
- **Staff+ (L6/E6+):** Drives proactively. Handles seat-map concurrency with a **hold/confirm** (reserve a seat for N minutes; OCC or a `UNIQUE(flight, seat)` constraint prevents double-assignment), but flips the usual goal: airlines **deliberately overbook** because **5–15% of passengers no-show**, so the system *intentionally* sells beyond capacity and manages the rare bump (US involuntary bump rate ~0.25/10,000; solicit volunteers first, then bump lowest-fare/latest-check-in, sparing top frequent-flyers). Models inventory as **nested fare-class buckets** (one-letter classes) with **protection levels** (Littlewood/EMSR: reserve seats for higher fare classes; nest so a high-fare booking is never rejected for a low-fare one), opened/closed by revenue management. Uses the **PNR** as the booking record, synced from GDS (Amadeus/Sabre — Sabre ~1M bookings/min peak). Idempotent booking keyed on PNR.

## Canonical decomposition

### Requirements
**Functional:**
- Passengers select seats on a seat map; no two passengers get the same seat
- Hold a seat during payment; confirm or release on timeout
- Sell by fare class with revenue-management inventory control
- Deliberately overbook to offset no-shows; handle bumps gracefully

**Non-functional (with numbers):**
- No-show rate 5–15% (route/season/class dependent) → overbooking target
- Involuntary bump rate ~0.25 per 10,000 passengers (US)
- Seat-map concurrency: hold window minutes; zero *double-assignment* (but intentional oversell of capacity)
- GDS scale: Sabre ~1M booking transactions/min peak

### Core entities
- **Seat:** (flight, seat_no) → available | held | assigned; held has a TTL
- **FareClass bucket:** nested inventory with a protection level per class
- **PNR (Passenger Name Record):** the booking record (passengers, segments, tickets, SSRs)
- **Inventory:** seats sold vs authorized (= capacity × overbooking factor)

### API
- `GET /flights/:id/seatmap` → seat availability (read-heavy)
- `POST /hold {flight, seat, pnr}` → reserve seat (OCC / unique constraint), TTL
- `POST /confirm {pnr}` → assign held seats, issue tickets (idempotent on PNR)
- inventory control: open/close fare classes per protection levels

### HLD
Two concurrency problems sit on top of each other. The **micro** problem is seat-map contention: two passengers must not be assigned the same physical seat, solved with a **hold/confirm** flow (select → seat goes `held` with a TTL → `assigned` on payment, or back to `available` on timeout) backed by either OCC (version/conditional update) or a DB `UNIQUE(flight, seat)` constraint as the hard guarantee. The **macro** problem inverts ticketing: airlines **deliberately overbook** because a known fraction of passengers no-show (5–15%), so the *authorized* inventory exceeds physical capacity by an overbooking factor chosen per route/season. When more passengers show up than seats, the system manages a **bump**: solicit volunteers (compensation) first, then involuntarily deny boarding by policy (lowest fare paid, latest check-in, sparing top frequent-flyer tiers) — kept rare (~0.25/10,000) by tuning the overbooking factor.

Inventory is **fare-class structured**: each cabin is divided into fare-class buckets (one-letter codes) with **protection levels** — the number of seats reserved for a class and all higher classes (Littlewood's rule for two classes, EMSR for many). Buckets are **nested** (not partitioned) so a high-fare booking is never rejected in favor of a low-fare one — lower classes draw from a shared pool capped by protection levels, and revenue management opens/closes classes dynamically. The **PNR** is the durable booking record (passengers, segments, tickets, special-service requests), often synced from a **GDS** (Amadeus/Sabre); booking is idempotent on PNR so retries don't duplicate. Availability reads (seat maps, fare quotes) are read-heavy and cached; the writes (hold/confirm) are the contended path.

### Deep dives
1. **Seat-map concurrency + the overbooking inversion.** The seat-assignment race is standard (hold/confirm + unique constraint), but the Staff+ distinction is that airlines *want* to oversell capacity — the opposite of `ticketmaster`'s strict no-oversell. The design must therefore track two numbers: physical capacity and **authorized inventory** (capacity × overbooking factor), allowing bookings up to the authorized limit. The factor is set from historical no-show rates (5–15%), trading the cost of an occasional bump (compensation, ~0.25/10,000) against the revenue of empty-seat avoidance. Naming this inversion — "prevent double-*assignment* of a seat, but deliberately oversell the *cabin*" — is the senior-vs-staff line.
2. **Nested fare-class inventory + protection levels.** A seat isn't just "a seat" — it's sold at a fare class, and revenue management wants to save seats for late-booking high-fare passengers rather than sell them all cheaply early. **Protection levels** (Littlewood's rule, EMSR) compute how many seats to reserve for each class and above; **nesting** ensures a higher class can always borrow from lower-class availability (so you never reject a high-fare booking while low-fare seats remain). The booking path must check the relevant fare bucket's open/closed state and protection level, not just total seats. This revenue-management layer is what makes airline inventory distinct from a flat seat count, and it's a rich deep-dive most candidates miss.
3. **PNR, idempotency, and GDS scale.** The booking of record is the **PNR**, which spans the booking lifecycle (passengers, segments, tickets, SSRs) and may be created/synced via a GDS. Booking must be **idempotent on the PNR** (a retried confirm doesn't issue duplicate tickets or double-assign seats) — the same idempotency-key discipline as `idempotent-payment`. At GDS scale (Sabre ~1M booking transactions/min peak, migrating mainframe → microservices), the read path (availability/shopping) hugely dominates writes, so availability is cached and the contended write path (hold/confirm) is kept short. The framing: PNR is the consistency anchor, idempotency prevents duplicate issuance, and the read/write asymmetry drives caching.

## Known failure modes
1. **Two passengers assigned the same seat.** A race in seat assignment double-books. Production answer: hold/confirm with a TTL + `UNIQUE(flight, seat)` constraint (or OCC) so only one assignment commits; the loser re-picks.
2. **Too many show up (over-bump).** Overbooking factor set too high → many involuntary bumps, cost + reputation. Production answer: tune the factor from per-route no-show data; solicit volunteers first; cap and monitor the involuntary bump rate; prioritize bump order by policy.
3. **Duplicate booking on retry.** A timed-out confirm is retried and issues two tickets. Production answer: idempotency keyed on PNR; the confirm is idempotent (re-running yields the same single booking).

## (Delineation note)
`airline-seat-booking` is the reservation-with-deliberate-overbooking variant — distinct from `ticketmaster` (strict no-oversell seat holds) by the overbooking inversion and fare-class inventory. The hotel/date-range variant is `hotel-booking`; revenue-management *modeling* depth is out of scope (this is the booking-concurrency angle). Payment is `stripe-payments`.

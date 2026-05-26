# Admission Control

Source: `staff-engineer-study-guide.md`.

## Virtual Waiting Room / Token-Based Admission

**Definition.** A waiting room sits in front of the application (CDN edge, Lambda@Edge, or a dedicated gateway) and issues each arriving user a signed wait-token (typically a JWT carrying a queue position and timestamp); the application only accepts requests bearing a token whose position has been dequeued, converting a thundering herd into a metered FIFO stream.

**Canonical use.** Ticketmaster on a Taylor Swift on-sale parks 500K users in a Redis sorted set keyed by arrival time, issues each a JWT position token, and releases batches every 500ms into the booking service — so Postgres sees a steady flow instead of a half-million simultaneous seat-hold attempts.

**Production systems.** Ticketmaster Smart Queue (token-based hold at edge), Cloudflare Waiting Room (edge-deployed JWT queue), Queue-it (third-party waiting room used by hype drops and ticketing).

**Alternatives.** Synchronous rate limiting at the load balancer with 429s (simpler, but the user experience is random failures rather than an estimated wait); admit-all + downstream backpressure (works only if every downstream layer can shed load gracefully).

## Queued Admission with Fair-Share

**Definition.** Multiple admission queues run in parallel with priority weights or fair-share scheduling (e.g., VIP, regular, bot-suspected), so each cohort drains at its allotted rate; weighted fair queueing prevents one cohort from starving another even when its arrival rate dwarfs the others.

**Canonical use.** A ticketing platform routes verified frequent-buyer accounts to a VIP queue draining at 70% of capacity, regular users to a queue at 28%, and bot-suspected traffic to a 2% queue with deeper inspection — so the bot flood cannot freeze out humans entirely while still preserving some admission for re-validated suspects.

**Production systems.** Cloudflare Waiting Room (priority lanes by attribute), Queue-it (VIP queues and access codes), Linux CFS / WFQ (the underlying scheduling primitive in network gear and OS schedulers).

**Alternatives.** Single FCFS queue with per-cohort rate limits (simpler but cohorts can still block each other under burst); strict-priority queueing (VIP first, others only when VIP empty — risks total starvation of lower tiers).

## Reservation + Hold / Soft-Lock

**Definition.** The system grants the user a time-bounded exclusive claim on a scarce resource (e.g., "these 4 seats are yours for 10 minutes"); the hold auto-releases on TTL expiry, freeing the resource for others — typically backed by a `held` status column with `expires_at` and a background sweeper, or a Redis key with TTL.

**Canonical use.** Ticketmaster moves a seat from `available` to `held` for 10 minutes while the user enters payment details; a sweeper job resets unconfirmed holds back to `available` and the booking transaction re-checks `holds.expires_at > NOW()` atomically with the status promotion to avoid the expiry-vs-commit race.

**Production systems.** Ticketmaster seat holds (Postgres `held` status + sweeper), Airbnb / Booking.com room holds during checkout, Amadeus/Sabre PNR seat holds with TTL (airline GDS).

**Alternatives.** No-hold optimistic checkout — claim the resource only at payment commit (lower latency but ugly UX when the seat vanishes after card entry); pessimistic row lock for the whole checkout (correct but serializes one user per resource per checkout duration — unusable for long flows).

## Optimistic Admission with Retry

**Definition.** Accept every request, let conflicting writes lose at commit time via a version check or conditional update, and return a 409 so the client refreshes and retries; the inverse of waiting rooms — no queue, just a fast-fail race that is cheap when contention is rare.

**Canonical use.** Online auction bids run `UPDATE auctions SET current_bid=?, version=version+1 WHERE id=? AND version=? AND current_bid<?` — exactly one of N concurrent bids commits, losers see 0 affected rows and resubmit with the fresh price; no row lock and no admission gate because true contention on one auction row at one instant is rare.

**Production systems.** DynamoDB conditional expressions, Postgres OCC with version columns (eBay-style bidding, Ticketmaster low-contention seat updates), HTTP If-Match / ETag preconditions.

**Alternatives.** Pessimistic row locking (`SELECT FOR UPDATE`) — correct but serializes throughput per resource; queued admission upstream — convert contention into a controlled stream rather than a retry storm (preferred when contention is high enough that retry rate explodes).

## Backpressure

**Definition.** When a downstream component is saturated, signal upstream to slow down or reject rather than queueing requests indefinitely — typically via 429/503 with `Retry-After`, gRPC `UNAVAILABLE`, or TCP window shrinkage; the principled distinction from rate limiting is that backpressure is *reactive* (driven by observed downstream load) whereas rate limiting is *prescriptive* (a fixed cap), and admission control is binary *accept/reject* whereas rate limiting *slows down*.

**Canonical use.** An API gateway watching downstream queue depth and DB connection saturation flips to shedding traffic with 503s when the booking service exceeds 80% of its connection pool, so the spike doesn't translate into a request-queue collapse where every request times out together.

**Production systems.** Envoy / Istio circuit breakers and outlier detection, Netflix Hystrix / concurrent-limits adaptive concurrency, Kafka producer backpressure via `max.in.flight.requests`.

**Alternatives.** Unbounded buffering (queue everything — leads to bufferbloat, cascading timeouts, and head-of-line blocking); fixed-rate token bucket (simple but blind to actual downstream health).

## Bot Mitigation at Admission

**Definition.** The admission layer fingerprints clients and gates bots before they reach the contested resource, using invisible CAPTCHA, device fingerprinting, mouse/swipe/accelerometer behavioral biometrics, IP-velocity checks, and per-account verification — defense-in-depth, because no single signal suffices.

**Canonical use.** Nike SNKRS gates a drop with a waiting-room checkpoint in front of the origin (>50% of blocked bots share one IP), runs behavioral biometrics on mobile clients to distinguish swipe patterns from scripted taps, and enforces account verification + per-account entry caps so bot operators can't trivially mass-create raffle entries — the gate's job is converting "fastest script wins" into "verified human among the eligible."

**Production systems.** Cloudflare Bot Management (behavioral + ML scoring), Akamai Bot Manager, Google reCAPTCHA v3 / invisible CAPTCHA, Nike SNKRS bot detection layer.

**Alternatives.** Post-hoc bot filtering (let traffic in, scrub orders afterward — loses inventory to bots that briefly held it); raffle / random admission (sidesteps speed-optimization but vulnerable to fake-account mass entry without verification).

## Surge Pricing as Implicit Admission Control

**Definition.** Rather than queue or reject, raise the price until demand naturally falls to match supply — an economic admission gate where willingness-to-pay determines who is admitted; widely used in ride-share and dynamic-fare airline pricing as a substitute for explicit rationing.

**Canonical use.** Uber multiplies fares 2-5x in a localized surge zone during a concert let-out, suppressing low-urgency demand (riders defer or take transit) until the rider/driver ratio rebalances — the price is the gate, no queue or 429 needed, but the cost is felt as fairness loss (price-insensitive users always win).

**Production systems.** Uber / Lyft surge pricing, airline yield management (Littlewood/EMSR fare-class protection levels that effectively close cheap classes as demand rises), AWS Spot Instance pricing.

**Alternatives.** Hard rationing via queues (fair across willingness-to-pay but slower and frustrating); subsidized capacity expansion (recruit more drivers via bonuses — works on minutes-to-hours horizon, not seconds); waitlists with explicit position (fairer but unusable when supply must clear in real time).

## Failure Modes

**Definition.** Admission systems fail in characteristic ways: **token leak** (a bot scrapes or replays wait-tokens, bypassing the queue — mitigated by signed tokens with short TTL, single-use IDs, and bind-to-session); **queue starvation** (a cohort or position bucket never drains because higher-priority arrivals keep cutting in — mitigated by fair-share with guaranteed minimum service rate per cohort); **priority inversion** (a low-priority holder of a downstream lock blocks high-priority admitted users — mitigated by priority inheritance or by making downstream resources priority-aware); **retry storm** (after a brief outage, every rejected client retries simultaneously, doubling the original surge — mitigated by exponential backoff with jitter, `Retry-After` headers, and circuit breakers at the edge).

**Canonical use.** Post-incident reviews on hype drops almost always surface at least one of these: a leaked token endpoint that scalpers exploited, a VIP queue that starved the regular pool, or a retry storm after a 30-second blip that took the system down for an hour because every client's exponential backoff aligned on the same boundary.

**Production systems.** AWS Route 53 / ELB jittered retry guidance (retry-storm mitigation), Stripe `Retry-After` semantics (cooperative backoff), Cloudflare signed waiting-room tokens (anti-leak).

**Alternatives.** Static admission caps with no priority and no retries (simple, immune to most of these failures, but useless when load shifts or partial outages occur); chaos testing of admission paths in pre-prod (catches token-leak and retry-storm shapes before they hit production).

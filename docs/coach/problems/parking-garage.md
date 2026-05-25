---
slug: parking-garage
archetype: concurrent-resource
sources:
  sd_handbook_parking: systemdesignhandbook.com/guides/design-a-parking-lot-system-design/
  skip_locked: netdata.cloud/academy/update-skip-locked/
  semaphore_guide: thelinuxcode.com/semaphores-in-process-synchronization-a-practical-production-first-guide/
  redis_atomic: redis.io/docs/latest/develop/data-types/strings/
  ddia_fencing: timilearning.com/posts/ddia/part-two/chapter-8/
---

# Parking Garage (finite-slot allocation under concurrency)

## Bar anchors
- **Mid-level (L4/E4):** Object-models cars/spots/levels; allocates a free spot. Treats it as pure OOD; doesn't address two gates concurrently claiming the last spot or distributed scale.
- **Senior (L5/E5):** Tracks available spots, atomically allocates/releases, prevents allocating spot N+1 when full. Knows the last-spot race at multiple entrances. May not articulate the atomic counter vs per-spot allocation, multi-entrance contention, or distributing across locations.
- **Staff+ (L6/E6+):** Drives proactively. Frames it as a **distributed finite-slot allocation system** (not just OOD): an **atomic available-count** (Redis `DECR`/`INCR`, single-threaded so no lock) for instant gate feedback, plus **per-spot assignment** that must be atomic — two cars at different gates claiming the **last spot** is the core hazard, prevented by a **row-level lock / conditional update** (`UPDATE spots SET status='occupied' WHERE id=? AND status='free'`, 0 rows = lost) or `FOR UPDATE SKIP LOCKED` (each gate grabs a *different* free spot without blocking). Optimizes spot lookup with a **bitmap** (row of spots = bit array; nearest-free via a per-entrance min-heap). **Partitions** by level/zone/location so contention is local. Generalizes the pattern to any finite-pool allocation (the archetype's canonical "limited resource"). Counts entries/exits idempotently (ticket as key).

## Canonical decomposition

### Requirements
**Functional:**
- Admit a car if a spot is free; assign a specific spot; release on exit
- Never allocate the same spot to two cars, or admit beyond capacity
- Fast gate decision (entry shouldn't wait); support multiple entrances/levels

**Non-functional (with numbers):**
- Multiple concurrent entrances claiming a shared finite pool; zero double-allocation
- Instant gate feedback (atomic counter, sub-ms); zero over-capacity
- Partitioned by level/zone for local contention

### Core entities
- **Spot:** id, level/zone, status (free | occupied), type
- **Available counter:** atomic count per zone/level (Redis) for fast admit/reject
- **Ticket:** entry record (idempotency key for entry/exit counting)
- **Allocation:** the (car → spot) assignment, atomic

### API
- `POST /enter {gate}` → atomic count check + assign a free spot (conditional update / SKIP LOCKED); 200 (spot) / full
- `POST /exit {ticket}` → free the spot, increment the count (idempotent)
- spot lookup: bitmap scan / per-entrance min-heap for nearest free spot

### HLD
Treat the garage as a **distributed finite-slot allocator**, not an OOD toy. Two layers: a fast **atomic available-count** per zone/level (Redis `DECR` on entry, `INCR` on exit — single-threaded Redis makes these atomic with no locks) gives the gate **instant admit/reject** without a DB round-trip; and **per-spot assignment** that picks a specific free spot and marks it occupied **atomically**. The core hazard is **two cars at different gates claiming the last spot** — the assignment must be a single atomic step. Two equivalent mechanisms: a **conditional update** `UPDATE spots SET status='occupied', car=? WHERE id=? AND status='free'` (0 affected rows ⇒ someone took it, try another), or **`FOR UPDATE SKIP LOCKED`** so each gate's transaction grabs a *different* free spot row without blocking on the others (ideal for many concurrent entrances drawing from one pool). Spot lookup is optimized with a **bitmap** (a level's spots as a bit array → fast free-spot scan) and a per-entrance **min-heap** returning the nearest free spot.

To scale, **partition** by level/zone/location: each partition manages its own spots and counter, so contention is local and the system scales horizontally across garages. Entry/exit **counting** is made idempotent (the ticket as an idempotency key) so a retried gate event doesn't double-decrement. The deeper point is that this is the archetype's **canonical finite-resource allocation** — the same shape as allocating from a connection pool, a license pool, or any bounded set of interchangeable units, which connects it directly to `resource-pool`.

### Deep dives
1. **The last-spot race + atomic allocation.** With multiple entrances drawing from one pool, two cars can both observe "1 free" and both be admitted/assigned the same spot — over-capacity and double-allocation. The fix is atomicity at the *assignment*: a conditional `UPDATE … WHERE status='free'` makes claiming a spot a compare-and-set (0 rows = lost, retry another), or **`FOR UPDATE SKIP LOCKED`** lets concurrent gate transactions each lock and take a *distinct* free spot without waiting on each other — the cleanest pattern for "N workers, M interchangeable units." The Redis atomic counter handles the fast admit/reject decision; the DB handles which specific spot. The Staff+ point: separate the cheap capacity gate (atomic counter) from the atomic per-unit assignment, and use SKIP LOCKED so concurrent entrances don't serialize.
2. **Finite-slot allocation as the archetype's core pattern.** Strip the cars and this is "allocate one unit from a bounded pool of interchangeable units under concurrency, release on done" — identical to a DB connection pool, a pool of licenses/IPs/phone numbers, or a counting semaphore. The mechanisms generalize: a counting semaphore (acquire decrements, blocks/queues if none free; release increments), atomic counters for the gate, and SKIP LOCKED / conditional update for picking a specific unit. Releasing must be reliable (a car that never "exits," or a crashed holder, leaks a spot) — hence exit idempotency and, in the pool analogy, lease TTLs to reclaim leaked units. Naming this generalization (parking = `resource-pool` with a physical skin) is the depth signal.
3. **Optimized lookup + partitioning.** "Find a free spot" shouldn't scan all spots: a **bitmap** per level makes free-spot detection a bitwise op, and a per-entrance **min-heap** keyed by distance returns the nearest free spot in O(log n) (assign it, pop it; on free, push it back). **Partitioning** by level/zone/location localizes contention (each partition has its own counter + spot set) and scales the system horizontally across many garages — turning the classic single-lot OOD question into a distributed allocation system. Idempotent entry/exit counting (ticket = key) keeps the count accurate under retried gate hardware events. These move the answer from "a class diagram" to "a concurrent, scalable allocator."

## Known failure modes
1. **Double-allocation of the last spot (multi-gate race).** Two gates assign the same spot / admit over capacity. Production answer: atomic conditional update (`WHERE status='free'`) or `FOR UPDATE SKIP LOCKED` so each gate takes a distinct free spot; atomic counter for the capacity gate.
2. **Leaked spots.** A car never "exits" (or a crash/retry mis-counts), so a spot stays occupied forever / the count drifts. Production answer: idempotent exit (ticket key), reconciliation/sweep, and (in the pool analogy) lease TTLs to reclaim units from crashed holders.
3. **Hot-partition contention at a busy entrance.** One gate/level takes all the load and serializes. Production answer: partition by level/zone, SKIP LOCKED to avoid blocking across concurrent claims, per-entrance min-heaps so entrances don't contend on the same spots.

## (Delineation note)
`parking-garage` is the canonical **finite-slot allocation** variant — the physical-skinned sibling of `resource-pool` (connection/license pools). Often an OOD-flavored question elevated here to a distributed allocator. The lock primitive is `distributed-lock`; building Redis is infra-primitives. Here it's atomic counter + atomic per-unit assignment (SKIP LOCKED) + partitioning.

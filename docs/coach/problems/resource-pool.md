---
slug: resource-pool
archetype: concurrent-resource
sources:
  semaphore_guide: thelinuxcode.com/semaphores-in-process-synchronization-a-practical-production-first-guide/
  java_semaphore: docs.oracle.com/javase/7/docs/api/java/util/concurrent/Semaphore.html
  hikaricp_sizing: github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing
  distributed_semaphore: medium.com/picus-security-engineering/limiting-simultaneous-tasks-using-distributed-semaphores-0f7aab47395a
  skip_locked: netdata.cloud/academy/update-skip-locked/
---

# Resource Pool (finite pool allocation under concurrency)

## Bar anchors
- **Mid-level (L4/E4):** Hands out resources from a list. Doesn't bound concurrent usage, handle exhaustion, or reclaim resources from crashed holders.
- **Senior (L5/E5):** Uses a counting semaphore / bounded pool, blocks or times out when exhausted, releases on done. Knows a crashed holder can leak a resource. May not articulate fairness, lease+TTL reclamation, pool sizing, or the distributed-semaphore mechanics.
- **Staff+ (L6/E6+):** Drives proactively. Models it as a **counting semaphore**: acquire (P) decrements the available count and **blocks/queues** if none free; release (V) increments and wakes a waiter — a binary semaphore being the 1-permit case. Adds **fairness** (FIFO permit grant to avoid starvation — Java's fairness flag trades throughput for predictability) and **timeout** (block up to `connectionTimeout`, then fail — HikariCP default 30s). Reclaims from crashed holders via **lease + TTL** (a permit auto-releases if not renewed; a dead-letter/republish if a held message isn't acked) and **leak detection** (flag a permit held too long). Sizes the pool deliberately (**HikariCP: connections = (cores × 2) + spindles ≈ ~10**; Oracle benchmark: shrinking the pool cut response 100ms→2ms; PG TPS flattens ~50 conns — *a small saturated pool with waiters beats a huge one*). For distributed pools, uses a **distributed semaphore** (Redis count + lease, or Curator shared semaphore over ZooKeeper) and `FOR UPDATE SKIP LOCKED` to claim a *distinct* free unit without blocking. Generalizes to connection pools, license/seat pools, IP/phone-number pools.

## Canonical decomposition

### Requirements
**Functional:**
- Allocate one unit from a bounded pool of interchangeable units; release on done
- Bound concurrent usage to the pool size; block/queue or reject when exhausted
- Reclaim units from crashed/leaked holders; allocate fairly (no starvation)

**Non-functional (with numbers):**
- Pool size deliberately small (HikariCP ≈ (cores×2)+spindles; ~10 typical)
- Acquire timeout (HikariCP default 30s) then fail; leak detection threshold (≥2s)
- Lease TTL for crash reclamation (≥ ~3× renewal interval)
- Fair (FIFO) vs unfair (higher throughput, starvation risk) tradeoff

### Core entities
- **Permit / semaphore count:** the number of free units
- **Lease:** a held permit with a TTL (auto-reclaim on holder death)
- **Wait queue:** blocked acquirers (FIFO if fair)
- **Unit:** an interchangeable resource (connection, license, IP, GPU slot)

### API
- `acquire(timeout)` → permit (decrement; block/queue if none; fail on timeout)
- `release(permit)` → increment; wake a waiter
- distributed: Redis `DECR`/lease, Curator shared semaphore, or `FOR UPDATE SKIP LOCKED` to grab a free unit
- renewal: KeepAlive/heartbeat to hold a lease; stop → auto-reclaim

### HLD
The abstraction is a **counting semaphore** over a bounded set of interchangeable units. **Acquire (P)** decrements the available count; if it would go negative, the caller **blocks** and joins a wait queue (or fails after a **timeout**). **Release (V)** increments the count and wakes a waiter. A binary semaphore (1 permit) is mutual exclusion; a counting semaphore (N permits) bounds concurrency to N. **Fairness** is a deliberate choice: a *fair* (FIFO) semaphore grants permits in request order (no starvation, slightly lower throughput); an *unfair* one maximizes throughput at the risk of starving an unlucky waiter. **Timeout** prevents indefinite blocking — HikariCP's `getConnection()` blocks up to `connectionTimeout` (default 30s) then throws.

The two hard operational problems are **leaks** and **sizing**. A holder that crashes (or forgets to release) **leaks** a unit, shrinking the effective pool until it's empty — fixed by a **lease + TTL** (the permit auto-releases if the holder stops renewing; a message-queue variant republishes an un-acked permit via a dead-letter exchange) and **leak detection** (flag a permit held longer than a threshold). **Sizing** is counterintuitive: pools should be **small** — HikariCP recommends `connections = (core_count × 2) + effective_spindles` (≈10 for a 4-core single-disk box), and Oracle's benchmark showed *shrinking* the pool cut response time from ~100ms to ~2ms (PostgreSQL TPS flattens around 50 connections) because a small pool saturated with waiters outperforms a large pool that thrashes the backend. For **distributed** pools (units shared across machines), use a **distributed semaphore** (Redis count + lease, or a Curator shared semaphore over ZooKeeper) and `FOR UPDATE SKIP LOCKED` to atomically claim a *distinct* free unit without blocking on others. This is the **canonical finite-resource allocation** that underlies connection pools, license/seat pools, IP/phone-number pools, and the physical `parking-garage`.

### Deep dives
1. **Counting semaphore + fairness + timeout.** The core primitive: a counter of free units, with acquire/release as decrement/increment and a wait queue for exhaustion. The design decisions are **fairness** (FIFO grant prevents starvation but costs throughput; Java's `Semaphore(permits, fair)` flag exposes exactly this) and **timeout** (bound the wait, then fail fast rather than hang — HikariCP 30s default), plus whether acquire **blocks** (back-pressure) or **rejects** (load-shed) on exhaustion. Getting these right is the difference between a pool that degrades gracefully under load and one that deadlocks or starves. The Staff+ framing: a resource pool is a counting semaphore plus policies for *what happens when it's empty* (queue fairly, time out, or shed).
2. **Leak reclamation (the operational killer).** The failure that takes pools down in production is **leaked permits**: a holder crashes or a bug skips `release`, so the unit is never returned and the pool slowly drains to zero (then every acquire times out). Defenses: **leases with TTL** (the permit is held only while renewed via heartbeat/KeepAlive; a dead holder stops renewing and the lease auto-expires, reclaiming the unit), a **dead-letter + message-TTL** scheme for queue-based semaphores (un-acked permit republished), and **leak detection** (log/alert when a permit is held past a threshold — HikariCP's `leakDetectionThreshold`, min 2s). Note the parallel to fencing in `distributed-lock`: reclaiming a lease from a *paused-not-dead* holder risks two users of one unit, so reclamation needs the same care (idempotent use, or fencing). The framing: allocation is easy; *reliable reclamation* under crashes is the hard, must-name part.
3. **Sizing + distributed pools.** Sizing is famously counterintuitive: **smaller is faster**. HikariCP's formula `(cores × 2) + spindles` yields ~10, and Oracle's real-world test cut response 100ms→2ms by *shrinking* the pool — because more connections than the backend can truly run in parallel just adds context-switching and lock contention (PG TPS flattens ~50). The right model is "a small pool, saturated, with threads waiting" — the wait queue absorbs bursts, the backend runs at peak efficiency. For **distributed** pools (units across machines: a shared license count, a pool of egress IPs, GPU slots), a single in-process semaphore won't do — use a **distributed semaphore** (Redis count + lease, Curator/ZooKeeper shared semaphore) or claim distinct DB-row units with `FOR UPDATE SKIP LOCKED` (each acquirer locks a *different* free row, no blocking). The generalization: parking spots, connections, licenses, IPs — all the same bounded-pool allocator with the same semaphore + lease + sizing concerns.

## Known failure modes
1. **Permit leak → pool exhaustion.** A crashed/buggy holder never releases; the pool drains to empty and all acquires time out. Production answer: lease + TTL auto-reclamation (heartbeat renewal), dead-letter/republish for queue semaphores, leak detection alerts; ensure `release` in a finally block.
2. **Pool too large (or too small).** Oversized pools thrash the backend (slower); undersized pools reject/queue excessively. Production answer: size by `(cores×2)+spindles` ≈ small; a small saturated pool + wait queue beats a big one; load-test for the backend's flattening point (~50 for PG).
3. **Starvation / unbounded blocking.** An unlucky acquirer waits forever, or unfair scheduling starves it. Production answer: fair (FIFO) semaphore where starvation matters; acquire timeout (fail fast) to bound blocking; back-pressure vs load-shed policy chosen explicitly.

## (Delineation note)
`resource-pool` is the abstract **finite-pool allocation** primitive; `parking-garage` is its physical-skinned instance, and seat/inventory holds are domain-specific cases. The lock primitive is `distributed-lock`; the consensus engine (ZooKeeper/etcd) is infra-primitives — reference, don't re-derive. Here it's the counting semaphore + lease reclamation + sizing.

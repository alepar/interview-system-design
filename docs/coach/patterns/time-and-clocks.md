# Time and Clocks

Source: `staff-engineer-study-guide.md`.

## Wall-Clock Time and NTP

**Definition.** Wall-clock time (e.g., `CLOCK_REALTIME` on Linux) is the OS's view of civil time; NTP (Network Time Protocol) synchronizes it against upstream reference servers via periodic step or slew adjustments, with no inherent guarantee of monotonicity or bounded skew under failure.

**Canonical use.** Stamp user-facing timestamps (log lines, created_at columns, JWT `exp` claims) where readability and rough correlation across machines matter more than fine-grained ordering — and explicitly never use it to measure durations or to compare two timestamps from different hosts as if they were exact.

**Production systems.** Linux `ntpd` / `chronyd` (typically 10-100ms skew on commodity hardware over the public internet, 1-10ms with a local stratum-1 server), AWS Time Sync Service (microsecond-class skew within a Region via a dedicated PTP-grounded fleet), Google's leap-smear time service (spreads leap seconds across ~24h to avoid the `23:59:60` jump).

**Alternatives.** PTP (sub-microsecond, hardware-assisted); dedicated GPS/atomic-clock receivers per datacenter (Spanner's TrueTime substrate); explicit synthetic time abstraction in tests so wall-clock dependence never enters production code paths.

## PTP (Precision Time Protocol)

**Definition.** PTP (IEEE 1588) is a LAN-grade clock-synchronization protocol that uses hardware timestamping in NICs and switches to achieve sub-microsecond accuracy between participants on the same network fabric — orders of magnitude tighter than NTP because it eliminates kernel/software jitter from the timestamp path.

**Canonical use.** Synchronize trading-system hosts in an exchange colocation so that order timestamps reflect actual arrival order at the matching engine within tens of nanoseconds — required by MiFID II for trade reconstruction and by every HFT firm for fair sequencing.

**Production systems.** NASDAQ / NYSE matching-engine fabrics (PTP grandmaster + boundary clocks on every switch hop), 5G radio access networks (3GPP requires <1.5µs base-station sync for handoff), Meta's Time Appliance Project (open-source PTP grandmaster reference design driving Meta's fleet to ~100ns).

**Alternatives.** NTP (much cheaper but 10-100ms skew, unsuitable for ordering trades or 5G slots); GPS receivers per host (more expensive than PTP-over-LAN, but no fabric dependency); White Rabbit (a CERN-developed PTP profile achieving sub-nanosecond accuracy for particle-physics instrumentation).

## Monotonic Clocks

**Definition.** A monotonic clock (`CLOCK_MONOTONIC` on Linux, `System.nanoTime()` on the JVM, `time.monotonic()` in Python) measures elapsed time from an arbitrary epoch, is guaranteed never to go backwards, and is immune to NTP step adjustments and operator clock-setting — at the cost of being meaningless to compare across processes or across reboots.

**Canonical use.** Measure RPC latency, lease durations, retry backoffs, and timeouts — anywhere `t2 - t1` must be a non-negative real-time interval. Wall-clock subtraction here is a bug: an NTP step backward during the operation produces negative durations and crashes naive monitoring code.

**Production systems.** Kubernetes leader-election lease accounting (etcd uses monotonic time to gate lease expiry checks), JVM `System.nanoTime()` (the canonical micro-benchmarking primitive in JMH), Linux kernel scheduler (all time accounting is monotonic).

**Alternatives.** Monotonic-raw clocks (`CLOCK_MONOTONIC_RAW`, not slewed by NTP — useful when you need hardware-tick accuracy at the cost of drift from wall clock); boot-time clocks (`CLOCK_BOOTTIME`, counts suspend time — needed on mobile/laptops where the process suspends across lid close).

## Lamport Timestamps

**Definition.** A Lamport timestamp is a single integer counter per process that increments on every local event and, on receive of a message with timestamp `t_remote`, jumps to `max(local, t_remote) + 1` — yielding a total order consistent with causality (if A happened-before B, then `L(A) < L(B)`) but unable to distinguish causal from concurrent events.

**Canonical use.** Order operations in a single-leader replicated log (e.g., generate `(lamport_ts, node_id)` tuples as monotone IDs) where the only requirement is that causally-ordered events stay ordered and ties can be broken arbitrarily — without paying for vector-clock overhead.

**Production systems.** ZooKeeper `zxid` (a 64-bit Lamport-like counter: 32-bit epoch + 32-bit counter, used as a fencing token in distributed-lock primitives), Apache Cassandra (per-cell timestamps in last-write-wins resolution, application-supplied or wall-clock-derived).

**Alternatives.** Vector clocks (detect concurrent vs causal at higher overhead); wall-clock + node-id tiebreaker (simple but doesn't preserve causality if clocks skew); HLC (Lamport-plus-physical-time, gives causality and stays close to real time).

## Vector Clocks

**Definition.** A vector clock is a per-process array `V[i]` of counters such that each process increments its own slot on local events and takes the element-wise max on message receive — enabling partial ordering: `V_A < V_B` iff every slot of `V_A` is `≤` the corresponding slot of `V_B` (and at least one is strictly less), otherwise `A` and `B` are concurrent.

**Canonical use.** Detect concurrent writes in leaderless replicated stores so the system can surface a conflict (sibling objects in Dynamo / Riak) rather than silently letting last-write-wins discard a concurrent update — the application or a CRDT then merges siblings deterministically.

**Production systems.** Amazon Dynamo (the original 2007 paper introduces version vectors for sibling resolution), Riak (version vectors with dotted variants to bound size growth under churn), Voldemort (LinkedIn's open-source Dynamo clone).

**Alternatives.** Dotted version vectors (Riak's evolution — bounds vector size against client churn); Lamport timestamps (cheaper but loses concurrency detection); CRDTs (mathematical merge instead of conflict surfacing — convergence without ever needing to detect concurrency).

## Hybrid Logical Clocks (HLC)

**Definition.** An HLC is a tuple `(physical_ms, logical_counter)` that takes the max of the local physical clock and any incoming HLC's physical component on each event, bumping the logical counter when the physical part doesn't advance — preserving Lamport-style causality while staying bounded-close to wall-clock time (typically ±250ms under healthy NTP per Kulkarni et al. 2014).

**Canonical use.** Timestamp transactions in a cross-region distributed database so that snapshot reads at a given HLC see a causally consistent view without requiring atomic-clock hardware — clients can also request "read at the latest HLC I've observed" for read-your-writes consistency across sessions.

**Production systems.** CockroachDB (every transaction's commit timestamp is an HLC; combined with read-refresh on push to give serializable isolation without commit-wait), MongoDB (cluster time is an HLC; drives causal consistency sessions and majority-read tracking), YugabyteDB (HLC over Raft groups).

**Alternatives.** TrueTime + commit-wait (stricter — gives strict serializability — but requires GPS/atomic-clock infrastructure); pure Lamport (no physical-time anchor; timestamps drift arbitrarily far from wall clock); wall-clock with NTP only (no causality guarantees across skew).

## TrueTime (Spanner)

**Definition.** TrueTime is Google's clock API that returns an interval `[earliest, latest]` representing now with an explicit uncertainty bound (epsilon) of typically 1-7ms in Google datacenters — sourced from a fleet of GPS receivers and atomic clocks per cell, with bounds derived from the worst-case drift between resync intervals.

**Canonical use.** Spanner picks `commit_ts := TT.now().latest` at transaction commit and then commit-waits until `TT.now().earliest > commit_ts` before acknowledging the client — guaranteeing the commit timestamp is in the absolute past for every observer, which delivers external consistency (strict serializability) across the global database. Average commit-wait cost ≈ epsilon/2 ≈ 2-4ms, often overlapped with the Paxos fsync so it is nearly free.

**Production systems.** Google Spanner (the original, GPS + atomic clocks in every datacenter; epsilon monitored as an SLI), Google Cloud Spanner (same substrate exposed externally), AWS Time Sync Service ClockBound (a TrueTime-style bounded-interval API for EC2, microsecond-class within a Region).

**Alternatives.** HLC + read-refresh (CockroachDB — no hardware, retry on contention instead of wait on every commit); session-bound causal consistency (cheaper but weaker — no real-time ordering across sessions); 2PL with a single global sequencer (Calvin / FaunaDB — pre-orders transactions, no clock dependence for correctness).

## Clock-Derived IDs

**Definition.** A clock-derived ID composes a timestamp prefix with a worker identifier and a per-millisecond sequence into a single sortable integer or string — yielding 64-bit IDs that are k-sorted (rough time order across the cluster, strict order per worker) without requiring a central sequencer on the hot path.

**Canonical use.** Generate primary keys for a write-heavy partitioned database (tweets, orders, events) at millions of IDs/sec/node, where time-prefixed IDs give good B-tree insert locality and make range queries by creation time efficient — and where the ID itself reveals creation time for debugging and TTL policy.

**Production systems.** Twitter Snowflake (41-bit ms timestamp + 10-bit machine + 12-bit sequence = 4096 IDs/ms/machine, 69-year lifespan from 2010 epoch), Instagram (41+13+10 baking shard_id directly into the ID for routing), Sonyflake (39-bit 10ms-granularity + 16-bit machine + 8-bit sequence, optimized for 65K machines), UUIDv7 (RFC 9562, 48-bit ms timestamp + 74 random bits — standardized k-sortable UUID).

**Alternatives.** UUIDv4 (fully random — no ordering, no time leak, but poor B-tree insert locality); central auto-increment (single point of contention, simple semantics); KSUID / ULID (Lamport-prefixed variants with different bit allocations); HLC-derived IDs (causal ordering at slightly higher cost).

## Common Failure Modes

**Definition.** Time-based bugs cluster around a few canonical failure patterns: lease expiration races (holder's GC pause exceeds lease TTL; another client acquires; both believe they hold the lock — see distributed-lock fencing-token discussion), NTP step adjustments causing wall-clock to jump backward and break monotonicity assumptions (Snowflake's published policy: refuse to issue IDs until the clock catches up), clock travel during leap seconds (the legacy `23:59:60` insertion crashed Reddit, LinkedIn, and many JVMs in 2012 and 2015 — modern fix is leap-smear), and epoch rollovers (Y2K at 100-year boundaries, Y2038 at signed 32-bit Unix time exhaustion, Snowflake's ~2079 epoch exhaustion at 41-bit ms from 2010).

**Canonical use.** Treat time as adversarial in any safety analysis: assume the clock can jump forward, backward, freeze, or skew; rely on monotonic clocks for durations, fencing tokens for mutual exclusion across leases (never TTL alone), HLC or TrueTime where causal/external consistency matters, and explicit epoch-rollover planning with overlap windows for any timestamp-derived primitive nearing exhaustion.

**Production systems.** Spanner (monitors TrueTime epsilon as an SLI; sheds write load when uncertainty exceeds threshold), Kafka (uses fencing via leader epoch / generation clock to reject stale producer requests rather than depending on wall-clock lease timing), CockroachDB (read-refresh on HLC push avoids relying on wall-clock skew bounds for correctness), Google leap-smear (eliminates the 61st-second class of bugs by smearing the leap across 24h).

**Alternatives.** Persisting last-issued timestamp + sequence across restarts (defeats backward-NTP-jump for ID generators); hard-failing on clock-skew SLI breach (Spanner's approach — preserve safety, accept availability loss); using only monotonic clocks for all internal logic and wall-clock only for human-facing display (the conservative Staff+ default).

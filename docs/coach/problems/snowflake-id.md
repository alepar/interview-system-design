---
slug: snowflake-id
archetype: infra-primitives
sources:
  twitter_snowflake: blog.twitter.com/engineering/en_us/a/2010/announcing-snowflake
  sonyflake: github.com/sony/sonyflake
  hlc_paper: cse.buffalo.edu/tech-reports/2014-04.pdf
  spanner_truetime: cloud.google.com/spanner/docs/true-time-external-consistency
  snowflake_id_wiki: en.wikipedia.org/wiki/Snowflake_ID
---

# Twitter Snowflake (distributed ID sequencer)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic auto-incrementing counter with a central DB; doesn't address scaling beyond one writer. May know UUIDs are an alternative; doesn't articulate why UUIDs lose temporal ordering.
- **Senior (L5/E5):** Names Snowflake (Twitter) as 64-bit timestamp + machine_id + sequence; understands per-machine sequence rolls over after 4096/ms. Discusses ZooKeeper-coordinated machine-ID assignment at category level. May know about clock skew as a failure mode but may not articulate the refuse-on-backward-jump policy.
- **Staff+ (L6/E6+):** Drives proactively. Cites Twitter Snowflake bit layout: **41 bits timestamp (ms) + 10 bits machine_id + 12 bits sequence** = 4096 IDs/ms/machine; 41-bit timestamp ≈ 69 years from custom epoch (Twitter chose 2010-11-04 as epoch). Cites the **refuse-on-backward-clock-jump policy** ("snowflake will refuse to generate ids until a time that is after the last time we generated an id" — Twitter blog). Compares **bit-layout variants**: Sonyflake (39 bits timestamp at 10ms granularity + 16 bits machine + 8 bits sequence) — different trade-off favoring machine count over per-ms throughput; Instagram (41 bits timestamp + 13 bits shard_id + 10 bits sequence) — incorporates shard awareness directly into the ID. Distinguishes **strict serializability vs causal consistency vs k-sortedness**: Snowflake gives k-sorted (rough time order, machine-local strict order); HLC gives causal consistency at no special-hardware cost; TrueTime + commit-wait gives strict serializability at ~4ms commit-wait cost. Quantifies **HLC structure**: 48-bit physical timestamp + 16-bit logical counter; tolerates ±250ms NTP skew; preserves causality. Names **TrueTime + commit-wait** explicitly with Spanner's published epsilon (1-7ms typical, ~4ms average → commit-wait cost ≈ epsilon/2). Articulates the **machine-ID assignment via consensus** (Twitter Snowflake's original design used ZooKeeper-locked ephemeral nodes; modern variants use EC2 IP-derived for Sonyflake or config-driven). Stretch (Sr Staff bar): articulates **epoch exhaustion** as a 69-year long-term failure mode requiring planned re-epoch; discusses **sequence overflow within ms** under burst and the wait-for-next-ms vs extend-bits trade-off.

## Canonical decomposition

### Requirements
**Functional:**
- Generate 64-bit globally-unique, roughly-ordered IDs at 100K+/sec/datacenter across 10+ datacenters
- Monotonic ordering within a single generator instance (per-machine strict-monotonic)
- k-sortedness globally (most IDs from millisecond N have smaller value than most IDs from millisecond N+1)
- Survive clock skew within an NTP-bounded budget
- Optionally extend to HLC for causal consistency or TrueTime for strict serializability

**Non-functional (with numbers):**
- 4096 IDs/ms/machine (Snowflake 12-bit sequence) = 4.1M IDs/sec/machine
- 1024 machines/cluster (Snowflake 10-bit machine_id) = ~4.2M IDs/ms cluster-wide
- 41-bit timestamp lifespan: ~69 years from custom epoch
- TrueTime epsilon: 1-7ms typical, ~4ms average (Spanner DC published)
- HLC bound: tolerates ±250ms NTP skew (Kulkarni et al. 2014)
- Sonyflake: 256 IDs/10ms/machine × 65536 machines = 1.6M IDs/sec cluster-wide (different trade-off)

### Core entities
- **Generator instance:** one process per machine; holds (current_timestamp, current_sequence)
- **Machine ID:** unique 10-bit (Snowflake) or 16-bit (Sonyflake) identifier per generator; assigned via ZooKeeper / IP-derivation / config
- **ID:** 64-bit composite (1 unused sign bit + timestamp bits + machine_id bits + sequence bits)
- **HLC timestamp:** (physical_clock_ms, logical_counter) — used for causal-consistency variants
- **TrueTime interval:** [earliest, latest] returned by Spanner's TT API — used for strict-serializability variants

### API
- `next_id() → 64-bit ID` — fast path: <1μs in-process
- For HLC: `next_hlc() → (physical_ms, logical_counter)` — preserves causality across machines
- For TrueTime: `tt_now() → (earliest_ms, latest_ms)` — exposes clock uncertainty
- For lock-aware Snowflake: `bind_machine_id(zookeeper_path) → machine_id` — acquires unique ID via ephemeral znode

### HLD
The generator is **process-local** — no central coordinator on the hot path. Each process holds `(last_ms, sequence)`; on `next_id()`: read current_ms from monotonic clock; if current_ms > last_ms, reset sequence to 0; if current_ms == last_ms, increment sequence; if current_ms < last_ms, refuse to generate (Twitter Snowflake policy) — wait until clock catches up. Compose: `id = (current_ms - epoch_ms) << 22 | machine_id << 12 | sequence`.

**Machine ID assignment** is the only coordination point. Twitter Snowflake's original design: each generator instance creates an ephemeral znode in ZooKeeper at `/snowflake/machines/<machine_id>` — the smallest unused ID is selected. On generator restart: re-acquire the same machine_id via the lock; on crash: the ephemeral znode disappears, the ID is available for the next instance. **Sonyflake's alternative**: derive machine_id from EC2 private IP address (last 16 bits) — no coordination required, but constrains the IP-allocation policy. Modern variants use config-driven assignment for Kubernetes deployments (each pod gets a unique machine_id via StatefulSet ordinal + namespace hash).

**Clock-skew handling**: NTP can jump the clock backward (rare but real). Snowflake's published policy: **refuse to generate IDs until the clock catches up** to last_ms. The wait is bounded by the size of the backward jump (typically sub-second on a well-managed NTP setup). Anti-pattern: emit an ID with current_ms < last_ms → ID ordering violated → potentially duplicate IDs if last_ms's sequence was at max. **Sonyflake's variant**: uses elapsed time from a fixed epoch instead of wall clock, eliminating the backward-jump scenario at the cost of more complex monotonic-clock dependency.

**HLC (Hybrid Logical Clock)** for causal consistency: an HLC timestamp is `(physical_ms, logical_counter)`. On a local event: `hlc = max(local_physical_clock, hlc.physical) + (logical_counter increment if physical didn't advance, else 0)`. On receiving a remote message with HLC `(remote_physical, remote_logical)`: `hlc = max(local_physical_clock, hlc.physical, remote_physical) + adjusted_logical`. Preserves causality: if event A causes event B, B's HLC > A's HLC. Used by CockroachDB, YugabyteDB, MongoDB for causal-consistency-without-special-hardware.

**TrueTime + commit-wait** for strict serializability: Spanner's TT API returns `[earliest, latest]` representing current time with bounded uncertainty (epsilon). For external consistency (strict serializability): `commit_ts := TT.now().latest`; wait until `TT.now().earliest > commit_ts` before reporting commit. Guarantees the commit_ts is in the absolute past from any observer. Average wait = epsilon/2 ≈ 2-4ms. Requires GPS + atomic clock infrastructure (Google has it).

### Deep dives
1. **Bit-layout trade-offs and the canonical alternatives.** **Snowflake (Twitter, 2010)**: 41 timestamp + 10 machine + 12 sequence. Optimizes for: 4096 IDs/ms/machine throughput, 1024 machines, 69-year horizon. Trade: at 4096 IDs/ms peak, sustained high-rate generators must wait for next ms — small batch latency under burst. **Sonyflake (Sony)**: 39 timestamp at 10ms granularity + 16 machine + 8 sequence. Optimizes for: 65536 machines (cluster-wide deployment), 256 IDs/10ms (smaller per-machine burst). Trade: 10ms granularity means coarser k-sortedness. **Instagram modified**: 41 timestamp + 13 shard_id + 10 sequence. Shard-id is baked into the ID, enabling routing decisions from the ID itself (Instagram uses shard-by-user_id, so the ID directly addresses the shard). Trade: shard-id is fixed (can't rebalance without rewriting IDs). **Bit-allocation decision criteria**: (a) what's the throughput per generator? (more sequence bits if high); (b) how many generators? (more machine bits if many); (c) what's the desired ID lifespan? (more timestamp bits if 100+ years); (d) is shard-awareness valuable? (Instagram-style if yes, separate concern if no). Staff+ commit: pick layout with criteria, address epoch-exhaustion planning (at 41 bits / 69 years, set up the next-epoch transition before exhaustion — usually a config change with overlap window).

2. **Clock-skew handling: refuse-on-backward-jump vs HLC vs TrueTime.** Three production approaches: (a) **refuse-on-backward-jump** (Snowflake's policy) — simplest, but means brief unavailability during NTP corrections; clients must handle "no ID right now, retry"; (b) **monotonic-clock-only** (Sonyflake variant) — use OS monotonic clock that never goes backward; immune to NTP corrections but doesn't survive process restart cleanly (must persist the monotonic-clock offset); (c) **HLC** — fold logical counter into the timestamp so that even on physical-clock jump-back, the HLC stays monotonic via the logical increment; trade is the resulting timestamp doesn't match wall-clock exactly. For Snowflake-style use cases (just need unique k-sorted IDs), refuse-on-backward-jump is fine. For database-replication ordering (where causal consistency matters), HLC is required. For external-consistency systems (Spanner-class), TrueTime + commit-wait is required. Staff+ commit: pick mechanism per workload, address the failure mode if clock skew is unbounded (NTP infrastructure failure → all three approaches degrade; Snowflake stalls; HLC drifts further from wall clock; TrueTime monitors epsilon + rejects transactions when uncertainty exceeds threshold).

3. **Machine-ID assignment via consensus: ZooKeeper, EC2 IP, or config.** The only coordination point in Snowflake-class generators. **ZooKeeper-locked ephemeral nodes** (Twitter's original): each generator instance creates `/snowflake/machines/<id>` with EPHEMERAL flag; the smallest unused id is selected (sometimes via sequential znode + minimum scan). On process restart, the lock is re-acquired (same id reused if available; new id otherwise). On crash, the ephemeral znode disappears, the id is available for reuse. Cost: ZK round-trip on every generator startup; ZK as a hard dependency. **EC2 IP-derived** (Sonyflake): machine_id = last 16 bits of private IPv4 address. No coordination, but requires IPs to be unique within the cluster (typically true) and stable across restart (typically false — pod IP changes on restart). **Config-driven** (Kubernetes StatefulSet ordinal): pod's ordinal index + namespace hash gives a unique machine_id; works for StatefulSet deployments but not for Deployment (where pods are interchangeable). Staff+ commit: pick assignment mechanism with criteria (ZK if you have ZK already; IP if EC2-bound; ordinal if K8s StatefulSet); address what happens during machine_id collision (the failure mode if two generators get the same id — duplicate IDs within their respective sequence ranges, hard to detect; the fix is hard-fail at startup if collision detected).

## Known failure modes
1. **Clock drift past 1ms during NTP step → IDs collide or refuse to issue.** A backward NTP step (rare but real) moves the clock back; if it crosses last_ms, Snowflake refuses to generate; if last_ms+1's sequence had overflowed, the new ID could collide with one already issued. Production answer: monotonic-clock-only mode (use `CLOCK_MONOTONIC` not `CLOCK_REALTIME`); persist last_ms + sequence across restarts; alert on backward-jump detection.

2. **Machine-ID reuse after restart with new IP/ordinal.** If machine_id is derived from a non-stable identifier (EC2 IP, K8s pod IP), restarts can produce different IDs; if the previous machine's IDs hadn't all been written downstream before restart, the new machine might issue IDs that collide with in-flight previous-machine IDs. Production answer: stable machine_id source (ZK lock, StatefulSet ordinal, config); on restart, verify no collision by querying a registry; hard-fail on collision.

3. **Sequence overflow within ms under burst.** 4096 IDs/ms exceeded → 4097th ID in the same ms would need a longer sequence field. Production answer: wait until next ms (introduces brief 1ms latency spike for the bursting client); alternatively extend bit allocation at design time if sustained throughput is known to exceed 4M IDs/sec/machine.

## Notes for the coach
- **This is plausibly-asked at Twitter, Instagram, Discord, Sony, Google (Spanner-adjacent), CockroachDB, YugaByte.** Hello Interview and ByteByteGo both list "Design a unique ID generator" as a canonical primitive. The Twitter Snowflake announcement (2010) is the primary historical reference.
- **The bit-layout-trade-off-derivation is the L7 flex.** A candidate who can articulate Snowflake's 41+10+12 layout AND derive the Sonyflake/Instagram alternatives from different optimization criteria is at Sr Staff bar.
- **HLC vs TrueTime vs refuse-on-backward-jump three-way comparison is the L7 depth.** Most candidates know one; the Sr Staff candidate articulates all three with criteria.
- **The 69-year-from-epoch lifespan is the long-term-planning anchor.** A candidate who flags epoch-exhaustion as a future migration concern (with the overlap-window strategy for the next-epoch transition) demonstrates production-system-lifecycle thinking.
- **No direct AI-infra counterpart** — sequencers are generic infra; the closest AI-infra analog is `prompt-cache-infrastructure`'s cache-key generation (which uses similar hashing patterns) but the framing is generic.
- **Cross-coverage:** below `spanner` (TrueTime is the strict-serializability use case for IDs), `kafka` (uses timestamp-based ordering in similar spirit), `stripe-payments` (idempotency-key generation is conceptually a sequencer problem). When other problems mention "generate a unique ID," this is the substrate.
- **Don't allow drift into "what about UUID v7?"** — UUIDv7 is a timestamp-prefixed UUID with similar k-sortedness; it's a legitimate alternative but the Snowflake / HLC / TrueTime taxonomy is more pedagogically useful. Note the UUIDv7 alternative briefly but stay on the Snowflake-axis discussion.

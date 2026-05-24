---
slug: dynamodb
archetype: infra-primitives
sources:
  dynamodb_atc_2022: usenix.org/system/files/atc22-elhemali.pdf
  dynamo_paper: allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
  discord_scylladb: discord.com/blog/how-discord-stores-trillions-of-messages
  cassandra_paper: cs.cornell.edu/projects/ladis2009/papers/lakshman-ladis2009.pdf
  amazon_science: amazon.science/blog/lessons-learned-from-10-years-of-dynamodb
---

# Amazon DynamoDB (eventually-consistent distributed KV store)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic sharded KV store: hash the key, route to a node, replicate to N nodes for durability. Names "consistent hashing" but may not articulate virtual nodes or why naive `hash(key) mod N` is wrong. Discusses eventual vs strong consistency at category level. Picks a replication factor (3 typical). Doesn't address vector clocks, hinted handoff, anti-entropy, or hot-partition mitigation unprompted.
- **Senior (L5/E5):** Names consistent hashing with virtual nodes for heterogeneous capacity and incremental rebalance on node add/remove. Articulates N/R/W tuning (e.g., N=3, R=2, W=2 with R+W>N for read-your-writes); knows about sloppy quorum + hinted handoff for write availability under partition. Discusses conflict resolution: vector clocks vs last-write-wins timestamps. Identifies anti-entropy via Merkle trees as the background repair mechanism. Knows about hot partitions as a real failure mode but may not articulate adaptive capacity or specific mitigations.
- **Staff+ (L6/E6+):** Drives proactively. Quantifies scale: DynamoDB peaked at 89.2M req/sec during Amazon Prime Day 2021 over a 66-hour window (USENIX ATC 2022 paper). Articulates the architectural evolution: original Dynamo (SOSP 2007) was leaderless quorum + vector clocks; **modern DynamoDB is CP per partition** — each partition is a Multi-Paxos replication group with leader-only writes and strongly consistent reads available, write-ahead log archived to S3 for 11-nines durability beyond the 3-replica window. Names the admission-control evolution: bursting (per-partition idle-token sharing) → adaptive capacity (move quota to hot partitions) → **Global Admission Control (GAC)** — central token-bucket service replenishing request-router-local buckets, eliminating bi-modal cache-miss behavior. Names MemDS (Perkle = Patricia + Merkle tree) as the in-memory horizontally-scaled metadata cache that fixed router cold-cache thundering herds at 99.75% hit rate. Cites availability SLA: 99.99% regular tables, 99.999% Global Tables (cross-region replicated). For comparison with the AP-leaning alternative (Cassandra / Riak), names the Discord 2023 migration: 177-node Cassandra → 72-node ScyllaDB, p99 read 40-125ms → 15ms, p99 write 5-70ms → 5ms — driven by JVM GC pauses in Cassandra and operational pain of `nodetool repair`. Stretch (Sr Staff bar): articulates how Discord's Rust data-service layer (consistent-hash routing on channel_id with request coalescing) prevented hot partitions in the DB layer entirely; describes adaptive capacity's auto-split mechanism.

## Canonical decomposition

### Requirements
**Functional:**
- Put/Get/Delete by primary key (partition key or partition + sort key composite)
- Configurable consistency: eventual (read from any replica) or strong (read from leader)
- Replication across multiple AZs for durability across AZ failure
- Auto-scaling of throughput capacity (read/write units) per table
- Optional secondary indexes (GSI = global secondary index; LSI = local within partition)
- Cross-region replication (Global Tables) for disaster recovery + multi-region read

**Non-functional (with numbers):**
- 89.2M req/sec peak (DynamoDB Prime Day 2021, USENIX ATC 2022)
- Single-digit millisecond p99 latency
- 99.99% availability (regular tables), 99.999% (Global Tables)
- 11-nines durability (WAL archived to S3 beyond per-partition 3-replica)
- Scale to billions of items per table, PB-scale total
- Multi-AZ replication: 3 replicas per partition across 3 AZs

### Core entities
- **Table:** table_name, partition_key_schema, sort_key_schema?, GSI_list, LSI_list, throughput_mode (provisioned | on_demand), replicated_regions
- **Partition:** partition_id, key_range (or hash range), replication_group (3 Multi-Paxos members across AZs), leader_replica
- **Replica:** replica_id, partition_id, role (leader | follower), local_WAL, local_storage_engine
- **Item:** primary_key (partition_key + optional sort_key), attributes (schemaless), version (for conditional updates)
- **MemDS node:** stateless metadata cache; holds (partition_key_hash → partition_id → replica_set) mapping via Perkle structure
- **GAC (Global Admission Control):** central service tracking per-table token bucket, replenishing request-router-local buckets

### API
- `PutItem(table, item, condition_expression?)` → unconditional or conditional write
- `GetItem(table, key, consistency=eventual|strong)` → item or null
- `DeleteItem(table, key, condition_expression?)`
- `Query(table, partition_key, sort_key_range)` → items within one partition
- `Scan(table, filter)` → full-table scan (rarely used at scale)
- `TransactWriteItems` → multi-item ACID transaction (since 2018; 2PC across involved partitions)
- `BatchGetItem` / `BatchWriteItem` → up to 25 items batched
- Streams: `DescribeStream` / `GetRecords` for change-data-capture

### HLD
Each table is sharded by partition_key hash into N partitions; each partition is a **Multi-Paxos replication group** of 3 replicas across 3 AZs. The leader serves writes and strongly-consistent reads; followers serve eventually-consistent reads. Writes are committed to the local WAL on the leader, replicated to followers via Paxos, then materialized into the local storage engine (SSTable-style). WAL segments are periodically archived to S3 for 11-nines durability beyond the per-partition 3-replica.

Request routers are stateless. On a request, the router resolves the partition via **MemDS** — an in-memory horizontally-scaled metadata service using a Perkle (Patricia + Merkle tree) structure to map `partition_key_hash → partition_id → replica_set`. MemDS replaced an earlier metadata cache pattern that suffered cold-cache thundering herds at 99.75% hit rate (sub-1% miss rate × tens of millions of req/sec = significant cold-cache load that the old design couldn't absorb).

**Admission control** is layered: per-partition bursting (idle tokens shared with hot neighbors) → adaptive capacity (auto-split a hot partition into multiple sub-partitions across nodes) → **GAC (Global Admission Control)** — central token-bucket per table replenishing router-local buckets at regular intervals. GAC enforces total table throughput uniformly across all routers; per-partition fine-grained allocation happens via adaptive capacity within the GAC budget.

For **Global Tables** (cross-region), each region operates an independent table; writes replicate asynchronously to all regions via DynamoDB Streams + an internal replication pipeline. Conflicts resolve by last-writer-wins on a server-generated timestamp. Strong consistency is per-region; cross-region is eventual. SLA bumps to 99.999% because regional failover absorbs region-level events.

**Comparison with the leaderless quorum alternative (original Dynamo, Cassandra):** the SOSP 2007 paper architecture used (N=3, R=2, W=2) sloppy quorum + vector clocks + Merkle tree anti-entropy. Modern DynamoDB moved to CP-per-partition via Multi-Paxos because: (a) leader-based replication gives strongly-consistent reads from the leader without read-your-writes hassle; (b) auto-split + GAC handle hot partitions better than client-side vector-clock reconciliation; (c) WAL archival to S3 gives durability beyond the replication-group's per-replica disk. Cassandra retains the leaderless model with tunable consistency (CL.ONE / QUORUM / ALL); Discord moved off Cassandra to ScyllaDB primarily for the C++ shard-per-core architecture (no JVM GC pauses).

### Deep dives
1. **Consistent hashing evolution and adaptive capacity.** Original Dynamo: random token assignment per virtual node on the ring. Worked but had operational pain — bootstrap (replicating data to a new node) was slow, and key-range sizes were irregular. Strategy 2: equal-sized partitions, each owning a fixed range of the hash space. Better, but still required manual rebalancing. Strategy 3 (modern DynamoDB): equal-sized partitions with even distribution across nodes — every node owns a similar number of partitions, and partitions are split when a single partition's traffic exceeds a threshold (**adaptive capacity** — DynamoDB's published 2017 mechanism). Auto-split: hot partition is identified by per-partition traffic > threshold; the system creates a new partition with a sub-range of keys; existing data is replicated to the new replication group; routers update via MemDS. Trade-off: brief routing flap during split; risk of split-induced "cool" sub-partitions if traffic was concentrated on a few keys. Virtual nodes (multiple ring positions per physical node) handle heterogeneous hardware (a fatter node owns more virtual positions). Staff+ commit: virtual node count, split threshold, what happens during split (routing transition, write fence on old partition during cutover).

2. **N/R/W tuning, sloppy quorum, and the conflict-resolution choice.** Quorum config: N=3 replicas, W=write quorum, R=read quorum. R+W>N gives "strong-ish" consistency (read after write sees the write, modulo clock skew). Production patterns: (N=3, W=2, R=2) is the Dynamo default — fast writes (don't wait for slowest replica), strong-ish reads; (N=3, W=3, R=1) for write-heavy with infrequent reads; (N=3, W=1, R=3) inverse. **Sloppy quorum + hinted handoff** (Dynamo): when a target replica is down, writes succeed on the next-clockwise replica with a "hint" that the data belongs elsewhere; when the original target recovers, hints are replayed. Trade: write availability up; read-after-write monotonicity briefly violated until hint replays. **Conflict resolution under partition** (concurrent writes to different replicas): (a) **vector clocks** (original Dynamo) — track causality, return all "concurrent" versions on read, application reconciles; complex but lossless; (b) **last-writer-wins** by server timestamp (Cassandra default, DynamoDB Global Tables) — simple, silently drops one of two concurrent writes; (c) **CRDTs** (Riak optional, Redis specific data types) — data-type-aware merge functions; only works for specific structures (counter, set, register). Modern DynamoDB inside a region: leader-based, conflicts don't arise. Across regions (Global Tables): LWW timestamps. Staff+ commit: pick conflict-resolution per use case; address what application sees on conflict (multiple versions, single resolved value, error?).

3. **Hot-partition mitigation and the Discord case study.** Naive design: one tenant's hot key (e.g., a popular channel's message stream) routes to one partition, that partition's replica saturates while others sit idle. Mitigations: (a) **adaptive capacity** (DynamoDB) — auto-split the hot partition; (b) **request coalescing upstream** (Discord's Rust data-service layer) — multiple concurrent requests for the same key are batched into one DB query, dramatically reducing DB load on hot keys; (c) **read-through cache** (Memcached / Redis tier in front) — hot keys serve from cache, only cache misses hit DB; (d) **shard-key redesign** — add a hash prefix or time bucket to spread one logical entity across multiple partitions, with a separate aggregation layer for queries across the sub-shards. Discord's published 2023 migration is the canonical case study: 177-node Cassandra cluster, trillions of messages; hot partitions caused cascading latency under unbounded concurrency; JVM GC pauses caused tail-latency spikes (Cassandra is Java/JVM, ScyllaDB is C++ shard-per-core). Migration to 72-node ScyllaDB dropped p99 reads 40-125ms → 15ms and p99 writes 5-70ms → 5ms. Critically, Discord didn't just swap DBs — they built a Rust data-service layer with consistent-hash routing on channel_id + request coalescing that prevented hot-partition pathology in the new system. Staff+ commit: identify the failure mode pre-emptively, choose the mitigation that's right for the workload (adaptive capacity for variable load; request coalescing for read-heavy hot keys; shard-key redesign for fundamentally skewed data).

## Known failure modes
1. **Hot partition cascading latency under unbounded concurrency.** Single hot key saturates one partition's replica → write latency spikes → upstream backpressure → cascading slowdown. Production answer: layered defenses — (a) request coalescing at the application/service layer (Discord's Rust pattern: batch concurrent reads for the same key); (b) adaptive capacity auto-split at the DB layer (DynamoDB); (c) read-through cache (Memcached) for very-hot read keys; (d) shard-key redesign for fundamentally skewed access patterns. Anti-pattern: ignore hot partitions and rely on the DB to auto-scale — works for moderate skew, fails under whale-tenant scenarios.

2. **Hinted handoff replay storm after long node downtime.** A node returns after extended downtime; hints accumulated during its absence replay all at once; network and node saturate. Production answer: throttled hint replay (rate-limit by bytes-per-second per source-target pair); read-repair as the slower-but-steady alternative path (anti-entropy via Merkle trees in the background); for very-long downtime, consider rebuilding the replica from peers rather than replaying hints.

3. **JVM GC pause induced tail-latency spikes (Cassandra-specific; Discord's published reason to migrate).** Cassandra is Java; full GC pauses can be hundreds of ms to seconds; reads/writes during the pause time out; client retries pile on. Production answer: tune GC (G1GC with tight pause targets), keep heap small relative to data (most data should be in OS page cache, not heap), monitor GC pauses as a primary SLI. For workloads where this is unacceptable: migrate to ScyllaDB (C++ shard-per-core, no JVM) or accept the latency profile. Discord's migration is the canonical "we tuned everything and still couldn't get past the JVM" case study.

## Notes for the coach
- **This is the canonical "design DynamoDB / Cassandra" interview prompt.** Asked-confirmed at Amazon (canonical) and on every infra interview-prep list (ByteByteGo Vol 2; Hello Interview; Educative Grokking; IGotAnOffer FAANG). The DynamoDB Ten Years Later paper (USENIX ATC 2022) is the primary engineering source every Staff+ interviewer expects familiarity with; the original Dynamo SOSP 2007 paper is the historical anchor.
- **The 89.2M req/sec Prime Day 2021 number is the headline scale anchor.** Citing it grounds the design pressure quantitatively.
- **The Cassandra-vs-DynamoDB architectural fork is the Staff+ discrimination probe.** Cassandra retains the leaderless quorum + vector-clock-ish (server-timestamp LWW) model from the original Dynamo; modern DynamoDB moved to CP-per-partition Multi-Paxos. A candidate who articulates this fork unprompted is at Sr Staff bar. The right answer for a new system depends on workload: Cassandra-class for write-heavy AP with multi-DC active-active; DynamoDB-class for read-heavy with strong-read requirement.
- **The Discord 2023 migration case study is the modern Staff+ literacy signal.** Citing Discord's published migration (177 → 72 nodes, p99 40-125ms → 15ms reads, p99 5-70ms → 5ms writes) plus their Rust data-service layer with request coalescing demonstrates 2023+ infra-engineering literacy. A candidate proposing Cassandra without acknowledging the JVM-GC operational pain and the ScyllaDB / DynamoDB alternatives is anchoring on 2015-era patterns.
- **Cross-coverage with AI-infra `prompt-cache-infrastructure`:** the AI version uses similar consistent-hashing + replication substrate but adds KV-cache semantics (prefix-tree keying, GPU-VRAM tier). Coach should announce "no LLM-specific framing" up front for this primitive version.
- **MemDS (Perkle = Patricia + Merkle tree) is a non-obvious depth signal.** Most candidates skip the metadata-cache architecture entirely; the Sr Staff candidate names it and explains the 99.75% hit rate cold-cache thundering herd that motivated the design change.

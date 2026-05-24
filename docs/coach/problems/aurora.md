---
slug: aurora
archetype: infra-primitives
sources:
  aurora_sigmod_2017: pages.cs.wisc.edu/~yxy/cs764-f20/papers/aurora-sigmod-17.pdf
  aurora_sigmod_2018: assets.amazon.science/dc/2c/82c69500499eaca0ff058a7a8b1c/amazon-aurora-on-avoiding-distributed-consensus-for-i-os-commits-and-membership-changes.pdf
  aurora_256_tib: aws.amazon.com/about-aws/whats-new/2025/07/amazon-aurora-postgresql-database-clusters-256-tib-storage-volume/
---

# Amazon Aurora (disaggregated cloud-native relational database)

## Bar anchors
- **Mid-level (L4/E4):** Would likely struggle — this is a "modern database architecture" question that assumes familiarity with classical RDBMS architecture as a baseline. May know Aurora as "MySQL-compatible managed database" but not articulate the disaggregation insight. Doesn't address log-as-the-database, quorum design, or segment-based repair unprompted.
- **Senior (L5/E5):** Names "separated compute from storage" at category level; understands Aurora has read replicas that share the same storage volume. May discuss multi-AZ replication. Doesn't articulate the specific 6/3 quorum design, the redo-log-only network traffic, or the segment-level repair model.
- **Staff+ (L6/E6+):** Drives proactively. Cites Verbitski et al., SIGMOD 2017 §3.2: **"In Aurora, the only writes that cross the network are redo log records. No pages are ever written from the database tier, not for background writes, not for checkpointing, and not for cache eviction"** — the "log is the database" insight. Articulates the **6/3 quorum design** (§2.1): "replicating each data item 6 ways across 3 AZs with 2 copies of each item in each AZ"; write quorum Vw=4/6, read quorum Vr=3/6 — tolerates (a) AZ failure + 1 additional node without losing reads, (b) AZ failure without losing write availability. Names **segment-based repair** (§2.2): "A 10GB segment can be repaired in 10 seconds on a 10Gbps network link" → an additional failure during repair has a 10-second exposure window, dramatically reducing the probability of compound failure. Cites **crash recovery** (§4.3): "an Aurora database can recover very quickly (generally under 10 seconds) even if it crashed while processing over 100,000 write statements per second" — because the storage tier continuously applies log records, "Nothing is required at database startup" — no redo replay phase. Quantifies throughput vs mirrored MySQL: 35× more transactions on SysBench write-only 100GB 30-min r3.8xlarge (SIGMOD 2017 §3.2); storage-tier I/Os reduced 46×; peak 121K writes/sec + 600K reads/sec on r3.8xlarge (§6.1.1). Quantifies volume: 64 TB at SIGMOD 2017 publication; raised to 128 TiB; raised to **256 TiB for Aurora PostgreSQL in July 2025** (AWS announcement). Up to 15 read replicas sharing one storage volume; replica lag ≤20ms typically. Stretch (Sr Staff bar): articulates the SIGMOD 2018 follow-up on **avoiding 2PC for multi-segment writes**: Aurora uses quorum-based commit with "AZ+1 failure tolerance" rather than 2PC, eliminating the coordinator-blocking problem entirely at the storage layer.

## Canonical decomposition

### Requirements
**Functional:**
- MySQL/PostgreSQL-compatible relational database (Aurora MySQL, Aurora PostgreSQL)
- Separated compute (DB instance) from storage (durable distributed storage tier)
- Multiple read replicas sharing the same storage volume (no replica-specific data movement)
- Crash recovery in seconds, not minutes (no redo log replay at startup)
- Tolerate single AZ failure + 1 additional node without loss of reads
- Online volume growth (transparent to application)

**Non-functional (with numbers):**
- 35× throughput vs mirrored MySQL on SysBench write-only benchmark (Verbitski et al. SIGMOD 2017)
- Storage tier I/Os reduced 46× vs mirrored MySQL
- Peak 121K writes/sec + 600K reads/sec on r3.8xlarge (§6.1.1)
- 6/3 quorum: 6 copies of each segment, 3 AZs, Vw=4, Vr=3
- 10 GB segments; 10-second repair window on 10 Gbps network
- Recovery <10 seconds after crash at 100K writes/sec
- Volume size: 64 TB → 128 TiB → 256 TiB (July 2025)
- Up to 15 read replicas per cluster; replica lag ≤20ms typical
- 99.99% availability for single-region Aurora; 99.999% for Aurora Global Database

### Core entities
- **DB instance (compute):** runs MySQL/PostgreSQL engine; stateful for transaction logic but stateless w.r.t. data — all reads/writes go to the storage tier
- **Storage volume:** 10 GB segments × N segments per volume; 6 copies of each segment across 3 AZs (2 per AZ)
- **Protection Group (PG):** the 6 copies of one segment forming a quorum unit
- **Storage node (bookie-equivalent):** a node in the storage tier; hosts segments from many volumes; receives redo log records, materializes pages on demand
- **Read replica:** another DB instance attached to the same volume; reads its own cache + storage; receives invalidations from primary via redo log stream
- **Aurora Global Database:** cross-region replication; secondary regions are read-only with <1s typical replication lag

### API
- MySQL / PostgreSQL wire protocol (Aurora is wire-compatible with both flavors)
- Cluster management: `CreateDBCluster`, `CreateDBInstance` (primary or replica), `DescribeDBClusterEndpoints`
- Endpoints: cluster endpoint (always primary), reader endpoint (load-balanced across replicas), instance endpoints (specific instance)
- Storage API (internal): `WriteLogRecord(redo_record)` to PG quorum (Vw=4); `ReadPage(page_id, snapshot_lsn)` from PG quorum (Vr=3)

### HLD
**The architectural insight: ship redo log records, not pages.** Classical replicated MySQL ships 8KB pages from primary to replicas + storage; Aurora ships only the redo log records (typically tens of bytes per modification). The storage tier asynchronously materializes pages from the log records — pages become "a cache of log applications" rather than the source of truth.

**Compute tier**: the DB instance runs MySQL/PostgreSQL engine, handles SQL parsing, query planning, transaction management, buffer pool management. On a write, it generates a redo log record and ships it to the storage tier; on read, it consults its local buffer pool first, falls back to fetching the page from storage. The buffer pool may include dirty pages (writes not yet materialized in storage) but the redo log is durably stored at the storage tier (Vw=4 quorum) before commit.

**Storage tier**: distributed across 6 storage nodes per Protection Group (PG), with each PG holding one 10 GB segment of the volume. Writes (redo log records) replicate to 6 copies across 3 AZs (2 per AZ); commit requires Vw=4 acks (any 4 of 6). Reads need Vr=3 acks for consistency (any 3 of 6). The math: Vw + Vr > V (4+3 > 6) ensures any read sees any committed write (overlapping read/write quorums). The storage tier **continuously applies log records to materialize pages in the background** — so on database crash recovery, "nothing is required at database startup" — no redo replay (which can take minutes-to-hours in MySQL after a crash with large dirty buffer pool).

**The 6/3/4/3 quorum design** is the headline. 3 AZs gives geographic diversity (correlated failure isolation). 6 copies (2 per AZ) means losing one AZ entirely still leaves 4 copies, satisfying Vw=4 → writes can still commit. Losing one AZ + 1 additional node leaves 3 copies, satisfying Vr=3 → reads can still serve. **AZ+1 failure tolerance** is the SLA target. 2/3 quorum (3 copies, 1 per AZ) would not give this — AZ failure leaves only 2 copies, satisfying neither Vw=4 nor Vr=3 with the next failure.

**Segment-based repair**: each PG is 10 GB. On detected loss of a copy (storage node failure), the system identifies the affected PGs and re-replicates each 10 GB segment from a surviving copy. On a 10 Gbps network link, 10 GB transfers in ~10 seconds → exposure window during which an additional failure could matter is ~10 seconds (vs hours for whole-instance repair). The probability of compound failure within a 10-second window is dramatically smaller than within a longer window.

**LSN-based ordering**: every log record gets a Log Sequence Number (LSN) from a monotonic counter. The storage tier uses LSN to maintain ordering on per-page log application; the DB instance uses LSN to coordinate replicas (replica knows the primary's LSN frontier, only serves reads up to that point for strong consistency, or up to its own cache frontier for eventual).

**Read replicas** attach to the same storage volume — no replica-specific data movement, no replica-specific storage cost. Each replica has its own buffer pool; on write at primary, the redo log stream invalidates replica buffer pool entries (replica cache flushes affected pages); replica reads either fresh data from storage or up-to-date cache. Replica lag ≤20ms typical because the replica isn't replaying logs (storage tier does that); it's just invalidating cache entries.

### Deep dives
1. **The "log is the database" insight and the 46× I/O reduction.** Classical replicated MySQL: primary writes the page to local storage + ships the page (or page + log) to replicas + storage. With replication factor 3, write amplification = 3× pages = 24KB per 8KB modification. Aurora: primary writes only the redo log record (typically <100 bytes per modification) to the storage tier; storage tier applies the log to materialize pages in the background. Write amplification at the network level: ~100 bytes per modification × 6 copies = 600 bytes (vs 24KB classical) → ~40× reduction. The actual published number is 46× I/O reduction on SysBench write-only at 100GB / 30-min / r3.8xlarge. The throughput win: 35× more transactions in the same time window because the DB instance isn't bottlenecked on page write I/O; the storage tier handles materialization asynchronously without blocking commits. **Crash recovery is the bonus**: classical MySQL on crash must replay the redo log (read from disk, apply to dirty pages in buffer pool) — minutes to hours for large dirty sets. Aurora's storage tier has been continuously applying the redo log all along — at crash recovery, "Nothing is required at database startup" (§4.3) → recovery in <10s even after crashing at 100K writes/sec. Staff+ commit: articulate the architectural inversion (compute owns transaction logic; storage owns the durable log + page materialization), address the trade-off (storage tier complexity is now Aurora-specific; can't run on commodity DBaaS).

2. **The 6/3/4/3 quorum rationale.** 6 copies across 3 AZs, Vw=4, Vr=3. **Why not 3 copies (1 per AZ)?** AZ failure leaves 2 copies; the next failure leaves 1; you can't satisfy any quorum > 1 → write unavailable after AZ failure. **Why not 4 copies (1 AZ has 2 copies)?** AZ-with-2 loss leaves 2 copies; can't satisfy Vw=3. **Why 6 (2 per AZ)?** AZ loss leaves 4 copies (Vw=4 satisfied → writes still commit); AZ loss + 1 additional leaves 3 (Vr=3 satisfied → reads still serve). The **AZ+1 failure tolerance** is the SLA promise; the math constrains the quorum design uniquely. Vw=4 + Vr=3 > V=6 ensures read-after-write linearizability (any read quorum intersects any write quorum). Trade-off: 6× storage cost vs 3× — Aurora's customers pay for the durability; the alternative (3× replication + tolerating worse failure modes) is what classical replicated MySQL provides at lower cost. Staff+ commit: derive the math from the failure-tolerance requirement, address what happens at 2-AZ-loss (writes pause until enough copies return — the rare correlated-AZ-failure case).

3. **Segment-based repair: minimizing the compound-failure window.** Failure modes scale with the exposure window. If repair takes hours (whole-instance copy), an additional failure during that window can lose data. If repair takes seconds (10 GB segment on 10 Gbps), the compound window is small. Aurora's design: partition the volume into 10 GB segments; on detected copy loss, re-replicate just that segment (10 GB) → ~10 seconds on a 10 Gbps network link. Compare: classical MySQL replica failure → entire instance must be re-built from backup (terabytes; hours). Combined with the 6/3 quorum: write durability is preserved through (AZ failure + 1 additional copy loss) for the 10-second window during segment repair → compound failure probability dramatically smaller. **The SIGMOD 2018 follow-up extended this**: multi-segment writes (logical operations spanning multiple PGs) need atomic commit; Aurora replaced 2PC with **quorum-based commit with AZ+1 failure tolerance** — no coordinator, no blocking; commit is "all required PGs reached Vw" → quorum disagreement is impossible under AZ+1 failure model. Staff+ commit: segment size choice (small → low exposure window but more metadata overhead; large → less metadata but longer exposure), what happens during ongoing segment-repair (degraded mode: writes may stall if Vw can't be reached during repair on the affected PG; reads may have higher latency if Vr requires reading from the replication source).

## Known failure modes
1. **Quorum loss under correlated AZ + node failure.** AZ outage + 1 additional node loss leaves 3 copies; Vw=4 not satisfied → writes pause. AZ outage + 2 additional node losses leaves 2 copies; Vr=3 not satisfied → reads also pause. Production answer: monitor copy-count per PG as an SLI; alerting on copy loss; automated segment-repair pipeline prioritizes PGs with low copy count; for global-grade availability, Aurora Global Database replicates to a second region (asynchronous, <1s lag) so the second region can be promoted.

2. **LSN allocation backpressure.** The DB instance allocates LSNs from a monotonic counter; if storage tier can't keep up (sub-Vw acks), LSN allocation stalls → database slows to match storage-tier throughput. Production answer: monitor storage-tier ack latency as the primary SLI; provision storage IOPS for peak load + safety margin; rate-limit user-visible writes if storage tier is degraded.

3. **Storage-tier hot segment.** One PG receives disproportionate traffic (e.g., a hot tablespace or hot index page) → that PG's storage nodes saturate; writes affecting that PG slow down. Production answer: segment splitting when per-PG write rate exceeds threshold; index design that spreads writes across multiple pages (avoiding monotonic-key indexes which hot the last page); horizontal sharding at the application layer for fundamentally hot data.

## Notes for the coach
- **This is asked-confirmed at AWS L6+ database/infra rounds.** Verbitski et al. SIGMOD 2017 + 2018 papers are the primary references; ByteByteGo Vol 2 covers "design a cloud database"; plausibly-asked at Snowflake (FoundationDB-based metadata), Databricks (Delta Lake disaggregated storage), PlanetScale, Neon, and any company building modern cloud databases.
- **The "log is the database" quote is the literacy unlock.** Citing the SIGMOD 2017 §3.2 quote verbatim demonstrates familiarity with the canonical reference; the candidate who articulates the 46× I/O reduction + 35× throughput numbers is at Sr Staff bar.
- **The 6/3/4/3 quorum math is the depth probe.** A candidate who recites "6 copies, 3 AZs" without deriving Vw=4 and Vr=3 from the AZ+1 failure model is at Senior; the Staff+ candidate derives the quorum design from the failure-tolerance requirement.
- **The segment-based repair window (10s on 10 Gbps) is the operational-reality anchor.** Connecting repair time to compound failure probability is the modern fault-tolerance reasoning pattern.
- **The 2018 SIGMOD follow-up on avoiding 2PC** is the L7 stretch flex. Most candidates know the 2017 paper; the Sr Staff candidate cites the 2018 paper's quorum-based multi-segment commit as the further architectural insight.
- **Don't allow drift into "design MySQL" full implementation.** Stay on the disaggregation primitive shape; SQL parsing, query optimization, replication topology between primary and replicas are out of scope. The question is about the storage architecture that enables Aurora's properties.
- **No direct AI-infra counterpart** — Aurora is the modern cloud-database substrate; the closest AI-infra analog is `prompt-cache-infrastructure` (KV-cache materialization is conceptually similar to page materialization from log), but the framing is generic infrastructure.
- **Cross-coverage:** sits adjacent to `s3` (Aurora uses S3 for WAL archive — durability beyond storage-tier 6 copies), `dynamodb` (which also moved to leader-based replication per-partition + S3 WAL archive — similar architectural patterns at a different abstraction level), `pulsar` (the log-as-substrate pattern reappears).

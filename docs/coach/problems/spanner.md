---
slug: spanner
archetype: infra-primitives
sources:
  spanner_paper: storage.googleapis.com/gweb-research2023-media/pubtools/1974.pdf
  spanner_truetime: cloud.google.com/spanner/docs/true-time-external-consistency
  foundationdb_paper: foundationdb.org/files/fdb-paper.pdf
  cockroachdb_atomic_clocks: cockroachlabs.com/blog/living-without-atomic-clocks/
  calvin_paper: cs.yale.edu/homes/thomson/publications/calvin-sigmod12.pdf
---

# Google Spanner / FoundationDB / CockroachDB (distributed transaction coordinator)

## Bar anchors
- **Mid-level (L4/E4):** Would struggle — this is the deepest infra problem in the catalog. May know "2PC = two-phase commit" at category level but not articulate the blocking problem on coordinator failure. Doesn't address consensus-replicated coordinators, MVCC, or external consistency unprompted.
- **Senior (L5/E5):** Names 2PC for cross-shard atomic commits; identifies the coordinator-blocking problem (participants hold locks if coordinator crashes mid-protocol). Discusses serializable isolation at category level. May or may not know about MVCC or external consistency / strict serializability.
- **Staff+ (L6/E6+):** Drives proactively. Names the **modern fix to 2PC blocking**: run 2PC over consensus-replicated participants (Spanner's key insight) — each shard is a Paxos group; the coordinator state is itself replicated via a Paxos group; coordinator crash → another replica takes over → resumes 2PC from durable state → no participants stranded. Distinguishes **external consistency vs serializability**: serializable = some valid serial order exists; external consistency (strict serializability) = the serial order respects real-time wall-clock order across transactions. Articulates **TrueTime + commit-wait** for external consistency (Spanner): TrueTime returns a [earliest, latest] interval; commit_ts = TT.now().latest; wait until TT.now().earliest > commit_ts before reporting commit; guarantees the commit_ts is in the absolute past. Cites Spanner's published epsilon (TrueTime uncertainty) of 1-7ms typical with ~4ms average → ~4ms commit-wait cost. Articulates the **HLC + read-refresh alternative** (CockroachDB): HLC = physical wall-clock max with logical Lamport counter; no special hardware required; on commit-time-pushed transactions, the read-set is re-validated (read-refresh) to ensure linearizability — pay latency via retry rather than via commit-wait. Names **OCC vs 2PL** trade-off: FoundationDB uses OCC (validate at commit, retry on conflict; high abort rate under contention, lower latency at low contention); Spanner uses 2PL + snapshot reads; both correctness-equivalent under serializable isolation. Names **Calvin** (Thomson et al., SIGMOD 2012) as the deterministic-ordering alternative: pre-compute a global transaction order via a sequencer (replicated via Paxos), participants execute deterministically → no 2PC needed; trade is transactions must declare read/write sets upfront. Quantifies FoundationDB Sequencer throughput at ~1M txns/sec (SIGMOD 2021 paper). Stretch (Sr Staff bar): cites CockroachDB's Parallel Commits optimization (halves commit latency from 2 consensus rounds to 1); articulates the **disk corruption defense** (Chubby's checksums-and-rejoin pattern applied here).

## Canonical decomposition

### Requirements
**Functional:**
- ACID transactions across multiple shards with serializable isolation (or external consistency / strict serializability)
- Non-blocking reads via MVCC (snapshot reads at past timestamps)
- Survive coordinator failure without participant stranding
- Support both OLTP-style (read-modify-write) and OLAP-style (long-running analytical) transactions
- Cross-region replication with bounded latency on local-region transactions

**Non-functional (with numbers):**
- 10K cross-shard txns/sec target; p99 commit latency <100ms
- Spanner TrueTime epsilon: 1-7ms typical, ~4ms average → ~4ms commit-wait
- 100-1000 tablets per spanserver (Spanner deployment)
- 10-second Paxos leader leases (Spanner default)
- FoundationDB Sequencer: ~1M txns/sec ceiling
- 99.999% availability for billing-grade ACID systems
- Single-region commit: ms-scale; cross-region commit: 10-100ms (depending on geographic spread)

### Core entities
- **Shard / Tablet:** unit of data partition; each shard is a Paxos group of N replicas across AZs
- **Paxos group:** the consensus replication primitive backing each shard
- **Transaction coordinator:** the participant chosen to drive the 2PC protocol for a cross-shard transaction; itself a Paxos group so it's fault-tolerant
- **TrueTime API:** returns (earliest, latest) interval representing current wall-clock time with explicit uncertainty epsilon
- **HLC timestamp:** Hybrid Logical Clock = (physical_ts, logical_counter); on receive of remote message, hop ahead if remote is in the future
- **MVCC version chain:** each row stores multiple versions indexed by commit_ts; reads at snapshot_ts see the version with commit_ts ≤ snapshot_ts

### API
- `begin_transaction(isolation_level=serializable)` → txn_handle
- `read(txn, key)` → value at snapshot of txn (MVCC version)
- `read_for_update(txn, key)` → value + 2PL lock or OCC read-set entry
- `write(txn, key, value)` → buffered, applied on commit
- `commit(txn)` → 2PC across involved shards; returns commit_ts; **commit-wait** delays return if TrueTime; **read-refresh + retry** if HLC + pushed timestamp
- `abort(txn)` → release locks, discard write buffer
- `read_at(snapshot_ts, key)` → MVCC snapshot read (non-blocking, no 2PC)

### HLD
The dataset is sharded; each shard is a **Paxos group** of N replicas (typically 3-5) across availability zones. Within a shard, the leader serializes operations via 2PL (Spanner) or OCC (FoundationDB) + replicates via Paxos. Cross-shard transactions use **2PC** — one participant is the coordinator; each participant prepares + votes; coordinator decides commit-or-abort + writes the decision durably; participants apply + release locks.

**The blocking-coordinator problem (classical 2PC):** if the coordinator crashes after PREPARE but before COMMIT/ABORT, participants are stuck holding locks indefinitely — they can't unilaterally commit (might violate atomicity if coordinator decided abort) or unilaterally abort (might violate atomicity if coordinator decided commit). Modern systems **fix this by replicating the coordinator over Paxos**: the coordinator's 2PC state machine is itself a replicated state machine. Coordinator failure → another replica takes over → reads the durable 2PC state → resumes the protocol → no stranded participants. This is Spanner's key insight.

**External consistency** (strict serializability) requires that the serial order respects real-time wall-clock order: if transaction A's commit completes before transaction B starts, then A's commit_ts < B's commit_ts. **TrueTime + commit-wait** (Spanner): TrueTime returns `[earliest, latest]` with bounded epsilon (1-7ms in Google DCs, ~4ms typical). At commit time, coordinator picks `commit_ts := TT.now().latest`, then waits until `TT.now().earliest > commit_ts` before reporting commit success — guarantees the commit_ts is in the absolute past from any observer's perspective. Average commit-wait cost = epsilon/2 ≈ 2-4ms. This wait can be overlapped with disk fsync (often making it nearly free).

**HLC + read-refresh** (CockroachDB): HLC = (physical_clock, logical_counter); preserves causal order (Lamport-style) plus closeness to real-time. No commit-wait; instead, on commit-time-pushed transactions, the read-set is re-validated against the new commit_ts (read-refresh: were the read values still valid at the pushed timestamp?); if not, retry. Trade: no special hardware (no GPS/atomic clocks); pay latency via retries on contended workloads rather than via commit-wait on every transaction.

**OCC vs 2PL:** FoundationDB uses **OCC** — record read-set + write-set during the transaction, validate at commit time that no concurrent transaction modified the read-set, retry on conflict. Spanner uses **2PL + snapshot reads** — locks acquired incrementally during the transaction, blocking on conflict. OCC has lower latency at low contention (no lock-acquire overhead) but higher abort rate at high contention. 2PL is the inverse. Both give serializable isolation; both correctness-equivalent.

**Calvin alternative:** Rather than 2PC, Calvin pre-computes a global transaction order via a Sequencer (replicated via Paxos); every replica executes the transactions in identical order via a deterministic scheduler; no 2PC because the order is pre-decided. **Trade:** transactions must declare read/write sets upfront (limits dynamic transactions where the read-set depends on the data). Used in commercial systems like FaunaDB.

### Deep dives
1. **2PC over Paxos: the modern fix to coordinator blocking.** Classical 2PC: coordinator crashes after PREPARE; participants hold locks indefinitely; unable to safely commit or abort without coordinator's decision. The blocking is provably unavoidable for any commit protocol with independent recovery (FLP-related result). **Modern fix**: replicate the coordinator state machine via Paxos/Raft → coordinator becomes fault-tolerant; on crash, another replica picks up from the durable log. Each shard is a Paxos group; one is chosen as coordinator; the coordinator's 2PC state (PREPARE votes received, decision) is replicated via the coordinator's Paxos group. On coordinator failure, the new leader of that group reads the 2PC state and resumes (sending COMMIT or ABORT to participants; if no decision was logged, ABORT is safe). **Cost**: every 2PC phase = 1 Paxos round across the coordinator group → 2 Paxos rounds for 2PC (PREPARE + COMMIT) + 1 Paxos round per participant's local commit → total commit latency ~3 RTTs across geographic distance. CockroachDB's **Parallel Commits** optimization overlaps the coordinator's commit-decision write with the participants' apply, halving commit latency from 2 consensus rounds to 1 (cutting cross-region commit latency by 50-100ms in practice). Staff+ commit: 2PC-over-Paxos architecture, who owns the coordinator role (one of the participants typically, chosen at transaction start), what happens on participant failure during PREPARE phase.

2. **TrueTime + commit-wait vs HLC + read-refresh: external consistency without atomic clocks.** External consistency is hard because clock skew across nodes is unbounded under standard NTP. Two solutions: (a) **TrueTime** (Spanner): GPS + atomic clocks in each datacenter give bounded clock uncertainty (epsilon 1-7ms in Google DCs); the TT API exposes the uncertainty as an interval; commit-wait until `TT.now().earliest > commit_ts` guarantees the commit is in the absolute past. Cost: ~4ms per commit on average; requires GPS+atomic-clock infrastructure (Google has it, customer datacenters typically don't). (b) **HLC + read-refresh** (CockroachDB): HLC = `max(local_physical_clock, max_remote_hlc_seen) + logical_increment`; preserves causality, stays close to real-time. No commit-wait; instead, on contention (a concurrent transaction pushed our commit_ts forward), re-validate the read-set against the new commit_ts (read-refresh) — if read values still valid, commit at new ts; if not, retry. Trade: HLC + read-refresh is "free" on uncontended workloads but expensive on hot rows (retry storms); TrueTime is uniformly ~4ms per commit. **Both achieve external consistency**, just with different cost models. Staff+ commit: pick mechanism with criteria (controlled environment with GPS available → TrueTime; commodity hardware → HLC + read-refresh), address what happens during clock skew event (Spanner monitors epsilon and rejects transactions when uncertainty exceeds threshold).

3. **OCC vs 2PL vs Calvin: three approaches to serializable cross-shard.** **2PL (Two-Phase Locking)**: acquire shared lock on read, exclusive lock on write, release at commit; ensures serializable order via blocking on conflicting accesses. Pros: simple model; works for any access pattern. Cons: deadlocks possible (need detector); contention causes blocking, not retries; lock-table memory overhead. **OCC (Optimistic Concurrency Control)**: record read-set + write-set during execution; at commit, validate that no concurrent transaction modified the read-set; retry on conflict. Pros: no locks during execution (lower latency on uncontended); works well with MVCC for snapshot isolation. Cons: high abort rate under contention; livelock possible without backoff. **Calvin (deterministic ordering)**: pre-compute the order of transactions globally; replicate the order via Paxos; participants execute in identical order via deterministic scheduling — no concurrency between conflicting transactions because the order is decided. Pros: no 2PC, no locks during execution. Cons: transactions must declare read/write sets upfront (limits transactions whose read-set depends on data — e.g., "read all orders for customer X" can't be declared until X is known). FoundationDB uses OCC; Spanner + CockroachDB use 2PL + snapshot reads; FaunaDB uses Calvin. Staff+ commit: pick CC mechanism with criteria for the workload (OCC for low-contention OLTP; 2PL for mixed; Calvin for batch-heavy with known access patterns).

## Known failure modes
1. **Cross-shard contention causing OCC abort storm.** Hot key contended by many concurrent transactions → OCC validates fail → all retry → re-validate fails → cascading retries → throughput collapses. Production answer: contention-aware retry (exponential backoff with jitter on aborts); application-level batching (combine multiple operations on the same key into one transaction); per-row queue + serialize (FoundationDB's design philosophy: avoid hot rows at the application level rather than fix in the DB).

2. **TrueTime uncertainty spike under clock-infrastructure failure.** GPS receiver fails or atomic clock drifts; epsilon grows from 4ms to 100ms; commit-wait inflates 25× → throughput collapses; queues back up. Production answer: Spanner monitors epsilon as an SLI; if epsilon exceeds threshold, alert + shed write load; for Spanner customer deployments without GPS, fall back to a smaller geographic region with tighter clocks; for non-Spanner deployments, use HLC + read-refresh which doesn't depend on clock infrastructure.

3. **Stuck 2PC on coordinator failure (in non-replicated coordinator 2PC).** Classic 2PC bug: coordinator crashes between PREPARE and COMMIT/ABORT; participants hold locks indefinitely; recovery requires manual intervention. Production answer: replicate the coordinator over Paxos (Spanner, CockroachDB, FoundationDB) so coordinator failover takes a few seconds rather than blocking indefinitely. Anti-pattern: classical 2PC without coordinator replication is unsuitable for any production system at L6+ scale.

## Notes for the coach
- **This is the deepest infrastructure problem in the catalog.** Plausibly-asked at Google (Spanner is the primary substrate), Snowflake (FoundationDB-based metadata layer), Apple (FoundationDB), CockroachDB / YugaByte. Less common at AI labs directly but a perfect cross-cutting question because it touches consensus, MVCC, time, and replication.
- **The 2PC-over-Paxos insight is the L6+ unlock.** A candidate who proposes classical 2PC without the coordinator-replication fix is missing the modern architecture; the Staff+ candidate names it explicitly with the Spanner source.
- **The TrueTime epsilon (1-7ms, ~4ms typical) is the concrete scale anchor.** Citing it grounds the commit-wait cost quantitatively.
- **The TrueTime-vs-HLC-vs-Calvin three-way comparison is the L7 differentiation flex.** Most candidates know about TrueTime via Spanner; the Sr Staff candidate articulates the HLC + read-refresh alternative (CockroachDB's choice without atomic clocks) and the Calvin deterministic-order alternative (no 2PC at all).
- **CockroachDB's Parallel Commits halving commit latency is the modern optimization signal.** Worth citing for current-frontier literacy.
- **Don't allow drift into "design SQL query planning" — stay on the transaction-coordinator primitive.** SQL parsing, query optimization, etc. are separate problems; this question is specifically about cross-shard ACID semantics + the consensus/time substrate.
- **No direct AI-infra counterpart** — transaction coordinators are generic infra; the closest AI-infra analog is the consistency model in `prompt-cache-infrastructure` (version-aware cache invalidation) but the substrate is different.
- **Cross-coverage:** sits above `zookeeper` (consensus substrate), uses `s3` for WAL archive in some systems, related to `dynamodb` (which moved from leaderless Dynamo to leader-based Multi-Paxos per partition — same consensus substrate idea but no cross-partition transactions).

# Consistency / Coordination

Pattern reference for `/study-patterns 3G`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3G.

## Quorum Reads/Writes (R + W > N)

**Definition.** In a system with N replicas, requiring R read acknowledgments and W write acknowledgments such that R + W > N guarantees at least one node in a read quorum has the latest write.

**Canonical use.** Set R=2, W=2, N=3 in Cassandra to get strong consistency on a 3-replica ring at the cost of one node failure tolerance per quorum operation.

**Production systems.** Apache Cassandra (tunable consistency levels), Amazon DynamoDB (strongly consistent reads).

**Alternatives.** Eventual consistency with R=1, W=1 for maximum availability; leader-based replication where only the leader serves reads (simpler, single point of ordering).

## Vector Clocks / Version Vectors

**Definition.** A vector clock assigns a per-node logical counter to each event, enabling partial ordering of events and detection of causality versus concurrent updates across a distributed system.

**Canonical use.** Amazon Dynamo uses version vectors to detect conflicting writes (concurrent updates to the same key) and surface them to the client or resolver rather than silently discarding one.

**Production systems.** Amazon DynamoDB (internally), Riak.

**Alternatives.** Lamport timestamps (total ordering but cannot detect concurrency); last-write-wins with wall-clock timestamps (simple but loses concurrent writes silently).

## Hinted Handoff, Read Repair, Anti-Entropy / Merkle Trees

**Definition.** Hinted handoff temporarily stores writes for an unavailable replica on another node; read repair corrects stale replicas on the read path; anti-entropy uses Merkle tree comparison to identify and sync diverged data ranges between replicas in the background.

**Canonical use.** Cassandra uses all three in combination so that temporary node outages do not cause permanent data loss: hints replay when the node recovers, reads repair on access, and nodetool repair runs Merkle-tree anti-entropy for long-term divergence.

**Production systems.** Apache Cassandra, Amazon DynamoDB (anti-entropy with Merkle trees).

**Alternatives.** Synchronous replication (no divergence, but higher write latency and availability cost); full-copy comparison for anti-entropy (correct but O(data) bandwidth vs O(log data) for Merkle).

## Consensus Protocols: Paxos, Raft, ZAB

**Definition.** Consensus protocols allow a cluster of nodes to agree on a single value (or log entry) despite node failures, with Paxos being the theoretical foundation, Raft being the understandable engineering variant (leader-based, sequential log), and ZAB (ZooKeeper Atomic Broadcast) being a Paxos variant optimized for primary-backup replication.

**Canonical use.** etcd uses Raft to provide a strongly consistent key-value store that Kubernetes uses for all cluster state; a Raft leader serializes log entries and replicates to a majority before committing.

**Production systems.** etcd / Consul (Raft), CockroachDB (Raft per range), ZooKeeper (ZAB).

**Alternatives.** Multi-Paxos (more flexible, harder to implement correctly); Viewstamped Replication (academically equivalent to Raft).

## Leader Election and Fencing Tokens

**Definition.** Leader election designates one node as the authoritative coordinator for a resource; fencing tokens are monotonically increasing integers issued with each lease so that a deposed leader's stale writes are rejected by storage if a new leader has already claimed a higher token.

**Canonical use.** A distributed job scheduler elects a leader via ZooKeeper ephemeral node; each lease grants a fencing token, and the job store rejects writes with token < current, preventing a slow old leader from corrupting state after network partition recovery.

**Production systems.** Apache ZooKeeper ephemeral nodes, etcd leader election, AWS DynamoDB conditional writes (as fencing).

**Alternatives.** Consensus-based lease (Raft), which embeds leader election; application-level heartbeat with timeout (simpler, weaker fencing guarantees).

## Distributed Locking (Redlock, ZooKeeper, Chubby)

**Definition.** Distributed locking coordinates exclusive access to a shared resource across processes or machines; Redis Redlock acquires a majority of N independent Redis nodes within a timeout, ZooKeeper uses ephemeral sequential znodes for fair locking, and Chubby (Google) provides advisory locks backed by Paxos consensus.

**Canonical use.** A cron-job scheduler uses ZooKeeper locking to ensure exactly one worker node executes a given scheduled task even when multiple nodes start simultaneously.

**Production systems.** Redis Redlock (with caveats around clock skew), Apache ZooKeeper, Google Chubby (internal).

**Alternatives.** Database row-level locks (simpler, not distributed); Raft-backed etcd locks (stronger correctness than Redlock, lower throughput than Redis).

## Lease, Write-Ahead Log, Segmented Log, High-Water Mark, Generation Clocks

**Definition.** A lease is a time-bounded lock; a write-ahead log (WAL) records mutations before applying them for crash recovery; a segmented log splits the WAL into fixed-size files for efficient compaction and truncation; a high-water mark is the highest log index safely replicated to a quorum; a generation clock (epoch) is a monotonically increasing integer bumped on leader change to invalidate stale actors.

**Canonical use.** Kafka brokers use a segmented log for the partition commit log, track the high-water mark as the last offset safe to expose to consumers, and increment the leader epoch (generation clock) on leader failover to reject stale producer requests.

**Production systems.** Apache Kafka (all five), etcd WAL + generation term.

**Alternatives.** Shadow paging instead of WAL (used by SQLite in WAL-off mode); in-memory state with snapshots (simpler, loses durability on crash).

## Operational Transform (OT) vs CRDTs

**Definition.** Operational Transform (OT) achieves convergence in collaborative editing by transforming concurrent operations against each other through a central server; CRDTs (Conflict-free Replicated Data Types) use mathematically designed state (state-based) or operation (op-based) structures that always merge deterministically without coordination.

**Canonical use.** Google Docs uses OT with a central server to serialize and transform concurrent character insertions; Figma migrated toward CRDT-like structures so offline edits merge automatically on reconnect without a transformation server.

**Production systems.** Google Docs (OT), Yjs and Automerge (CRDTs used in Liveblocks, Zed editor, Notion offline).

**Alternatives.** Last-write-wins registers (simple but lossy for concurrent edits); pessimistic locking (correct but blocks concurrent collaboration).

## Optimistic vs Pessimistic Concurrency Control

**Definition.** Optimistic concurrency control (OCC) allows concurrent reads and writes, then validates at commit time that no conflicting write occurred (aborting if so); pessimistic concurrency control acquires row-level locks upfront, serializing access but blocking concurrent readers/writers.

**Canonical use.** An e-commerce checkout uses OCC via ETags: the client reads inventory, submits a purchase with the read version, and the server rejects (409 Conflict) if another order already decremented stock.

**Production systems.** PostgreSQL MVCC (optimistic reads, row locks for writes), MySQL InnoDB (pessimistic row-level locks by default), DynamoDB conditional writes (OCC).

**Alternatives.** Serializable Snapshot Isolation (SSI) as a middle ground that detects conflicts automatically; two-phase locking (2PL) for strict serializability with higher contention.

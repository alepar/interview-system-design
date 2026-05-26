# Consensus

Source: `staff-engineer-study-guide.md`.

## Paxos (Basic / Single-Decree)

**Definition.** Lamport's original protocol for getting a cluster of nodes to agree on a single value despite crash failures; three roles (proposer, acceptor, learner) execute a two-phase prepare-accept round where a proposer first wins a quorum of promises for a ballot number, then proposes a value that acceptors must accept if they haven't already promised a higher ballot.

**Canonical use.** Agreeing on a single decision (e.g., "which replica is the new leader" or "what is the next log index's value") with safety under arbitrary message loss/reordering and (eventual) liveness once the network stabilizes.

**Production systems.** Google Chubby (Multi-Paxos with single-decree as the building block per OSDI 2006), legacy DynamoDB partition-leader election.

**Alternatives.** Raft (leader-based, designed for understandability); Viewstamped Replication (academically equivalent).

## Multi-Paxos / Leader-Based Optimization

**Definition.** A stable leader (distinguished proposer) skips Phase 1 (prepare) for subsequent values after one successful prepare round, collapsing each new decision to a single round-trip; this is the practical foundation for replicated state machines.

**Canonical use.** Replicating a sequence of log entries — once a leader is established for a given ballot, each subsequent log entry needs only an accept round, giving steady-state commit latency of one quorum RTT.

**Production systems.** Google Chubby (5-replica cells, 90K-100K clients/cell), Google Spanner (Paxos group per shard with 10-second leader leases).

**Alternatives.** Raft (similar throughput, more prescriptive log model); Zab (similar leader-based structure tailored to ZooKeeper's primary-backup style).

## Raft

**Definition.** A leader-based consensus protocol decomposed into three subproblems — leader election, log replication, and safety — designed explicitly for understandability versus Paxos; the new leader must hold the longest committed log (Log Matching + Leader Completeness), and 150-300ms randomized election timeouts prevent election livelock.

**Canonical use.** Replicating a strongly-consistent KV log across 3 or 5 nodes where every write goes through the leader and is replicated to a majority before commit; linearizable reads served via `ReadIndex` (leader confirms still-leader via heartbeat, then serves locally).

**Production systems.** etcd (Kubernetes control-plane state store; ~50 watches/cluster via apiserver fan-out), CockroachDB (Raft per range), TiKV, HashiCorp Consul (Raft for KV/ACL state, Serf gossip for membership).

**Alternatives.** Multi-Paxos (equivalent expressiveness, harder to implement correctly); Zab (similar guarantees, ZooKeeper-specific recovery phase).

## Zab (ZooKeeper Atomic Broadcast)

**Definition.** A leader-based total-order broadcast protocol used by ZooKeeper; epoch-numbered (a generation clock bumps on every leader change), strict FIFO from leader to followers, with an explicit recovery phase that synchronizes followers' logs to the new leader before serving writes.

**Canonical use.** Replicating ZooKeeper's znode tree across a 3-or-5-replica ensemble where all writes serialize through the leader and reads can be served eventually-consistent from followers.

**Production systems.** Apache ZooKeeper (Hunt et al., USENIX ATC 2010), historically the substrate beneath Kafka pre-KRaft.

**Alternatives.** Raft (closer to Zab than to Multi-Paxos; Kafka KRaft replaced Zab-on-ZooKeeper with internal Raft in Kafka 4.0+); Multi-Paxos (more flexible, allows any node to lead and recover later).

## Viewstamped Replication

**Definition.** Oki & Liskov's replication protocol (1988) that predates both Paxos and Raft; uses explicit views (a view = a configuration with a designated primary), view changes when the primary is suspected, and prepare/commit phases functionally equivalent to Multi-Paxos.

**Canonical use.** Academic reference point — historically used in pedagogical treatments to motivate the leader-based consensus design, and to demonstrate that Raft, Multi-Paxos, and VR are isomorphic up to terminology.

**Production systems.** Rare in production by name; influenced Harp file system and modern Raft implementations.

**Alternatives.** Raft (modernized presentation with the same operational shape); Multi-Paxos (more general, allows non-primary nodes to drive recovery).

## Leader Election

**Definition.** Selecting one node as the authoritative coordinator for a resource via a deterministic protocol — Bully algorithm (highest-ID node wins via comparison messages), lease-based leadership (one node holds a TTL-bounded lease and renews it), or consensus-embedded election (Raft / Multi-Paxos bake election into the protocol); failure detection (heartbeat timeout or phi-accrual) determines when a new election fires.

**Canonical use.** A distributed job scheduler elects a leader via ZooKeeper ephemeral-sequential znodes (smallest sequence number wins; others watch the next-lower znode to avoid herd effect on release); the elected leader holds a lease and renews via KeepAlives.

**Production systems.** Apache ZooKeeper (ephemeral-sequential znode recipe), etcd (built-in leader election API backed by Raft), Google Chubby (Paxos-backed leader election with 30s worst-case master election).

**Alternatives.** Bully algorithm (simple but assumes synchronous reliable links — rarely used in production); application-level heartbeat with timeout (simpler than consensus, weaker guarantees against split-brain).

## Quorum Sizing and Split-Brain

**Definition.** Strongly-consistent consensus requires a majority quorum (N/2+1) for both writes and reads — under a network partition, at most one side has the majority and can make progress, so split-brain is structurally impossible; 2f+1 nodes tolerate f failures (3-node cluster survives 1 failure, 5-node survives 2).

**Canonical use.** Choosing 3-node or 5-node Raft/Zab/Paxos clusters; 3 is the minimum for fault tolerance, 5 absorbs one failure during a maintenance window without losing quorum.

**Production systems.** etcd (3 or 5 nodes), ZooKeeper (3 or 5 replicas, Chubby standard is 5), Amazon Aurora (6/3 quorum: 6 copies across 3 AZs, Vw=4 / Vr=3 — non-consensus quorum tolerating AZ+1 failure).

**Alternatives.** Flexible quorums (Howard et al. — read and write quorums can be different sizes as long as they intersect); witness/arbiter nodes (a lightweight third node to break ties in a 2-replica setup, common in MongoDB).

## Common Failure Modes

**Definition.** Consensus protocols are robust to crash-stop failures but exhibit characteristic operational pathologies — slow leader (heartbeats arrive but commit throughput collapses), asymmetric network partitions (leader can send heartbeats but can't receive votes), clock-skew effects on leases (a node believes its lease is valid past actual expiry, enabling split-brain writes), and Byzantine failures (a node lies about its log state — out of scope for Paxos/Raft/Zab which assume crash-stop).

**Canonical use.** Tuning election timeout vs heartbeat interval (larger = more tolerant to network blips but slower failover); enabling Raft pre-vote so partitioned nodes don't trigger spurious term increments on rejoin; pairing leases with monotonic fencing tokens (znode sequence, etcd modRevision) so a GC-paused leader's stale writes are rejected resource-side per Kleppmann's Redlock critique.

**Production systems.** etcd (pre-vote extension to Raft to prevent election storms; documented Kubernetes-at-10K-nodes Raft log pressure that drove the Lease API), Apache ZooKeeper (1-minute lock-delay after ungraceful holder failure for partial fencing when the resource can't validate tokens), Google Chubby (45s client jeopardy state to absorb brief network blips before declaring session dead).

**Alternatives.** PBFT / HotStuff (Byzantine fault-tolerant consensus — used in permissioned blockchains; 3f+1 nodes tolerate f Byzantine failures with substantially higher message complexity); deterministic ordering via a Calvin-style sequencer (replicate the global transaction order rather than per-decision agreement).

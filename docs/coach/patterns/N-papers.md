# Key Distributed-Systems Papers

Pattern reference for `/study-patterns 3N`. Each entry is a paper (or book). Field mapping: Definition = 1-sentence summary of what it introduced (year + author); Canonical use = when to invoke/cite in an interview; Production systems = systems implementing or descended from the paper's ideas; Alternatives = related papers / competing approaches.

Source: `staff-engineer-study-guide.md` §3N.

## Google File System (GFS)

**Definition.** Ghemawat, Gobioff, and Leung (2003) introduced a distributed file system optimized for large sequential reads and record appends on commodity hardware, using a single master for metadata and chunkservers for 64 MB data chunks.

**Canonical use.** Cite GFS when discussing how to store massive write-once / append-only data cheaply, and to explain why relaxed consistency (atomic record append, not POSIX) is acceptable for batch workloads.

**Production systems.** GFS itself (Google internal), HDFS (Hadoop Distributed File System — open-source GFS descendant powering most Hadoop ecosystems).

**Alternatives.** Colossus (GFS successor at Google, distributed master); Ceph (open-source, no single master, stronger POSIX consistency).

## MapReduce

**Definition.** Dean and Ghemawat (2004) introduced a programming model and runtime for parallel data processing across thousands of commodity nodes using Map (key-value transformation) and Reduce (aggregation) phases with automatic fault tolerance via task re-execution.

**Canonical use.** Cite MapReduce to explain how to build fault-tolerant batch analytics on commodity clusters, and to motivate why modern frameworks like Spark replaced it (in-memory shuffle, DAG execution).

**Production systems.** Hadoop MapReduce (open-source implementation), Google internal MR pipelines (still running at massive scale).

**Alternatives.** Apache Spark (in-memory DAG, supersedes MR for iterative jobs); Apache Flink (stream-first, unified batch/stream model).

## BigTable

**Definition.** Chang et al. (2006) introduced a distributed, sorted, multi-dimensional sparse map (row key × column family × timestamp → value) built on GFS and Chubby, providing a wide-column store suitable for web indexing at Google scale.

**Canonical use.** Cite BigTable when designing a wide-column NoSQL store that needs fast point lookups and range scans on a sorted row key, especially for time-series or sparse-attribute workloads.

**Production systems.** Google Cloud Bigtable (managed service), Apache HBase (open-source BigTable on HDFS), Apache Cassandra (shares wide-column model but uses ring-based distribution instead of tablet servers).

**Alternatives.** DynamoDB (key-value, not wide-column, but similar operational model); RocksDB (embedded LSM store, building block for many wide-column systems).

## Chubby

**Definition.** Burrows (2006) introduced a coarse-grained distributed lock service built on Paxos-replicated state, providing a reliable namespace of small files used for leader election, service discovery, and configuration storage inside Google.

**Canonical use.** Cite Chubby when explaining the need for a strongly consistent coordination primitive (lock / lease / barrier) in a distributed system, and to motivate why you'd use ZooKeeper or etcd rather than building your own.

**Production systems.** Google Chubby (internal), Apache ZooKeeper (open-source Chubby-inspired coordination service), etcd (simpler Raft-based alternative, backbone of Kubernetes).

**Alternatives.** etcd (Raft instead of Paxos, simpler codebase); Consul (adds service discovery and health checking on top of a Raft store).

## Spanner

**Definition.** Corbett et al. (2012) introduced a globally distributed, externally consistent relational database using TrueTime (GPS + atomic clock bounded uncertainty) to assign commit timestamps, enabling serializable transactions across planetary-scale shards.

**Canonical use.** Cite Spanner when arguing for strong consistency at planet scale, or when a design requires cross-shard transactions with globally consistent snapshots — and to justify why TrueTime makes this feasible without a global lock.

**Production systems.** Google Cloud Spanner (managed service), CockroachDB (open-source Spanner-inspired, uses HLC instead of TrueTime).

**Alternatives.** Vitess (MySQL sharding, no global transactions); YugabyteDB (Spanner-inspired, Raft per tablet group).

## Amazon Dynamo

**Definition.** DeCandia et al. (2007) introduced a highly available key-value store using consistent hashing, vector clocks for conflict detection, sloppy quorums, and anti-entropy via Merkle trees, explicitly choosing availability and partition tolerance over strong consistency.

**Canonical use.** Cite Dynamo when explaining eventual consistency, sloppy quorums, or hinted handoff — especially for shopping carts or session stores where availability trumps immediate consistency.

**Production systems.** Amazon DynamoDB (derived service, dropped vector clocks, added GSIs), Apache Cassandra (adopted consistent hashing + tunable consistency from Dynamo).

**Alternatives.** Spanner (opposite trade-off: strong consistency, lower availability under partition); Riak (close open-source Dynamo implementation with vector clocks).

## Kafka

**Definition.** Kreps, Narkhede, and Rao (2011) introduced a distributed commit log optimized for high-throughput, durable, replicated event streaming, where consumers pull from ordered, partitioned, immutable log segments retained for configurable durations.

**Canonical use.** Cite Kafka when designing event-driven architectures, change-data capture pipelines, or any system where multiple consumers need independent replay of the same event stream at different offsets.

**Production systems.** Apache Kafka (open-source, runs at LinkedIn, Uber, Netflix), Confluent Platform (managed Kafka + Schema Registry), AWS MSK.

**Alternatives.** AWS Kinesis (managed, simpler ops, 7-day retention limit); Apache Pulsar (adds multi-tenancy and geo-replication natively); RabbitMQ (queue semantics, not a log — messages deleted after consumption).

## ZooKeeper

**Definition.** Hunt et al. (2010) introduced a coordination service providing a hierarchical namespace of znodes with watches (change notifications), linearizable writes, and FIFO client ordering, built on Zab (ZooKeeper Atomic Broadcast) consensus.

**Canonical use.** Cite ZooKeeper when explaining how distributed systems implement leader election, distributed locks, or configuration management without rolling a custom Paxos implementation.

**Production systems.** Apache Kafka (uses ZooKeeper for controller election, migrating to KRaft), Apache HBase (master election and region server coordination), Hadoop YARN.

**Alternatives.** etcd (simpler Raft-based, preferred for new systems); Consul (adds service mesh features); Chubby (Google's internal predecessor).

## Paxos

**Definition.** Lamport (1998, "The Part-Time Parliament"; simplified 2001 as "Paxos Made Simple") introduced the foundational consensus algorithm for reaching agreement on a single value among distributed nodes despite failures, using a two-phase prepare/accept protocol.

**Canonical use.** Cite Paxos as the theoretical basis for any distributed consensus discussion — mention it by name when asked how leader election or replicated state machines work, then note that Raft is the modern implementation-friendly equivalent.

**Production systems.** Google Chubby (Paxos-based), Google Spanner (Paxos per shard), Apache Zookeeper's Zab (Paxos variant).

**Alternatives.** Raft (same safety, more understandable, preferred for new implementations); Multi-Paxos (optimized for log replication, Paxos variant); Viewstamped Replication (concurrent independent derivation).

## Raft

**Definition.** Ongaro and Ousterhout (2014, "In Search of an Understandable Consensus Algorithm") introduced a consensus algorithm designed for comprehensibility, decomposing consensus into leader election, log replication, and safety, with strong leader semantics that simplify reasoning.

**Canonical use.** Cite Raft as the consensus algorithm of choice for new replicated state machines — it is what etcd, CockroachDB, and TiKV use — and explain leader election and log replication when asked how a distributed database achieves fault tolerance.

**Production systems.** etcd (Kubernetes control plane), CockroachDB (per-range Raft groups), TiKV (per-region Raft, backing TiDB).

**Alternatives.** Paxos (equivalent safety, harder to implement correctly); Multi-Paxos / EPaxos (better throughput under geo-distributed leaderless scenarios).

## The LSM-Tree

**Definition.** O'Neil et al. (1996) introduced the Log-Structured Merge-Tree, a write-optimized data structure that buffers writes in a sorted in-memory structure (memtable), flushes to immutable sorted files (SSTables), and periodically compacts them — trading read amplification for dramatically higher write throughput than B-trees.

**Canonical use.** Cite LSM-tree whenever explaining why write-heavy NoSQL databases (Cassandra, RocksDB) outperform B-tree databases on ingestion workloads, and to explain compaction, read amplification, and bloom filters as implementation details.

**Production systems.** RocksDB (Facebook's LSM engine, embedded in CockroachDB/TiKV/MyRocks), Apache Cassandra (SSTables + compaction strategies), LevelDB (Google's simpler LSM, basis for RocksDB).

**Alternatives.** B-tree (read-optimized, lower read amplification, used in PostgreSQL/MySQL/InnoDB); Fractal Tree (write-optimized B-tree variant, used in TokuDB/MariaDB).

## Designing Data-Intensive Applications (Kleppmann)

**Definition.** Kleppmann (2017) wrote the canonical book synthesizing distributed systems fundamentals — replication, partitioning, transactions, consensus, stream processing — into a practitioner-accessible reference grounded in real system internals.

**Canonical use.** Reference DDIA as the definitive study resource when asked about the theoretical underpinning of any topic in this guide; in interviews, dropping "as Kleppmann explains in DDIA" signals serious preparation.

**Production systems.** Not a system — a book; its examples cover Kafka, Spanner, Cassandra, ZooKeeper, and many others throughout.

**Alternatives.** Alex Xu *System Design Interview* Vols. 1–2 (interview-focused, breadth over depth); Chip Huyen *Designing Machine Learning Systems* (ML system design equivalent); Martin Fowler *Patterns of Enterprise Application Architecture* (older, application-level patterns).

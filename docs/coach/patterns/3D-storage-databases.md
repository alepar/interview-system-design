# Storage and Databases

Pattern reference for `/study-patterns 3D`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3D.

## SQL — B-Tree Storage Engines

**Definition.** Relational databases store data in B-tree indexed pages, supporting ACID transactions and rich SQL queries; they are the correct default unless a specific scale or schema requirement justifies otherwise.

**Canonical use.** Use PostgreSQL or MySQL InnoDB for transactional workloads (payments, reservations, user accounts) where referential integrity, joins, and strong consistency are required.

**Production systems.** PostgreSQL, MySQL InnoDB.

**Alternatives.** SQLite for embedded/single-node; CockroachDB or Spanner for globally distributed SQL with consensus-based consistency.

## NoSQL — Key-Value Stores

**Definition.** Key-value stores provide O(1) get/put by primary key with no schema, optimized for high-throughput lookups of simple values.

**Canonical use.** Use Redis for session storage, leaderboards (sorted sets), and distributed locks; use DynamoDB for serverless, auto-scaling key-value with single-digit-millisecond latency at any scale.

**Production systems.** Redis, Amazon DynamoDB.

**Alternatives.** Memcached (pure cache, simpler than Redis); Riak (Dynamo-style leaderless for high availability).

## NoSQL — Document Stores

**Definition.** Document databases store semi-structured JSON/BSON documents, allowing flexible schemas and nested objects without joins.

**Canonical use.** Use MongoDB for product catalogs, user profiles, or content repositories where each document has a different shape and the access pattern is primarily by document ID or a small set of indexes.

**Production systems.** MongoDB.

**Alternatives.** PostgreSQL JSONB (documents + full SQL); Couchbase (document store with built-in cache layer).

## NoSQL — Wide-Column LSM-Tree Stores

**Definition.** Wide-column stores organize data by row key and column family, using LSM-trees for write-optimized ingestion; they scale horizontally to petabytes and are tuned for time-series and append-heavy workloads.

**Canonical use.** Use Cassandra or ScyllaDB for high write throughput at scale (e.g., chat message storage, IoT telemetry) where queries are always by a well-known partition key and eventual consistency is acceptable.

**Production systems.** Cassandra, ScyllaDB (Discord migrated from Cassandra's 177 nodes to 72 ScyllaDB nodes), Google BigTable, HBase.

**Alternatives.** DynamoDB (managed, similar access patterns); InfluxDB for pure time-series with downsampling built in.

## NoSQL — Graph Databases

**Definition.** Graph databases store entities as nodes and relationships as edges, enabling efficient traversal of many-hop relationships that would require expensive recursive joins in SQL.

**Canonical use.** Use Neo4j for friend-of-friend recommendations, fraud detection rings, or knowledge graphs where the query pattern is "find all paths between nodes within N hops."

**Production systems.** Neo4j.

**Alternatives.** PostgreSQL with recursive CTEs for small graphs; Amazon Neptune (managed graph); representing graphs in a KV store with adjacency-list encoding for extreme scale.

## Specialized Stores — Time-Series, Search, Vector, Columnar, Geospatial

**Definition.** Purpose-built stores optimize for a narrow access pattern: time-series (InfluxDB, Prometheus TSDB, TimescaleDB) for append-and-downsample; search (Elasticsearch/OpenSearch) for full-text inverted indexes; vector (Pinecone, Weaviate, pgvector, Milvus) for ANN similarity; columnar OLAP (ClickHouse, Snowflake, Redshift) for analytical aggregations; geospatial (PostGIS, Redis Geo) for proximity queries.

**Canonical use.** Use Elasticsearch for full-text product search with faceting; use ClickHouse for real-time analytics over billions of rows where query latency must stay under seconds.

**Production systems.** Elasticsearch/OpenSearch, ClickHouse, Pinecone, InfluxDB, PostGIS.

**Alternatives.** PostgreSQL covers time-series, search (tsvector), and geospatial (PostGIS) at moderate scale before specialized stores are warranted.

## ACID vs BASE and Isolation Levels

**Definition.** ACID (Atomicity, Consistency, Isolation, Durability) guarantees transactional correctness; BASE (Basically Available, Soft state, Eventually consistent) trades consistency for availability and partition tolerance; isolation levels (Read Committed, Repeatable Read, Snapshot, Serializable) control visibility of concurrent writes.

**Canonical use.** Use Serializable isolation for financial ledgers to prevent phantom reads; use Read Committed (PostgreSQL default) for most OLTP to balance correctness with concurrency.

**Production systems.** PostgreSQL (all four isolation levels), CockroachDB (Serializable by default).

**Alternatives.** Optimistic concurrency control (version numbers/ETags) as an application-level alternative to database-enforced Serializable; CRDT-based merging for eventual consistency without isolation overhead.

## Indexes

**Definition.** Indexes are auxiliary data structures that speed up reads at the cost of write overhead and storage: B-tree (range queries), hash (equality only), GiST/SP-GiST (geometric, full-text, ranges), GIN (inverted, for arrays and full-text), bitmap (low-cardinality columns), covering (stores extra columns to avoid heap fetch).

**Canonical use.** Add a covering index that includes all columns in a frequent query's SELECT and WHERE clause to eliminate the table heap access entirely and halve query latency.

**Production systems.** PostgreSQL (all index types), MySQL InnoDB (B-tree and covering).

**Alternatives.** Materialized views for precomputed aggregates instead of complex indexes; denormalized tables to avoid index joins altogether.

## Sharding Strategies

**Definition.** Sharding horizontally partitions data across multiple database nodes; strategies include range (partition by value range, e.g., user ID 0–1M on shard 1), hash (partition by hash of key for uniform distribution), geo (partition by region), and directory (a lookup table maps each key to its shard).

**Canonical use.** Use hash sharding for uniform write distribution across shards; use range sharding when you need to scan contiguous key ranges (e.g., time-series data by timestamp) and can tolerate hot shards during ingestion spikes.

**Production systems.** Vitess (hash sharding for MySQL, used at YouTube/Slack), DynamoDB (hash partitioning internally), Cassandra (consistent hash ring).

**Alternatives.** Consistent hashing to minimize resharding cost when the shard count changes; directory-based sharding for flexibility at the cost of an extra lookup hop.

## Replication

**Definition.** Replication copies data to multiple nodes for durability and read scale: leader-follower (one writer, many readers), multi-leader (multiple writers in different regions, conflict resolution needed), and leaderless/Dynamo-style (any node accepts writes; quorum R+W>N for consistency).

**Canonical use.** Use leader-follower replication with async followers for read replicas in a standard web app; use leaderless replication (Cassandra, DynamoDB) when write availability across regions is more important than strong consistency.

**Production systems.** PostgreSQL streaming replication (leader-follower), Cassandra (leaderless), DynamoDB (multi-leader across regions).

**Alternatives.** Consensus-based replication (Raft/Paxos via CockroachDB, Spanner) for strong consistency without a single leader bottleneck.

## Federation

**Definition.** Federation (also called functional partitioning) splits a monolithic database into separate databases by feature domain (e.g., users DB, products DB, orders DB), reducing write contention and enabling independent scaling.

**Canonical use.** Apply federation when a single database becomes a bottleneck because multiple high-write feature teams share it, and cross-feature joins are rare enough to be handled in application code.

**Production systems.** Early-stage Pinterest (split monolithic MySQL into federated per-feature DBs), many large-scale microservice architectures.

**Alternatives.** Schema-level namespacing within one DB (simpler, avoids cross-DB joins); sharding (scales one domain further after federation).

## Denormalization

**Definition.** Denormalization stores redundant or precomputed data alongside the primary record to eliminate joins at read time, trading write complexity and storage for read performance.

**Canonical use.** Denormalize a user's follower count into the user row so that displaying a profile page requires one row fetch instead of a COUNT aggregate over millions of follower records.

**Production systems.** Cassandra schemas (denormalize aggressively because JOINs are not supported), DynamoDB single-table design.

**Alternatives.** Materialized views (DB-maintained denormalization); CQRS read models (application-managed denormalized projections).

## Materialized Views and CQRS

**Definition.** A materialized view is a precomputed, stored query result refreshed on a schedule or trigger; CQRS (Command Query Responsibility Segregation) separates the write model (commands) from the read model (queries), allowing each to be optimized independently.

**Canonical use.** Use CQRS with an event-driven pipeline to maintain a read-optimized projection (e.g., a denormalized Cassandra table for a news feed) that is updated asynchronously from write-side events.

**Production systems.** PostgreSQL materialized views; Kafka + Cassandra/Elasticsearch for event-driven CQRS read models (used at LinkedIn, Netflix).

**Alternatives.** Database views (no storage benefit, computed at query time); Redis cache as a CQRS read model for sub-millisecond reads.

## Two-Phase Commit, Saga, and Outbox Pattern

**Definition.** 2PC coordinates a distributed transaction with a prepare and commit phase (blocking, single point of failure at coordinator); Saga breaks a transaction into local steps with compensating actions for rollback; the outbox pattern publishes events atomically with a DB write by writing to a local outbox table and relaying via CDC.

**Canonical use.** Use the Saga pattern with the outbox pattern for multi-service workflows (e.g., order placement spanning inventory, payment, and shipping services) to achieve eventual consistency without a distributed lock.

**Production systems.** Stripe (outbox + idempotency keys for payments), Uber (Saga for trip state machine), Amazon (Saga in order management).

**Alternatives.** 2PC for small, same-datacenter transactions where blocking is acceptable; TCC (Try-Confirm-Cancel) as a variant of Saga with explicit reservation semantics.

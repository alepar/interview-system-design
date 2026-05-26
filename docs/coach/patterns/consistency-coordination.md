# Consistency / Coordination

Source: `staff-engineer-study-guide.md`.

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

## Sequence CRDTs: RGA, Fugue, YATA

**Definition.** Sequence CRDTs assign each element (typically a character or run) a unique, totally-ordered position identifier so concurrent inserts/deletes converge deterministically without a central transformer. **RGA** (Replicated Growable Array) is the original linked-list-plus-tombstones design with `(timestamp, site)` ids; **Fugue** addresses RGA's "interleaving anomaly" where concurrent same-position inserts produce nonsensical character-by-character interleaving (Kleppmann et al., PaPoC 2019) by modeling positions as nodes in a tree to achieve maximal non-interleaving; **YATA** (Yjs's variant) is RGA-adjacent, using `origin`/`originRight` neighbor ids at insertion time with run coalescing to keep metadata O(runs) not O(chars). Tombstones persist for deletes so concurrent ops still resolve; GC is hard because causal stability is unprovable under offline editing.

**Canonical use.** A peer-to-peer collaborative text editor where users may go offline: Yjs (YATA) ships the document as a binary state-based update, integrates concurrent inserts via the YATA `integrate()` loop, and stores deletes as a compact delete-set (~4.5KB for 77k deletes) rather than per-character tombstones.

**Production systems.** Yjs (YATA, used by Liveblocks, Zed editor, Notion offline), Automerge (RGA-style), Eg-walker (frontier OT/CRDT hybrid with order-of-magnitude smaller steady-state memory).

**Alternatives.** OT (server-authoritative, simpler but bottlenecked at one server, O(n²) on long-branch merge); Logoot/LSEQ (dense fractional ids, but suffer the full interleaving anomaly — avoid for text).

## Set CRDTs: OR-Set, LWW-Element-Set, 2P-Set

**Definition.** Set CRDTs converge concurrent add/remove operations on a collection. **OR-Set (Observed-Remove)** tags each add with a unique id so a concurrent add-then-remove doesn't lose the add — remove only tombstones the tags it has observed, and a concurrent add carries a fresh unseen tag that survives ("add-wins"). **LWW-Element-Set** stamps each element with a timestamp and resolves by last-writer-wins, losing concurrent adds silently if the remove's timestamp wins. **2P-Set** maintains separate "add" and "remove" sets with removes permanent (tombstones grow forever, re-add impossible).

**Canonical use.** A Dynamo-style shopping cart where "add to cart" must never be rejected, even under partition: tagging each add `(item_id, (replica, counter))` and tombstoning only observed tags eliminates the classic deleted-item resurrection anomaly that plain set-union merge causes.

**Production systems.** Riak (OR-Set as a built-in CRDT type), Soundcloud / Amazon-style cart architectures, Notion's offline `content` collection (OR-Set semantics).

**Alternatives.** State-merge with a custom application resolution callback (Dynamo-style siblings); PN-Counter for quantity rather than membership; remove-wins OR-Set dual where deletes should beat concurrent adds.

## Fractional Indexing

**Definition.** For ordering items in a list (FigJam canvas objects, Notion blocks, Trello cards, Figma child order) without re-numbering neighbors on every insert. Each position is an arbitrary-precision fraction (often a base-95 ASCII string) in (0,1); inserting between two items picks a value strictly between their indices (averaging), so an insert touches only the new item. Supports unbounded insertion between any two positions but indices grow longer over time, eventually requiring rebalancing. Concurrent inserts at the same gap are disambiguated by a server-assigned fresh position (Figma) or by a stable tiebreak; runs interleave under concurrent insertion, which is fine for design objects but wrong for text.

**Canonical use.** Figma's `parent.children` z-order: each child stores a fractional `index`, an insert between two children averages their keys, and the server hands the second concurrent insert at the same spot a fresh unique position so peers converge.

**Production systems.** Figma / FigJam (fractional indices for child order and shape z-order), Notion (block ordering), Linear (issue ordering), Excalidraw (`syncInvalidIndices()` rebalance).

**Alternatives.** Integer indices with periodic re-numbering (cheaper for stable lists, O(n) on inserts); a sequence CRDT (RGA/Fugue) when run interleaving matters (text); a server-assigned monotonic sequence (simple but no concurrent inserts between positions).

## Movable Tree CRDTs

**Definition.** For collaborative tree editing (Notion block tree, Figma object hierarchy, file-system replicas) where nodes can be reparented concurrently. Naive per-field LWW on `parent` allows concurrent moves to create cycles (A→B while B→A) or duplicate subtrees. Kleppmann/Mukhutdinov's "highly-available move operation for replicated trees" totally orders move operations against a logical clock and, on each move, undoes any concurrent move that would create a cycle in causal order — guaranteeing a deterministic, cycle-free tree on all replicas.

**Canonical use.** Notion's offline block tree: two users move blocks into each other's subtrees while offline; on reconnect the movable-tree CRDT picks one move and re-homes the other rather than corrupting the tree.

**Production systems.** Notion (their own variant atop SQLite offline cache — algorithm not fully public), Apple Notes (CloudKit-based tree sync), academic implementations atop Automerge.

**Alternatives.** Server-coordinated moves with cycle rejection (Figma: server holds authoritative tree, rejects updates that would create a cycle — no offline support); pessimistic locking of the tree during move (correct, blocks concurrent collaboration); per-field LWW on `parent` (broken — produces cycles and duplicates).

## Awareness CRDT

**Definition.** A state-based CRDT for ephemeral collaboration state (cursor positions, presence, selections, viewports) that must not persist into the document. Each client publishes its own `{clock, state, lastUpdated}` and listens to all others; merge is trivial because each client's slot is partitioned by clientID (no cross-client conflict). State expires after a timeout (Yjs: 30s without refresh) and is rebroadcast on an interval (Yjs: ≥ every 15s) to handle missed updates.

**Canonical use.** Yjs awareness protocol: a client sets `awareness.setLocalStateField('cursor', {x,y})`, the y-websocket provider broadcasts the awareness blob on a separate channel from the document update, and remote peers see live cursors without anything touching the persisted document or its CRDT history.

**Production systems.** Yjs awareness (Liveblocks, Zed, Tiptap), Figma presence channel (cursors at ~33ms / 30 FPS, never journaled), Replicache poke channel for liveness.

**Alternatives.** Server-authoritative presence (server bottleneck, single point of failure); pub/sub with a custom merge function (re-invents awareness CRDT, usually worse); writing cursors into the main document (pollutes history, kills GC, journaling overhead).

## Optimistic vs Pessimistic Concurrency Control

**Definition.** Optimistic concurrency control (OCC) allows concurrent reads and writes, then validates at commit time that no conflicting write occurred (aborting if so); pessimistic concurrency control acquires row-level locks upfront, serializing access but blocking concurrent readers/writers.

**Canonical use.** An e-commerce checkout uses OCC via ETags: the client reads inventory, submits a purchase with the read version, and the server rejects (409 Conflict) if another order already decremented stock.

**Production systems.** PostgreSQL MVCC (optimistic reads, row locks for writes), MySQL InnoDB (pessimistic row-level locks by default), DynamoDB conditional writes (OCC).

**Alternatives.** Serializable Snapshot Isolation (SSI) as a middle ground that detects conflicts automatically; two-phase locking (2PL) for strict serializability with higher contention.

## HTTP Conditional Write: If-Match / If-Unmodified-Since -> 412

**Definition.** Record-level OCC over HTTP: a client GETs a resource and remembers its `ETag` (an opaque version identifier); subsequent writes carry `If-Match: <etag>` (or `If-Unmodified-Since: <date>`) so the server returns **412 Precondition Failed** if the resource has changed since the read. The client must then GET the latest version and retry (or surface a conflict to the user). This is the canonical sync-protocol consistency mechanism where storage is HTTP and per-record locking is impractical — WebDAV, CalDAV, CardDAV, and most modern REST APIs rely on it for lost-update prevention. Conflict granularity is **record-level**, not field-level; the protocol detects the conflict but the application chooses how to merge.

**Canonical use.** Calendar sync (CalDAV): two devices edit the same VEVENT offline from ETag v1; the first PUT with `If-Match: v1` succeeds and bumps to v2; the second PUT with `If-Match: v1` gets **412**, forcing a GET of v2 and a conflict resolution before retry — no silent clobber.

**Production systems.** CalDAV / CardDAV clients (Apple Calendar, Google Calendar Sync, Fastmail, Thunderbird), GitHub API conditional requests (`If-Match` / `If-None-Match` on issues and refs), S3 conditional writes, generic WebDAV servers.

**Alternatives.** Full pessimistic lock via a separate locking endpoint (WebDAV LOCK/UNLOCK — serializes editors, complex to expire); a custom version vector in the request body (more expressive but loses HTTP-cache and proxy interop); server-assigned monotonic order over a push channel (Replicache / Linear — better for high-frequency collaboration than ETag round-trips).

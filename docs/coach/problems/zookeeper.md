---
slug: zookeeper
archetype: infra-primitives
sources:
  zookeeper_paper: usenix.org/legacy/event/atc10/tech/full_papers/Hunt.pdf
  chubby_paper: research.google.com/archive/chubby-osdi06.pdf
  raft_paper: raft.github.io/raft.pdf
  kleppmann_redlock: martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
  zookeeper_recipes: zookeeper.apache.org/doc/r3.8.5/recipes.html
---

# Apache ZooKeeper / Google Chubby (distributed coordination service)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic Raft-or-Paxos-replicated KV store. Names sessions and ephemeral nodes at category level. Discusses leader election as a use case but may not articulate the watch-predecessor recipe. Doesn't address fencing tokens, lock-delay, or jeopardy semantics unprompted.
- **Senior (L5/E5):** Names ZooKeeper's Zab protocol (or Raft for etcd) for consensus; articulates the 3-or-5-replica deployment with 2f+1 fault tolerance. Discusses ephemeral znodes tied to client sessions and how their auto-deletion enables liveness detection. Knows about watch semantics at category level (one-shot watches in ZK). Identifies leader election via ephemeral-sequential znodes as the canonical recipe. May or may not surface the fencing-token-on-the-resource problem.
- **Staff+ (L6/E6+):** Drives proactively. Names the **lease + fencing-token + resource-side-validation triplet** as the canonical safe-distributed-locking pattern (per Kleppmann's published Redlock critique). Articulates the failure mode this triplet defends against: client acquires lock → GC-pauses for 60s → lease expires → another client acquires → original client wakes up still believing it holds the lock → both write → corruption. The fix requires (a) lease with auto-release TTL, (b) monotonic fencing token at acquisition (ZK's znode sequence number; etcd's modRevision; Chubby added "sequencers" later), (c) **resource-side validation** that rejects writes from holders with stale tokens. Quantifies Chubby scale: 5-replica cell, 90K-100K clients per cell, **93% of all RPCs are KeepAlives** (workload dominated by session liveness, not real lock ops); 256KB file size cap to discourage misuse as a data store; 30s worst-case master election; 45s client grace period in "jeopardy" state; 1-minute lock-delay after ungraceful holder failure. Names Chubby's checksums-and-rejoin pattern for disk-corruption safety. Articulates watch-protocol fork: ZK one-shot watches (re-arm required; may drop under load — defensive client design); etcd streaming MVCC watches (revision-indexed, resumable on disconnect, multiplexed via gRPC). Names ZK's herd-effect mitigation: leader election watches the next-lower-sequence znode only, not all znodes. Stretch (Sr Staff bar): articulates Multi-Paxos vs Raft vs Zab trade-offs (Raft requires new leader to have the longest committed log; Multi-Paxos allows any node and recovers later; Zab is leader-based strict FIFO).

## Canonical decomposition

### Requirements
**Functional:**
- Strongly-consistent small-data KV store with hierarchical namespace (znodes)
- Client sessions with heartbeat-based liveness; ephemeral znodes auto-deleted on session expiry
- Watch API: clients register interest in znode changes; broker notifies on change
- Atomic multi-znode transactions (compare-and-swap across multiple keys)
- Leader election + distributed lock as derived recipes on top of the primitives
- Fencing token (monotonic per-lock sequence number) issued at acquisition for safe handoff

**Non-functional (with numbers):**
- 5-replica cell (Chubby standard; ZK uses 3 or 5)
- 90K-100K clients per cell (Chubby published)
- 93% of RPCs are KeepAlives — workload dominated by session liveness
- 100K reads/sec/ensemble, 10K writes/sec/ensemble (typical ZK)
- 256 KB file size cap (Chubby) / 1 MB znode default (ZooKeeper) — discourages misuse as a data store
- 30 s worst-case master election; 45 s client grace period in jeopardy state
- 150-300 ms randomized election timeout (Raft / etcd standard)
- 2f+1 fault tolerance: 3-node cluster survives 1 failure, 5-node survives 2

### Core entities
- **Cell / Ensemble:** the set of 3 or 5 replicas running consensus
- **Replica:** holds a copy of the state machine; one is elected leader at any time
- **Session:** client → cell connection with TTL; identified by 64-bit session ID; heartbeated via KeepAlives
- **Znode (ZK) / file (Chubby):** the unit of state; hierarchical path; flags include EPHEMERAL (tied to session), SEQUENTIAL (monotonic suffix), PERSISTENT
- **Watch:** client-registered interest in znode changes; ZK one-shot (re-arm required), etcd streaming (revision-indexed)
- **Lease:** TTL-bound holder claim; auto-released on expiry; foundation for locks + leader election

### API
- `create(path, data, flags)` → znode/file created; SEQUENTIAL flag returns monotonic-suffixed name
- `getData(path, watch?)` → current value (+ register watch if requested)
- `setData(path, data, version)` → conditional update (compare-and-swap on version)
- `delete(path, version)` → conditional delete
- `getChildren(path, watch?)` → list children (+ watch on changes to children set)
- `multi([ops])` → atomic batch of compare-and-swap operations
- `exists(path, watch?)` → existence check + watch
- Session: client connects, gets session ID; sends KeepAlive every `session_timeout / 3`; on disconnect, has `session_timeout` to reconnect or session expires (ephemeral znodes deleted, watches fired)

### HLD
The coordination service runs **N replicas (3 or 5)** with **consensus** (Zab for ZooKeeper, Raft for etcd, Multi-Paxos for Chubby) for replicated state-machine semantics. One replica is elected leader; all writes go through the leader and replicate via the consensus protocol; reads can be served from the leader (linearizable) or from followers (eventually consistent — ZK's default; etcd uses `ReadIndex` for linearizable follower reads).

**Sessions** are client connections with TTLs. Each client connects to one replica, gets a session ID, and sends KeepAlives every `session_timeout/3`. If KeepAlives stop arriving, the session enters **jeopardy** state on the client (cache disabled, no new operations) while attempting to reconnect; after a grace period (~45s in Chubby), the session expires server-side and all **ephemeral znodes** (created with EPHEMERAL flag, tied to the session) are deleted, all **watches** owned by the session are fired with disconnect events.

**Ephemeral + sequential znodes** are the canonical primitives for leader election and distributed locks. Recipe: every candidate creates `ELECTION/lock-<seq>` with EPHEMERAL_SEQUENTIAL flags. The candidate with the smallest sequence number is the leader (or lock holder). Other candidates watch the next-lower-sequence znode (not the leader, which would cause a herd-effect storm on release). When the lock holder's session expires (graceful release or crash), its ephemeral znode is deleted; the next-in-line is notified; promotes itself.

The **fencing token** is the sequence number of the held znode — a monotonic per-lock identifier. When the lock holder writes to the protected resource (a DB, a file, a service API), it includes the fencing token. The resource validates: if it has seen a higher token previously, reject the write (the writer is stale, has lost the lock). This prevents the classic split-brain scenario: holder A acquires → GC-pauses 60s → lease expires → holder B acquires → B writes (token=42) → resource records 42 → A wakes up still believing it holds → A writes (token=41) → resource rejects (41 < 42 already seen).

The **consensus protocol choice** (Raft vs Multi-Paxos vs Zab) has subtle operational implications. Raft (150-300ms randomized election timeout) requires the new leader to have the longest committed log; lagging followers can't lead. Multi-Paxos allows any node to lead and recovers missing log entries during steady state; more flexible but harder to reason about. Zab (ZooKeeper) is leader-based strict FIFO with an explicit recovery phase; closer to Raft than to Multi-Paxos.

### Deep dives
1. **The lease + fencing-token + resource-side-validation triplet (Kleppmann's canonical safe-locking pattern).** Naive distributed lock: acquire → do work → release. Three failure modes: (a) client crashes mid-work → lock held forever — fix with **lease** (TTL-bound, auto-released); (b) network partition splits the cluster, both sides think they hold the lock → fix with **consensus** (only the leader can issue leases); (c) client GC-pauses past lease expiry → wakes up, doesn't know it's lost the lock, writes to the resource — **fencing token** required. The fencing token must be (i) monotonically increasing per-lock (ZK sequence number, etcd modRevision, Chubby sequencer), (ii) passed to the protected resource on every write, (iii) **validated by the resource** which rejects writes with stale tokens. Without #iii, the token is useless — it just travels with the write but doesn't prevent corruption. This is Kleppmann's published critique of Redlock: Redlock has no facility for generating monotonic fencing tokens, so even if it correctly handles network partitions, it can't defend against GC-pause-induced split brain. Staff+ commit: name the triplet explicitly, articulate the GC-pause failure mode, address what happens when the resource doesn't natively support token validation (rare modern systems lack it; for those, use lock-delay as partial mitigation).

2. **KeepAlive workload dominance and the operational reality.** Chubby's published data: 93% of all RPCs are KeepAlives. This is the operational reality of any session-based coordination service — the actual lock/file ops are dwarfed by liveness traffic. Implications for design: (a) KeepAlive path must be the optimized hot path; proxy-batched KeepAlives at the client library level (one proxy holds 10K client sessions, sends one aggregate KeepAlive to the cell); (b) jeopardy state UX — when local lease expires, client doesn't immediately declare session dead; enters jeopardy (disable cache, suspend new operations, wait grace period ~45s for re-handshake) — this prevents flapping under brief network blips; (c) longer KeepAlive intervals when the cluster is healthy (client backs off); (d) session timeout selection — too short causes false expirations during brief blips; too long means slow detection of real failures. Production target: session_timeout ≥ 2× max-observed network-blip-duration. Staff+ commit: KeepAlive batching strategy, jeopardy state semantics, what happens to in-flight operations during jeopardy (suspend? fail? retry on reconnect?).

3. **Watch API design: one-shot vs streaming-revision.** ZooKeeper's watches are **one-shot** — fire once, client must re-arm; this prevents unbounded watch backlog on the server but requires defensive client code (after firing, the watcher must immediately re-read state + re-register, accepting that brief changes between fire-and-re-arm may be missed). etcd's watches are **streaming gRPC, revision-indexed** — a single stream multiplexes many key ranges per client (Kubernetes informers depend on this for efficiency); revision-indexed means a client reconnecting after disconnect can replay events from its last-seen revision without missing changes (until the revision is garbage-collected by compaction). Trade-off: ZK's one-shot is simpler server-side, harder client-side; etcd's streaming is more efficient for many-keys-per-client but requires history retention until compaction. For coordination patterns where missed events are a correctness issue (leader election, membership), etcd's streaming model is strictly better. For simple "tell me when this changes" with idempotent re-read, ZK's one-shot is sufficient. Staff+ commit: pick watch model with criteria; address what happens during leader change (do watches survive? get fired with a "disconnected" event? require re-registration?); replay-from-revision protocol if applicable.

## Known failure modes
1. **Split-brain via GC pause + missing fencing.** Client acquires lock, GC-pauses for 60s, wakes up believing it still holds the lock; meanwhile, the coordinator has given the lock to another client. Without fencing token validation at the resource, both write → corruption. Production answer: the lease + fencing-token + resource-side-validation triplet is mandatory; for resources that can't validate, use **lock-delay** (Chubby's 1-minute grace period after ungraceful release — the coordinator refuses to issue a new lock for that duration, hoping the prior holder's in-flight writes are quiesced). Anti-pattern: rely on lease TTL alone; client clocks aren't trustworthy under GC.

2. **Cascading session expiry on cluster leader change.** Master election causes brief unavailability; all clients re-handshake simultaneously when the new master is up → KeepAlive storm. Production answer: jittered client backoff on reconnect; jeopardy state (clients don't immediately declare session dead on first KeepAlive failure); proxy layer (client library) that absorbs the storm by batching KeepAlives. Chubby's published 30s worst-case master election is the design budget.

3. **Disk corruption violates Paxos persistence (Chubby's published issue).** A replica's disk silently corrupts; replica may renege on commitments made before the corruption — violates Paxos safety. Production answer (Chubby's published pattern): per-block checksums on disk content; on detected corruption, force a cold-restart and rejoin from peers (don't try to recover the corrupted state); a "marker" left in GFS at startup so the replica can detect "I am a fresh start, not a recovery" and refuse to participate as if I had old data.

## Notes for the coach
- **This is the canonical lock-service / coordination-service interview prompt.** Asked widely at FAANG / cloud infra (AWS, Google, Azure) and confirmed at companies building control planes (Cloudflare, Kubernetes-adjacent infra). The Burrows Chubby paper (OSDI 2006) and the Hunt et al. ZooKeeper paper (USENIX ATC 2010) are the primary references.
- **The fencing-token + resource-side-validation triplet is the Staff+ unlock.** Kleppmann's published Redlock critique is the canonical reference for why naive locking fails. A candidate who proposes a lock service without articulating fencing tokens and resource-side validation is missing the central safety property; surface as a category-level gap if not addressed.
- **The 93% KeepAlives workload anchor is the non-obvious depth signal.** Most candidates jump straight to consensus protocols without addressing the operational reality that the session-liveness path is the hot path. The candidate who articulates this is at Sr Staff bar.
- **`etcd` is a separate problem** in this catalog (covers etcd-specific watch fan-out + GKE Spanner migration story). If the candidate steers strongly toward etcd, redirect: "let's keep this focused on the coordination-service primitive shape; the etcd-specific operational concerns are a separate problem." If the interviewer pivots toward "design etcd specifically," that's a separate problem.
- **The ZK vs etcd vs Chubby comparison is the L7 differentiation flex.** Comparing protocol choices (Zab vs Raft vs Multi-Paxos), watch semantics (one-shot vs streaming-revision), and operational scale (Chubby 90K clients/cell, etcd 10K clients/server, ZK 100K reads/sec) demonstrates breadth across all three reference architectures.
- **Cross-coverage:** the consensus substrate here underlies `etcd`, `spanner` (Paxos groups per shard), `aurora` (uses Paxos-like quorum), and indirectly `kafka` (KRaft replaces ZK). Naming consensus once and reusing across problems is the right meta-pattern.

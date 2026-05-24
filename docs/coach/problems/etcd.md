---
slug: etcd
archetype: infra-primitives
sources:
  etcd_api: etcd.io/docs/v3.5/learning/api/
  etcd_8gb: perfectscale.io/blog/etcd-8gb
  alibaba_10k_nodes: alibabacloud.com/blog/how-does-alibaba-ensure-the-performance-of-system-components-in-a-10000-node-kubernetes-cluster_595469
  gke_65k_nodes: cloud.google.com/blog/products/containers-kubernetes/
---

# etcd / HashiCorp Consul (distributed configuration store with watch API)

## Bar anchors
- **Mid-level (L4/E4):** Knows etcd is "the Kubernetes config store" at category level. May discuss key-value semantics. Doesn't address watch fan-out, MVCC, transactional multi-key updates, or operational scale limits unprompted.
- **Senior (L5/E5):** Names Raft as the consensus protocol; articulates strongly-consistent KV with hierarchical key prefixes. Discusses watch API at category level (clients receive notifications on key changes). Knows about etcd as a control-plane substrate. May not address the 8 GB DB cap or the watch fan-out architecture.
- **Staff+ (L6/E6+):** Drives proactively. Distinguishes etcd from `zookeeper` by the **read-dominated, watch-driven nature** of the workload: etcd's MVCC + streaming-revision watches enable many-keys-per-client efficiently (Kubernetes informers depend on this). Cites the **operational constraint**: 8 GB DB size practical ceiling (officially capped via `--quota-backend-bytes`); at ~80K Kubernetes objects in a multi-tenant cluster with CRD spam, etcd starts overloading; **GKE 15K → 65K nodes required migrating the control plane from etcd to a Spanner-backed store** (Google Cloud Blog 2024). Quantifies the Kubernetes-at-10K-nodes scale: full Node object updates generate ~1GB/min of Raft log; the Kubernetes Lease API (KEP-589) was introduced specifically to strip heartbeats out of full Node objects, dramatically reducing write amplification. Articulates etcd's **MVCC over bbolt**: every write creates a new revision indexed against the Raft log; reads are linearizable via `ReadIndex` (leader confirms still-leader via heartbeat, then serves locally); compaction discards old revisions. Names the **Txn (transactional multi-key)** primitive: `compare-and-swap on N keys atomically` enables declarative reconciliation patterns (e.g., rotate leader lease + update routing table in one atomic op). Articulates the **watch fan-out problem**: 100K kubelets watching the same Pod spec — naive broadcast fails; Kubernetes apiserver implements a **watch cache** that absorbs the fan-out (1 etcd watch per resource type, fan out to N kubelet streams from the apiserver cache); progress notifications + bookmark events to avoid full re-list on disconnect. Names **lease + fencing-token-as-modRevision**: etcd's modRevision serves as the monotonic fencing token for distributed locking (just like ZK sequence numbers). Stretch (Sr Staff bar): articulates the **Consul alternative architecture** (Raft for KV/ACL state + Serf SWIM gossip for membership/failure detection at O(log N)); 3-or-5 server agents + thousands of client agents.

## Canonical decomposition

### Requirements
**Functional:**
- Strongly-consistent hierarchical KV store with prefix queries
- Watch API: clients register interest in key changes; broker delivers events with bounded latency
- Transactional multi-key updates (etcd Txn / ZK multi-op / Consul KV-Txn)
- Sessions / leases for ephemeral state + auto-cleanup
- MVCC for time-travel reads (watch from revision N; read at revision N)
- Linearizable reads when required; eventually-consistent local follower reads for read scaling

**Non-functional (with numbers):**
- 100K services / clients watching the cluster (Kubernetes scale)
- 1M reads/sec (mostly served from follower local caches)
- 10K writes/sec (all through Raft leader)
- p99 watch notification <1s
- **8 GB DB size practical ceiling** (officially capped)
- At ~80K Kubernetes objects, etcd starts overloading
- Kubernetes-at-10K-nodes: ~1GB/min of Raft log from Node object updates pre-Lease-API
- GKE 15K-node ceiling (pre-2024) → 65K nodes with control plane on Spanner-backed store

### Core entities
- **Cluster:** 3 or 5 etcd nodes running Raft consensus
- **Key:** hierarchical path (e.g., `/registry/pods/default/my-pod`); supports prefix range queries
- **Revision:** global monotonic counter, advances on every write; basis for MVCC + watch semantics
- **Lease:** TTL-bound; can attach keys to the lease for auto-deletion on expiry
- **Watch:** streaming gRPC subscription on a key or key range; resumable from a revision
- **Txn:** atomic compare-and-swap on multiple keys with then/else branches
- **bbolt:** etcd's on-disk B+ tree storage (a maintained fork of BoltDB)

### API
- `Get(key, range_end?, revision?)` → values; supports range queries (prefix); optional snapshot revision
- `Put(key, value, lease?)` → revision number; optional lease for auto-deletion
- `Delete(key, range_end?)` → revision number
- `Watch(key, range_end?, start_revision?)` → streaming gRPC; events include Put/Delete with new revision
- `Txn(compare=[(key, op, value)], success=[ops], failure=[ops])` → atomic conditional batch
- `Lease.Grant(ttl)` → lease_id; `Lease.KeepAlive(lease_id)` → renew; `Lease.Revoke(lease_id)` → delete all keys attached
- Admin: `Compact(revision)` discards history below revision; `Defragment` reclaims space after compaction

### HLD
The cluster is **3 or 5 nodes** running **Raft consensus** (Raft's 150-300ms randomized election timeout typical). One node is leader; all writes go through it; writes are replicated to a majority before commit. Reads are either **linearizable** (via `ReadIndex` — leader confirms it's still leader via heartbeat, then serves locally — adds 1 RTT but no Raft round) or **eventually consistent** from any follower's local copy.

The on-disk store is **bbolt** (B+ tree mmap'd file). The KV is **MVCC**: each write creates a new revision; old revisions are kept until compaction; the revision serves as the global monotonic counter that orders events. Watch from revision N replays all changes since N (until they're compacted), enabling resumable subscriptions across client disconnects.

The **watch API** is the killer feature for Kubernetes-style control planes. Naive watch: 100K kubelets each open a watch on `/registry/nodes/<their-node>` — that's 100K active watches; broker fan-out cost grows with watch count. Kubernetes mitigates with the **apiserver watch cache**: the apiserver opens ONE watch per resource type to etcd, caches the stream locally, fans out to N kubelet watch streams from the local cache. etcd's per-watch cost stays at the resource-type count (~50), not the kubelet count (100K). **Progress notifications** (etcd 3.4+) are periodic events sent on idle watches to advance the client's known revision; **bookmark events** are similar — both prevent a slow watch from forcing a full re-list on reconnect (the client knows its current revision and resumes from there).

**Linearizable reads via ReadIndex**: when a client requests a linearizable read, the leader sends a no-op heartbeat to confirm it's still the leader (single RTT, no log entry); on majority confirmation, it serves the read from local state. Cost: 1 RTT per linearizable read (vs no RTT for eventually-consistent). Alternative: **lease-based reads** — leader holds a time-bounded lease; during the lease window, reads serve locally without confirmation (Spanner-style). Etcd doesn't expose lease-based reads to clients but uses similar internally.

**Transactional multi-key Txn**: atomic compare-and-swap on multiple keys. Used for declarative reconciliation: "set leader_lease to X AND update routing_table to Y, only if current leader_lease is Z (the previous leader)." Without this primitive, coordination patterns require additional locking. ZooKeeper's `multi-op` and Consul's `KV-Txn` are equivalents.

**Consul's alternative architecture**: Consul uses **Raft for KV/ACL/service-catalog state** (odd number of server agents — 3 tolerates 1 failure, 5 tolerates 2) + **Serf SWIM gossip** for membership and failure detection at O(log N). Architecture splits server agents (Raft quorum, authoritative state) from client agents (one per app host, stateless, forward queries, participate in gossip). Federation across DCs uses a separate WAN gossip pool restricted to server agents. **Why Consul + Serf**: gossip-based failure detection scales to tens of thousands of nodes without the Raft-leader bottleneck; Raft only handles the small-state KV/ACL workload.

### Deep dives
1. **The 8 GB DB cap and the GKE 15K → 65K node Spanner migration.** etcd's MVCC + bbolt storage has an officially-recommended 8 GB DB size cap (`--quota-backend-bytes`). Exceeding triggers NOSPACE alarm; writes rejected until compaction + defrag. Why the cap: bbolt's mmap'd B+ tree gets pathological behavior at large sizes (random read amplification, defrag time grows non-linearly). At Kubernetes-at-10K-nodes scale, full Node object updates (heartbeat + status) generate ~1GB/min of Raft log; without compaction keeping up, the DB grows rapidly. **Alibaba's published 2020 workaround**: Kubernetes Lease API (KEP-589) introduces a small Lease object per Node that carries only the heartbeat timestamp; Node status updates are decoupled from heartbeats; full Node object writes become rare. ~10× reduction in etcd write rate. **GKE 65K-node cluster** (Google Cloud Blog 2024): even with Lease API, etcd's 8 GB cap is insufficient at extreme scale; GKE migrated the Kubernetes control plane's storage backend from etcd to a **Spanner-backed store** that scales beyond etcd's ceiling. This is a major architectural pivot — etcd is no longer the universal Kubernetes substrate at the extreme upper end. Staff+ commit: cite the 8 GB cap, name the Lease API as the historical workaround, name the Spanner-backed migration as the 2024+ extreme-scale answer.

2. **Watch fan-out: streaming-revision watches + apiserver watch cache + bookmark events.** Naive watch implementation: each client opens a separate watch on the broker; broker holds per-watch state + delivers events to each. At 100K clients on the same key, the broker's per-watch overhead dominates. **etcd's streaming-revision model**: watches are gRPC streams indexed by revision; a single stream can multiplex many key-range subscriptions; clients resume from the last-seen revision on disconnect (until compaction discards old revisions). **Kubernetes apiserver watch cache**: the apiserver opens ONE watch per resource type to etcd; caches the stream in memory; fans out to N client (kubelet) watch streams from the local cache. So etcd sees ~50 active watches (one per resource type), not 100K. The apiserver-cache pattern is the standard for any system fanning out etcd watches to many clients. **Bookmark events** (Kubernetes 1.15+) are periodic events sent on idle watches: they carry the current revision number but no actual key change. This prevents a slow watch from getting stuck — the client knows its current revision, so on disconnect it can resume from there without re-listing the entire state. Staff+ commit: name the apiserver-cache pattern, address what happens when the apiserver itself crashes (cache rebuilds via initial LIST + WATCH), bookmark cadence policy.

3. **Linearizable reads via ReadIndex + the MVCC compaction trade-off.** Etcd's reads can be either linearizable (current state of the cluster) or stale (any follower's local copy). Linearizable via **ReadIndex**: the leader sends a no-op heartbeat to confirm it's still the leader (majority acknowledgement, 1 RTT but no log entry); on confirmation, serves the read from local state. This is cheaper than a Raft round but still requires the heartbeat RTT. Alternative: **lease-based reads** — leader holds a time-bounded lease (e.g., 10s); during the lease, reads serve locally without confirmation; on lease expiry, reads stall until lease renewal. Etcd doesn't expose lease-based reads to clients but uses similar internally. **MVCC compaction trade-off**: every write creates a new revision; old revisions accumulate until compacted. Compaction reclaims history; **defragmentation** (separate step) reclaims disk space after compaction. Both are operationally disruptive — defrag locks the bbolt file briefly. Without aggressive compaction, the DB grows toward the 8 GB cap; with compaction, watch-resume-from-revision is bounded (watches that have lagged past the compacted revision must re-list). Staff+ commit: pick read consistency policy per use case (linearizable for control-plane decisions, stale for read scaling), compaction cadence, what happens to lagged watchers when compaction passes their resume point (full re-list).

## Known failure modes
1. **DB > 8 GB triggers cluster halt.** Compaction lags churn; DB grows past quota; NOSPACE alarm fires; all writes rejected. Production answer: continuous compaction policy (automatic compaction every N hours or N revisions); periodic defrag during low-traffic windows (defrag locks the bbolt file briefly); alerting on DB size growth approaching the cap; per-tenant write-rate cap to prevent one tenant's CRD spam from saturating the cluster; for extreme scale, etcd sharding by control-plane partition or migration to Spanner-backed alternative (the GKE 2024 path).

2. **Watch stream backlog overflows server-side buffer.** Client too slow to consume watch events; server-side buffer fills; cluster instability or watch closure. Production answer: per-client buffer cap (etcd enforces this); on overflow, the server closes the watch with a "compacted" error; client re-establishes watch by full LIST then WATCH from a fresh revision (Kubernetes informer's `Resync` behavior); rate-limit watch event delivery to slow clients (less common in etcd; more common in custom watch services).

3. **Raft leader election storm under network instability.** Brief network blip between leader and followers triggers election timeout; new leader elected; original leader rejoins with stale log; replication catches up. Repeated under chronic instability → repeated elections → cluster unavailability for writes. Production answer: tune election timeout vs heartbeat interval (larger = more tolerant to blips but slower failover); use of "pre-vote" (etcd extension to Raft: candidate first asks if others would vote without incrementing term, preventing partitioned nodes from triggering unnecessary elections); monitor leader-change rate as a stability SLI.

## Notes for the coach
- **This is plausibly-asked at Cloudflare, Kubernetes-adjacent infra companies, and AI labs running training-job control planes.** Less canonical than "design ZooKeeper" but a sharper Staff+ prompt because it forces watch-scale + operational-limit reasoning.
- **The 8 GB DB cap + GKE Spanner migration is the modern-scale anchor.** A candidate who only treats etcd as "a Raft-replicated KV" without the operational ceiling is missing the production reality.
- **The watch fan-out via apiserver-cache pattern is the L7 differentiation.** Most candidates treat the watch problem as "etcd handles it"; the Sr Staff candidate articulates that etcd by itself can't fan out to 100K clients — the application layer (apiserver) absorbs the fan-out.
- **Consul comparison is the breadth signal.** Naming Serf gossip for membership (O(log N) failure detection independent of Raft) demonstrates literacy with the alternative architecture.
- **Distinct from `zookeeper` problem by workload framing.** `zookeeper` is the coordination service (locks, leader election, fencing tokens with 93% KeepAlive workload); `etcd` is the configuration store (watch-driven, MVCC, transactional multi-key). Both run consensus protocols underneath but the surface design pressures differ. If the candidate confuses the two, redirect: "let's keep this on the config-store shape — assume the lock-service primitive exists separately."
- **No direct AI-infra counterpart** — control-plane state store is generic infra; AI-training control planes use etcd, AI-serving control planes use etcd; the substrate is the same.
- **Cross-coverage:** below `kubernetes-scheduler` (the scheduler depends on etcd as its state store), adjacent to `zookeeper` (same consensus substrate, different surface), connected to `spanner` (the migration target for extreme-scale etcd replacement).

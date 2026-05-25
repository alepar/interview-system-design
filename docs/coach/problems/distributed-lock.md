---
slug: distributed-lock
archetype: concurrent-resource
sources:
  kleppmann_locking: martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
  redlock: redis.antirez.com/fundamental/redlock.html
  redis_distlock_docs: redis.io/docs/latest/develop/clients/patterns/distributed-locks/
  zk_recipes: zookeeper.apache.org/doc/r3.2.2/recipes.html
  ddia_fencing: timilearning.com/posts/ddia/part-two/chapter-8/
---

# Distributed Lock (application-level mutual exclusion)

## Bar anchors
- **Mid-level (L4/E4):** Uses Redis `SETNX` then `EXPIRE` as a lock. Doesn't see the crash-between-commands gap, the failover problem, or that TTL-based locks can be held by two clients.
- **Senior (L5/E5):** Atomic `SET key val NX PX ttl`, random token + Lua compare-and-delete on release, TTL for auto-release. Knows single-instance Redis is unsafe across failover and Redlock exists. May not articulate fencing tokens, the safety-vs-liveness distinction, or when to use ZooKeeper/etcd.
- **Staff+ (L6/E6+):** Drives proactively. Distinguishes **efficiency locks** (best-effort, occasional double-work is fine — single Redis `SET NX PX` suffices) from **correctness locks** (mutual exclusion must hold — and here naive TTL locks are *unsafe*). Explains **why**: a **GC/process pause or network delay** can exceed the lease (Client 1 acquires, pauses, lease expires, Client 2 acquires, both think they hold it — HBase saw multi-minute GC pauses, GitHub ~90s packet delays), and Redlock relies on **wall-clock** timing assumptions (clock jumps, bounded pauses) that distributed systems don't guarantee — so **Redlock is too heavy for efficiency yet unsafe for correctness** (Kleppmann). The correct fix is a **fencing token**: a monotonically increasing number issued per acquisition, attached to every write, and the protected resource **rejects any token lower than the highest seen** — so a paused/stale holder's write is fenced off. Redlock can't produce fencing tokens; **ZooKeeper** (zxid / znode version, ephemeral-sequential nodes) or **etcd** (lease + monotonic revision) can. States the principle: **safety must not depend on timing; only liveness may.**

## Canonical decomposition

### Requirements
**Functional:**
- Grant mutual exclusion on a resource across processes/machines
- Auto-release if the holder crashes (no permanent deadlock)
- For correctness-critical use, guarantee no two holders ever act simultaneously

**Non-functional (with numbers):**
- Lock TTL sized > expected work + margin (and ≥ ~3× renewal interval for lease locks)
- Safety independent of clock/timing; liveness via timeout
- Fencing token monotonic per acquisition (for correctness locks)

### Core entities
- **Lock key:** a key whose holder owns the resource (with a random owner token)
- **Lease / TTL:** auto-release window for crash safety
- **Fencing token:** monotonic number per acquisition, checked by the resource
- **Consensus store (for correctness):** ZooKeeper/etcd providing the token + lock

### API
- acquire: `SET lock {random_token} NX PX {ttl}` (single Redis) → owner
- release: Lua `if GET lock == my_token then DEL` (don't delete someone else's lock)
- correctness: acquire via ZK ephemeral-sequential / etcd lease → get a fencing token; resource rejects stale tokens

### HLD
Start by **classifying the lock**. An **efficiency lock** (avoid duplicate work, but a rare double-execution is harmless — e.g. dedup a cron job) only needs best-effort mutual exclusion: a **single-instance Redis** lock with the atomic `SET key {random_token} NX PX {ttl}` (the `NX`+`PX` in one command — never the old `SETNX`-then-`EXPIRE`, which leaves a permanent lock if the process crashes between them), released with a **Lua compare-and-delete** (`if value == my_token then DEL`, so a client whose lease already expired can't delete a lock another client now holds), and a **TTL** for crash auto-release. That's correct *enough* and simple.

A **correctness lock** (two holders would corrupt data / double-charge) is harder, and the key insight is that **TTL locks are fundamentally unsafe** for it: any client can pause (a stop-the-world **GC pause**, a long **network delay**, a VM freeze) past the lease, during which another client acquires the lock — now both believe they hold it. Redlock (N=5 Redis masters, majority quorum) doesn't fix this and adds **wall-clock timing assumptions** (clock jumps from NTP, bounded pauses) that don't hold in real systems — Kleppmann's verdict: unnecessarily heavy for efficiency, insufficiently safe for correctness, and it **can't generate fencing tokens**. The robust answer is a **fencing token**: each acquisition returns a monotonically increasing number; the client includes it with **every write** to the protected resource, and the resource **remembers the highest token it has processed and rejects any lower** — so a stale holder resuming after a pause is fenced out. Get fencing tokens from a real **consensus system**: **ZooKeeper** (the `zxid` or znode version; ephemeral-sequential znodes give fair FIFO locks that auto-release when the session dies) or **etcd** (a lease the client renews via KeepAlive, plus a globally monotonic **revision** usable directly as the token). The governing principle: **safety properties must hold without timing assumptions; only liveness (eventual progress) may depend on timeouts** — Redlock inverts this, which is its flaw.

### Deep dives
1. **Efficiency vs correctness locks — and why TTL alone is unsafe for correctness.** The classification drives everything. For efficiency, single-Redis `SET NX PX` + Lua release + TTL is fine (occasional double-work tolerated). For correctness, walk the failure: Client 1 acquires the lock, enters a stop-the-world GC pause (HBase: minutes; or a 90s network delay like GitHub's), the lease expires, Client 2 acquires the *same* lock, then Client 1 resumes and writes — **both acted under "the lock," violating mutual exclusion**. No TTL value fixes this (the pause is unbounded), and adding more Redis nodes (Redlock) doesn't either. This is the canonical "locks are not enough" result, and recognizing that *a lock with a lease cannot by itself guarantee correctness* is the Staff+ bar.
2. **Fencing tokens (the correct safety mechanism).** Since you can't prevent a paused client from *thinking* it holds the lock, you instead make its stale writes **harmless**: every acquisition yields a monotonically increasing **fencing token**; the client sends the token with each write; the **protected resource** tracks the highest token it has accepted and **rejects any write with a lower token**. So when Client 2 (token 34) has written, Client 1's delayed write (token 33) is rejected — fenced off. Crucially, this pushes enforcement to the *resource*, not the lock service, and requires a lock service that issues monotonic tokens — which Redlock doesn't, but ZooKeeper (zxid/version) and etcd (revision) do. The framing: a lock grants *permission*, a fencing token makes *stale permission safe*.
3. **Choosing the lock service + lease management.** For correctness, use a **consensus system**: ZooKeeper ephemeral-sequential znodes (lowest sequence holds the lock; watch only the predecessor to avoid the herd; ephemeral node auto-deletes on session loss → auto-release) or etcd (a **lease** with TTL that the client renews via periodic KeepAlive; stop renewing on crash → lease + lock expire; every change gets a monotonic revision = free fencing token). Lease TTL sizing: set it to **≥ ~3× the renewal interval** so a transient stall doesn't cause premature expiry (e.g. 10s KeepAlive → 30s TTL). For efficiency, single Redis is fine but **unsafe across failover** (if the master dies after granting but before replication, a promoted replica can grant the same lock to a second client) — acceptable for best-effort, not for correctness. The decision tree: efficiency → single Redis `SET NX PX`; correctness → ZK/etcd + fencing tokens.

## Known failure modes
1. **Two holders due to a pause exceeding the lease.** GC/network pause expires the lease while the holder is frozen; another client acquires it. Production answer: fencing tokens (resource rejects stale tokens) — a lease alone cannot prevent this; never rely on TTL for correctness.
2. **Lock lost on failover (single Redis) / unsafe Redlock for correctness.** Master crash between grant and replication, or Redlock's timing assumptions. Production answer: ZooKeeper/etcd consensus lock + fencing tokens for correctness; reserve single-Redis/Redlock for efficiency-only locks.
3. **Releasing someone else's lock / permanent lock.** A client deletes a lock it no longer owns, or `SETNX`+`EXPIRE` crashes between commands leaving a stuck lock. Production answer: atomic `SET NX PX`, random owner token + Lua compare-and-delete on release, TTL for auto-release.

## (Delineation note)
`distributed-lock` is the application-level mutual-exclusion primitive underlying many problems in this archetype (seat holds, inventory, wallet). Building the consensus engine (ZooKeeper ZAB, etcd Raft) is infra-primitives `etcd`/`zookeeper` — reference, don't re-derive. Here it's the efficiency-vs-correctness classification + fencing tokens.

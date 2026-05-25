---
slug: local-first-sync
archetype: conflict-resolution
sources:
  replicache_how: doc.replicache.dev/concepts/how-it-works
  replicache_global_version: doc.replicache.dev/strategies/global-version
  electricsql: electric-sql.com/docs/api/http
  linear_sync: github.com/wzhudev/reverse-linear-sync-engine/blob/main/SUMMARY.md
  local_first_essay: inkandswitch.com/essay/local-first/
---

# Local-First Sync Engine (Replicache / ElectricSQL / PowerSync / Linear)

## Bar anchors
- **Mid-level (L4/E4):** Proposes "cache in localStorage and POST changes." No conflict model, no rollback, no offline queue, assumes the network is always there.
- **Senior (L5/E5):** Client-side store with optimistic local writes, a queue of pending mutations sent to the server, and a pull to refresh. Knows offline edits must be replayed on reconnect. May not articulate the rebase-on-server-authority model, exactly-once via mutation ids, why timestamp-based pulls are broken, or compare the real engines.
- **Staff+ (L6/E6+):** Drives proactively. Frames it against the Ink&Switch **"local-first" 7 ideals** (instant local, multi-device, network-optional, seamless collab, longevity, privacy, ownership). Specifies the **Replicache model**: **push/pull/poke** (poke = a 0-byte "pull now" hint, deliverable over any channel) with **speculative client mutations replayed git-rebase-style** on the new server state, **per-client `lastMutationID`** for exactly-once, and **IDs passed *into* mutators** (not generated inside) so they're stable across replay. Explains why **naive last-modified-timestamp pulls are broken** (a push committing at t1 while a pull reads t2>t1 misses the push). Compares **ElectricSQL** (read-path Shapes over HTTP, **CDN-collapsed to scale 100k→1M clients flat**, ~6ms write propagation), **PowerSync** (client SQLite + **blocking FIFO upload queue**, so the client never resolves conflicts locally), and **Linear** (server-authoritative, OT-like, a **global monotonic `lastSyncId`**, bootstrap-then-delta, Object Pool + IndexedDB + undo on rejection). Notes Linear/Figma/Replicache **chose server authority over CRDTs** for operational simplicity.

## Canonical decomposition

### Requirements
**Functional:**
- Local reads/writes are instant; the app works fully offline
- Local mutations apply optimistically, then reconcile against the server (authoritative)
- Sync is incremental: a reconnecting client fetches only what changed
- Exactly-once application of each client mutation despite retries/reconnects

**Non-functional (with numbers):**
- Local read/write < 1ms (in-process store); scan ~500MB/s; hundreds of MB client view
- ElectricSQL: flat memory/latency from 100k→1M concurrent clients (CDN request collapsing); ~6ms write propagation
- Mutation exactly-once via per-client lastMutationID
- Survives long offline gaps (queue persisted in IndexedDB/SQLite)

### Core entities
- **Mutation:** a named, parameterized intent with a per-client sequential **mutationID**
- **Client view / local store:** the client's optimistic state (IndexedDB / SQLite)
- **Server authority:** canonical state; assigns order (global version / lastSyncId)
- **Poke / delta:** "pull now" hint / the incremental change set since the client's cursor

### API
- `mutate(name, args)` → apply optimistically locally + enqueue for push
- push: `POST /push {clientID, [mutations with ids]}` → server executes, advances lastMutationID
- pull: `POST /pull {clientID, cookie}` → patch to current server state + new cookie
- poke: 0-byte "you should pull" signal (SSE/WebSocket/push) → triggers a pull

### HLD
The client holds a **persisted local store** (IndexedDB or SQLite) and applies every mutation **optimistically and instantly** — reads/writes never wait for the network. Each mutation is a **named, parameterized intent** (e.g. `addTodo({id, text})`) assigned a **per-client sequential mutationID**. Mutations are batched and **pushed** to the server, which **re-executes** them authoritatively (the server has its own implementation of each mutation — the client's was speculative) and records the client's high-water-mark **lastMutationID** transactionally with their effects, giving **exactly-once** semantics (replays with id ≤ lastMutationID are ignored). On **pull**, the client receives a patch to the current server state plus a new cursor/cookie; it then **replays its still-unconfirmed local mutations on top of the new server state — a git rebase** — and reveals the patched-and-replayed result atomically. A **poke** is a content-free hint ("pull soon") that lets the realtime layer stay a stateless request/response while still feeling live. Critically, **IDs and other "random" inputs are passed into mutators as arguments**, not generated inside, so replay is deterministic.

**Why not naive timestamps:** a pull that says "give me everything modified after t" races with in-flight pushes — a push that began before t but commits after can be missed, silently losing data. The robust strategies use a **server-defined order** (a global version counter incremented per push, or Linear's global `lastSyncId`) so pulls are exact. The engines differ in topology: **ElectricSQL** syncs read-path **Shapes** (filtered partial replicas) over plain HTTP that **CDNs collapse**, so one service scales 100k→1M clients with flat memory/latency and ~6ms write propagation; **PowerSync** uses a client SQLite + a **blocking FIFO upload queue** and *doesn't advance to a new server checkpoint until all local writes are acked*, so the client never resolves conflicts locally; **Linear** is server-authoritative and OT-like, with a single monotonic **lastSyncId** as the database version, a full **bootstrap** then **/sync/delta** of `SyncAction`s, an in-memory **Object Pool** (UUID→model) hydrated lazily, and client-side **undo/redo/revert** to handle server rejections. The throughline: **when you already have a server, let it define order** (rebase pending mutations) rather than pay CRDT P2P costs — the choice Replicache, Linear, and Figma all made.

### Deep dives
1. **The rebase reconciliation model.** Optimistic local mutations are *speculative*; the server's re-execution is *authoritative* and may differ (the room you booked is now taken, so the server's `bookRoom` books a different one or errors). On each pull the client drops its unconfirmed mutations, applies the server patch to reach the true server state, then **replays the still-pending mutations on top** — exactly git rebase — so the user's in-flight work is preserved against the new base and corrections appear atomically. This requires **deterministic mutators** (IDs passed in, not generated) and **per-client lastMutationID** so the server applies each mutation exactly once and the client knows which to drop. The Staff+ insight: this gives CRDT-like "edit offline, converge later" UX *without* CRDTs, by making the server the single source of order and replaying intents.
2. **Why timestamp pulls are broken (and what to do instead).** Walk the race: client c1 pushes p1; the server begins committing p1 at t1; meanwhile c2 pulls "changes since t2" and the server answers up to t2 > t1, but p1 hasn't committed yet — so c2 records "I'm current as of t2" while missing p1's rows, which it will *never* re-pull. The fix is a **server-assigned monotonic order**: a global version incremented atomically with each push (Replicache's Global Version Strategy) or Linear's lastSyncId, so a pull cursor is a position in a total order, not a wall-clock time. This is the subtle correctness bug that separates a real sync engine from a naive one.
3. **Engine comparison and the server-authority-vs-CRDT choice.** Map the design space: **Replicache** (general mutations + rebase + poke; you implement mutators twice), **ElectricSQL** (read-path Shapes, CDN-collapsed, Postgres↔SQLite, brilliant fan-out but write path is your app's), **PowerSync** (mobile-first, blocking FIFO upload queue avoids client-side conflict resolution entirely), **Linear** (bespoke OT-like total order, the gold standard for snappy local-first). The unifying Staff+ point: **all of these reject CRDTs** because a central server can define order for free, and CRDT metadata/complexity is only worth it when you genuinely need peer-to-peer or serverless operation. Name the axis (need P2P? → CRDT; have a server? → server-authority + rebase) explicitly.

## Known failure modes
1. **Lost data from timestamp-based pulls.** The push/pull commit race silently drops writes. Production answer: server-assigned monotonic order (global version / lastSyncId), pull cursors as positions in that order — never wall-clock "modified since."
2. **Non-deterministic replay.** A mutator that generates a random ID or reads `now()` produces different results on client vs server, so rebase diverges. Production answer: pass all non-deterministic inputs into the mutator as arguments; keep mutators pure functions of (state, args).
3. **Huge offline backlog on reconnect.** A client offline for days has a massive mutation queue / delta to apply. Production answer: bound the delta (Linear falls back to a full bootstrap if the lastSyncId gap is too large), batch + apply in one transaction, and model "you lost access to this row" as an explicit delete in the pull rather than a silent omission.

## (Spine note)
`local-first-sync` is the offline-first sync-engine family; it can use `yjs` as its merge engine (CRDT path) or server-authority + rebase (Replicache/Linear path). It shares push/pull/poke + local SQLite with `notion`'s offline mode, and the WebSocket/poke transport with messaging — reference, don't re-derive.

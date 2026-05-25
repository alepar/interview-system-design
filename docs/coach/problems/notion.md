---
slug: notion
archetype: conflict-resolution
sources:
  notion_data_model: notion.com/blog/data-model-behind-notion
  notion_sharding: notion.com/blog/sharding-postgres-at-notion
  notion_offline: notion.com/blog/how-we-made-notion-available-offline
  notion_request_limits: developers.notion.com/reference/request-limits
---

# Notion (block-based collaborative workspace at 200B+ blocks)

## Bar anchors
- **Mid-level (L4/E4):** Models a doc as a big JSON document in a row. Doesn't recognize the block tree, how it shards, or how offline editing reconciles.
- **Senior (L5/E5):** Models everything as a block (a row with a parent pointer + ordered children), stores blocks in a relational DB, recognizes the workspace as the natural sharding unit, and that offline editing needs conflict resolution. May not articulate the sharding math, the VACUUM-driven motivation, the CRDT-for-offline choice, or partial-load.
- **Staff+ (L6/E6+):** Drives proactively. States the model: **everything is a block** (UUID, type, properties map, ordered `content` array of child IDs + upward `parent` pointer; permissions inherit by walking parents to the workspace root). Blocks are **Postgres rows**: **~20B (2021) → 200B+ (2024)**, sharded by **`workspace_id` into 480 logical shards** (32 physical × 15 in 2021, re-sharded to 96 × 5 by 2023; **480 chosen for many divisors** so hosts grow incrementally — 512 would force 32→64 host doublings). Names **VACUUM stalling + per-table/db capacity ceilings** as the real sharding driver. For collaboration: **offline pages migrate to a CRDT model** + local **SQLite** cache, with push-based sync (lastDownloadedTimestamp watermarks, partial load of ~first 50 rows of a DB). Proposes the offline conflict model (per-field LWW + OR-Set collections + a **movable-tree CRDT** for `parent_id`) while flagging the exact algorithm isn't fully public.

## Canonical decomposition

### Requirements
**Functional:**
- Documents are trees of typed blocks; blocks move, nest, and transform types
- Permissions inherit down the tree from the workspace root
- Offline editing on multiple devices reconciles on reconnect
- Large pages/databases load partially (don't fetch everything)

**Non-functional (with numbers):**
- 200B+ block rows (2024), doubling every ~6–12 months
- 480 logical shards across 96 physical Postgres (2023); sharded by workspace_id
- API granularity: rich-text ≤2,000 chars, ≤100 blocks/array, ≤1,000 blocks/create
- Offline: local SQLite cache; partial load (~first 50 DB rows)

### Core entities
- **Block:** `id (UUIDv4)`, `type`, `properties` (JSON; e.g. title text), `content` (ordered child IDs), `parent` (upward pointer), `workspace_id`
- **Workspace:** the sharding + permission root; one workspace = one logical shard
- **LocalStore:** client SQLite mirror of the user's accessible blocks
- **SyncState:** per-client lastDownloadedTimestamp watermark per page

### API
- `GET /load-page-chunk` → hydrate a page's blocks (partial; first N rows of DBs)
- `POST /submitTransaction` → apply block ops (create/update/move/delete)
- push channel: server emits "page changed" on a page's channel; client refetches pages newer than its watermark
- offline: queue ops in SQLite; on reconnect, sync + CRDT-merge

### HLD
The data model is uniform: **every block is a row** `(id, type, properties, content[], parent, workspace_id)`, and pages, text, list items, even databases are blocks. The tree is bidirectional (downward `content` order + upward `parent`), and **permission checks walk `parent` pointers up to the workspace root** — which is why each block has a single parent (no ambiguous multi-parent). Because every block carries a `workspace_id` and operations are workspace-local, **`workspace_id` is the shard key**: cross-shard joins are avoided. The sharding journey is the Staff+ story — a single Postgres hit VACUUM stalls and per-table/db capacity ceilings, so Notion sharded to **480 logical shards** (32 physical × 15 logical in 2021; re-sharded to 96 × 5 by 2023). 480 was chosen for its many divisors so physical hosts can grow incrementally (512 would force doubling 32→64). Migration used double-write → audit-log catch-up → dark-read verification → cutover.

For **collaboration/offline**, pages marked available-offline migrate to a **CRDT data model** with a local **SQLite** cache; sync is push-based — the server emits a message on a page's channel when a batch of updates lands, and clients track a **lastDownloadedTimestamp**, refetching only pages whose server `lastUpdatedTime` is newer. Large databases **load partially** (the first ~50 rows; more on demand) so a huge workspace doesn't fetch everything. The exact offline merge algorithm isn't fully public; a defensible model is **per-field LWW** for scalar block properties, **OR-Set** semantics for the ordered `content` collection, and a **movable-tree CRDT** (Kleppmann's highly-available move) for `parent` to avoid cycles/duplication under concurrent reparent.

### Deep dives
1. **The block-as-row model + workspace sharding.** Uniform schema (one `blocks` table) makes the system a graph database on Postgres, and `workspace_id` is the locality unit that makes sharding clean (all of a workspace's blocks co-locate; permission walks stay within a shard). Walk the sharding math: 480 logical shards (divisor-rich) decoupled from physical hosts so you re-balance by moving logical shards, not re-hashing; the 32×15 → 96×5 re-shard kept 480 logical constant. The migration playbook (double-write, audit log, backfill, dark reads, cutover) is the Staff+ operational content. The driver was **VACUUM stalling + capacity ceilings**, not raw row count alone — a precise "why now" that separates Staff+ from Senior.
2. **Offline conflict resolution for a block tree.** The hard part is the tree: concurrent edits to scalar properties are easy (per-field LWW), and the `content` ordering is an OR-Set/fractional-index problem, but **concurrent reparenting** can create cycles or duplicate subtrees (move A under B while moving B under A). The principled answer is a **movable-tree CRDT** (Kleppmann's "highly-available move operation for replicated trees") that defines a deterministic, cycle-free resolution. Flag that Notion's published material confirms a CRDT model + SQLite for offline but not the exact algorithm, so *propose* the model rather than assert it — the Staff+ move is reasoning to it from first principles.
3. **Push-based partial sync + watermarks.** Hydrating a 200B-block backend per client is impossible, so loads are partial (page-chunk fetches, first ~50 DB rows) and sync is incremental: the server emits a lightweight "page changed" poke on the page's channel, and the client refetches only pages whose `lastUpdatedTime` exceeds its `lastDownloadedTimestamp`. This is the same push/pull/poke shape as `local-first-sync` — reference it. Combined with the SQLite cache, it gives offline-capable, bandwidth-bounded sync over a relational backend rather than a CRDT-native store.

## Known failure modes
1. **Concurrent reparent creating a cycle or duplicate subtree.** Two users move blocks into each other's subtrees offline. Production answer: a movable-tree CRDT with deterministic, cycle-free resolution (pick one move, re-home the other), not naive per-field LWW on `parent`.
2. **VACUUM stalls / capacity ceiling on the monolith.** Postgres autovacuum can't keep up and per-table/db limits loom. Production answer: shard by workspace_id into divisor-rich logical shards decoupled from physical hosts; this was Notion's actual trigger, not row count alone.
3. **Cross-workspace hot blocks (public templates).** A widely-duplicated public template breaks workspace locality. Production answer: read-only edge caching for hot public content; keep the write path workspace-local.

## (Spine note)
`notion` is the block-tree, relational-store flavor of collaborative editing; its offline path connects to `local-first-sync` (push/pull/poke + local SQLite) and `crdt-primitive` (per-field LWW + OR-Set + movable-tree CRDT). Storage-engine alternatives (globally-distributed) are infra-primitives `spanner` — reference, don't re-derive.

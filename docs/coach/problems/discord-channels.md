---
slug: discord-channels
archetype: interactive-messaging
sources:
  discord_trillions: discord.com/blog/how-discord-stores-trillions-of-messages
  discord_billions: discord.com/blog/how-discord-stores-billions-of-messages
  tns_scylla_migration: thenewstack.io/how-discord-migrated-trillions-of-messages-to-scylladb
  scylla_summit_bo_ingram: ScyllaDB Summit 2023 "How Discord Migrated Trillions of Messages" (Bo Ingram)
---

# Discord channels — message storage at trillion-message scale (Cassandra→ScyllaDB)

## Bar anchors
- **Mid-level (L4/E4):** Proposes a SQL DB partitioned by user. Doesn't address hot partitions on viral channels. Treats history scroll as a simple `ORDER BY timestamp DESC LIMIT N` without acknowledging the partition scan cost.
- **Senior (L5/E5):** Names Cassandra/ScyllaDB partition by channel + time-bucket. Discusses history-scroll via clustering order. May or may not address hot-partition mitigation, the JVM GC tail-latency story, or the migration playbook.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the Cassandra→ScyllaDB migration **with explicit numbers**: 177→72 nodes, 53% disk reduction, read p99 40-125ms→15ms, write p99 5-70ms→5ms. Identifies the **hot-partition problem on viral channels** and designs a **Rust data-services layer** doing **request coalescing** (multiple concurrent reads to the same partition collapse into one DB query) with **consistent-hash routing by channel_id** so coalescing actually works. Articulates why ScyllaDB over Cassandra: **C++ shard-per-core architecture eliminates JVM GC pauses** (the dominant p99 tail source). Names the **migration playbook**: dual-write → bulk-migrate via custom Rust migrator (3.2M records/sec, ETA 3 months → 9 days) → sample-read verification → cut over reads. Stretch (Sr Staff bar): articulates hybrid-RAID1 storage topology (local NVMe + persistent disk mirror for speed + durability); names the tombstone-heavy migration edge case (stall at 99.9999% fixed by forced compaction).

## Canonical decomposition

### Requirements
**Functional:**
- Store trillions of messages partitioned by channel
- History scroll p99 <10ms; reverse-chronological order (newest first)
- Survive viral channels with millions of messages/day
- Support edit + delete with tombstone semantics
- Migration playbook from Cassandra → ScyllaDB with zero downtime

**Non-functional (with numbers):**
- 177 Cassandra nodes → 72 ScyllaDB nodes (53% disk reduction)
- Read p99: 40-125ms (Cassandra) → 15ms (ScyllaDB)
- Write p99: 5-70ms → 5ms
- Migration throughput: 3.2M records/sec via custom Rust migrator
- Per-channel partition; time-bucketed within channel

### Core entities
- **Channel:** channel_id, guild_id?, created_at, settings
- **Bucket:** (channel_id, bucket_id) — time bucket within channel (e.g., 10-day buckets)
- **Message:** message_id (Snowflake-class, embeds timestamp), channel_id, bucket_id, author_id, content, edited_at?, deleted?
- **DataService:** Rust intermediary; per-channel coalescing queue; consistent-hash router
- **Migrator:** Rust bulk-copy job; sample-read verifier; tombstone-aware

### API
- `POST /channels/{id}/messages` — append; assigns Snowflake message_id; bucket derived from timestamp
- `GET /channels/{id}/messages?before=X&limit=50` — paginated history scroll; single-partition scan
- `PATCH /channels/{id}/messages/{msg_id}` — edit (writes new clustering-row with edited_at)
- `DELETE /channels/{id}/messages/{msg_id}` — tombstone

### HLD
Schema: `((channel_id, bucket_id), message_id)` — partition key is `(channel_id, bucket_id)`, clustering key is `message_id` (descending for reverse-chrono scroll). Each partition holds one time-bucket of messages for one channel; partition stays small enough to scan quickly. History scroll = single partition scan with clustering bound; multiple buckets fetched in sequence for older history. **Rust data-services layer** sits between API and ScyllaDB: receives reads, **coalesces** concurrent identical reads (multiple concurrent requests for `(channel=X, bucket=Y, before=Z)` collapse to one DB query, response broadcast back to all waiters); routes by **consistent-hash on channel_id** so all coalesce candidates for a channel hit the same data-services node (otherwise coalescing wouldn't work — concurrent reads on different nodes never see each other). **Storage topology** uses hybrid-RAID1: local NVMe SSD + persistent disk mirror — speed of local + durability of persistent. **Migration** (Cassandra → ScyllaDB): dual-write phase (writes go to both DBs); custom Rust bulk migrator with 3.2M records/sec throughput; sample-read verification (reads from both, compares); cut over reads.

### Deep dives
1. **Schema + hot-partition mitigation via data-services coalescing.** Partition by `(channel_id, bucket_id)`; bucket_id derived from timestamp (e.g., 10-day windows). For a viral channel with 1M msgs/day, each bucket holds 10M messages — too large; tune bucket size smaller for hot channels (1-day, 1-hour). History scroll touches recent buckets; reads localized. **Hot partition under viral spike** (e.g., World Cup, drop event): naive design floods the DB partition replicas; ScyllaDB shard-per-core helps but doesn't eliminate. **Data-services coalescing**: concurrent reads for same `(channel, bucket, before)` collapse to one DB query. Consistent-hash router ensures all candidates land on the same data-services node. Trade: coalescing requires sub-millisecond grouping window; too long = added latency; too short = misses coalescing opportunities.

2. **Why ScyllaDB over Cassandra — C++ shard-per-core vs JVM GC.** Cassandra is JVM-based; GC pauses (Stop-The-World or even concurrent-GC mark phases) cause p99 spikes. ScyllaDB is C++ with shard-per-core (each core owns a shard of data; no cross-core locking; no GC pauses). Reverse-query performance: ScyllaDB optimized for clustering-key reverse-scans (history scroll), Cassandra has historical perf issues there. Memory model: ScyllaDB uses Seastar framework (async I/O, kernel bypass for some workloads); Cassandra uses thread-per-request. Operational: ScyllaDB simpler tuning (per Discord); no JVM heap tuning. Result: 177 → 72 nodes (less compute needed); 53% disk reduction (better compaction); p99 read 40-125ms → 15ms.

3. **The migration playbook.** Phase 1: **dual-write** — writes go to both Cassandra and ScyllaDB; reads still from Cassandra. Phase 2: **bulk migrate** historical data — custom Rust migrator scans Cassandra in token-range order, writes to ScyllaDB; 3.2M records/sec sustained; ETA fell from 3 months (initial estimate with off-the-shelf tooling) to 9 days. **Tombstone-heavy ranges stalled migrator at 99.9999% completion** — tombstones don't carry data but consume scan time; fix was forced major compaction on those ranges before migration. Phase 3: **sample-read verification** — read same key from both DBs, compare; alert on mismatch. Phase 4: **cut over reads** — gradual percentage shift Cassandra → Scylla; full cutover when error rate stays clean. Phase 5: **decommission Cassandra**.

## Known failure modes
1. **Hot partition under viral spike** (World Cup goal, drop event → channel goes from 100 msg/min to 100K msg/min). Production answer: data-services coalescing flattens read spike before hitting DB; per-channel bucket-size tuning (smaller buckets for hot channels); ScyllaDB shard-per-core absorbs more write load than equivalent Cassandra cluster.

2. **Tombstone explosion from message deletes** (channel where many messages get deleted; tombstones accumulate in partitions). Production answer: per-channel TTL'd buckets (old buckets aged out entirely); scheduled compaction; for migration, forced compaction on tombstone-heavy ranges to unblock migrator.

3. **GC pause cascades** (Cassandra-era). One Cassandra node hits a long GC pause; coordinator times out; client retries pile onto remaining replicas; cascade. Production answer: ScyllaDB eliminates the class entirely (no GC). In the Cassandra era: aggressive heap tuning, GC algorithm choice (G1 vs CMS), speculative-retry config to avoid waiting for slowpokes.

## Notes for the coach
- **Asked-confirmed at Discord.** The Cassandra-to-Scylla migration story is explicit interview-prep canon; Bo Ingram's ScyllaDB Summit 2023 talk is the reference. **Plausibly-asked** at Slack, Snap.
- **The migration playbook is itself a Staff+ design.** Candidates who articulate dual-write → bulk-migrate → sample-verify → cut-over with explicit failure-mode handling (tombstone stalls) demonstrate the migration-design bar; candidates who say "we just switch" miss the playbook entirely.
- **The 177→72 nodes + 53% disk reduction numbers are the canonical anchors.** Memorize them.
- **Adversarial probe: "we have a 10M-member-viewers spike during one channel — what breaks first?"** Strong answer: data-services coalescing absorbs; if coalescing window too short, DB partition hits replica limit; per-channel sub-bucketing as escape. Weak answer: "add more nodes" without addressing the read-coalescing pattern.

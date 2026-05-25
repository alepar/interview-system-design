---
slug: instagram-feed
archetype: fan-out
sources:
  instagram_cassandra: sujeet.pro/articles/instagram-cassandra-migration
  discord_scylla: discord.com/blog/how-discord-stores-trillions-of-messages
  hello_interview_fb_feed: hellointerview.com/learn/system-design/problem-breakdowns/fb-news-feed
  pinterest_pixie: cs.stanford.edu/people/jure/pubs/pixie-www18.pdf
---

# Instagram feed — hybrid push/pull at ~1M-follower celebrity threshold + Cassandra wide-row inbox + Rocksandra/ScyllaDB lineage + Akkio microshard placement

## Bar anchors
- **Mid-level (L4/E4):** Push to all followers; reads from a single per-user inbox. No celebrity awareness; storage explodes on big accounts.
- **Senior (L5/E5):** Names hybrid push/pull at celebrity threshold. May or may not articulate the Cassandra wide-row schema, Rocksandra/ScyllaDB JVM-GC escape, or Akkio microshard placement.
- **Staff+ (L6/E6+):** Names (a) **hybrid threshold at ~1M followers** — non-celebrity push, celebrity pull-merged at read; (b) **two parallel threads at request time** (read inbox + fetch fresh celebrity content + merge); (c) **Cassandra wide-row** `((user_id), activity_id DESC)` so newest-N are physically first on disk; (d) **Rocksandra/ScyllaDB rescue from JVM GC** — Discord's published Cassandra→ScyllaDB migration is the public proxy (177→72 nodes, p99 reads 40-125ms→15ms); (e) **Akkio microshard placement** (OSDI 2018) — shrank connection-info from 5× full to 3× regional, ~50% latency & cross-DC traffic reduction; (f) **stories rail as separate fan-out path** with 24h TTL handled by Cassandra TTL not cron sweep.

## Canonical decomposition

### Requirements
**Functional:**
- Post image/video/carousel
- View home feed (chronological + algorithmic; this design covers fan-out only, ML ranking is separate)
- Follow/unfollow; block/mute
- Stories rail (24h ephemeral)

**Non-functional:**
- ~2B MAU; Instagram Cassandra fleet 1,000+ nodes, hundreds of TB, millions of ops/sec
- 1M+ write QPS; avg read 20ms / p99 ~100ms (2016 numbers)
- Celebrity threshold ~1M followers
- ~200 posts/user precomputed = ~4TB total
- <500ms read latency with 1-min eventual consistency tolerance

### Core entities
- **User:** user_id, follower_count, is_celebrity (cached flag)
- **Post:** post_id (TimeUUID), author_id, media_urls[], created_at
- **InboxEntry:** user_id (partition), post_id (TimeUUID DESC clustering)
- **Follow:** follower_id, followee_id
- **Story:** story_id, author_id, created_at, ttl=24h

### API
- `POST /posts` → {post_id}
- `GET /feed?cursor=<>&limit=20` → {posts[], next_cursor}
- `POST /follows`, `DELETE /follows/:id`
- `GET /stories?cursor=<>` → {stories[]}

### HLD
Write path: Post Service writes canonical post to Cassandra (sharded by author_id). Publishes `post.created` event to PinLater/Kafka. Fan-out Workers consume: fetch author's `is_celebrity` flag; if non-celebrity, push (user_id, post_id, TimeUUID) into each follower's inbox via Cassandra wide-row insert; if celebrity, skip push entirely. Inbox table: `((user_id), activity_id) WITH CLUSTERING ORDER BY (activity_id DESC)` — newest-N at top of partition. Write CL=TWO, read CL=ONE, LeveledCompaction.

Read path: Feed Service runs two parallel threads. Thread A: read user's inbox (LIMIT 50 from Cassandra wide row, already ordered DESC). Thread B: fetch followed-celebrity outboxes (each celebrity's recent posts cached in Redis with short TTL, shared across all viewers). Merge by TimeUUID; bulk-hydrate post objects from object cache (fallback to Cassandra base table). Return cursor for pagination.

Cassandra fronted by Rust data-services tier (request coalescing on consistent hash to collapse concurrent identical reads). Cross-region: Akkio microshards user data to geographically nearest DC; cross-region cache invalidation via PgQ events alongside replicated rows.

### Deep dives
1. **Hybrid fan-out + read-time merge.** Non-celebrity push to all followers' inboxes async via PinLater. Celebrity skips inbox write; pulled at read-time and merged by TimeUUID. Trade: read latency increases slightly for users following celebrities (most do), but write storm avoided. Threshold ~1M is configurable per-author.
2. **Cassandra wide-row + Rocksandra/ScyllaDB lineage.** Schema: partition_key=user_id, clustering=TimeUUID DESC → newest at top. Tombstone-heavy partitions on deletes cause read amplification. **Rocksandra** (CASSANDRA-13474) plugged RocksDB into Cassandra; GC stalls dropped 2.5%→0.3%; p99 read 60ms→20ms. **Discord's public Cassandra→ScyllaDB**: 177→72 nodes, p99 reads 40-125ms→15ms; Rust data-services with request coalescing.
3. **Akkio microshard placement + cross-region invalidation.** Akkio (OSDI 2018) places user's microshard in nearest DC; connection-info shrank 5×→3× regional. ~50% latency reduction. **Cross-region cache invalidation**: PgQ events alongside replicated rows; comment from region A invalidates follower's cached feed in region B.

## Known failure modes
1. *Hot partition cascade* on one user_id spikes one node's latency; quorum reads break across cluster. Production answer: Rust data-services coalescing requests by consistent-hash; ScyllaDB shard-per-core eliminates JVM GC tail.
2. *Celebrity backfill on follow* — new follower sees nothing from new celebrity until read-time merge. Production answer: async inbox-backfill worker walks new-followee's recent posts; or merge celebrity outbox at first read until backfill completes.
3. *Block/mute filtering trade* — write-time blocks save inbox storage (require scrub on block-list change); read-time mute reflects current state without scrub. Production: write-time for hard blocks, read-time for mute.

## Notes for the coach
- **Asked-confirmed at Meta/Instagram.** Hello Interview "Design Facebook News Feed" canonical.
- **Architectural opposite** of `linkedin-feed` (pull) and `reddit-feed` (community-scoped). Drill all three for the push-vs-pull-vs-hybrid trifecta.
- **The ~1M celebrity threshold + two-parallel-thread merge is the Staff+ unlock.**
- **Adversarial probe: "Lady Gaga has 80M followers and posts 5×/day. What's the storage bill if you push?"** Strong answer: 80M followers × 5 posts × 16 bytes/entry = ~6.4 GB/day per celebrity in inbox writes; multiply by celebrity count → push storage unfavorable; hybrid mandatory. Weak answer: "we'd scale Cassandra horizontally" without quantifying the cost vs read-time merge.

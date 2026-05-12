---
slug: twitter-timeline
archetype: fan-out
sources:
  hello_interview: hellointerview.com/learn/system-design/problem-breakdowns/twitter
---

# Twitter Home Timeline

## Bar anchors
- **Mid-level (L4/E4):** Produces a working fan-out-on-write OR fan-out-on-read architecture with a Redis cache for timelines. Defines post-tweet and get-timeline endpoints, estimates read/write ratio roughly (reads dominate), and picks a persistent tweet store (Postgres or similar). Does not need to identify the celebrity/high-follower problem or compare the two fan-out strategies unprompted.
- **Senior (L5/E5):** Explicitly compares fan-out-on-write vs fan-out-on-read — articulates write amplification vs read amplification trade-offs. Identifies the celebrity problem (a user with 10M followers triggers 10M Redis writes on a single tweet). Proposes a hybrid strategy: fan-out-on-write for normal users, fan-out-on-read for users above a follower threshold. Justifies Redis sorted sets for per-user timeline materialization and discusses TTL/eviction for inactive users.
- **Staff+ (L6/E6+):** Drives the session proactively. Raises timeline materialization storage cost (N users × M cached tweets × object size), Redis cluster sharding strategy for hot celebrity accounts, and multi-region replication latency for global timelines. Defines a fan-out lag SLO for high-throughput events (viral tweets, major live events), proposes priority queues and autoscaling for fan-out workers, and discusses ranked timeline scoring as an extension requiring a separate ML ranking step before delivery.

## Canonical decomposition

### Requirements
**Functional:**
- Post a tweet (text + optional media)
- View home timeline (chronological feed of followed users' tweets; optional ranked mode)
- Follow / unfollow a user
- Like and retweet

**Non-functional (with numbers):**
- 500M monthly active users; ~100M daily active users
- 200M tweets/day ≈ 2,300 writes/sec average; 20,000 writes/sec peak
- 100:1 read-to-write ratio → ~230,000 timeline reads/sec average
- Home timeline read latency <200ms p95
- Fan-out lag SLO: 95% of timelines updated within 5s of tweet creation
- 99.9% availability for the read path; writes can tolerate brief degradation

### Core entities
- **User:** user_id, username, follower_count, following_count, created_at
- **Tweet:** tweet_id, author_id, content (280 chars), media_urls[], created_at, like_count, retweet_count
- **Follow:** follower_id, followee_id, created_at
- **Like:** user_id, tweet_id, created_at
- **Timeline:** user_id, tweet_id, score (timestamp or ML score) — materialized cache entry

### API
- `POST /tweets` body={content, media_ids[]?} → {tweet_id, created_at}
- `GET /timeline?cursor=<cursor>&limit=<n>` → {tweets[], next_cursor}
- `POST /follows` body={followee_id} → {ok: true}
- `DELETE /follows/:followee_id` → 204 No Content
- `POST /likes` body={tweet_id} → {ok: true}

### HLD
The tweet write path lands on a stateless Tweet Service, which writes the canonical tweet record to a sharded Postgres cluster (sharded by author_id). The service then publishes a `tweet.created` event to a Kafka topic (partitioned by author_id). A pool of Fan-out Workers consumes from Kafka: for each tweet, a worker fetches the author's follower list from a Follow Service (backed by a Cassandra table keyed on followee_id) and, for each follower below the celebrity threshold (~10K followers), appends the tweet_id and score (Unix timestamp) to that follower's per-user Redis sorted set (ZADD). Each sorted set is capped at the most recent 800 entries via ZREMRANGEBYRANK.

The home timeline read path hits the Timeline Service: it reads the user's Redis sorted set to get an ordered list of tweet_ids, then bulk-fetches tweet objects from a Redis tweet object cache (populated on write; falls back to Postgres). The assembled list is returned in a single response with a cursor for pagination.

For celebrity accounts (follower_count > 10K), fan-out-on-write is skipped. Instead, when a user requests their timeline, the Timeline Service fetches the most recent tweets from each celebrity they follow (via the Tweet Service / Postgres read replica), merges them with the user's pre-materialized sorted set using a min-heap merge, and returns the unified result. Celebrity tweet lists are cached in Redis with a short TTL (30s) and shared across all viewers to amortize fetch cost.

All services are stateless and horizontally scalable behind an AWS ALB. Fan-out workers scale via Kafka consumer group lag metrics (KEDA or custom autoscaler). Postgres uses one primary and two read replicas per shard; Redis runs as a Redis Cluster across 6+ nodes with consistent hashing.

### Deep dives
1. **Fan-out-on-write vs fan-out-on-read** — Fan-out-on-write writes tweet_ids to every follower's timeline cache at write time; reads are O(1) sorted-set lookups. The cost is write amplification: a tweet by a user with 1M followers triggers 1M Redis writes. Fan-out-on-read avoids this by assembling the timeline on every read, but read amplification is O(followees × recent_tweets), making p95 latency blow out for users following thousands of accounts. The production answer is a hybrid: fan-out-on-write for users with follower_count ≤ threshold, fan-out-on-read for celebrities above threshold, with a merge step at read time.
2. **Celebrity problem and threshold tuning** — The threshold (e.g., 10K followers) is a configurable parameter. Above it, the fan-out worker skips the push. At read time the Timeline Service identifies which followees are "celebrities" (cached flag on User), fetches their recent tweets in parallel (bounded by a 50ms timeout), and merges via a k-way merge sort keyed on created_at. Celebrity tweet lists are stored in a shared Redis key (not per-viewer) with a 30s TTL; the cache is populated lazily on first miss and refreshed by a low-priority background job.
3. **Timeline storage cost and TTL** — Storing 800 tweet_ids per user × 100M DAU × 8 bytes ≈ 640 GB of Redis sorted-set data. Inactive users (no login in 30 days) are evicted with Redis key TTL (ttl=30d, refreshed on login). On re-login, a cold-start job reconstructs the timeline from Postgres (last N tweets from each followee). Storage cost is further reduced by storing only tweet_id (8 bytes) + score (8 bytes) in the sorted set, hydrating full tweet objects from a separate tweet object cache.

## Known failure modes
1. **Fan-out lag during viral or high-throughput events** — A single celebrity tweet or a major live event (Super Bowl) generates a spike of 50K+ tweets/sec. Fan-out workers fall behind; followers see stale timelines past the 5s SLO. Mitigation: autoscale workers via Kafka lag (KEDA); use a priority queue (separate Kafka topic) for high-urgency fan-outs; shed load by skipping fan-out for users inactive in the last 7 days during the spike.
2. **Hot celebrity account overload on read path** — A top-10 celebrity's shared Redis timeline key receives 500K reads/sec during a breaking-news moment. A single Redis node becomes a hotspot. Mitigation: replicate the celebrity timeline key across multiple Redis nodes (read replicas or consistent-hash ring with multiple slots); use local in-process caches (Caffeine, 1s TTL) on the Timeline Service pods to absorb burst traffic without hitting Redis on every request.
3. **Cross-region read consistency on follow updates** — A user follows a new account; the follow is written to the primary region's Cassandra, but the fan-out worker in a secondary region hasn't replicated the new follow yet. The new followee's tweets don't appear on the next timeline fetch. Mitigation: route follow writes to the home region and replicate asynchronously (Cassandra multi-region replication, typically <1s lag); document the acceptable window (up to 5s) in the API contract; use read-your-writes consistency for the following user by pinning their timeline reads to the primary for 10s after a follow action.

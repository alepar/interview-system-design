---
slug: tinyurl
archetype: caching-read-heavy
sources:
  hello_interview: hellointerview.com/learn/system-design/problem-breakdowns/bitly
---

# TinyURL (URL Shortener)

## Bar anchors
- **Mid-level (L4/E4):** Produces a working architecture with an encoder service, a persistent store (e.g., Postgres), and a Redis cache for hot redirects. Defines the shorten and redirect endpoints, estimates QPS roughly, and picks a reasonable encoding strategy (base62). Does not need to lead the collision or analytics conversation unprompted.
- **Senior (L5/E5):** Proactively compares counter-based vs random encoding, explains collision probability and retry budget, justifies cache-aside with LRU + TTL, designs the analytics path (async via Kafka) without losing the main flow. Covers cache eviction policy reasoning and mentions CDN for very-hot URLs. Handles interviewer probes on "what happens when Redis restarts?" with a concrete answer.
- **Staff+ (L6/E6+):** Drives the entire session. Proactively raises hot-URL stampede (thundering herd on viral links), encoder shard hotspot, multi-region read replica strategy, and cost analysis (storage, CDN egress, Redis memory at 100M codes). Proposes observable failure bounds: encoder retry SLA, cache hit-rate SLO, fallback path when cache is down. Discusses build-vs-buy (Bitly-style SaaS vs in-house) and operational cost trade-offs.

## Canonical decomposition

### Requirements
**Functional:**
- Shorten a long URL to a 6-7 character code
- Redirect a short code to the original URL (302 or 301)
- Optional: custom alias for the short code
- Optional: expiry / TTL per URL
- Optional: per-link click analytics (count, geography, referrer)

**Non-functional (with numbers):**
- 100M shortenings/month ≈ 40 writes/sec on average; burst to 4,000 writes/sec
- 10:1 read-to-write ratio → ~400 redirects/sec average; burst to 40,000 redirects/sec
- Redirect latency <100ms p95 (critical UX path)
- 5-year retention minimum; 365B codes over 5 years if uncapped
- 99.99% availability for the redirect path (revenue-impacting)
- Analytics ingestion can tolerate up to 60s lag

### Core entities
- **ShortURL:** code (PK), long_url, created_at, expires_at, user_id (nullable), custom (bool)
- **User:** user_id, email, created_at (optional — anonymous shortenings allowed)
- **Click:** click_id, code, timestamp, ip_address, user_agent, referrer

### API
- `POST /shorten` body={url, custom_alias?, ttl_seconds?} → {code, short_url, expires_at}
- `GET /:code` → HTTP 302 Location: long_url (redirect; 301 only if analytics not needed)
- `GET /:code/stats` → {total_clicks, clicks_by_day[], top_referrers[]} (analytics endpoint)
- `DELETE /:code` → 204 No Content (owner or admin only)

### HLD
The write path accepts a URL via `POST /shorten`. An Encoder Service generates a unique short code using a counter-based approach: a distributed ID generator (Snowflake or a DB sequence shard) produces a monotonically increasing integer, which is base62-encoded into a 6–7 character string. This avoids collision checking entirely for the normal path. The (code, long_url, metadata) record is written to a sharded Postgres cluster, sharded by consistent-hash on `code`. A write-through step populates Redis immediately so the first redirect is cache-hit.

The read path for `GET /:code` checks a Redis LRU cache first (cache-aside). On cache hit, the service returns a 302 redirect in <5ms. On cache miss, it queries the Postgres shard, writes back to Redis with a jittered TTL (base 24h ± 20%), and redirects. For URLs that go viral, a Cloudflare or Fastly CDN layer caches the 302 response at edge PoPs; this requires using a cacheable 302 (Cache-Control: max-age=3600) or a 301, which shifts the redirect to the browser.

Click events are fire-and-forget: the redirect service publishes a lightweight event `{code, ts, ip, ua, ref}` to a Kafka topic `clicks`. A Flink or Spark Streaming consumer aggregates click counts into ClickHouse (OLAP) for analytics queries, and into DynamoDB for per-code counters (cheap and fast key-value lookups). Deduplication on Kafka consumer retries is handled by a unique event_id in the payload; the consumer uses idempotent writes.

All services are horizontally scalable stateless instances behind an AWS ALB. Postgres uses one primary and two read replicas per shard for redirect fallback when Redis is cold. The Encoder Service's ID generation is the one stateful component and is protected by a ZooKeeper-managed token-range lease per instance.

### Deep dives
1. **Encoding scheme and collision handling** — Counter-based (Snowflake ID → base62) guarantees uniqueness without collision checks but exposes sequential codes, enabling enumeration. Random 6-char base62 gives 56B possibilities; collision probability is ~0.01% at 100M codes but retries (up to 3) handle it. Counter-based is preferred for throughput; random is preferred for privacy. A hybrid: random with a DB unique index and retry on `UNIQUE VIOLATION` (p(retry) < 0.001% at current scale) keeps code unpredictability while staying simple.
2. **Cache strategy** — Cache-aside with Redis LRU (maxmemory-policy: allkeys-lru). Hot-code TTL is jittered ±20% to prevent a mass expiry storm. Viral links that exceed 1,000 redirects/min are promoted to CDN edge cache (Cloudflare Workers KV) with a longer TTL, offloading origin entirely. On Redis restart, the cache is pre-warmed by a background job scanning the top-1,000 codes by recent click count from ClickHouse; this completes in <30s and reduces cold-start spike to origin.
3. **Analytics pipeline** — Redirect service publishes to Kafka `clicks` topic (replication factor 3, retention 7d). A Flink job consumes, deduplicates by event_id within a 5-minute window, and writes aggregated rollups (hourly, daily) into ClickHouse. Per-code running counters land in DynamoDB via a separate lightweight consumer. `GET /:code/stats` queries DynamoDB for totals and ClickHouse for time-series. At 40K redirects/sec burst, Kafka brokers are sized for 200MB/s ingress; Flink parallelism scales with consumer group lag.

## Known failure modes
1. **Hot-URL stampede (thundering herd on viral link)** — A viral link goes from 0 to 50K redirects/sec in seconds. A cold Redis cache means all requests hit Postgres simultaneously. Mitigation: cache-aside with a mutex (only one goroutine populates cache per key using SETNX with a short TTL lock); after population, all waiters read from cache. Longer-term: CDN edge cache absorbs steady-state traffic; Redis is the backstop, not the primary for true hot codes.
2. **Encoder collision at scale** — At 1B+ total codes, random-6-char collision probability rises to ~2%. Retry budget of 3 attempts with exponential backoff covers p99.99 of cases. Counter-based encoding eliminates collisions but requires the Snowflake service to be highly available (single point). Mitigation: two Snowflake instances with non-overlapping node-ID ranges; if both are down, fall back to crypto/rand with DB unique-index retry (graceful degradation, not outage).
3. **Cache cold start on Redis restart** — Unplanned Redis failover or planned restart causes all redirects to fall through to Postgres. With 40K redirects/sec, this saturates the DB in seconds. Mitigation: Redis Cluster (in-memory replication across 3 nodes, failover <30s); background pre-warm job restores top codes from ClickHouse; Postgres read replicas absorb read traffic during the warm-up window; circuit breaker reduces redirect retry storms.

# Caching

Pattern reference for `/study-patterns 3E`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3E.

## Where to Cache

**Definition.** Caching can be applied at multiple layers: client (browser/app cache), CDN (edge PoP), reverse proxy (Nginx/Varnish), app server (in-process memory), distributed cache (Redis/Memcached), DB query cache, and object/blob cache.

**Canonical use.** Cache static assets at the CDN, session tokens in a distributed cache (Redis), and expensive DB query results in an in-process LRU cache on the app server — layering caches so each layer absorbs the traffic that escaped the one above it.

**Production systems.** Cloudflare (CDN), Redis (distributed cache), Varnish (reverse proxy cache).

**Alternatives.** Collapsing all caching to one distributed cache layer (simpler ops, but higher latency than in-process); eliminating DB query cache in favor of read replicas.

## Cache Strategies

**Definition.** Cache-aside (lazy loading) populates the cache on miss; write-through updates cache and DB synchronously on every write; write-behind (write-back) updates the cache immediately and the DB asynchronously; refresh-ahead proactively reloads entries before they expire.

**Canonical use.** Use cache-aside for read-heavy workloads where most data is never accessed (cold data never pollutes the cache); use write-through when reads immediately follow writes and stale reads are unacceptable.

**Production systems.** Redis (used in all four modes depending on application logic), AWS ElastiCache.

**Alternatives.** Read-through cache (cache handles miss logic itself, e.g., NCache, Ehcache) to centralize cache-population logic; no cache (full DB reads) when data is too dynamic to benefit from caching.

## Eviction Policies

**Definition.** Eviction policies determine which entries are removed when the cache is full: LRU (Least Recently Used) evicts the longest-idle entry; LFU (Least Frequently Used) evicts the least-accessed; FIFO evicts the oldest inserted; TTL expires entries after a fixed time; ARC (Adaptive Replacement Cache) dynamically balances recency and frequency.

**Canonical use.** Use LRU as the default for general-purpose caches where recent access is a good proxy for future access; use LFU for media or recommendation caches where a small set of viral items should stay hot despite irregular access timing.

**Production systems.** Redis (LRU, LFU, TTL, and allkeys-* variants), Memcached (LRU with segmented LRU variant).

**Alternatives.** SLRU (Segmented LRU, Memcached default) to protect newly inserted items from being immediately evicted by a scan; size-tiered eviction for large objects where entry count alone is a poor proxy for memory pressure.

## Stampede Protection

**Definition.** Cache stampede (thundering herd) occurs when many concurrent requests miss on the same expired key and simultaneously query the DB; mitigations include request coalescing (one backend fetch, others wait), probabilistic early expiration (extend TTL stochastically before expiry), and distributed locks (only one process refreshes, rest serve stale).

**Canonical use.** Use request coalescing (a single in-flight lock per cache key) for high-QPS endpoints where a single key expiry would generate thousands of simultaneous DB queries.

**Production systems.** Redis (SETNX-based locks for stampede prevention), Nginx (proxy_cache_lock directive), Facebook Memcached (lease tokens).

**Alternatives.** Background refresh (a separate process reloads the cache before expiry, so users never see a miss); serve stale-while-revalidate to immediately return stale content while an async refresh proceeds.

## Hot-Key Mitigation

**Definition.** A hot key is a cache entry receiving a disproportionate fraction of requests (e.g., a celebrity's profile or a viral post), overwhelming a single cache node; mitigations include sharded counters (distribute writes across N keys), jittered TTL (randomize expiry to spread reloads), and replication of hot keys across multiple cache nodes.

**Canonical use.** For a viral post receiving millions of reads per second, replicate the cached object to N cache nodes and route each request to a random replica to distribute the load across the ring.

**Production systems.** Meta (hot-key replication in Memcached), Twitter (sharded counters for like counts), Redis Cluster (client-side routing to replicas).

**Alternatives.** Local in-process cache as a secondary layer (absorbs hot-key reads before they reach the distributed cache); read-through cache with automatic replication on high hit rate detection.

## Consistent Hashing with Virtual Nodes

**Definition.** Consistent hashing places both cache nodes and keys on a hash ring so that adding or removing a node reshuffles only K/N keys (K = total keys, N = nodes); virtual nodes (vnodes) assign each physical node multiple positions on the ring to ensure even distribution even with heterogeneous or few nodes.

**Canonical use.** Use consistent hashing with vnodes in a distributed cache (Memcached, Redis Cluster) so that scaling the cluster from 10 to 11 nodes only migrates ~9% of keys instead of remapping the entire keyspace.

**Production systems.** Amazon DynamoDB (consistent hashing internally), Apache Cassandra (token ring with vnodes), Memcached client libraries (ketama algorithm).

**Alternatives.** Rendezvous hashing (highest random weight) for simpler implementation with similar properties; modulo hashing (simple, but full remap on resize — avoid for mutable clusters).

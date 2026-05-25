---
slug: product-catalog
archetype: caching-read-heavy
sources:
  hi_caching: hellointerview.com/learn/system-design/core-concepts/caching
  aws_caching_library: aws.amazon.com/builders-library/caching-challenges-and-strategies/
  prime_day_2024: aws.amazon.com/blogs/aws/how-aws-powered-prime-day-2024-for-record-breaking-sales/
  swr_webdev: web.dev/articles/stale-while-revalidate
  cloudfront_hit_ratio: docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cache-hit-ratio.html
---

# Product Catalog (read-heavy e-commerce reads with freshness)

## Bar anchors
- **Mid-level (L4/E4):** Reads product rows from the DB on each page view and "caches them." Doesn't address staleness on price/inventory change, the read:write skew, or spike handling.
- **Senior (L5/E5):** Cache-aside product data in Redis with TTL, CDN for images, invalidate on update, read replicas for the DB. Knows reads dominate. May not articulate the write-strategy choice (cache-aside vs write-through), cache-key normalization, stale-while-revalidate, or the latency-revenue link.
- **Staff+ (L6/E6+):** Drives proactively. Picks a **caching strategy by data volatility**: cache-aside (lazy, delete-on-write) for the bulk; write-through where reads ≫ writes *and* freshness matters; a **denormalized/materialized read model** (CQRS) so a product page is one read, not a multi-table join. Splits **static (CDN-cached images, `max-age` 7d, 80–95% hit) from dynamic/per-user (browser-only, not shared-edge)**, and normalizes the **cache key** (forward `product_id`, not `session_id`). Handles **price/inventory freshness** via **event-driven invalidation** (price-change event → Redis Pub/Sub evict, or tag/group invalidation) and **stale-while-revalidate** / soft-TTL+hard-TTL (serve stale if downstream is down). Defends the **latency-revenue link** (Amazon: +100ms ≈ −1% sales) and spike handling (Prime Day 2024: CloudFront 1.3T requests, DynamoDB 146M req/sec at single-digit-ms; predictive autoscale + cache + read replicas). Adds **negative caching** for 404s.

## Canonical decomposition

### Requirements
**Functional:**
- Serve product detail pages (metadata, price, availability, images) at very high read volume
- Reflect price/inventory changes within a bounded staleness window
- Survive shopping spikes (Black Friday / Prime Day) without origin overload

**Non-functional (with numbers):**
- Massively read-heavy (100:1+); latency monetized (+100ms ≈ −1% sales)
- CDN static-asset hit ratio 80–95%; images `Cache-Control: max-age=604800` (7d)
- Spike scale: CloudFront 1.3T requests, DynamoDB 146M req/sec (Prime Day 2024)
- Price/inventory freshness within seconds (event-driven invalidation)

### Core entities
- **Product:** sku, title, attributes, price, availability, image refs (mostly-read, occasionally-updated)
- **Materialized read model:** denormalized product view (one read, no joins)
- **Cache entry:** product:{sku} in Redis (cache-aside) + images at CDN edge
- **Invalidation event:** price/inventory change → evict/refresh the affected entries

### API
- `GET /product/{sku}` → cache-aside Redis (→ DB/read-replica on miss); images via CDN
- price/inventory update → publish invalidation (Pub/Sub) → evict product:{sku}
- CDN cache for `/images/...` with long max-age + purge-on-update

### HLD
A product page is read orders of magnitude more than it's written, so the design is read-optimized. Product metadata is served **cache-aside** from Redis (read cache → DB/read-replica on miss → populate cache with TTL; **delete-on-write** rather than update-on-write to avoid stale entries), and the underlying read is a **denormalized/materialized read model** (CQRS-style) so one page = one read, not a multi-table join. **Static assets** (images, CSS) are cached at the **CDN edge** with long `max-age` (e.g. 7 days, 80–95% hit), while **dynamic/per-user** bits (the signed-in name, cart) are cached only in the **browser**, never the shared edge — and the **cache key** is normalized (forward `product_id`, drop `session_id`, consistent case) so equivalent requests share one object.

**Freshness** is the central tension: price and availability change occasionally but must not be wildly stale. The answer is **event-driven invalidation** — a price/inventory change publishes an event (Redis Pub/Sub, or tag/group invalidation for all entries dependent on a product) that evicts/refreshes the affected cache entries within seconds — combined with **stale-while-revalidate** (serve the slightly-stale value instantly while refreshing) and the AWS **soft-TTL/hard-TTL** pattern (refresh at the soft TTL, but keep serving up to the hard TTL if the downstream is unavailable — trading freshness for resilience). **Spikes** (Prime Day: CloudFront 1.3T requests, DynamoDB 146M req/sec at single-digit-ms) are absorbed by the CDN + read replicas + cache, with predictive autoscaling and pre-warmed caches for promoted products. Latency is treated as **revenue** (+100ms ≈ −1% sales), so p99 on the read path is a business SLO. **Negative caching** (cache 404s briefly) stops repeated misses for nonexistent SKUs from hammering origin.

### Deep dives
1. **Caching strategy by volatility + the read model.** Not all product data is equal: titles/descriptions/images are near-static (long-TTL, CDN), price/availability are volatile (short-TTL or event-invalidated). Cache-aside with delete-on-write is the default; write-through fits where reads ≫ writes and freshness is required and write volume is low. Underneath, a **materialized read model** (denormalized product view, updated from write-side events) turns a page render into a single read — the CQRS payoff for a read-heavy surface. The Staff+ point: choose the cache pattern and TTL *per field class*, not one policy for the whole product.
2. **Freshness vs staleness: invalidation + stale-while-revalidate.** The hard requirement is "price changed → don't show the old price for long" without making every read hit the DB. Event-driven invalidation (price-change event → Pub/Sub evict, or tag-based group invalidation for all dependent entries) bounds staleness to seconds; **stale-while-revalidate** hides refresh latency (serve stale, refresh async); **soft-TTL/hard-TTL** (AWS Builders' Library) adds resilience — refresh at soft TTL, but keep serving up to hard TTL if the pricing service is down. The framing: pick the staleness window per field (a 7-day image vs a 10-second price) and back it with explicit invalidation, not just TTL expiry.
3. **Spike handling + the latency-revenue link.** A flash sale concentrates reads on a few hot products; the cache + CDN + read replicas absorb it, but hot keys need stampede protection (single-flight, probabilistic early expiration, TTL jitter) and pre-warming of promoted SKUs. The business framing makes this non-optional: Amazon's "+100ms ≈ −1% sales" means p99 on the product read is a revenue metric, justifying the caching investment (Prime Day proves the scale: CloudFront 1.3T requests, DynamoDB 146M req/sec, single-digit-ms). Negative caching protects against miss-storms on bad/expired SKUs.

## Known failure modes
1. **Stale price/availability shown to buyers.** A price change doesn't reach the cache and customers see the old price. Production answer: event-driven invalidation (Pub/Sub / tag-group) bounding staleness to seconds + short TTL on volatile fields + query-time check at checkout (the authoritative price is re-validated on purchase).
2. **Hot-product cache stampede on a flash sale.** A promoted SKU's entry expires under peak load and the origin is flooded. Production answer: single-flight coalescing, probabilistic early expiration, TTL jitter, and pre-warm promoted products before the sale.
3. **Cache-key fragmentation / low hit ratio.** Forwarding session/user params caches per-user copies of shared content. Production answer: normalize the cache key (forward only product-identifying params), split per-user bits to browser-only caching, keep shared content shared.

## (Delineation note)
`product-catalog` is the read-heavy-with-freshness caching problem. The inventory **reservation/oversell** logic is the concurrent-resource archetype (`ticketmaster`) — referenced, not re-derived; product **search** is search-indexing (`amazon-product-search`); the object store/CDN are infra-primitives / `cdn-edge-cache`. Here it's cache strategy + invalidation + freshness for read-dominant catalog reads.

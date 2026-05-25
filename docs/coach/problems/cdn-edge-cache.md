---
slug: cdn-edge-cache
archetype: caching-read-heavy
sources:
  fastly_purge: fastly.com/blog/fastly-instant-purge-under-150ms-for-over-a-decade
  fastly_surrogate_keys: fastly.com/documentation/guides/full-site-delivery/purging/working-with-surrogate-keys/
  cloudflare_instant_purge: blog.cloudflare.com/instant-purge/
  cloudfront_origin_shield: docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/origin-shield.html
  mdn_cache_control: developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control
---

# CDN / Edge Cache (designing the content-delivery cache + purge)

## Bar anchors
- **Mid-level (L4/E4):** "Put a CDN in front." Knows it caches content near users. Doesn't address cache keys, TTL/headers, invalidation, or the cache hierarchy.
- **Senior (L5/E5):** Edge PoPs cache content by URL with TTL/Cache-Control; origin on miss; purge on update. Knows hit ratio matters and there's an origin-shield/tiered layer. May not articulate cache-key design, surrogate-key (tag) purge, the edge/shield purge race, or per-tier Cache-Control.
- **Staff+ (L6/E6+):** Drives proactively. Designs the **edge → shield/tiered → origin** hierarchy (origin shield collapses many regional misses into ~one origin fetch; CloudFront reports up to **57% origin-load / 67% p90-latency** reduction). Designs the **cache key** (normalize query params — forward only meaningful ones, consistent case — to avoid caching duplicates) and **per-tier Cache-Control** (`s-maxage` for shared/CDN vs `max-age` for browser; `stale-while-revalidate`, `stale-if-error`). Owns **invalidation**: purge-by-URL, **purge-by-surrogate-key/tag** (one request purges all objects sharing a key — e.g. all pages referencing an article), soft-purge (mark stale + revalidate). Knows purge is **fast and distributed** (Fastly ~**150ms** globally via a gossip variant, 256-key batches; Cloudflare coreless purge <150ms p50) and the **edge/shield purge-ordering race** (purge twice ~2s/~30s apart). Uses **consistent/rendezvous hashing** for edge routing + hot-object handling. Targets 90%+ hit ratio.

## Canonical decomposition

### Requirements
**Functional:**
- Cache content at edge PoPs near users; fetch from origin on miss; serve with low latency
- Invalidate/purge content on update at multiple granularities (URL, tag, prefix, all)
- Control freshness per tier (browser vs shared CDN cache)
- Protect the origin (collapse misses, serve stale on error)

**Non-functional (with numbers):**
- Target hit ratio 90%+; origin shield up to 57% origin-load / 67% p90 reduction
- Purge propagation ~150ms globally (Fastly/Cloudflare); 256 surrogate keys/batch
- Edge/shield purge race ⇒ purge twice (~2s single-key, ~30s purge-all)
- Multi-granularity purge: URL, surrogate key/tag, hostname, prefix, all

### Core entities
- **Edge PoP:** caches objects; serves from cache or fetches from origin/shield
- **Shield / upper tier:** the only tier that talks to origin (request collapsing)
- **Cache key:** identifies a cached object (URL + normalized headers/query)
- **Surrogate key (tag):** groups objects for tag-based purge

### API
- `GET <url>` → edge cache → shield → origin on miss; served per Cache-Control
- purge by URL / surrogate-key / prefix / hostname / all
- soft-purge: mark stale (serve stale + revalidate) vs hard purge (evict)

### HLD
Content is cached at **edge PoPs** near users; a request is served from the edge if warm, else forwarded up a **hierarchy** — to a **shield / upper-tier** PoP and only then to **origin**. The shield exists to **collapse requests**: many regional edge misses for the same object funnel through one upper-tier node that makes ~one origin fetch (CloudFront Origin Shield reports up to 57% origin-load and 67% p90-latency reductions). The **cache key** decides hit ratio: normalize the URL + headers (forward only meaningful query params like `product_id`, drop `session_id`, normalize case) so equivalent requests share one cached object rather than fragmenting the cache. **Cache-Control** sets freshness per tier — `s-maxage` for the shared/CDN cache, `max-age` for the browser, plus `stale-while-revalidate` (serve stale, refresh async) and `stale-if-error` (serve stale if origin is down); `CDN-Cache-Control` lets the origin target CDN tiers separately.

**Invalidation** is the hard half. Purge granularities: by **URL**, by **surrogate key/tag** (tag content with keys so "purge all pages referencing article X" is one request — purge-by-tag, not by enumerating URLs), by **hostname/prefix**, and **purge-all** (heaviest). Modern CDNs purge **fast and globally**: Fastly distributes purges via a **gossip-protocol variant** in ~150ms (256 surrogate keys per batch); Cloudflare's coreless purge hits <150ms p50. With a shield hierarchy, purge ordering is **non-deterministic** — an edge can re-fill from a not-yet-purged shield — so the mitigation is to **purge twice** (~2s apart for single-object/key, ~30s for purge-all). **Soft purge** (mark stale + revalidate) avoids a stampede on purge by serving stale while refetching. Edge routing/placement uses **consistent or rendezvous hashing** so a node failure remaps only its keys (the rest of the cache stays warm), with extra virtual nodes / replication for hot objects.

### Deep dives
1. **Cache-key design + per-tier Cache-Control.** Hit ratio is governed by the cache key and the TTL. A sloppy key (forwarding `session_id`, inconsistent case, all query params) caches the *same* content under many keys, tanking hit ratio; normalizing to the semantically-relevant params collapses them. Per-tier freshness uses `s-maxage` (shared/CDN) distinct from `max-age` (browser) so the CDN can hold content for 10 minutes while browsers hold it for 1, plus `stale-while-revalidate`/`stale-if-error` for graceful degradation. The Staff+ point: most "low hit ratio" problems are cache-key hygiene, not cache size.
2. **Invalidation: surrogate keys + the purge race.** Purge-by-URL doesn't scale when one logical change affects many URLs (an article shown on the homepage, category pages, and itself). **Surrogate keys/tags** solve this: tag objects with keys (`article:123`), and one purge-by-tag invalidates all of them. The subtle correctness issue is the **edge/shield ordering race**: a request can hit a purged edge, miss, and re-fill from a shield that hasn't been purged yet — re-caching stale content. The fix is to **purge twice** with a gap (~2s single-key, ~30s purge-all) so the shield is clean before the edge refetches. Soft-purge (serve stale + revalidate) avoids a thundering herd at purge time.
3. **Hierarchy + origin protection + edge routing.** Tiered cache / origin shield is the request-collapsing layer that turns N regional misses into ~1 origin fetch — the single biggest origin-protection lever (57%/67% reductions). Within a tier, **consistent hashing** (or rendezvous/HRW hashing) maps objects to edge nodes so a node loss remaps only its share (the rest stays warm — critical because a miss is an expensive cross-globe origin fetch). A single overwhelmingly-hot object still hot-spots one node, so allocate more virtual nodes to higher-capacity nodes or replicate the hot object. `stale-if-error` + generous grace keep the edge serving during an origin outage. The framing: the hierarchy and hashing exist to keep the origin idle and the cache warm through failures.

## Known failure modes
1. **Stale content after purge (edge/shield race).** An edge re-fills from a not-yet-purged shield. Production answer: purge twice with a gap (~2s key, ~30s all), or purge top-down with confirmation; soft-purge to serve stale safely meanwhile.
2. **Low hit ratio from bad cache keys.** Forwarding volatile params (session_id) fragments the cache. Production answer: normalize the cache key to semantically-relevant params, consistent casing, vary only on what matters.
3. **Hot object / origin overload on miss.** A single viral object hot-spots one edge node or a miss-storm hits origin. Production answer: origin shield/tiered cache (request collapsing), replicate/extra-vnode the hot object, single-flight on miss, stale-while-revalidate.

## (Delineation note)
`cdn-edge-cache` is the generic content-delivery-cache + invalidation primitive that `news-homepage`, `wikipedia`, `pastebin`, and `product-catalog` build on. DNS-based traffic steering to PoPs is `dns`; the object store is infra-primitives `s3`. Here it's edge hierarchy + cache-key + surrogate-key purge.

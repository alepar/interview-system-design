---
slug: wikipedia
archetype: caching-read-heavy
sources:
  wm_figures: meta.wikimedia.org/wiki/Wikimedia_in_figures_-_Wikipedia
  wm_cdn_ats: techblog.wikimedia.org/2020/11/25/wikimedias-cdn-the-road-to-ats/
  wm_caching_overview: wikitech.wikimedia.org/wiki/Caching_overview
  mw_parser_cache: mediawiki.org/wiki/Manual:Parser_cache
  wm_kafka_purge: wikitech.wikimedia.org/wiki/Kafka_HTTP_purging
---

# Wikipedia (read-heavy article serving with edit invalidation)

## Bar anchors
- **Mid-level (L4/E4):** Renders articles from the DB on each request and "caches popular ones." Doesn't address the read:write skew, the rendering cost, or invalidation on edit.
- **Senior (L5/E5):** Multi-tier cache (edge CDN → app → DB) with a high hit ratio, a render/parser cache for article HTML, and purge-on-edit. Knows reads massively outnumber edits. May not quantify the tiers, articulate cascading invalidation (templates), or the reliable purge pipeline.
- **Staff+ (L6/E6+):** Drives proactively. Quantifies the workload — Wikimedia ~**10,000 page views/sec**, English Wikipedia ~**4,500 views/sec vs ~2 edits/sec (~2000:1 read:write)**, 296B views in 2024 — and the **cache tiers**: a CDN frontend (in-memory Varnish, **90–99% hit**) over an on-disk backend (ATS, only **2–4% of backend traffic**), with **>90% of reads served by the CDN** before touching MediaWiki. Below the CDN, the **parser cache** stores rendered article HTML in two tiers (Memcached + MySQL, 18 shards) since re-rendering wikitext is expensive. Owns **invalidation on edit**: an edit (or a cascading template/Wikidata change) must **purge the affected URLs** from edge caches; Wikimedia moved from unreliable **HTCP multicast UDP** to a **Kafka-based purge pipeline** (MediaWiki → Kafka → Purged → Varnish/ATS) for reliable fan-out. Notes admission policies (size-based + probabilistic) deciding RAM vs disk.

## Canonical decomposition

### Requirements
**Functional:**
- Serve article pages to a massive read audience with low latency
- Re-render and invalidate caches correctly when an article (or a template it uses) is edited
- Cascading edits (a template/Wikidata item used by millions of pages) propagate correctly

**Non-functional (with numbers):**
- ~10,000 views/sec (Wikimedia); EN WP ~4,500 views/sec vs ~2 edits/sec (~2000:1)
- CDN frontend hit ratio 90–99%; on-disk backend only 2–4% of backend traffic
- >90% of reads served by the CDN without reaching MediaWiki
- Parser cache in Memcached (tier 1) + MySQL (tier 2), 18 shards

### Core entities
- **Article (page):** wikitext source → rendered HTML (the expensive product)
- **Parser cache:** rendered HTML cache (Memcached + MySQL tiers)
- **CDN cache:** Varnish (in-memory frontend) + ATS (on-disk backend)
- **Purge event:** an invalidation message for the URLs affected by an edit

### API
- `GET /wiki/{Article}` → served from CDN (90%+); parser cache → render on deeper miss
- edit → save → enqueue purge for affected URLs (incl. cascading dependents)
- purge: MediaWiki → Kafka → Purged → Varnish/ATS PURGE

### HLD
The workload is overwhelmingly **read** (EN Wikipedia ~4,500 views/sec vs ~2 edits/sec, ~2000:1), so the architecture is a stack of read caches. The **CDN frontend** (in-memory **Varnish**) absorbs **90–99%** of requests; misses fall to an **on-disk backend (ATS)** that serves only **2–4%** of backend traffic; overall **>90% of reads never reach MediaWiki**. When a request does reach the application, the **parser cache** returns the article's pre-rendered HTML (rendering wikitext — templates, links, parser functions — is CPU-expensive), stored in two tiers: **Memcached** (tier 1, 18-shard pool) and **MySQL** (tier 2). **Cache admission** policies (a size cutoff plus a probabilistic policy whose admission probability decreases with object size) decide what stays in fast RAM vs disk.

The hard part is **invalidation on edit**. When an article is edited, its rendered HTML and its CDN-cached URLs are stale and must be **purged**; worse, edits **cascade** — editing a widely-used template or a Wikidata item invalidates *every* page that transcludes it (potentially millions). MediaWiki computes the affected URLs (`CdnCacheUpdate::purge`) and must fan the purge out reliably to all edge nodes. Wikimedia originally used **HTCP multicast UDP**, which proved unreliable at high purge rates, and moved to a **Kafka-based pipeline** (MediaWiki → Kafka → a "Purged" consumer → Varnish/ATS PURGE) so purges are durably delivered even under load. Busy frontend nodes peak >10,000 rps *including* PURGE traffic, which set the design target.

### Deep dives
1. **The read-cache stack + parser cache.** Two distinct caching layers solve two distinct costs: the **CDN (Varnish/ATS)** eliminates network + app round-trips for the 90–99% of identical anonymous reads, while the **parser cache** eliminates the *rendering* cost (wikitext→HTML) for the misses that reach MediaWiki. Splitting them matters because they're invalidated differently (a CDN purge vs a parser-cache regeneration) and tiered differently (RAM Varnish vs RAM Memcached + MySQL). The admission policy (probabilistic, size-decreasing) is the refinement that keeps the hottest small objects in RAM. The Staff+ framing: cache the *expensive computed artifact* (rendered HTML), not just the bytes, and tier by cost.
2. **Edit invalidation + cascading dependencies.** A read-heavy system with edits lives or dies on invalidation correctness. A simple article edit purges its own URLs; the hard case is **cascading**: a template or Wikidata item is transcluded by millions of pages, so one edit invalidates a huge dependency set. The system must enumerate dependents and purge them all — bounded and rate-limited so a single high-fan-out edit doesn't become a purge storm. This is the canonical "invalidation is the hard part of caching" lesson, with a real dependency graph behind it.
3. **Reliable purge fan-out (HTCP→Kafka).** Invalidation is only correct if the purge actually reaches every edge node; a dropped purge means users see stale content indefinitely (until TTL). Wikimedia's evolution — from **HTCP multicast UDP** (fast but lossy at high rates) to a **Kafka pipeline** (durable, replayable, ordered fan-out: MediaWiki → Kafka → Purged → Varnish/ATS) — is the Staff+ story: at scale, invalidation needs a reliable delivery substrate, not best-effort multicast. The tradeoff is added latency/infra for guaranteed delivery; the alternative (lost purges) is a correctness bug, not just a performance one.

## Known failure modes
1. **Lost purge ⇒ persistent stale article.** A dropped invalidation leaves the old version cached until TTL. Production answer: a durable purge pipeline (Kafka) with retries/ordering instead of best-effort UDP multicast; bounded TTLs as a backstop.
2. **Cascading-edit purge storm.** Editing a popular template invalidates millions of pages at once, flooding the purge system. Production answer: rate-limit/batch cascading purges, prioritize, and lean on TTL expiry for the long tail rather than purging everything instantly.
3. **Render thundering herd on a hot article miss.** A popular article's parser-cache entry expires and many requests trigger expensive re-renders. Production answer: single-flight on render, stale-while-revalidate from the CDN, and pre-render/warm popular pages after an edit.

## (Delineation note)
`wikipedia` is the read-heavy-with-edits + cache-invalidation problem (the article-with-mutations cousin of `news-homepage`'s mostly-static content). Generic CDN purge mechanics are `cdn-edge-cache`; the object store is infra-primitives `s3`; Kafka itself is infra-primitives. Here it's the read-cache stack + correct invalidation under cascading edits.

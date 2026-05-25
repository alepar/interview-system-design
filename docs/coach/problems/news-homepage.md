---
slug: news-homepage
archetype: caching-read-heavy
sources:
  cache_stampede: systemoverflow.com/learn/design-fundamentals/scalability-fundamentals/cache-stampede-and-thundering-herd-when-everyone-asks-at-once
  xfetch: cseweb.ucsd.edu/~avattani/papers/cache_stampede.pdf
  varnish_esi: varnish-cache.org/docs/6.0/users-guide/esi.html
  fastly_offload: fastly.com/resources/ebook/cache-the-uncacheable-and-save-huge-on-egress
  varnish_grace: info.varnish-software.com/blog/two-minute-tech-tuesdays-grace-mode
---

# News Homepage (extreme-read content under spikes)

## Bar anchors
- **Mid-level (L4/E4):** Serves pages from the app/DB and "adds a cache." Doesn't address traffic spikes, cache-miss stampedes, or the multi-tier topology.
- **Senior (L5/E5):** Multi-tier cache (browser → CDN → reverse proxy → app → DB), full-page caching for anonymous traffic, high hit ratio. Knows breaking news invalidates caches. May not articulate the thundering-herd/stampede defenses, fragment (ESI) caching, or the offload math.
- **Staff+ (L6/E6+):** Drives proactively. Lays out the **multi-tier read path** (browser → CDN edge → reverse proxy/Varnish → app → DB) and quantifies **offload** (a great CDN offloads 95%; improving 90%→95% *halves* origin load — "5% offload = 50% fewer origin servers"). Names and solves the **cache stampede / thundering herd** on a hot-article miss with **request coalescing / single-flight** (10,000 simultaneous misses → 1 origin fetch), **stale-while-revalidate** (serve stale instantly, refresh in background), **TTL jitter** (±10–20% to desync expirations), and **probabilistic early expiration / XFetch** (recompute before expiry with rising probability — `Δ·β·log(rand())`, proven optimal vs uniform). Uses **Edge-Side Includes (ESI)** to cache shared fragments (e.g. "most-popular" widget) once and include them across pages. Handles **breaking-news invalidation** (purge/short-TTL the changed pages) and serves stale-if-error for resilience.

## Canonical decomposition

### Requirements
**Functional:**
- Serve news pages to a massive, mostly-anonymous, read-heavy audience with low latency
- Survive traffic spikes (a breaking story) without melting the origin
- Update pages quickly when news breaks (bounded staleness / fast invalidation)

**Non-functional (with numbers):**
- Massively read-heavy; target CDN hit ratio 90–95%+
- 90%→95% offload halves origin miss load (5% offload ≈ 50% origin servers)
- Spike: requests/sec can jump orders of magnitude on a breaking story
- Breaking-news freshness within seconds to low minutes

### Core entities
- **Page / fragment:** full page or an ESI fragment, each with its own cache policy/TTL
- **Cache tier:** browser, CDN edge, reverse proxy (Varnish), app, DB
- **Surrogate key / tag:** groups cached objects for targeted purge on update

### API
- `GET /article/{id}` → served from the nearest warm cache tier; origin on miss
- ESI: page template includes `<esi:include src="/fragment/most-popular"/>`
- purge: `PURGE` by URL or surrogate-key on content update

### HLD
The read path is a **cache hierarchy**: the browser cache, then the **CDN edge** (the bulk of offload), then a **reverse proxy (Varnish)**, then the app, then the DB. The goal is to answer almost everything from an upstream tier so the origin sees only a trickle — and the math is steep: improving CDN offload from 90% to 95% *halves* the origin miss rate (10%→5%), roughly halving origin servers/cost. Anonymous news traffic is highly cacheable (everyone gets the same page), so **full-page caching** dominates; per-user bits (if any) are split out as separate **ESI fragments** with their own TTLs, and shared widgets (a "most-popular articles" list) are cached **once** and included across all pages, lifting hit ratio.

The danger is the **cache stampede**: when a hot article's cache entry expires, thousands of concurrent requests all miss and hit the origin at once. Defenses: **request coalescing / single-flight** (only one request regenerates; the rest wait and share — 10,000 misses → 1 origin query); **stale-while-revalidate** / Varnish **grace mode** (serve the stale copy instantly while refreshing in the background — eliminates the stampede at the cost of brief staleness); **TTL jitter** (±10–20% randomization so many keys don't expire simultaneously); and **probabilistic early expiration (XFetch)** (recompute a value before its TTL with probability rising as expiry nears — `Δ·β·log(rand())`, proven optimal vs a uniform distribution). **Breaking-news invalidation** purges or short-TTLs the changed pages/fragments (by surrogate key), and **stale-if-error** serves the last good copy if the origin is down. The whole design is "keep the origin idle; absorb spikes and misses in the cache tiers."

### Deep dives
1. **Cache stampede / thundering herd — the central failure.** A single hot key expiring under high concurrency is the classic news-site outage. Walk the four complementary defenses: **single-flight** (a lock/coalescing so one request fetches, others wait — turns N misses into 1), **stale-while-revalidate/grace** (return stale immediately, refresh async — removes the synchronous miss entirely), **TTL jitter** (desync expirations across keys), and **probabilistic early expiration** (XFetch: `Δ·β·log(rand())` recomputes early with rising probability; Vattani et al. proved the exponential distribution optimal vs uniform). The Staff+ signal is naming more than one and explaining the tradeoff (staleness vs origin protection).
2. **Multi-tier topology + the offload math.** Each tier exists to shrink what reaches the next: browser cache (repeat visits), CDN edge (geographic + the bulk of offload), reverse proxy (datacenter-local + ESI assembly), app, DB. The non-obvious lesson is the **nonlinear value of hit ratio**: at 90% hit, 10% misses reach origin; at 95%, only 5% — so a 5-point hit-ratio gain *halves* origin load and cost. This reframes "make the cache a bit better" as "halve the fleet," and justifies investing in cacheability (ESI fragmentation, cache-key hygiene, longer TTLs where safe).
3. **Fragment (ESI) caching + invalidation.** A news page mixes long-lived content (the article body) with shared/short-lived widgets (most-popular, live-updating tickers). **ESI** lets the edge assemble a page from independently-cached fragments, each with its own TTL — so the article caches for minutes while the "breaking" ticker caches for seconds, and a shared widget is cached once and reused across thousands of pages. **Invalidation** on an edit purges just the affected fragment/page (surrogate-key purge), not the whole site. The tradeoff: fragmentation raises hit ratio and update granularity but adds assembly complexity at the edge.

## Known failure modes
1. **Cache stampede on a breaking story.** A hot article's entry expires and the origin is flooded. Production answer: single-flight coalescing + stale-while-revalidate/grace + TTL jitter + probabilistic early expiration; the origin should never see a thundering herd.
2. **Stale breaking news.** A correction/update doesn't reach readers because caches hold the old page. Production answer: surrogate-key purge on edit + short TTLs on volatile fragments; balance freshness against hit ratio per fragment.
3. **Origin outage during a spike.** The origin falls over exactly when traffic peaks. Production answer: stale-if-error (serve last good copy), generous grace windows, autoscale origin, and shed/queue low-value traffic — degrade to slightly-stale rather than down.

## (Delineation note)
`news-homepage` is the extreme-read content-serving + stampede-defense problem. The generic CDN/edge-cache design + purge mechanics are `cdn-edge-cache`; the read-heavy-with-edits-and-invalidation variant is `wikipedia`. Building the object store is infra-primitives `s3`. Here it's cache-tier topology + thundering-herd under spikes.

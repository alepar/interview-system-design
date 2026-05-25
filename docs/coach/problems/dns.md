---
slug: dns
archetype: caching-read-heavy
sources:
  cloudflare_dns: cloudflare.com/learning/dns/dns-server-types/
  rfc2308: rfc-editor.org/rfc/rfc2308.html
  google_public_dns: en.wikipedia.org/wiki/Google_Public_DNS
  catchpoint_ttl: catchpoint.com/dns-monitoring/dns-ttl
  route53_latency: repost.aws/questions/QU_3bkj87FR_yfOprSBtoRsg/how-latency-routing-in-route-53-works
---

# DNS (hierarchical read-heavy caching system)

## Bar anchors
- **Mid-level (L4/E4):** Knows DNS maps names to IPs and "there's caching." Can't describe the resolver hierarchy, TTL semantics, or why DNS is the canonical multi-tier read cache.
- **Senior (L5/E5):** Describes the resolver hierarchy (recursive resolver → root → TLD → authoritative) and TTL-based caching at each layer. Knows anycast spreads the roots and GeoDNS routes by location. May not articulate negative caching, the TTL consistency-vs-staleness tradeoff quantitatively, or cache hit ratios.
- **Staff+ (L6/E6+):** Drives proactively. Frames DNS as **the canonical hierarchical read cache**: a recursive resolver checks its cache, else queries **root → TLD → authoritative**, caching every record by its **TTL** (when TTL expires the resolver re-resolves). Quantifies: **13 root IP addresses scaled via anycast to ~2,000 servers** (~130B root queries/day in 2025); **Google 8.8.8.8 serves >1T queries/day** for ~10% of users with a two-tier name-partitioned cache; resolver **cache hit ratios 85–95%**; cached lookup <1ms vs cold 50–200ms. Explains **negative caching (RFC 2308)** (cache NXDOMAIN by min(SOA MINIMUM, SOA TTL)). Owns the **TTL tradeoff**: short TTL (60–300s) propagates changes in minutes but multiplies authoritative query load (60s vs 3600s ⇒ ~60× load); long TTL (12–24h) cuts traffic 60–80% but delays updates — and **low TTL ≠ guaranteed fast propagation** (some resolvers honor their own cached period). Names the migration pattern (lower TTL 24–48h before a change, raise after). Covers **GeoDNS/latency-based routing** (Route 53 by resolver IP / EDNS Client Subnet) + anycast.

## Canonical decomposition

### Requirements
**Functional:**
- Resolve a domain name to records (A/AAAA/CNAME/MX/…) with low latency, globally
- Cache aggressively while allowing changes to propagate within a bounded time
- Survive massive query volume and DDoS; route users to a nearby/low-latency answer
- Cache negative answers (NXDOMAIN) to reduce authoritative load

**Non-functional (with numbers):**
- Root: 13 IPs → ~2,000 anycast servers, ~130B queries/day; resolver cache hit 85–95%
- Cached lookup <1ms; cold full recursion 50–200ms
- TTL range 60s–86,400s (default ~3600s); 60s vs 3600s ⇒ ~60× authoritative load
- Google Public DNS >1T queries/day (~10% of users)

### Core entities
- **Record:** (name, type) → value, with a TTL (cache lifetime)
- **Recursive resolver:** caches records; walks the hierarchy on miss
- **Authoritative server:** the source of truth for a zone (holds the records + SOA)
- **SOA:** zone metadata incl. MINIMUM (controls negative-cache TTL)

### API
- `resolve(name, type) → {records, ttl}` (client → recursive resolver)
- resolver → root/TLD/authoritative queries on cache miss
- TTL on each record governs how long any layer may cache it

### HLD
DNS is a **layered read cache** by design. A client query hits a **recursive resolver**, which checks its cache; on a hit it returns immediately (<1ms). On a miss it walks the hierarchy: **root** nameserver (returns the TLD nameserver), **TLD** (returns the authoritative nameserver), **authoritative** (returns the record). Every record carries a **TTL** telling every caching layer how long it may keep it; when the TTL expires the resolver discards it and re-resolves. Caching exists at multiple layers — OS/stub cache, router, recursive resolver — so most queries are answered from a warm cache (resolver hit ratios 85–95%), which is why DNS scales to trillions of queries with a small authoritative footprint. **Negative caching** (RFC 2308) caches NXDOMAIN/no-data answers for `min(SOA MINIMUM, SOA TTL)` so repeated lookups of a nonexistent name don't hammer the authoritative servers.

Availability/scale come from **anycast**: the 13 root IP addresses are advertised from ~2,000 physical servers worldwide; BGP routes each query to the nearest instance, distributing load and absorbing DDoS. **GeoDNS / latency-based routing** (e.g. Route 53) returns the lowest-latency answer based on the recursive resolver's source IP (or EDNS Client Subnet), combining with anycast for sub-ms responses. The central design tension is the **TTL tradeoff**: it's the single knob trading cache efficiency (and authoritative load) against propagation delay (how fast a record change reaches users).

### Deep dives
1. **TTL as the consistency-vs-staleness knob.** TTL controls how long every cache may serve a record before re-resolving. Short TTL (60–300s) ⇒ changes propagate in minutes but authoritative query load multiplies (60s vs 3600s ≈ 60× more queries; raising to hours cuts traffic 60–80%). The crucial Staff+ nuance: **a low TTL does not guarantee fast propagation** — some resolvers and ISP caches keep serving the old value until their own cached period ends (and some clamp very low TTLs). Hence the **migration pattern**: lower the TTL 24–48h *before* a planned IP change so resolver caches adopt the short refresh cycle, make the change, then raise the TTL again to restore cache efficiency. This is the canonical "tune the cache TTL around a change" play.
2. **The resolver hierarchy + negative caching.** The root→TLD→authoritative walk is a delegation chain, and caching at each layer is what makes it scale: the root sees only TLD-referral misses, TLDs see only authoritative-referral misses, and authoritative servers see only the small fraction of queries that miss all resolver caches. Negative caching (RFC 2308) is the dual: caching "this name doesn't exist" for `min(SOA MINIMUM, SOA TTL)` prevents a misconfigured or attack pattern of repeated NXDOMAIN lookups from overwhelming authoritative servers. Together they bound authoritative load to ≈ (1 − hit_ratio) × total queries.
3. **Anycast + GeoDNS for scale, latency, and DDoS.** Anycast advertises the same IP from many locations; BGP routes each client to the topologically nearest instance, so the "13 root servers" are really ~2,000 boxes, and a DDoS is naturally split across them. GeoDNS/latency routing layers on top: the authoritative answer itself depends on where the query came from (resolver source IP or EDNS Client Subnet), returning the nearest CDN PoP or region. The subtlety is that the authoritative server sees the *resolver's* location, not the end user's — EDNS Client Subnet exists to pass a truncated client subnet through so the answer is geo-accurate. This is how DNS doubles as a global load-balancing/traffic-steering layer.

## Known failure modes
1. **Stale records after a change (slow propagation).** Users keep resolving the old IP after a migration because resolver/ISP caches honor the prior TTL. Production answer: pre-lower TTL 24–48h before the change; accept that some long-tail resolvers lag; for instant failover use a very low TTL on the critical record (paying the query-load cost) or anycast/health-checked routing instead of DNS changes.
2. **Authoritative overload / DDoS.** A flood of cache-missing or NXDOMAIN queries hits authoritative servers. Production answer: anycast to distribute, negative caching (RFC 2308) to absorb NXDOMAIN, response-rate-limiting, and over-provisioned authoritative capacity; cache hit ratios (85–95%) are the first line of defense.
3. **Cache poisoning / wrong answers cached.** A forged response gets cached and served to many users for the TTL. Production answer: DNSSEC (signed records) to authenticate answers, source-port randomization + 0x20 encoding to resist spoofing, and bounded TTLs so a poisoned entry self-heals.

## (Delineation note)
`dns` is the canonical hierarchical-read-cache + TTL-tradeoff problem. It anchors caching concepts (multi-tier cache, TTL, negative caching, anycast) reused across `cdn-edge-cache`, `tinyurl`, and `news-homepage`. The coordination/consistency primitives live elsewhere; here the focus is the read-cache hierarchy.

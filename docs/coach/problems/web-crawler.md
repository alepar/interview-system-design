---
slug: web-crawler
archetype: search-indexing
sources:
  mercator_paper: courses.cs.washington.edu/courses/cse454/15wi/papers/mercator.pdf
  ir_book_frontier: nlp.stanford.edu/IR-book/html/htmledition/the-url-frontier-1.html
  simhash_paper: research.google.com/pubs/archive/33026.pdf
  ir_book_crawl: nlp.stanford.edu/IR-book/pdf/20crawl.pdf
  hello_interview: hellointerview.com/learn/system-design/problem-breakdowns/web-crawler
  bytebytego: bytebytego.com/courses/system-design-interview/design-a-web-crawler
---

# Web Crawler (polite distributed crawler at web scale)

## Bar anchors
- **Mid-level (L4/E4):** Produces a queue-of-URLs + pool-of-workers design: dequeue a URL, fetch it, extract links, enqueue new URLs, store the page. Knows about robots.txt and de-duplicating URLs. Doesn't address politeness at scale, the seen-URL-vs-seen-content distinction, freshness re-crawl, or crawl traps unprompted.
- **Senior (L5/E5):** Names a URL frontier with prioritization, per-host politeness (don't hammer one server), and robots.txt + crawl-delay. Distinguishes a seen-URL set (have we queued this?) from content de-duplication. Knows the frontier is too big for RAM and must spill to disk. Discusses DNS as a cost. May not name the Mercator front/back-queue structure, simhash near-duplicate detection, or a principled freshness model.
- **Staff+ (L6/E6+):** Drives proactively. Specifies the **Mercator frontier**: K **front queues** for prioritization → biased random selection → B **back queues** for politeness (one host per back queue, FIFO) → a min-heap of next-allowed-fetch timestamps per host; rule of thumb **~3× back queues as crawler threads**. Distinguishes the **seen-URL set (Bloom filter,** ~1.2GB vs ~12GB exact for 1B URLs) from the **seen-content set (simhash:** 64-bit fingerprints, Hamming **k=3** for an ~8B-page repo — Manku/Jain/Das Sarma WWW 2007). Rate-limits at **both host and IP level** (shared hosting/CDN put many hosts on one IP). Models **freshness** as a per-URL Poisson change-rate under a fixed crawl budget, and cites Cho & Garcia-Molina that a **uniform** re-crawl policy beats proportional for average freshness. Handles **crawl traps** (calendars, session-IDs, infinite pagination) with path-segment caps, query-pattern blacklists, and per-host page caps. Quantifies a canonical target (~10B pages in ~5 days).

## Canonical decomposition

### Requirements
**Functional:**
- Discover and fetch pages starting from seed URLs, following extracted links
- Respect robots.txt and per-host crawl-delay (politeness)
- De-duplicate both URLs (don't re-queue) and content (don't store near-duplicates)
- Re-crawl pages to keep the corpus fresh, prioritized by change rate + importance
- Hand fetched content to the indexing pipeline

**Non-functional (with numbers):**
- Target ~10B pages in ~5 days (~3,750 pages/sec/machine → ~3.9 days on 8 machines)
- Frontier 10B+ URLs, majority disk-spilled with per-queue head in RAM
- Politeness: no concurrent requests to one host; honor crawl-delay (seconds)
- Seen-URL Bloom filter ~1.2GB for 1B URLs (tolerate rare false positives)
- Simhash near-dup: 64-bit, k=3 Hamming over a multi-billion-page repository
- Be a "good citizen": bounded request rate per host *and* per IP

### Core entities
- **URL:** normalized_url, host, ip, priority, discovered_ts, last_crawled_ts, next_crawl_ts
- **FrontQueue[K]:** priority-banded queues feeding the back queues
- **BackQueue[B]:** one host per queue, FIFO; paired with a min-heap entry of next-fetch time
- **SeenURLSet:** Bloom filter over normalized URLs ("have we queued this?")
- **ContentFingerprint:** 64-bit simhash per fetched page (near-duplicate detection)
- **Page:** url, content, fetch_ts, http_headers, outlinks

### API
- Internal: `frontier.add(url, priority)` → dedup against Bloom set, route to a front queue
- Internal: `frontier.next() → url` → biased-priority pick from front → back-queue routing → wait until host's next-fetch time
- Internal: `fetcher.fetch(url) → (content, headers)` → respects robots.txt cache + crawl-delay
- Internal: `dedup.is_near_duplicate(simhash) → bool` → Hamming ≤ k against the fingerprint store
- Internal: `scheduler.reschedule(url, change_observed)` → update next_crawl_ts via change-rate estimate

### HLD
The **URL frontier** is the heart. New URLs (from seeds or extracted links) are normalized and checked against a **Bloom filter** seen-set; unseen URLs are assigned a priority (importance × estimated value) and routed to one of K **front queues** (priority bands). A selector biased toward high-priority front queues pulls a URL and routes it to a **back queue** via a host→back-queue table, guaranteeing all URLs of a host land in the same back queue (FIFO). Each back queue is paired with an entry in a **min-heap** keyed by the host's next-allowed-fetch time. A crawler thread pops the heap's minimum, waits if necessary, fetches the URL, then refills that back queue from the front queues. Mercator's rule: ~3× as many back queues as threads keeps all threads busy while never violating per-host politeness.

The **fetcher** consults a cached robots.txt per host (honoring crawl-delay) and a **DNS cache** (resolution is a classic bottleneck; many hosts share an IP via CDN/shared hosting, so rate-limiting is applied at both host and IP). Fetched content is parsed: links are extracted and fed back to the frontier; a **64-bit simhash** fingerprint is computed and checked (Hamming ≤ 3) against a fingerprint store to drop near-duplicates before storage/indexing. Accepted pages go to a content store + the indexing pipeline.

The **freshness scheduler** estimates each URL's change rate (Poisson) from observed diffs and HTTP cache headers/sitemaps, then sets `next_crawl_ts`. Under a fixed crawl budget, a roughly-uniform revisit policy beats a strictly proportional one (proportional over-spends on a few rapidly-churning pages). The whole system is partitioned by host (a host is owned by one frontier shard) so politeness is enforceable without cross-shard coordination.

### Deep dives
1. **The Mercator front/back-queue frontier** — Two-level by design: front queues encode *what to crawl next* (priority); back queues encode *when we're allowed to* (politeness). Decoupling them means a high-priority URL on a host we just hit waits in its back queue without starving threads — they service other hosts meanwhile. The min-heap of next-fetch times is what makes "thousands of hosts, never two concurrent requests to one" tractable. The host→back-queue table is the invariant that prevents two threads from racing on the same host. Disk-spill: only each queue's head lives in RAM; the tail spills to disk because 10B+ URLs won't fit.
2. **Seen-URL (Bloom) vs seen-content (simhash)** — Two different dedup problems. "Have we already queued this URL?" is membership over billions of strings → a Bloom filter (~1.2GB for 1B URLs vs ~12GB exact), accepting rare false positives (a few real pages skipped — acceptable). "Is this page near-identical to one we already have?" is *content* similarity → simhash maps a page to a 64-bit fingerprint where near-duplicates differ in few bits; for an ~8B-page repo, treating fingerprints within Hamming distance 3 as duplicates is the documented Google setting. Simhash also detects spider traps: consecutive fetches producing near-identical content signal a trap.
3. **Freshness under a fixed crawl budget** — You cannot re-crawl everything constantly, so re-crawl frequency must be allocated. Model each page's changes as a (non-homogeneous) Poisson process estimated from observed change history; combine change rate with page importance to set revisit frequency. Counterintuitively, Cho & Garcia-Molina proved that for *average freshness* a uniform policy beats a proportional one — proportional over-allocates to a handful of pages that change every visit (you can never keep them fresh anyway) at the expense of everything else. Use HTTP `Last-Modified`/`ETag` and sitemaps as cheap change hints to avoid full re-fetches.

## Known failure modes
1. **Single-host hotspot / accidental DoS** — Naively parallelizing fetches sends a thundering herd at one server (or one IP hosting many sites), getting the crawler blocked and harming the target. Mitigation: the per-host back-queue + min-heap structure structurally prevents concurrent requests to a host; additionally rate-limit per *IP* (CDN/shared hosting), honor crawl-delay, and back off on 429/503. Politeness is both an ethical and a self-preservation requirement (blocked crawler = lost coverage).
2. **Frontier memory blow-up** — 10B+ URLs cannot live in RAM, and a naive in-memory queue OOMs within hours. Mitigation: disk-backed queues with only each queue's head in memory; the Bloom filter (not a hash set) for the seen-set; shard the frontier by host across machines so no single node holds the whole frontier. Monitor frontier size and apply admission control (drop low-priority discovered URLs) under pressure.
3. **Crawl/spider traps** — Dynamic calendars linking to "next month" forever, session-ID URLs that mint infinite distinct URLs for the same page, and infinite pagination cause the frontier to explode with worthless URLs. Mitigation: per-host page caps, URL-path depth/segment limits, query-pattern blacklists (e.g. drop or down-prioritize URLs with session-id params or `?`-heavy patterns), and simhash detection of consecutive near-duplicate content to recognize a trap and abandon that host subtree.

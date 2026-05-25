---
slug: top-k-trending
archetype: caching-read-heavy
sources:
  hi_topk: hellointerview.com/learn/system-design/problem-breakdowns/top-k
  cms_wikipedia: en.wikipedia.org/wiki/Count%E2%80%93min_sketch
  giydiren_topk: serhatgiydiren.com/system-design-interview-top-k-problem-heavy-hitters/
  twitter_tps: blog.x.com/engineering/en_us/a/2013/new-tweets-per-second-record-and-how
  sdh_topk: systemdesignhandbook.com/guides/design-top-k-system/
---

# Top-K / Trending (heavy hitters over a stream)

## Bar anchors
- **Mid-level (L4/E4):** Keeps an exact count per item in a hash map and sorts to get the top-K. Doesn't see the memory blowup at billions of distinct items or the streaming/time-window requirement.
- **Senior (L5/E5):** Counts in a stream, keeps a heap of the top-K, and precomputes/caches the result list. Knows exact counts of all items don't fit in memory and reaches for approximation. May not name Count-Min Sketch, the heavy-hitters algorithm, time windows, or the lambda fast/slow split.
- **Staff+ (L6/E6+):** Drives proactively. Solves heavy-hitters with a **Count-Min Sketch + min-heap of size K**: CMS gives fixed-memory frequency estimates (a 10×4000 CMS ≈ 160KB vs ~4GB for an exact map), with depth d=⌈ln(1/δ)⌉ hash functions controlling failure probability and width w=⌈e/ε⌉ controlling error magnitude (error ≤ ε·||count||₁ w.p. 1−δ). Pairs CMS with **Space-Saving / Misra-Gries** for exact top-item tracking. Handles **time windows** (tumbling vs hopping — a separate sketch+heap per window) and a **lambda architecture** (fast path: real-time approximate top-K via sketch; slow path: two MapReduce jobs for exact recompute). Crucially recognizes the **read side is trivially cacheable**: everyone reads the same tiny precomputed top-K list, so a refresh-every-few-minutes cache gives ~100% hit. Quotes stream scale (Twitter 143,199 tweets/sec record; trends use 5–15min sliding windows + Z-score anomaly detection).

## Canonical decomposition

### Requirements
**Functional:**
- Maintain the top-K most-frequent items over a high-volume stream (trending hashtags, top videos)
- Support time windows (last 5 min / hour / day) and refresh the published list periodically
- Reads are everyone fetching the same small top-K list (heavily cacheable)

**Non-functional (with numbers):**
- Stream rate up to ~143K events/sec (Twitter peak); billions of distinct items
- CMS ~160KB (10×4000) vs ~4GB exact map; refresh every few minutes
- Top-K read served from a precomputed cached list (~100% hit ratio)
- Approximate result acceptable (bounded error ε with probability 1−δ)

### Core entities
- **Count-Min Sketch:** 2D counter array CM[d][w] giving frequency estimates
- **Min-heap (size K):** current top-K candidates by estimated frequency
- **Window sketch:** a CMS+heap per time window (tumbling/hopping)
- **Published top-K list:** the small, cached, read-served result

### API
- `ingest(item)` → update the CMS, conditionally update the size-K heap
- `topK(window) → [items]` → read the precomputed list (cache hit)
- slow path: periodic MapReduce (frequency count → top-K) for exact recompute

### HLD
The write side ingests a high-volume stream and must answer "what are the K most frequent items" without storing an exact count per distinct item (billions of items ⇒ gigabytes). A **Count-Min Sketch** solves this in fixed memory: d hash functions map each item to one counter per row of a d×w array, increment all d; the estimated frequency is the **min** across the d counters (min reduces collision over-counting). Alongside, a **min-heap of size K** tracks the current top-K: on each ingest, estimate the item's count from the CMS and, if it exceeds the heap's min, insert/replace. CMS parameters set the error envelope: **w = ⌈e/ε⌉**, **d = ⌈ln(1/δ)⌉**, giving error ≤ ε·||count||₁ with probability 1−δ (e.g. d=10, w=2000 ⇒ 99.9% no-error). For exact top-item frequencies, pair with **Space-Saving / Misra-Gries**.

**Time windows** require a sketch+heap **per window** you want to query (tumbling = non-overlapping fixed windows; hopping = overlapping). Many systems run a **lambda architecture**: a **fast path** (sketch+heap aggregated over seconds, flushed to a serving store) gives real-time approximate top-K, while a **slow path** runs two MapReduce jobs (count frequencies, then top-K) for an exact recompute that backfills. The **read side is the easy part and the reason this lives in the caching archetype**: every client requests the same small top-K list, so the published result is cached and refreshed every few minutes (~100% hit ratio). Twitter-style trends add **Z-score anomaly detection** against a historical baseline (surface a spike, not just a high absolute count) over 5–15 min sliding windows.

### Deep dives
1. **Count-Min Sketch + heavy-hitters.** CMS is a fixed-size 2D counter array: hashing each item to d rows and taking the **min** estimate bounds over-counting from collisions; memory is independent of distinct-item count (160KB for 10×4000 vs 4GB exact). The parameter math (w=⌈e/ε⌉, d=⌈ln(1/δ)⌉; Cormode-Muthukrishnan) lets you dial accuracy vs space. CMS alone gives frequencies, not the top-K, so pair it with a size-K min-heap (candidates) and optionally Space-Saving/Misra-Gries for exact heavy-hitter tracking. The Staff+ point: trade bounded, quantified error for constant memory at stream scale.
2. **Time windows + lambda fast/slow.** "Trending in the last 5 minutes" needs windowed counts, which means a sketch+heap per window (tumbling or hopping). Real-time approximate results come from the **fast path** (in-memory sketch flushed every few seconds); exact results come from a **slow path** batch recompute (MapReduce: frequency count then top-K) that corrects drift. The serving layer merges/serves the freshest available. This is the canonical lambda pattern; if approximate real-time is sufficient, the fast path alone suffices — naming when you *don't* need the slow path is a senior-vs-staff signal.
3. **Why the read side is a caching problem.** Unlike most write-heavy stream problems, the *read* here is everyone asking for the same tiny list (top 10/50 trends). That makes it trivially cacheable: publish the computed top-K to a cache, refresh every few minutes, serve ~100% from cache. The interesting consistency choice is the **refresh cadence** (how stale the trending list may be) and **spam/quality filtering + Z-score** (a raw top-K by count surfaces persistent-but-boring items; trending wants *anomalous spikes*, so score against a baseline). This is why the problem belongs in read-heavy/caching despite the heavy write-side machinery.

## Known failure modes
1. **Exact-count memory blowup.** Storing a counter per distinct item over a billion-item stream exhausts memory. Production answer: Count-Min Sketch (fixed memory, bounded error) + size-K heap; accept ε-error for constant space.
2. **Hot-partition skew on the stream.** A single mega-popular item floods one partition/aggregator. Production answer: pre-aggregate (combiner/mini-batch) per key before the heap, partition the stream by item hash, and merge partial top-Ks.
3. **Stale or low-quality trending list.** A slow refresh misses breaking spikes; raw counts surface boring evergreen items. Production answer: short refresh cadence on the cached list + Z-score anomaly detection against a historical baseline + spam filtering, so "trending" means an actual surge.

## (Delineation note)
`top-k-trending` is the heavy-hitters-over-a-stream + cached-result problem. The ranked-by-score variant is `leaderboard`; per-item counting is `view-counter`; deep ranking models are ml-in-loop. Here it's approximate streaming structures feeding a tiny cached read.

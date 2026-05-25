---
slug: twitter-search
archetype: search-indexing
sources:
  earlybird_paper: notes.stephenholiday.com/Earlybird.pdf
  earlybird_summary: stephenholiday.com/notes/earlybird/
  twitter_1s_latency: blog.twitter.com/engineering/en_us/topics/infrastructure/2020/reducing-search-indexing-latency-to-one-second
  omnisearch: blog.x.com/engineering/en_us/a/2016/introducing-omnisearch
  the_algorithm_earlybird: github.com/twitter/the-algorithm
---

# Twitter Search (real-time search, Earlybird)

## Bar anchors
- **Mid-level (L4/E4):** Produces an inverted index over tweets with a query path returning matching tweets. Knows results should be recent. Proposes sharding by tweet id or user. Doesn't address the concurrency of indexing under live writes, reverse-temporal traversal, or sub-second indexing latency unprompted.
- **Senior (L5/E5):** Recognizes real-time search differs from web search: tweets must be searchable seconds after posting, while the index is read concurrently. Proposes an in-memory recent-tweets index plus an archive, ingestion via a stream (Kafka), and fan-out across shards with a coordinator merge. Knows newest-first ordering matters. May not articulate the single-writer/multi-reader lock-free index, the active-vs-sealed segment transition, or why reverse-chronological traversal inverts classic IR assumptions.
- **Staff+ (L6/E6+):** Drives proactively. Names **Earlybird** and its core: a **single-writer, multiple-reader lock-free** concurrent inverted index using memory barriers (locks are unaffordable with tens of cores × a searcher per core). Explains the **active (write-friendly, block-allocated) → sealed (read-optimized, immutable)** segment lifecycle. Explains **reverse-temporal posting traversal** (newest-first) and why it inverts the ascending-doc-id assumption baked into classic skip-list intersection. Quantifies: **~50ms average query latency including tweets posted 10s earlier**; a single 16M-tweet segment sustains **17K QPS, p95<100ms, p99<200ms** on 8 searcher threads (~6.7GB, optimization saves ~55% memory); ~5K QPS on a 144M-tweet server; **~60K queries/s while indexing ~80K tweets/s** by 2016. Names the **2020 redesign**: indexing latency cut **10s → 1s** by moving to **skip lists** (mid-list insert for out-of-order arrival) with a Kafka ingest buffer that sorts by strictly-increasing created-time, and a **Blender** that fans out across verticals (real-time/top/users/media) and reblends. Flags this lock-free reasoning as the least-transferable signal in the archetype.

## Canonical decomposition

### Requirements
**Functional:**
- A tweet is searchable within ~1s of posting (real-time)
- Boolean + phrase queries return matching tweets, newest-first by default
- Rank by relevance using engagement signals (likes/RTs/replies) updated after indexing
- Fan out across content verticals (real-time, top, people, media) and reblend
- Serve high query QPS while ingesting high write throughput concurrently

**Non-functional (with numbers):**
- Indexing latency ~1s end-to-end (post-2020; was 10s)
- ~50ms average query latency (including very recent tweets)
- Per-segment: 16M tweets, 17K QPS, p95<100ms, p99<200ms (8 searcher threads), ~6.7GB
- ~60K queries/s while indexing ~80K tweets/s (2016 scale)
- Lock-free reads concurrent with a single writer per segment

### Core entities
- **Tweet:** tweet_id (snowflake, time-ordered), user_id, text, created_at, lang, engagement_counts
- **Segment:** active (mutable, block-allocated postings) or sealed (immutable, read-optimized)
- **PostingList:** per-term, traversed in **reverse chronological** order (newest doc-id first)
- **Shard:** hash-partition of tweets; one single-writer index + many reader threads
- **Signal:** post-index engagement updates (fav/RT/reply counts) pushed by a Signal Ingester

### API
- `GET /search?q=...&type=recent|top` → tweets newest-first (recent) or engagement-ranked (top)
- Internal: Blender parses the query, fans out to Earlybird shards, reblends verticals
- Internal: ingesters read tweets from Kafka, extract fields, write to intermediate Kafka topics; Earlybirds consume and index
- Internal: Signal Ingester pushes engagement counts to Earlybirds post-index for ranking

### HLD
Tweets flow from the firehose into **Kafka**. **Ingesters** consume, extract indexable fields (text tokens, user, lang, entities), and write to intermediate Kafka topics; a buffer sorts incoming tweets into **strictly-increasing created-time order** before indexing so the index sees a near-monotonic stream. **Earlybird** shards (tweets hash-partitioned) consume and index into an **in-memory inverted index**. The critical property: each segment has **one writer thread** appending postings and **many reader threads** querying concurrently, coordinated **lock-free** via memory barriers — a write fence publishes new postings so readers either see the old or new state, never a torn one. Locks are infeasible: a server runs a searcher per CPU core (tens), and lock contention on the hottest postings would collapse throughput.

A segment starts **active** (write-friendly, block-allocated postings supporting appends) and, once full, is **sealed** into a compact **read-optimized immutable** form (~55% smaller). Postings are traversed **newest-first** (reverse chronological) because real-time search wants the most recent matching tweets and can early-terminate after enough recent hits — this inverts the ascending-doc-id assumption of classic postings intersection (the 2020 redesign adopted **skip lists** partly because they support mid-list insertion for out-of-order arrivals while still allowing fast traversal).

A query hits **Blender**, which parses it and fans out to the appropriate Earlybird shards across verticals (real-time, top, people, media). Each shard returns its local newest/most-relevant matches with ~50ms latency; Blender merges and reblends. Relevance separates **static features** (annotated at ingest: user info, language) from **resonance/real-time features** (fav/RT/reply counts) that a **Signal Ingester** pushes to Earlybirds after indexing; a lightweight logistic-regression ranker scores engagement likelihood for the "top" vertical.

### Deep dives
1. **Single-writer / multi-reader lock-free index** — The defining mechanism. One writer appends to postings; many readers traverse concurrently. Correctness without locks comes from carefully-ordered writes plus memory barriers: the writer fully builds a new posting entry, then a single volatile write (fence) publishes it, so a reader sees either the consistent old state or the consistent new state. Unrolled linked lists (original) gave cache-friendly append-only postings; the 2020 redesign moved to skip lists for O(log n) insert/lookup and easier concurrency under out-of-order arrival. The Staff+ point: at tens of searcher threads, locking the hot postings is a non-starter, so the data structure itself must be concurrency-safe by construction.
2. **Active vs sealed segments + reverse-temporal traversal** — New tweets go to the single **active** segment (mutable, block-allocated, optimized for fast append + concurrent read). When full it's atomically swapped and **sealed** into an immutable, compact, read-optimized layout (~55% memory savings) and a fresh active segment opens. Readers always traverse postings newest-first so they can early-terminate once they have enough recent results — the opposite of classic impact-ordered or ascending-doc-id traversal. This is why real-time search is its own engine, not just Elasticsearch with a 1s refresh: the access pattern, concurrency model, and segment layout are all built around "newest tweets, right now, under heavy concurrent writes."
3. **Cutting indexing latency 10s → 1s (2020 redesign)** — The end-to-end path (firehose → searchable) was ~10s and the bottleneck was the ingestion pipeline and the linked-list index's inability to cleanly handle out-of-order tweets. The redesign: ingesters read from Kafka and write extracted fields to intermediate Kafka topics; a buffer sorts tweets by strictly-increasing created-time so the index ingests a near-monotonic stream; the index moved to skip lists supporting mid-list insertion for the residual out-of-order arrivals. Result: ~1s indexing latency, decoupling ingest scaling from index scaling. The interview lesson: real-time-search latency is usually a pipeline+data-structure co-design problem, not a single knob.

## Known failure modes
1. **Out-of-order tweet arrival corrupts a strictly-ordered index** — If postings assume monotonically increasing doc-ids but tweets arrive out of created-time order (network reordering, multi-source ingest), naive append produces a mis-ordered postings list and wrong newest-first results. Mitigation: the ingest buffer sorts by created-time before indexing; skip lists tolerate the residual out-of-order inserts by supporting mid-list insertion rather than append-only.
2. **Searcher starvation when a segment seals** — Sealing converts an active segment to immutable form; done naively it blocks readers traversing that segment. Mitigation: lock-free read path + an atomic segment swap — readers finish on the old object while new queries bind to the sealed one; no global lock, no reader stall.
3. **Tail-latency blowup during a viral event** — A breaking event spikes both write volume (everyone tweets) and query volume (everyone searches the same terms), and the hottest postings get the most concurrent traversal. Mitigation: auto-scale reader replicas, cache the small set of trending query results (identical across users → high cache hit), rate-limit/late-bind cold expensive queries, and shed low-value load — protecting the real-time path that is the product's whole point during exactly the moments it matters most.

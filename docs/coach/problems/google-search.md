---
slug: google-search
archetype: search-indexing
sources:
  anatomy_paper: infolab.stanford.edu/pub/papers/google.pdf
  dean_wsdm09: "Jeff Dean, Challenges in Building Large-Scale Information Retrieval Systems, WSDM 2009 keynote"
  tail_at_scale: "Dean & Barroso, The Tail at Scale, CACM 2013"
  caffeine_blog: developers.google.com/search/blog/2010/06/our-new-search-index-caffeine
  searches_2025: "Search Engine Land, Mar 2025 — Google discloses 5T+ searches/year"
---

# Google Search (web-scale search engine)

## Bar anchors
- **Mid-level (L4/E4):** Produces crawl → index → serve at a high level. Knows an inverted index maps terms to document lists and that PageRank-style link analysis exists. Proposes sharding the index across machines. Doesn't quantify scale, distinguish retrieval from ranking, or address tail latency unprompted.
- **Senior (L5/E5):** Separates the offline indexing pipeline from the online serving fleet. Describes a scatter-gather: a query fans out to many index shards, each returns local top results, a coordinator merges. Names two-phase retrieval-then-rerank and that PageRank is a precomputed prior combined with query-time text scoring. Discusses caching for popular queries. May not address tail latency at thousands of shards, index tiers, or document-vs-term partitioning explicitly.
- **Staff+ (L6/E6+):** Drives proactively. Justifies **document-partitioning over term-partitioning** at web scale (a new doc touches one shard; term-partitioning requires cross-machine postings intersection per query and hot-terms hotspots). Articulates the **scatter-gather tail problem**: with thousands of leaves, p99 is dominated by the slowest shard, so uses hedged requests after p95, request cancellation, and partial-result return at X% shard reply (Dean's "tail at scale"). Names **index tiers** (RAM hot for top ~1% queries → SSD warm → disk/Colossus cold) and result caching (30–60% hit on head queries, Zipfian). Treats ranking as **two-phase**: cheap recall (text match + static priors) over billions → expensive learned re-rank over ~100s of features on the top-K~1000. Decouples the **Caffeine/Percolator incremental indexing pipeline** from an atomically-promoted immutable serving snapshot. Quantifies: 100+ PB index, ~158K avg QPS (from Google's 2025 disclosure of 5T+ searches/year; notes the older ~40K figure is ~4× stale), sub-200ms p99 with a ~100ms internal scatter-gather budget.

## Canonical decomposition

### Requirements
**Functional:**
- Crawl the web and maintain a fresh inverted index over hundreds of billions of pages
- Answer free-text queries with ranked, relevant results
- Incorporate link-based authority (PageRank-style prior) and ~100s of ranking features
- Keep results fresh: news/trending content indexed in minutes, not days
- Serve globally with low latency

**Non-functional (with numbers):**
- Index 100+ PB; corpus hundreds of billions of pages
- ~158K avg QPS (5T+ searches/year, Google 2025); peaks far higher (provision for peak)
- Sub-200ms p99 end-to-end; ~100ms internal scatter-gather budget
- Result-cache hit 30–60% on head queries
- Update latency: news content fresh within minutes (Caffeine reduced median doc age ~50%)
- Multi-region replication for latency + durability

### Core entities
- **Document:** url, fetched_content, outlinks, pagerank_prior, last_crawled, quality_signals
- **Posting:** term → [(doc_id, term_freq, positions, field flags)] in a document-partitioned shard
- **IndexShard:** inverted index for a random subset of docs; replicated across a serving pool
- **ServingSnapshot:** immutable, versioned index promoted atomically from the indexing pipeline
- **Query:** raw_terms, rewritten/expanded_terms, locale, personalization_context

### API
- `GET /search?q=...&loc=...` → ranked results (the only public surface that matters here)
- Internal: `root → parent/mixer → leaf` scatter-gather RPC tree
- Internal: indexing pipeline writes to a Bigtable-class repository; Percolator observers fire on changes; a builder promotes a new immutable serving snapshot

### HLD
**Offline path.** Crawled pages land in a Bigtable-class repository. The indexing pipeline (Caffeine, built on Percolator) processes documents incrementally — an observer fires when a doc's content column changes, recomputing its postings and link contributions — rather than rebuilding the whole index in batch. PageRank-style priors and other static signals are computed and stored per-doc. The output is an immutable, document-partitioned inverted index; a new version is built and **promoted atomically** so the serving fleet never sees a half-updated index.

**Online path.** A query hits a root server, which rewrites/expands it (synonyms, spelling, ~3–4 words can expand to ~50 terms when the index is in memory) and scatters it down a tree: root → parent/mixer → thousands of **leaf** servers, each owning one document-partitioned shard. Each leaf walks postings for the query terms, applies cheap recall scoring (text match + static priors), and returns its local top-K. Parents merge; the root assembles a global candidate set of ~1000, then runs an **expensive learned re-ranker** over ~100s of features to produce the final ordering. Each shard is replicated across a serving pool for throughput and fault tolerance; shards live in **tiers** (hot postings in RAM, warm on SSD, cold on disk/Colossus) assigned by predicted serving frequency. A multi-tier **result cache** absorbs head queries (Zipfian, 30–60% hit).

**Tail control.** With thousands of leaves contributing to every query, the slowest shard sets p99. The serving tree issues **hedged requests** (re-issue to a replica after the p95 deadline, cancel the loser), supports **request cancellation**, and can return **partial results** once X% of shards have replied — trading a sliver of recall for a bounded tail.

### Deep dives
1. **Document vs term partitioning** — Term-partitioning (each machine owns some terms' full postings) makes a multi-term query intersect postings across machines and creates hotspots on common terms, and a new document must touch every shard that holds one of its terms. Document-partitioning (each machine owns a random subset of docs, full local index) means every query fans out to all shards but each shard is self-contained: a new doc touches exactly one shard, scoring is local, and throughput scales by replicating shards. At web scale Google uses document partitioning; the scatter-gather + tail cost is the price, paid down with hedging and caching.
2. **Two-phase retrieval-then-rerank** — Running a 100-feature learned model over billions of documents per query is infeasible. Phase 1 is cheap, high-recall retrieval (postings walk + static priors like PageRank) narrowing billions → ~1000 candidates per shard/region. Phase 2 is an expensive ML re-ranker over the merged top-K, using features too costly to compute at recall time (query-document interaction, freshness, personalization). The Staff+ framing: recall optimizes for "don't lose the good doc," rerank optimizes for "order the survivors correctly," and the candidate budget (K) is the dial between latency and quality. (Keep the ranking-model training itself shallow — that's the ml-in-loop archetype.)
3. **Index tiers + result caching under a Zipfian query load** — Query popularity is heavily skewed, so a small result cache captures a large fraction of traffic (30–60% on head queries) and trending queries can be precomputed. For the long tail that misses the cache, the index itself is tiered: postings for frequently-served documents sit in RAM (since 2001 Google could hold the serving index in memory, enabling aggressive query expansion), less-served content on SSD, cold content on disk/Colossus. The eviction/promotion policy is driven by predicted serving frequency, and the cache must be invalidated/bypassed for freshness-sensitive queries (breaking news) where a stale cached result is worse than a slightly slower fresh one.

## Known failure modes
1. **A slow or failed shard dominates p99** — One leaf doing GC, hitting a cold disk seek, or degrading drags the whole query's tail because the root waits for all shards. Mitigation: hedged requests (re-issue to a replica after p95, take the first responder, cancel the other), per-shard deadlines with partial-result return once a coverage threshold (e.g. 98% of shards) is met, and tracking the "fraction of index represented in this response" so degradation is observable rather than silent.
2. **Hot-spotting on a viral query** — A breaking-news term spikes to orders of magnitude above baseline, overwhelming the shards and replicas serving it. Mitigation: multi-tier result cache fronting the serving tree (the viral query is identical across users, so it caches extremely well), admission control / load-shedding for low-value traffic, and precomputing top-N for detected trending queries. The cache also protects the backend during the spike.
3. **Stale results during a fast-moving news event** — A batch-rebuilt index can be days behind; for news that is a correctness failure, not just a latency one. Mitigation: the incremental indexing pipeline (Caffeine/Percolator) cut median doc age ~50% vs batch MapReduce by processing documents continuously and promoting fresh snapshots quickly; freshness-sensitive queries bypass or short-TTL the result cache; a separate fast-path real-time index can be blended for the most time-sensitive verticals (the `twitter-search`-style pattern).

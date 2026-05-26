# Search

Source: `staff-engineer-study-guide.md`.

## Inverted Index and Posting Lists

**Definition.** An inverted index maps each term to a posting list of (doc_id, [tf, positions, field_flags]) entries; posting lists are compressed (variable-byte / Frame-of-Reference + PFOR-Delta) and equipped with skip pointers so multi-term intersections walk only a fraction of each list.

**Canonical use.** Lucene/Elasticsearch holds a per-shard inverted index with an in-RAM FST term dictionary pointing into on-disk BlockTree postings; a multi-term AND query intersects posting lists in compressed form, using skip lists to leap past doc-ids that can't contribute, scoring inside the loop.

**Production systems.** Apache Lucene / Elasticsearch (FOR + PFOR-Delta, Roaring bitmaps for DocIdSet), Apache Solr, Postgres GIN index over tsvector, GitHub Blackbird sparse-grams (variable-length n-grams over code).

**Alternatives.** Forward index / linear scan (correct, infeasible past a few million docs); suffix arrays or n-gram indexes when word-tokenization fails (code search, CJK languages); learned-sparse postings (SPLADE) when synonym recall must be served by the inverted index itself.

## Scoring: TF-IDF and BM25

**Definition.** TF-IDF scores a doc as `tf(t,d) · log(N/df(t))` — frequency in the doc weighted by rarity in the corpus. BM25 fixes two TF-IDF defects: it **saturates** tf via `tf/(tf + k1·(1 - b + b·|d|/avgdl))` so a 100th occurrence isn't worth the same as the 2nd, and it **length-normalizes** so long documents don't trivially win — with k1∈[1.2, 2.0] controlling tf saturation and b∈[0, 1] (default 0.75) controlling length penalty.

**Canonical use.** Elasticsearch defaults to BM25 with k1=1.2, b=0.75 for every text field; BM25 also serves as the lexical leg of every hybrid retrieval system (see Hybrid Retrieval below) and remains a brutally strong zero-shot baseline (BEIR macro nDCG@10 ≈ 0.43, beating pure DPR ≈ 0.35 out of domain).

**Production systems.** Lucene/Elasticsearch (Okapi BM25 default since 5.0), Postgres `ts_rank_cd`, Vespa (BM25F field-weighted variant), every research benchmark uses it as the reference baseline.

**Alternatives.** TF-IDF (simpler, no saturation, still competitive for short docs); language-model retrieval (Dirichlet/JM smoothing) — theoretically principled but rarely outperforms BM25 in practice; BM25F when fields (title vs body) need independent length normalization.

## Two-Stage Retrieval: Candidate Generation + Reranking

**Definition.** A query first runs **cheap, high-recall retrieval** over billions of docs (postings walk + static priors like PageRank/popularity) to produce ~100–1000 candidates per shard, then an **expensive reranker** (LTR model with ~100s of features, or a cross-encoder / late-interaction model) re-orders only the merged top-K. The candidate budget K is the dial between latency and quality.

**Canonical use.** Google Search: cheap recall (text match + PageRank-style priors) over hundreds of billions of pages, leaves return local top-K, root assembles ~1000 globally and runs a learned ranker over hundreds of features. Same pattern at Amazon (lexical+semantic recall → conversion/sales/inventory-aware reranker) and across every web-scale search.

**Production systems.** Google web search (recall + learned rerank), Amazon Product Search (Semantic Product Search candidate gen + behavioral rerank), Bing, every recommender system (retrieval → ranking is the Staff+ unlock framing).

**Alternatives.** Single-stage retrieval with a fast scorer (works for small corpora or when recall+rank can share features); cascade ranking with 3+ stages (Google's full stack — adds an intermediate rerank to widen the K of the final stage).

## Learning-to-Rank (LTR) Reranking

**Definition.** LTR trains a model to order documents for a query. **Pointwise** treats each (q,d) as a regression/classification example (simple but ignores list structure); **pairwise** (RankNet, RankSVM, LambdaRank) trains on (q, d_better, d_worse) pairs to predict relative order; **listwise** (LambdaMART, ListNet, ListMLE) directly optimizes a list metric like nDCG. Features split into query-only (intent, length), doc-only (PageRank, freshness, conversion priors), and query-doc interactions (BM25 score itself, click-through, embedding similarity).

**Canonical use.** Amazon Semantic Product Search reranks the lexical+semantic candidate set with behavioral features (conversion rate, sales velocity, review signal, inventory) using a 3-part hinge loss over purchased / impressed-not-purchased / random triples. Google's web rerank ingests ~100s of features over the candidate top-K via gradient-boosted trees and learned models.

**Production systems.** LightGBM / XGBoost LambdaMART (Bing, Yandex, most e-commerce), Microsoft RankNet/LambdaMART (the academic lineage), TF-Ranking and PyTorch listwise libraries, Amazon's behavior-tuned hinge-loss bi-encoder.

**Alternatives.** Hand-tuned linear ranking (when no labels exist; baseline for cold start); cross-encoder reranker (BERT-class, higher quality, far slower — feasible only on top-10s to top-100s); ColBERT late-interaction MaxSim (near-cross-encoder quality at ~170× lower cost).

## Query Understanding

**Definition.** The query-rewriting pipeline that converts raw user input into a richer query: **spell correction** (edit-distance / Levenshtein automaton ≤2, n-gram language model for context); **query expansion** (synonym tables, stemming via Porter/Snowball, lemmatization); **query rewriting** (head/tail mapping — rewrite a sparse tail query toward a behavior-rich head query that inherits richer signals); **intent classification** (navigational / informational / transactional, or product-category routing).

**Canonical use.** Google rewrites a 3–4 word query into up to ~50 terms via synonym expansion before scattering it to leaves. Amazon's pipeline tokenizes → spell-corrects → plural/lemma-normalizes → synonym-expands → maps tail queries to behaviorally-rich head queries while preserving intent. Autocomplete pairs with spell correction for a full "as-you-type" round.

**Production systems.** Elasticsearch analyzers (tokenizer + token-filter chain: lowercase, stemmer, synonym), Lucene SuggestStopFilter and FuzzyQuery, Solr's SpellCheckComponent (n-gram + dict-based), Amazon's query reformulation layer.

**Alternatives.** No rewriting (works only when users type exact corpus terms — never true in practice); LLM-based query rewriting (higher quality, latency cost in the hundreds of ms, mostly used offline to mine head-query rewrites); cross-lingual query translation when serving multiple locales over one corpus.

## Index Sharding Strategies

**Definition.** **Document-partitioning** (each shard owns a random subset of docs, holds a self-contained local index): every query scatter-gathers to all shards but each shard is local, indexing a new doc touches exactly one shard, throughput scales by replicating shards. **Term-partitioning** (each machine owns full postings for some terms): a multi-term query intersects across machines, common terms become hot, a new doc must update every shard that holds one of its terms. **Replicas** carry no new docs — they multiply query-side throughput and provide failover.

**Canonical use.** Google, Elasticsearch, Twitter Earlybird, and GitHub Blackbird all use **document partitioning**: at web scale the scatter-gather + tail cost is the price (paid down with hedging and caching), but term-partitioning's cross-machine intersection and hot-term hotspots are unworkable.

**Production systems.** Elasticsearch (`hash(_id) % num_primaries`, replicas for throughput; ~10–50 GB/shard, <200M docs/shard, ~1,000 shards/node soft limit), GitHub Blackbird (hash by Git blob OID — gives even distribution AND content dedup for free), Twitter Earlybird (tweet hash + Blender fan-out).

**Alternatives.** Term-partitioning (rare; viable only for static, small-vocabulary corpora); routing-key sharding (e.g. `customer_id` for query locality — but risks one giant tenant creating a hot shard; mitigate with `routing_partition_size`); hybrid time-range + hash sharding for log/event corpora where recent data is hot.

## Near-Real-Time (NRT) Indexing via CDC

**Definition.** Documents flow from a primary store through **Change-Data-Capture** → Kafka (or similar) → indexer workers, which apply incremental updates (often partial-document updates of a single field rather than re-indexing the whole doc) to the search index. Lucene's **refresh** opens a new in-memory segment that is searchable but not yet durable (default 1s); **flush** fsyncs segments and rolls the translog. The refresh-interval trade-off: shorter = fresher but creates more small segments and forces merge work; longer = better ingest throughput but staler results.

**Canonical use.** Amazon's inventory pipeline: inventory DB → CDC → Kafka → partial-doc update to `in_stock` field → NRT refresh, so out-of-stock SKUs vanish from results within seconds. Twitter Earlybird's 2020 redesign cut indexing latency 10s → 1s by sorting tweets by created-time in a Kafka buffer and moving the postings structure to skip lists for clean mid-list insert. GitHub Blackbird delta-indexes only changed blobs on push.

**Production systems.** Elasticsearch translog + refresh, Yelp Nrtsearch (segment replication — primary indexes once, replicas pull pre-built segments from S3, cutting per-replica CPU and 30–50% latency), Debezium / Kafka Connect for CDC ingestion, Google Caffeine/Percolator (incremental observers replacing batch MapReduce indexing — cut median doc age ~50%).

**Alternatives.** Periodic batch rebuild (simpler, but staleness in hours/days — unacceptable for inventory, news, code search); full re-indexing on every change (correct, prohibitively expensive past trivial corpora); push-based replication (every replica re-indexes — Elasticsearch's default — bottlenecks on replica CPU at high write-heavy / high-replica scale).

## Hybrid Retrieval (Lexical + Dense ANN)

**Definition.** Run a **lexical leg** (BM25 over inverted index — strong on exact terms, IDs, rare tokens) and a **dense leg** (query embedding + ANN over HNSW/IVF-PQ — strong on paraphrase, synonymy, intent) in parallel, each returning top-K. Combine with **Reciprocal Rank Fusion** (`Σ 1/(k + rank)`, k=60) — rank-based fusion sidesteps the incompatible scales of BM25 (unbounded, corpus-dependent) and cosine (bounded, model-dependent) — or with a weighted score combination tuned against labeled relevance.

**Canonical use.** Hybrid retrieval at every RAG and modern search stack: BM25 finds the exact-token matches that embeddings miss (error codes, identifiers, rare terms), dense recovers the paraphrases lexical misses, RRF gives a consensus ordering. Empirically hybrid beats either leg alone by ~5–15% nDCG (BEIR: BM25 ≈0.43, ColBERTv2 ≈0.50, pure DPR ≈0.35 — worse than BM25 zero-shot, which is the empirical case for hybrid).

**Production systems.** Elasticsearch retrievers (RRF default k=60), OpenSearch hybrid query, Weaviate `alpha` (weighted), Qdrant named vectors, Vespa, Azure AI Search, Mongo Atlas — RRF is the default fusion in all of them.

**Alternatives.** Score-normalization fusion (fragile — outliers in one leg dominate by scale accident); SPLADE learned-sparse (BERT-MLM term expansion stays in the inverted index — one system, neural cost only at indexing); ColBERT late-interaction reranking over the fused top-100 (near-cross-encoder quality, never first-stage).

## Result Caching Topology

**Definition.** Search caches layer at several levels: **query-result cache** (full ranked result for an identical query — the fattest win on head queries); **fragment / posting-list cache** (hot posting lists in memory across queries); **per-shard top-K cache** (each shard's local result for repeated queries); **CDN/edge cache** in front of the search service (autocomplete, head queries). Cache keys must include filters/facets/sort/locale; invalidation fires on index refresh or CDC update for the affected entries.

**Canonical use.** Google absorbs **30–60% of head-query traffic** with a multi-tier result cache (query popularity is sharply Zipfian, so a small cache captures a large fraction of QPS). Amazon pre-warms head-query results before flash sales and uses per-key locking on miss so a stampede doesn't multiply backend work. Autocomplete's edge LRU achieves 90%+ hit rate on head prefixes — autocomplete is "a caching problem wearing a search problem's clothes."

**Production systems.** Lucene LRUQueryCache (filter cache), Elasticsearch shard-request cache + node query cache, Varnish / CloudFront in front of the search API, Redis for promoted/precomputed query results.

**Alternatives.** No result cache (forced when filters are unbounded / personalized, since the cache key space explodes); precompute-only (offline materialization of head queries — no online cache, but staleness on trending queries); CDN-only (simplest, but misses geo-distributed cache invalidation needs).

## Failure Modes and Operational Concerns

**Definition.** Search systems fail in characteristic ways: **stale index** (refresh interval too long or CDC backlog → unbuyable products, missing fresh news, just-pushed code not findable); **hot shard** from skewed routing (one tenant or one giant repo dominates a shard); **scatter-gather tail** (with thousands of leaves, p99 is set by the slowest shard — mitigated with hedged requests after p95 and partial-result return at X% coverage); **expensive query DoS** (pathological regex with no extractable literal, deep pagination `from: 100000`, unbounded fuzzy search); **cardinality explosion** in faceting (high-cardinality terms-aggregation OOMs the heap); **merge storms** during bulk load (frequent refreshes spawn tiny segments and the merger thrashes); **translog growth** (slow flush or offline node → long recovery replay).

**Canonical use.** Every search problem in the catalog enumerates these: Google's hedged requests + partial results for tail control, Elasticsearch's translog durability levers and `routing_partition_size` for hot-shard mitigation, GitHub Blackbird's per-shard regex timeouts and candidate caps, Amazon's stampede protection via per-key locking and TTL jitter on flash-sale queries.

**Production systems.** Dean & Barroso "The Tail at Scale" (CACM 2013) — hedged requests are the canonical mitigation; Lucene `TieredMergePolicy` (merge-storm tuning); Elasticsearch sequence numbers + global checkpoint (delta-replay recovery instead of full segment copy); circuit breakers (per-request memory caps) to bound aggregation explosions.

**Alternatives.** Synchronous full-replica writes (avoids translog complexity, blows write throughput); shorter refresh interval (fresher, more merge cost — the wrong trade for write-heavy ingestion); reject expensive queries up front via query-cost prediction (Vespa, Solr cost limits) vs let-them-run-with-a-timeout.

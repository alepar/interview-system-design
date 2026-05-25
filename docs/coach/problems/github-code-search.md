---
slug: github-code-search
archetype: search-indexing
sources:
  blackbird_blog: github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/
  code_search_history: github.blog/engineering/architecture-optimization/a-brief-history-of-code-search-at-github/
  zoekt: github.com/sourcegraph/zoekt
  zoekt_deepwiki: deepwiki.com/sourcegraph/zoekt
  sparse_ngrams: github.com/danlark1/sparse_ngrams
---

# GitHub Code Search (Blackbird) — substring + regex + symbol over 25 TB

## Bar anchors
- **Mid-level (L4/E4):** Proposes indexing code like text in Elasticsearch and searching keywords. Knows code is large and there are many repos. Doesn't recognize that word tokenizers fail on code, or address substring/regex/symbol search, dedup, or commit-level consistency unprompted.
- **Senior (L5/E5):** Recognizes code search needs substring and regex (not just whole-word matching) because of camelCase, snake_case, and punctuation, and proposes an **ngram/trigram index** instead of a word index. Knows repos contain massive duplication (forks) and that dedup matters. Discusses sharding and parallel search across shards. May not name Blackbird/Zoekt specifics, sparse-grams, blob-OID dedup, commit-level snapshot isolation, or symbol search as a separate index.
- **Staff+ (L6/E6+):** Drives proactively. Explains **why a word inverted index fails for code** (tokenizing on whitespace/punctuation prevents substring search inside identifiers) and uses an **ngram index** — trigrams (n=3) are the sweet spot (bigrams not selective, quadgrams too large), but plain trigrams over-match at GitHub scale so Blackbird uses **sparse-grams** (variable-length grams) to cut false positives. Names **content-addressed dedup by Git blob OID** (115 TB → ~28 TB unique content; identical files share an ID → even shard distribution + no duplicate indexing). Quantifies: **~45M repos, 115 TB, 15.5B documents, 25 TB index**; ingest **~120K docs/sec** (full reindex ~36h, delta indexing ~18h); per-shard p99 ~100ms, 64-core host **~640 QPS vs ~0.01 QPS for ripgrep** brute-force. Names **commit-level query consistency** (your search excludes a teammate's just-pushed commit until processed — "tricky with other engines") and a **separate symbol index** (Tree-sitter/ctags) for jump-to-definition. References **Zoekt** (trigram + byte-offsets, regex via literal-substring extraction).

## Canonical decomposition

### Requirements
**Functional:**
- Substring search inside identifiers (`fooBar`, `foo_bar`, partial tokens)
- Regex search across the corpus
- Symbol search (definitions, references) — jump-to-definition
- Scope by repo / org / language / path; respect repo visibility (private/public)
- Reflect pushes quickly with commit-level consistency

**Non-functional (with numbers):**
- Corpus ~45M repos, 115 TB code, 15.5B documents (53B+ source files at later scale)
- Index ~25 TB (ngrams + compressed unique content); content dedup 115 → ~28 TB
- Ingest ~120K docs/sec; full reindex ~36h, delta ~18h (>50% fewer docs)
- Per-shard p99 ~100ms; 64-core host ~640 QPS (vs ~0.01 QPS ripgrep)
- Cluster (Universe talk): ~5,184 vCPUs, 40 TB RAM, 1.25 PB storage, ~200 req/s avg

### Core entities
- **Blob:** a unique file content, addressed by Git **blob OID** (SHA) — the dedup + shard key
- **Document:** an indexed (repo, path, blob) tuple; many documents may share one blob
- **NgramPosting:** sparse-gram → [blob positions] (the substring index)
- **Symbol:** name, kind, defining blob+offset (Tree-sitter/ctags), a separate index
- **Shard:** by blob OID; even distribution, identical files indexed once

### API
- `GET /search?q=<substring|regex>&repo=&lang=&path=` → ranked code matches with line context
- `GET /search?q=symbol:Foo` → symbol definitions/references
- Internal: push event → delta-index changed blobs (via Kafka), publish to ingest pipeline
- Internal: regex → extract literal substrings → ngram lookup → candidate blobs → verify regex on candidates

### HLD
Code is **content-addressed by Git blob OID**. The corpus has enormous duplication (forks, vendored deps, copied files), so indexing by blob OID means identical files are stored and indexed **once** — collapsing 115 TB of code into ~28 TB of unique content, with the final index ~25 TB (ngrams + a compressed copy of unique content). Blob OID is also the **shard key**: hashing it spreads documents evenly across shards and avoids hot shards (no single huge file dominates a shard) while giving free dedup.

The index is an **ngram index**, not a word index, because code search must find substrings inside identifiers. Trigrams (n=3) balance selectivity vs size, but plain trigrams over-match at this scale (the trigram `for` appears everywhere), so Blackbird uses **sparse-grams** — variable-length grams chosen to be more selective — cutting false positives and query cost. A substring query looks up its grams, intersects posting lists to get candidate blobs, then verifies the literal match. A **regex** query is handled by extracting required literal substrings from the regex, using those for gram lookups to narrow candidates, then running the full regex only on the small candidate set (the Zoekt approach). A **separate symbol index** built with Tree-sitter/ctags powers jump-to-definition and `symbol:` queries.

The ingest pipeline sustains ~120K docs/sec; a full reindex of 15.5B docs takes ~36h, halved to ~18h by **delta indexing** (only changed blobs on a push, reducing docs to crawl by >50%). Pushes flow through a queue (Kafka) so per-blob updates are incremental. Queries fan out across shards (each shard a goroutine/worker), each returning local matches; a coordinator merges and ranks (symbol matches and in-name matches ranked higher). Crucially, results honor **commit-level consistency** and **repo visibility** — a private repo's blobs never surface to unauthorized users, and a just-pushed commit isn't searchable until its blobs are processed.

### Deep dives
1. **Why word indexes fail and how ngrams/sparse-grams fix it** — A standard inverted index tokenizes on whitespace/punctuation and matches whole words (or prefixes), so it cannot find `Bar` inside `fooBarBaz`, cannot match across `snake_case`, and cannot do regex. An **ngram index** indexes every length-n character sequence with its position, so substring search becomes "intersect the postings of the query's grams, then verify." Trigrams are the size/selectivity sweet spot, but common trigrams produce too many false-positive candidates at billions of documents — so Blackbird's **sparse-grams** pick variable-length, more-selective grams (and GitHub open-sourced `sparse_ngrams`, a C++ lib targeting <100ms at billions of LOC). The result: ~640 QPS on a 64-core host vs ~0.01 QPS for brute-force ripgrep on the same corpus — five orders of magnitude from precomputed grams.
2. **Content-addressed dedup by blob OID** — Git already content-addresses every file by a SHA (the blob OID). Using it as both the dedup key and the shard key gives two wins at once: identical files (rampant via forks and vendored code) are indexed exactly once (115 TB → ~28 TB unique), and hashing the OID distributes documents evenly across shards with no hot-shard skew. The `(repo, path, blob)` document layer maps user-visible locations back onto the deduplicated blobs, so one indexed blob can answer matches for thousands of repos that contain it. This is the structural reason a 115 TB corpus fits in a 25 TB index.
3. **Commit-level consistency + delta indexing** — Developers expect search to reflect reality: if you just pushed, your new code should be findable, and you shouldn't see a half-applied state. GitHub calls commit-level query consistency "tricky to do with other search engines." Pushes trigger **delta indexing** — only the changed blobs are re-indexed (via a Kafka-driven pipeline), so a monorepo push doesn't reindex the whole repo and the index converges quickly. Combined with visibility enforcement (private blobs never leak), this makes the index a faithful, access-controlled view of the current commit graph rather than a stale batch snapshot. The interview point: for code, freshness and consistency are correctness requirements, and delta indexing is what makes them affordable at 15.5B docs.

## Known failure modes
1. **Regex query that matches no precomputed grams** — A regex like `.*` or one with no extractable literal substring can't be narrowed by gram lookup and degenerates toward a brute scan over a large candidate set, blowing the latency budget. Mitigation: a query rewriter that extracts the most selective required literals and rejects/limits pathological patterns; cap candidate-set size and return partial results with a "refine your query" signal; per-shard timeouts so one expensive regex can't stall the fan-out.
2. **Hot-repo skew (linux kernel, chromium)** — A single enormous repo's blobs, if concentrated, can overload a shard or dominate result ranking. Although blob-OID sharding spreads blobs evenly, query-time concentration on one giant repo still skews load. Mitigation: blob-OID hashing already de-correlates blobs from repos; for query-time skew, multi-shard a single large repo's search and merge intra-repo, and apply per-repo result caps so one repo can't crowd out others.
3. **Monorepo push indexing latency** — A large push to a monorepo could, naively, force a huge reindex and delay searchability of the new code. Mitigation: delta indexing on the push event indexes only the changed blobs (>50% fewer docs than full), driven through a queue so spikes are absorbed; commit-level consistency ensures users see a coherent state (old or new, not torn) while the delta is applied. Throughput headroom (~120K docs/sec) absorbs normal push volume.

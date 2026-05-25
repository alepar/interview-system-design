---
slug: autocomplete
archetype: search-indexing
sources:
  lucene_fst: blog.mikemccandless.com/2010/12/using-finite-state-transducers-in.html
  algomaster: algomaster.io/learn/system-design-interviews/design-search-autocomplete-system
  bytebytego_ch13: torontostudygroup.github.io/study-notes/notes/system-design-interview/ch13/
  algolia_speed: algolia.com/blog/engineering/our-secret-recipe-for-speed-from-search-as-you-type-to-ai-search
  google_autocomplete: support.google.com/websearch/answer/7368877
---

# Search Autocomplete / Typeahead

## Bar anchors
- **Mid-level (L4/E4):** Builds a trie of past queries and walks it on each prefix to return matches. Knows to rank by popularity. Doesn't address the per-keystroke QPS amplification, precomputed top-K, the <100ms budget, or how completions stay fresh unprompted.
- **Senior (L5/E5):** Stores top-K completions **precomputed per trie node** so a lookup is O(prefix length) + a copy rather than a subtree walk. Adds client-side debounce and edge caching, recognizes the read-heavy/keystroke-amplified load, and shards the trie by prefix. Knows completions are refreshed periodically from query logs. May not name the Lucene FST representation, quantify the latency budget precisely, or handle hot-prefix replication and i18n.
- **Staff+ (L6/E6+):** Drives proactively. Names the **precomputed-top-K-per-node** design (return = copy of K, not traversal) and the **Lucene FST suggester** (weighted finite-state transducer: far less RAM than a plain trie via shared prefix+suffix compression, O(query-length) lookup, disk-resident). Quantifies the **<50–100ms p99 budget** (Algolia targets ≤50ms end-to-end; most queries 1–20ms) and the **per-keystroke QPS amplification** (500M searches/day × ~10 keystrokes ≈ 5B autocomplete queries/day → ~170K peak QPS) — mitigated by **client debounce (~300ms cuts calls 70–80%)** and Zipfian **edge caching (tiny LRU → 90%+ hit)**. Shards the trie by **first 1–2 prefix chars** with **extra replicas for hot prefixes** ("th-", "wh-"). Handles **freshness** (hourly FST rebuild + incremental per-prefix top-K refresh; breaking-news terms) and **i18n** (locale in the shard key, index multiplies by #locales). Pairs naturally with `spell-correction` for a full query-understanding round.

## Canonical decomposition

### Requirements
**Functional:**
- Return the top-K most-relevant completions for a query prefix, as the user types
- Rank completions by popularity + recency (+ optional personalization)
- Tolerate minor typos in the prefix (bounded fuzzy match)
- Keep completions fresh as query trends shift (breaking news, new products)

**Non-functional (with numbers):**
- p99 < 50–100ms server-side (Algolia targets ≤50ms end-to-end including network)
- Per-keystroke amplification: ~170K peak QPS (5B autocomplete queries/day)
- K ≈ 5–10 completions returned
- Read:write ratio extremely high (reads per keystroke; writes batched from logs)
- Edge/client cache hit 90%+ on head prefixes (Zipfian)

### Core entities
- **TrieNode / FST arc:** character/byte transition; nodes store precomputed top-K completions
- **Completion:** text, score (popularity × time-decay + personalization), source
- **PrefixShard:** subset of the trie keyed by first 1–2 chars; replicated, hot prefixes extra-replicated
- **QueryLog:** raw query stream feeding the offline frequency/top-K recompute

### API
- `GET /autocomplete?q=<prefix>&locale=<l>` → [{completion, score}] top-K, <100ms
- Internal: offline job aggregates query-log frequencies → recompute per-node top-K → rebuild FST
- Internal: `trie.topK(prefix) → [completion]` returns the precomputed list at the prefix's terminal node

### HLD
Reads dominate, so the design precomputes aggressively. An **offline pipeline** (MapReduce/Spark over query logs, often sampling — e.g. every 1000th query — to bound cost) computes each candidate completion's score (popularity with exponential time-decay, optionally per-locale) and the **top-K completions for every prefix**, materialized into the index node for that prefix. The serving structure is either an in-memory **trie with top-K stored per node** (lookup = walk to the prefix node, return its precomputed K — O(prefix length) + copy) or a **Lucene-style weighted FST** (a finite-state transducer that compresses shared prefixes *and* suffixes, fitting far more completions in RAM/disk than a plain trie, with O(query-length) lookup at a higher per-step CPU cost).

The trie/FST is **sharded by the first 1–2 characters** with consistent hashing; hot prefixes get extra replicas because query popularity over prefixes is itself skewed. In front sits a **cache hierarchy**: browser LRU → service-worker/IndexedDB → CDN/edge → backend. Because prefix popularity is **Zipfian**, a small edge cache captures the vast majority of traffic. The client **debounces** keystrokes (~300ms) and drops ≤1-character queries, cutting the keystroke-amplified QPS by 70–80% before it ever leaves the device. Personalization is layered client-side: the server returns the global top-K and the client merges in the user's recent searches from localStorage, avoiding per-user server state on the hot path.

Freshness: the FST/trie is fully rebuilt periodically (e.g. hourly) from fresh logs, with incremental per-prefix top-K updates for fast-moving terms so breaking-news completions appear without waiting for the full rebuild.

### Deep dives
1. **Precomputed top-K per node vs traversal, and trie vs FST** — Walking a trie's subtree at query time to find the most popular completions is too slow under a <100ms budget at 170K QPS, so each node **stores its top-K precomputed** — the lookup degenerates to "navigate to the prefix node, copy K." The trade is space (every node stores K) for time, which is the right trade for a read-dominated system. The FST is the memory-efficient evolution: by sharing both prefixes and suffixes it stores vastly more completions per GB than a plain trie (Lucene uses FSTs for suggesters, term dictionaries, and synonyms), at the cost of higher per-lookup CPU and a more complex update (rebuild rather than mutate). Choose trie-in-RAM when the completion set fits and updates are frequent; FST when the set is huge or disk-resident.
2. **Surviving per-keystroke QPS amplification** — The naive design issues one query per keystroke, multiplying search QPS by ~10×. Three compounding mitigations: (a) **client-side debounce** (~300ms) so only a typing *pause* triggers a request — cuts 70–80% of calls and feels instant; (b) **drop trivially-short prefixes** (≤1 char return nothing useful); (c) **edge caching** of completions — because prefix popularity is Zipfian, a tiny LRU at the CDN yields a 90%+ hit rate, so most keystrokes never reach the backend. What remains is a small, cacheable, highly-skewed tail. The Staff+ framing: autocomplete is a caching problem wearing a search problem's clothes.
3. **Freshness, hot prefixes, and i18n** — Completions must track query trends: a full FST rebuild hourly from logs handles drift, while incremental per-prefix top-K updates surface breaking-news terms in minutes. Prefix popularity is skewed, so shards for hot prefixes ("th-", "wh-", "fa-") need extra replicas to avoid becoming the latency bottleneck; sharding by first 1–2 chars (extending to 2nd/3rd char where one char is too coarse) balances this. Internationalization multiplies the index: completions are locale-specific, so locale goes in the shard key and the effective index size scales with the number of supported locales — a real capacity-planning input, not an afterthought.

## Known failure modes
1. **Spike overload (trending event)** — A breaking event makes everyone type the same prefix, and the per-keystroke amplification turns it into a backend flood. Mitigation: aggressive client debounce, edge-cache the trending completions with a short TTL (identical across users → near-100% hit), drop ≤1-char queries, and load-shed if the backend saturates. The cache is what keeps a viral prefix from melting the serving tier.
2. **Stale or low-quality suggestions** — If completions are only rebuilt slowly, breaking-news terms never surface and disappearing trends linger; worse, surfacing offensive or misleading completions is a reputational/safety problem. Mitigation: hourly full rebuild + incremental per-prefix refresh for freshness; a blocklist/policy filter applied at build time; time-decay scoring so stale trends fade. Treat "what we suggest" as a published statement subject to safety review, not just a popularity readout.
3. **Latency budget blown by fuzzy matching or personalization** — Unbounded edit-distance fuzzy matching explodes the candidate set (edit distance >2 matches a large fraction of the dictionary), and per-user server-side personalization adds a lookup on the hot path. Mitigation: cap fuzzy matching at Levenshtein ≤2 via a Levenshtein-automaton-aware FST traversal; do personalization client-side (merge recent searches locally) so the server path stays a stateless cached lookup; keep the server response to the global top-K within the <100ms budget.

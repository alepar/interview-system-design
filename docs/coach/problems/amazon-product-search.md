---
slug: amazon-product-search
archetype: search-indexing
sources:
  semantic_product_search: arxiv.org/pdf/1907.00937
  linden_speed: glinden.blogspot.com (Greg Linden, "Make Data Useful", Nov 2006)
  faceting: paradedb.com/learn/search-concepts/faceting
  solr_faceting: solr.apache.org/guide/solr/latest/query-guide/faceting.html
  amazon_latency: gigaspaces.com/blog/amazon-found-every-100ms-of-latency-cost-them-1-in-sales
---

# Amazon / E-commerce Product Search (faceted nav + inventory-aware ranking)

## Bar anchors
- **Mid-level (L4/E4):** Builds product search as text matching over a product catalog with filters. Knows ranking by relevance and that filters exist. Doesn't address faceted-count computation, inventory-aware ranking, or the latency-revenue link unprompted.
- **Senior (L5/E5):** Adds **faceted navigation** (filter by brand/price/category with counts) and recognizes ranking blends relevance with business signals (sales, reviews). Knows out-of-stock items should be down-ranked and that the catalog is large. Discusses caching for popular queries. May not articulate how facet counts are computed efficiently (doc-values/aggregations), inventory-update freshness, head/tail query handling, or query reformulation.
- **Staff+ (L6/E6+):** Drives proactively. Computes **faceted counts via doc-values + terms-agg (exact: brand/size) + range-agg (continuous: price)** in the same index scan, not separate queries. Makes ranking **inventory-aware** via near-real-time updates (CDC → Kafka → partial-doc update → NRT refresh so out-of-stock vanishes in seconds). Distinguishes **head vs tail queries** (head: cacheable, optimize p99; tail: single-shot, optimize median; rewrite sparse tail → behavior-rich head). Quantifies the **latency-revenue link** (Amazon: every 100ms ≈ 1% sales — citing the qualitative claim's real provenance, Greg Linden 2006, and flagging the "1%" as slide-deck not paper). References **Amazon Semantic Product Search** (KDD 2019): word uni/bigrams + char-trigrams + OOV hashing, a 3-part hinge loss (purchased / impressed-not-purchased / random). Names the **sponsored blend** (two-track organic + ad).

## Canonical decomposition

### Requirements
**Functional:**
- Full-text + structured-attribute product search over a huge catalog
- Faceted navigation: filter by brand/price/size/rating with live counts
- Rank by relevance + business signals (conversion, sales velocity, reviews, inventory)
- Down-rank/filter out-of-stock; reflect inventory changes quickly
- Query reformulation (spell, plural, synonym); blend sponsored results

**Non-functional (with numbers):**
- Catalog hundreds of millions of SKUs; embeddings of billions of products at scale
- Latency directly monetized: Amazon ~100ms = ~1% sales
- Inventory freshness: out-of-stock reflected within seconds (NRT partial update)
- Head queries cacheable (Zipfian); tail queries single-shot
- p99 a first-class SLO (it's a revenue metric, not just a quality metric)

### Core entities
- **Product:** sku, title, attributes{brand,size,color,…}, price, in_stock, sales_velocity, rating, embedding
- **Facet:** attribute → value → count (computed from doc-values at query time)
- **InventoryEvent:** sku, in_stock delta (CDC stream → partial-doc update)
- **Query:** raw → reformulated (spell/plural/synonym/tail→head) terms
- **RankingFeatures:** relevance + conversion priors + sales velocity + inventory + ad bid

### API
- `GET /search?q=...&brand=...&price=...&sort=...` → ranked products + facet counts
- Internal: inventory CDC → Kafka → `PUT product/_update/:sku {in_stock}` → NRT refresh
- Internal: query reformulation pipeline (tokenize → spell → synonym → plural/lemma)
- Internal: faceting via terms-agg (exact) + range-agg (price buckets) over doc-values

### HLD
Products are indexed with both a **text index** (title/description) and **structured attributes** stored as **doc-values** (columnar) for filtering, sorting, and faceting. A query is first **reformulated**: tokenized, spell-corrected (see `spell-correction`), plural/lemma-normalized, and synonym-expanded; a sparse **tail** query may be rewritten toward a behavior-rich **head** query to inherit its richer signals while preserving intent. The reformulated query retrieves candidates (lexical, increasingly hybrid with a semantic leg — Amazon's Semantic Product Search learns query/product embeddings from purchase behavior with a 3-part hinge loss separating *purchased* / *impressed-not-purchased* / *random*).

**Faceting** is computed in the **same index scan** that retrieves matches: terms-aggregations count exact attribute values (brand, size, color), range-aggregations bucket continuous values (price histograms), and cardinality-aggregations power "N+ brands" counters — all reading doc-values columns, so no document re-read and no separate aggregation query. **Ranking** blends text relevance with business signals: per-product conversion/sales-velocity priors precomputed nightly, review signals, and — critically — **inventory**. Inventory is kept fresh by a **CDC stream** (inventory DB → Kafka) that issues **partial-document updates** to the search index; with NRT refresh, an out-of-stock SKU is down-ranked or filtered within seconds, because showing buyable items is the whole point.

**Sponsored results** are a second track: ads are scored on their own relevance × bid and **calibrated into fixed slots** alongside organic results. The serving tier caches **head queries** aggressively (Zipfian, identical across users) and pre-warms promoted queries before flash sales; the **tail** is optimized for median latency since each tail query is essentially unique. Latency is treated as a revenue SLO end-to-end.

### Deep dives
1. **Faceted counts without a second query** — Naively, computing "237 results, 40 Nike, 18 under $50" would require separate count queries per facet value — far too slow. Instead, facet counts are computed during the **same scan** that retrieves matches, by reading **doc-values** (a per-field columnar structure written at index time): terms-aggregations tally exact values via compact integer ordinals/bitsets in memory, range-aggregations bucket continuous fields like price. Fields used only for faceting (not full-text search) are configured `indexed=false, docValues=true`. The result: facet counts are a near-free byproduct of the result scan, computed in memory over columnar data, not N extra queries. This is why doc-values (off-heap, columnar) are the load-bearing structure for e-commerce search, distinct from the inverted index that serves text match.
2. **Inventory-aware ranking via CDC** — Out-of-stock products must disappear from (or sink in) results fast: a top-ranked item that's unbuyable wastes the most valuable slot, and a stockout measurably craters a product's rank. So inventory is a **near-real-time ranking signal**, fed by change-data-capture from the inventory system into Kafka, applied as **partial-document updates** to the search index (update just the `in_stock`/quantity field, not the whole doc), made visible by NRT refresh within seconds. A query-time filter is the fallback for the brief window before the update lands. The Staff+ framing: e-commerce ranking is a *streaming* problem as much as an IR problem — the index must track a fast-moving real-world state (stock, price), and the pipeline latency (CDC → index) is a direct ranking-quality lever.
3. **Head/tail queries + the latency-revenue link** — E-commerce query traffic is sharply Zipfian: a short, lumpy **head** of high-frequency queries with rich behavioral history, and a long **tail** of rare, specific queries. They want opposite treatment: head queries are cached (identical across users, high hit rate) and optimized for p99 under load (flash-sale stampede → pre-warm + per-key locking); tail queries each occur ~once, can't be cached, and are optimized for median, often via **reformulation** to map a sparse tail query onto a head query's signal-rich neighborhood. Underlying all of it: latency is **monetized** — Amazon's classic finding that every 100ms of added latency costs ~1% of sales (the qualitative "substantial and costly drops in revenue" is verbatim from Greg Linden's 2006 talk; the "1%" is from the accompanying slides) — so p99 is a revenue SLO, not just a UX nicety, which justifies aggressive caching, pre-warming, and the doc-values/agg machinery that keeps faceted queries fast.

## Known failure modes
1. **Stale inventory shows out-of-stock items** — A lag between the inventory system and the search index surfaces unbuyable products in top results, wasting the best slots and harming conversion. Mitigation: CDC → Kafka → partial-doc update with NRT refresh so stock changes reflect in seconds, plus a query-time `in_stock` filter as the fallback for the sub-second window before the update lands.
2. **Facet-count drift under partial updates** — Frequent partial-document updates (inventory, price) can, over many segment merges and tombstones, let aggregation counts drift from the true state. Mitigation: periodically rebuild aggregations on a shadow index and alias-swap, and force-merge read-stable indices; treat facet counts as eventually-consistent and reconcile on a schedule rather than assuming partial updates keep them exact forever.
3. **Head-query cache stampede on a flash sale** — A flash sale concentrates traffic on a few queries; if their cache entries expire simultaneously, the backend is stampeded by identical expensive queries. Mitigation: pre-warm the promoted queries' cache before the sale, use per-key locking / request coalescing so only one backend computation happens per key on miss, and stagger TTLs so popular entries don't all expire together.

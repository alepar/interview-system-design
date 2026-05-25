---
slug: geo-place-search
archetype: search-indexing
sources:
  yelp_es: engineeringblog.yelp.com/2017/06/moving-yelps-core-business-search-to-elasticsearch.html
  yelp_ltr: engineeringblog.yelp.com/2014/12/learning-to-rank-for-business-matching.html
  yelp_nrtsearch: engineeringblog.yelp.com/2021/09/nrtsearch-yelps-fast-scalable-and-cost-effective-search-engine.html
  es_distance_feature: elastic.co/blog/distance-feature-query-time-and-geo-in-elasticsearch-result-ranking
  h3: h3geo.org/docs/
  s2: joudwawad.medium.com/location-indexing-complete-guide-36a143569555
---

# Geo / Place Search (Yelp/Maps) — text relevance + geo-proximity ranking

## Bar anchors
- **Mid-level (L4/E4):** Proposes storing places with lat/lng and finding nearby ones by distance, plus text match on name. Knows about geo distance. Doesn't address geo-indexing as a filter, combining proximity with text relevance + other signals, or how this differs from a dispatch system unprompted.
- **Senior (L5/E5):** Uses a **geo index (geohash/S2/H3)** to filter candidates by region, then text-matches and ranks by a blend of relevance + distance + rating. Knows naive lat/lng range scans don't scale. Distinguishes this from real-time vehicle dispatch. May not articulate geo-index-as-coarse-filter vs ranking-signal, distance-decay ranking, per-query filter inference, LTR-on-a-recall-engine, or the Nrtsearch segment-replication win.
- **Staff+ (L6/E6+):** Drives proactively. Treats **geohash/S2/H3 as a coarse FILTER** (narrow to candidates in a region), **not** as a ranking signal itself — then ranks with **text relevance + distance-decay**. Names **distance_feature ranking** (`BM25 × exp(-λ·distance)` or ES `distance_feature`, folding proximity into the *score* rather than hard-sorting by distance). Adds **per-query language-model filter inference** (Yelp inferring "outdoor seating" from "after work bars") and **LTR rerank on a recall engine** (Yelp uses ES as a recall engine, then a separate ML ranker). Cites **Yelp's Nrtsearch migration** (>90% of ES traffic; primary indexes once, replicas pull pre-built Lucene segments from S3; p50/p95/p99 −30–50%, cost −up to 40%). **Delineates from `uber`**: this is **IR over mostly-static geo-indexed places**, not real-time proximity/dispatch of moving entities. Quantifies: Google Maps **200M+ businesses** (~1.5M new/month); H3 res-9 ~0.1 km².

## Canonical decomposition

### Requirements
**Functional:**
- Text search over places ("pizza", "after work bars") combined with location
- Rank by relevance + proximity + quality (rating, popularity, hours/open-now)
- Filter by attributes (cuisine, price, outdoor seating) — some inferred from the query
- Keep place data fresh (hours, closures, new businesses)

**Non-functional (with numbers):**
- Corpus 200M+ places (Google Maps; ~1.5M new/month)
- Geo filter narrows to a region before scoring (geohash/S2/H3)
- Query latency competitive with consumer search (recall engine + LTR rerank)
- Place data mostly static (vs uber's high-frequency moving entities)
- Nrtsearch: p50/p95/p99 −30–50%, cost −up to 40% vs Elasticsearch

### Core entities
- **Place:** place_id, name, lat/lng, geo_cell (geohash/S2/H3), category, attributes, rating, hours, is_open
- **GeoIndex:** geohash/S2/H3 cell → places (the coarse spatial filter)
- **Query:** text + location (+ radius/viewport) + inferred filters
- **RankingFeatures:** text relevance + distance + rating/popularity + open-now (fed to LTR)

### API
- `GET /search?q=...&lat=..&lng=..&radius=..` → ranked places (relevance × proximity × quality)
- Internal: geo-filter (cell prefix / cell-cover of the viewport) → candidate places
- Internal: weighted-subquery relevance (name TF-IDF + location text + distance_feature)
- Internal: LTR rerank over the recall engine's candidate pool

### HLD
Places are indexed in a Lucene-based engine with a **geo index** (geohash, S2, or H3 cell) alongside text and attributes. A query carries text + a location (point + radius, or a viewport). The **geo index is used as a coarse filter**: resolve the query location to cells (a geohash prefix, or an S2/H3 cell cover of the viewport) and retrieve only places in those cells — so the engine scans far fewer documents than a global lat/lng range scan. Indexing geohash *prefixes* (edge n-grams) lets the filter be a fast exact prefix match rather than an expensive wildcard.

On the filtered candidate set, **relevance** is a **weighted combination of subqueries** (Yelp's model): a name subquery (TF-IDF match on business name), a location-text subquery, a phone subquery, and a **distance subquery** that boosts closer businesses. Crucially, proximity is folded into the **score**, not used to hard-sort — a slightly-farther but far-more-relevant place should outrank a nearby irrelevant one. This is `distance_feature`-style ranking (ES 7.2+): `score ≈ BM25 × exp(-λ·distance)` (a saturation/decay function), so distance is one weighted signal among many. Some attributes are **inferred per-query** by a language model (Yelp infers "outdoor seating" from "after work bars") and applied as soft filters/boosts.

For quality, the engine acts as a **recall engine** (good at fetching a relevant candidate pool fast) and a separate **learning-to-rank** layer reranks the pool over hundreds of signals (relevance, distance, rating, popularity, open-now, personalization) — extracting the heavy ranking out of the search engine into an ML layer. Yelp's serving moved from Elasticsearch to **Nrtsearch** (Lucene-based, gRPC) using **near-real-time segment replication**: the primary indexes once and replicas pull pre-built segments from S3, so nodes start/stop without rebalancing — improving p50/p95/p99 30–50% and cutting cost up to 40%. Freshness (hours, closures, new places) is handled by NRT partial updates + a query-time open-now filter.

### Deep dives
1. **Geo index as a filter, not a ranking signal** — The common mistake is treating the geo-index cell as the answer. Its job is **candidate narrowing**: geohash/S2/H3 partition the globe so "places near here" becomes "places in these cells," turning an O(corpus) distance scan into an O(cell contents) lookup. The choice among them is about cell geometry — **geohash** (base-32 prefix, simple, but prefix-breaks at the equator/meridian and non-uniform cell shapes), **S2** (cube projection + Hilbert curve, great for polygon/geofence containment, used by Google Maps), **H3** (hexagonal, uniform neighbor distance, great when adjacency matters) — but all three serve the same role here: a fast spatial filter. The *actual distance* is then computed precisely on the small candidate set and fed into ranking as a decayed signal. Confusing "which cell" (filter) with "how to rank" (score) is the Senior-vs-Staff line.
2. **Distance-decay ranking + per-query filter inference** — Hard-sorting by distance is wrong (the nearest place is often not the best answer); ignoring distance is also wrong (a great restaurant 40km away shouldn't top a "near me" search). The resolution is to fold distance into the **relevance score** via a decay function — `BM25 × exp(-λ·distance)` or ES `distance_feature` — so proximity is a tunable weight balanced against text relevance, rating, and popularity. Yelp's weighted-subquery model makes this explicit (name TF-IDF + distance subquery + …). On top, **per-query filter inference** uses a language model to map fuzzy intent to structured filters ("after work bars" → open-late + drinks + maybe outdoor seating), applied as soft boosts so the system answers the intent, not just the literal tokens. The Staff+ point: geo search is multi-objective ranking where distance is one weighted objective, and the weights (λ) are tunable per market/query-class.
3. **Recall engine + LTR, and the Nrtsearch segment-replication win** — Heavy ranking (hundreds of signals, ML models) doesn't belong inside the inverted-index query — it's too expensive to express and tune there. So the architecture splits: the search engine is a **recall engine** that fetches a relevant candidate pool fast (geo-filter + weighted relevance), and a separate **learning-to-rank** layer reranks that pool with the full feature set (relevance, distance, rating, open-now, personalization). (Keep the LTR model *training* shallow — that's the ml-in-loop archetype; here it's a serving-side rerank over the recall pool.) The operational lesson is Yelp's **Nrtsearch** migration: Elasticsearch's per-replica indexing CPU didn't scale, so they moved to Lucene-based Nrtsearch with **segment replication** (primary indexes once; replicas pull built segments from S3), letting nodes scale in/out without rebalancing and cutting p50/p95/p99 by 30–50% and cost up to 40% — the same indexing-CPU lesson as the `elasticsearch` problem, applied to a geo workload.

## Known failure modes
1. **Geohash prefix-break at cell boundaries** — A place just across a geohash cell boundary (or the equator/meridian) shares almost no prefix with the query point, so a prefix-only geo filter misses nearby results sitting in an adjacent cell. Mitigation: query the query cell *plus* its neighbors (geohash neighbor expansion), or use S2/H3 whose cell-cover of a viewport explicitly includes boundary-adjacent cells; never rely on a single prefix to capture "nearby."
2. **Hot-city skew** — Dense metros (NYC, SF) pack vastly more places into a cell than rural areas, so a single geo shard for a hot city becomes a CPU/latency hotspot while rural shards idle. Mitigation: sub-shard hot cities by finer H3/S2 cells within the city, and balance shards by document count rather than by uniform geographic area, so load tracks place density not land area.
3. **Stale hours / closures** — A place's hours change or it permanently closes, but the index still shows it as open and top-ranked, sending users to a closed business. Mitigation: NRT partial updates for hours/`is_open`/`permanently_closed` (driven by CDC from the place database), a query-time open-now filter as the fallback, and down-ranking/removing permanently-closed places promptly — treating place metadata as a fast-moving signal, not static reference data.

## (Delineation note)
This is the **IR angle on geo** — text-relevance ranked search over mostly-static places, with the geo index as a filter and distance as a ranking signal. Real-time proximity matching and dispatch of *moving* entities (drivers/riders) is the `uber` problem in the geo-proximity archetype.

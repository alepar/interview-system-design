---
slug: h3-s2-spatial-index
archetype: geo-proximity
sources:
  uber_h3: uber.com/blog/h3/
  h3_restable: h3geo.org/docs/core-library/restable
  uber_disco: dev.to/madhur_banger/architecting-an-uber-scale-real-time-tracking-dispatch-system-3a72
  s2_hierarchy: s2geometry.io/devguide/s2cell_hierarchy.html
  bytebytego_proximity: blog.bytebytego.com/p/proximity-service
  pokemongo: pokemongohub.net/post/article/comprehensive-guide-s2-cells-pokemon-go/
---

# H3 vs S2 vs alternative spatial indexes — H3 (Uber, hex-based, 16 resolutions 0-15, 122 base cells = 110 hex + 12 pentagons at icosahedron vertices, each resolution ~1/7 area of parent, non-perfect nesting unlike S2's strict quadtree) + H3 defining advantage: uniform-distance-to-neighbors enables clean k-ring queries (Uber DISCO 167K location updates/sec via res-9) + H3 has 12 unavoidable pentagons per resolution (placed over ocean) + S2 (Google, cube projection + Hilbert curve + 64-bit cell IDs, 31 levels) + S2 killer feature: 6 stitched Hilbert curves → any region = small set of contiguous integer ranges → B-tree range query = geospatial query for free + S2 region-coverer mixes cell levels for arbitrary polygons (wins for irregular geofence shapes) + Pokémon GO uses L17/L20/L16 simultaneously

## Bar anchors
- **Mid-level (L4/E4):** No spatial index choice; uses naive lat/lon range queries.
- **Senior (L5/E5):** Names H3 OR S2 OR geohash without deep trade analysis.
- **Staff+ (L6/E6+):** Names (a) **H3**: hex-based, 16 resolutions (0-15), 122 base cells (110 hex + 12 pentagons at icosahedron vertices); each resolution ~1/7 area of parent — non-perfect nesting; (b) **H3 defining advantage**: "hexagons have only one distance between centerpoint and neighbors, compared to two for squares or three for triangles" — uniform k-ring distance enables clean gradient analysis (surge propagation); (c) **H3 resolution cheat sheet**: res 5 ~253 km² (city), res 8 ~0.74 km² (surge default), res 9 ~0.11 km² (city block, dispatch), res 15 ~0.9 m²; total cells at res 15: 569.7 trillion; (d) **Uber DISCO** processes 167K location updates/sec via res-9 H3 cell; k-ring (origin + 6 neighbors) queries ~1-2 km candidate set; (e) **H3 has 12 unavoidable pentagons per resolution** at icosahedron vertices (placed over ocean to minimize urban impact); hex area max/min 1.21 (res 0) → 1.99 (res 15) — exact area aggregation must compensate; (f) **S2 projects cube onto sphere** then recursively subdivides each face into 4 children for 31 levels (0-30). Cell ID 64-bit: 3-bit face + 60-bit Hilbert position + trailing 1-bit level marker; (g) **S2 killer feature**: 6 Hilbert curves stitched into one loop covering sphere. Any spatial region = small set of contiguous integer ranges → range queries on B-tree (Bigtable/Spanner) become geospatial queries for free; (h) **S2 leaf cells (level 30)**: 6 × 4^30 ≈ 6.9 × 10^18 cells, ~1 cm across — every cm² of Earth addressable in 64-bit integer; (i) **S2 region-coverer mixes cell levels in single cover** — large interior + small edge — to approximate arbitrary polygons cheaply. S2 wins for irregular geofence shapes; H3 forces single-resolution cover; (j) **Pokémon GO uses multiple S2 levels** for distinct mechanics: L17 wayspot import, L16 Gym/PokéStop display within 630m, L20 spawn cells (Pokémon center within 50m) — canonical multi-level S2 production example.

## Canonical decomposition

### Requirements
**Functional:**
- Index points (driver, place, spawn, beacon) for fast proximity query
- Range queries within bounded distance
- k-NN queries
- Region coverage for arbitrary polygons (geofence)

**Non-functional:**
- 64-bit integer cell ID for B-tree indexing
- Uniform-distance-to-neighbors for k-ring (H3 advantage)
- Region-cover with mixed levels (S2 advantage)
- Sub-millisecond cell lookup

### Core entities
- **H3Cell:** 64-bit ID; res 0-15; ~1/7 area per resolution drop; 122 base cells
- **S2CellID:** 64-bit = 3-bit face + 60-bit Hilbert position + 1-bit level marker
- **Geohash:** base-32 string; interleaved lat/lon bits
- **RegionCover:** set of (cell_id, level) tuples approximating polygon

### API
- H3: `geoToH3(lat, lon, res)` → cell_id; `kRing(cell_id, k)` → cells[]
- S2: `S2CellId.FromPoint(lat, lon, level)` → cell_id; `RegionCoverer(min_level, max_level, max_cells).GetCovering(polygon)` → cells[]
- Geohash: `encode(lat, lon, precision)` → string; `neighbors(geohash)` → 8 strings

### HLD
Choice depends on workload:

**H3 — best for**: uniform-distance gradient analysis (Uber surge propagation), k-ring matchmaking (Uber DISCO 167K updates/sec via res-9 + k-ring(1) = 7 cells), uniform-cell area for aggregation. Trade: 12 pentagons (placed over ocean) + non-perfect nesting (1/7 ratio).

**S2 — best for**: arbitrary-shape region cover (Pokémon GO multi-level: L17 wayspots + L16 stop display + L20 spawn), B-tree range-indexable cell IDs (Spanner/Bigtable integration without bespoke spatial code), exact hierarchical aggregation. Trade: cube-face distortion + non-uniform neighbor distances.

**Geohash — best for**: prefix-indexable proxy in existing string-key DBs (Redis sorted-sets with 52-bit interleaved geohash, Elasticsearch geohash grid). Trade: meridian/pole boundary failures + pole distortion.

**R-tree / quadtree — best for**: arbitrary polygon containment (overlapping rectangles), adaptive density. Less common for global production but appears in PostGIS / map renderer pipelines.

### Deep dives
1. **H3 hex-cell structure + pentagons + uniform-neighbor property.** 16 resolutions; 122 base cells (110 hex + 12 pentagons at icosahedron vertices, over ocean). Each resolution ~1/7 area of parent — non-perfect nesting. Uniform distance to neighbors enables clean k-ring queries. Area non-uniformity 1.21-1.99 max/min ratio.
2. **S2 cube + Hilbert curve + range-query indexing.** Cube projection → 6 faces → recursive 4-way subdivision → 31 levels. 64-bit cell ID = 3-bit face + 60-bit Hilbert position + trailing 1-bit level marker. 6 stitched Hilbert curves: any region = small set of contiguous integer ranges → B-tree range query = geospatial query.
3. **S2 region-coverer mixes levels + Pokémon GO multi-level production example.** Region-coverer combines large interior + small edge cells for arbitrary polygon cover. H3 forces single-resolution. Pokémon GO: L17 wayspot import / L16 Gym display 630m radius / L20 spawn cells 50m radius.

## Known failure modes
1. *H3 pentagons over ocean still impact globally-distributed workloads*. Production answer: detect pentagon membership; fall back to S2 region-coverer for those cells.
2. *S2 cell distortion across cube faces* — cells near face boundaries are non-square. Production answer: region-coverer abstracts; rare to require exact-shape cells.
3. *H3 non-perfect nesting (1/7 area)* makes hierarchical aggregation tricky. Production answer: roll up to coarser resolution + manual rebalancing.

## Notes for the coach
- **Plausibly-asked at Uber, Google, Niantic, Foursquare, Pinterest.** H3 docs + S2 docs + Pokémon GO + Uber DISCO are canon.
- **Cross-coverage** with `uber` + `lyft-dispatch` (this archetype; H3 vs S2 in dispatch). With `google-maps-routing` (this archetype; S2 for vector tiles). With `geofence-notifications` (this archetype; S2 region-coverer for fence shapes).
- **The hex-uniform-neighbor (H3) vs cube-Hilbert-range-query (S2) trade is the canonical Staff+ unlock.** Mid-senior candidates pick one without justification; Staff+ candidates name the workload-specific reason.
- **Adversarial probe: "You're designing global ridesharing dispatch. H3 has 12 pentagons. What breaks at scale?"** Strong answer: pentagons placed over ocean → no urban areas affected; detect pentagon membership at request time (`isPentagon(cell_id)`); for queries that span a pentagon, fall back to S2 region-coverer for those cells OR widen k-ring to compensate for missing neighbor; for global surge analysis, hex uniform-neighbor advantage outweighs pentagon edge cases because no major city sits on a pentagon vertex. Trade analysis: H3 wins on uniform distance to neighbors (clean gradient propagation); S2 wins on arbitrary-shape region cover. Weak answer: "use S2" without naming the workload-specific reason.

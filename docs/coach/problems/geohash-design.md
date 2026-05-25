---
slug: geohash-design
archetype: geo-proximity
sources:
  wikipedia: en.wikipedia.org/wiki/Geohash
  neighbor_walkthrough: kbabuji.com/articles/geohash/
---

# Geohash — Gustavo Niemeyer 2008 public domain + interleaves bits of latitude and longitude + base-32 encodes the bitstring + hierarchical by construction (longer string = strict prefix of shorter, shared prefix → spatial proximity) + precision: 1 char ±2,500 km / 5 chars ±2.4 km / 8 chars ±19 m / 12 chars sub-meter (each added char shrinks cell by ~factor 32 via alternating lat/lon halvings) + two baked-in failure modes: (1) prefix→proximity is ONE-WAY (nearby points across meridian/poles share zero prefix), (2) cell shape distorts toward poles + standard k-NN workaround: union-search center + 8 neighbors (9× prefix scans) + production adoption: Elasticsearch + MongoDB + Redis (GEOADD = 52-bit interleaved geohash in sorted set) + HBase

## Bar anchors
- **Mid-level (L4/E4):** No spatial encoding; lat/lon range queries.
- **Senior (L5/E5):** Names geohash. May or may not articulate prefix-proximity property, neighbor algorithm, or meridian/pole failure modes.
- **Staff+ (L6/E6+):** Names (a) **Geohash** (Gustavo Niemeyer, 2008, public domain): interleaves bits of lat + lon, base-32 encodes bitstring; hierarchical — longer = strict prefix of shorter, shared prefix → spatial proximity; (b) **Precision table**: 1 char ±2,500 km / 5 chars ±2.4 km / 8 chars ±19 m / 12 chars sub-meter; each added char shrinks cell by ~factor 32 (alternating lat/lon halvings); (c) **Two baked-in failure modes**: (1) prefix→proximity implication is ONE-WAY — nearby points across cell boundary can share zero prefix (just east/west of meridian); (2) cell shape distorts toward poles since lat/lon aren't equal-area; (d) **Standard k-NN workaround**: compute 8 neighbors of query cell + union-search center + 8 neighbors. Buys correctness at 9× prefix scans; (e) **Neighbor computation**: decode geohash to center lat/lon, derive cell width/height from bit-count split between lat and lon, then re-encode 8 perturbed centers. Lookup tables per base-32 char also exist for O(1) neighbor without decode; (f) **Production adoption**: Elasticsearch, MongoDB, Redis (GEOADD stores 52-bit interleaved geohash in sorted set), HBase — leverages existing B-tree/LSM string indexes without bespoke spatial code.

## Canonical decomposition

### Requirements
**Functional:**
- Encode (lat, lon) → string (variable precision)
- Decode string → (lat, lon, error_bounds)
- Compute 8 neighbors
- Prefix scan for "find all in cell"

**Non-functional:**
- Encoding is base-32 string of arbitrary length
- Hierarchical: prefix containment
- B-tree/LSM string-index compatible

### Core entities
- **Geohash:** base-32 string (e.g., `9q8yyk8ytpxr`)
- **CellBounds:** {min_lat, max_lat, min_lon, max_lon}
- **NeighborSet:** 8 strings (N, NE, E, SE, S, SW, W, NW) + center

### API
- `encode(lat, lon, precision) → geohash`
- `decode(geohash) → (center_lat, center_lon, lat_err, lon_err)`
- `neighbors(geohash) → 8 strings`

### HLD
Encoding: interleave bits of lat (binary search 90 → -90) + lon (binary search 180 → -180). After N bit interleaves, base-32 encode (5 bits per char). Result: alternating lat/lon halvings give equal-information per char.

Decoding: parse base-32 char-by-char; reconstruct bit interleave; binary-search lat/lon ranges; result = (center, lat_err, lon_err).

Neighbor algorithm (option A): decode → derive cell width/height → encode 8 perturbed centers. (Option B): lookup table per base-32 char giving N/E neighbor; combine for diagonals.

k-NN: query cell + 8 neighbors → 9× prefix scans → union results → distance-filter to top-K.

Production: Redis GEOADD encodes (lat, lon) → 52-bit interleaved geohash → ZADD to sorted set. GEORADIUS = compute query-cell + neighbor cells + ZRANGEBYSCORE + post-filter by distance.

### Deep dives
1. **Niemeyer encoding + precision table.** Interleave bits of lat + lon, base-32 encode. Hierarchical by construction. Each added char shrinks cell by ~factor 32. Precision: 1 char ±2,500 km → 12 chars sub-meter.
2. **Boundary + pole failure modes + neighbor workaround.** Prefix→proximity is one-way. Nearby points across meridian/pole share zero prefix. Pole cells distort because lat/lon aren't equal-area. Standard k-NN: union-search center + 8 neighbors (9× prefix scans).
3. **Production adoption: Elasticsearch / MongoDB / Redis / HBase.** Geohash as string-prefix-indexable proxy for 2D proximity. Leverages existing B-tree/LSM string indexes without bespoke spatial code. Redis GEOADD = 52-bit interleaved geohash in sorted set; GEORADIUS = prefix scan + post-filter by distance.

## Known failure modes
1. *Meridian/pole boundary failure* — nearby points share zero prefix. Production answer: 8-neighbor union (9× scans) or migrate to H3/S2.
2. *Pole distortion* — cells become elongated. Production answer: H3/S2 if global coverage matters.
3. *Hot prefix in dense cities* — many places share long prefix. Production answer: include category in routing key (Yelp pattern); adaptive split/merge.

## Notes for the coach
- **Asked-confirmed at any company with geo data.** Foundational primitive. Hello Interview + ByteByteGo cover.
- **Cross-coverage** with `h3-s2-spatial-index` (this archetype; alternative primitives). With `yelp-search` (this archetype; geosharding by geohash). With infra-primitives #10 (Redis GEOADD).
- **The meridian/pole one-way prefix-proximity failure mode + 8-neighbor 9×-scan workaround is the canonical Staff+ unlock.** Mid-senior candidates use geohash naively; Staff+ candidates name the boundary failure + neighbor workaround.
- **Adversarial probe: "Find all restaurants within 1km of (37.7749, -122.4194)."** Strong answer: encode query point to 5-char geohash (~±2.4km cell). Geohash radix is 32 = 5 bits per char; 5 chars = 25 bits → cell ~4.9km × 4.9km (alternating lat/lon halvings make actual width vary by latitude — at SF latitude ~4.9km lon × ~4.9km lat). For 1km radius, that's overkill — use 6-char ~±0.61km. Query Redis: ZRANGEBYLEX center-cell-prefix-range + neighbor cells (8 more); union results; haversine post-filter to distance < 1km; sort by distance; return top-K. Watch for meridian/pole edge case (not in SF but framework should handle). Weak answer: "use Redis GEORADIUS" without naming the cell-precision choice and neighbor inclusion.

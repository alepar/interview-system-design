---
slug: pastebin
archetype: caching-read-heavy
sources:
  sds_pastebin: systemdesignsandbox.com/learn/design-pastebin
  sdh_pastebin: systemdesignhandbook.com/guides/design-pastebin/
  pastebin_school: systemdesignschool.io/problems/pastebin/solution
---

# Pastebin (read-heavy text storage + CDN edge)

## Bar anchors
- **Mid-level (L4/E4):** Stores paste text in a DB row keyed by a random ID, reads it back on GET. Knows IDs must be unique. Doesn't separate large blobs from metadata, address read-heavy caching, expiration, or the CDN.
- **Senior (L5/E5):** Separates the large paste blob (object store) from queryable metadata (DB), generates a random base62 ID, caches hot pastes, and adds TTL-based expiration. Knows reads dominate writes. May not articulate the inline-vs-blob size threshold, CDN pull-through edge caching matched to the access pattern, or the cleanup job.
- **Staff+ (L6/E6+):** Drives proactively. Puts the **paste blob in object storage (S3) keyed by paste ID** (~5–15× cheaper than SQL/GB) and **~200-byte metadata in a DB**; uses a **size threshold** (e.g. <1KB inline in metadata, larger → blob store) to avoid a round-trip for tiny pastes. Generates IDs as **random base62** (8 chars ⇒ 62⁸ ≈ 218T keyspace) with **collision-retry on insert**. Fronts reads with a **CDN pull-through cache** — the access pattern (read a few times right after creation, then forgotten) is *exactly* what a pull cache with natural cold-eviction wants. Adds **TTL expiration** (~1-day read-cache TTL; periodic cleanup job with a grace buffer), write-path **rate limiting**, and public/unlisted/private (unlisted = unguessable URL). Quotes a sizing (1M pastes/day × ~10KB ⇒ 10GB/day, ~36TB/10yr; read:write 5:1–100:1; 10MB max paste).

## Canonical decomposition

### Requirements
**Functional:**
- Create a paste (text up to a max size); get a short URL; read it back by ID
- Optional expiration (paste auto-deletes after a TTL) and visibility (public/unlisted/private)
- Reads vastly outnumber writes; reads must be fast

**Non-functional (with numbers):**
- Max paste size ~10MB; metadata ~200 bytes/paste
- ~1M pastes/day × ~10KB ⇒ ~10GB/day, ~36TB over 10 years
- Read:write 5:1 to 100:1; read latency low (CDN/cache served)
- Object storage ~$0.02/GB/mo vs SQL ~$0.10–0.30/GB/mo (5–15× cheaper)

### Core entities
- **Paste:** paste_id, content (blob in S3 or inline if small), created_at, expires_at, visibility, size
- **Metadata row:** paste_id → {s3_key, size, created_at, expires_at, visibility} (queryable, small)
- **Blob:** the paste text in object storage, keyed by paste_id

### API
- `POST /pastes` body={content, expiry?, visibility?} → {paste_id, url}
- `GET /{paste_id}` → content (served via CDN edge → object store on miss)
- internal: cleanup job purges rows/blobs where expires_at < now − grace

### HLD
On create, the API gateway **rate-limits** the write, validates size (≤10MB → 400 otherwise), generates a **random base62 ID** (retry on the rare insert collision), writes a small **metadata row** to the DB and the **blob to object storage** keyed by the ID (tiny pastes <~1KB may be stored inline in the metadata row to skip a blob round-trip). The read path is the interesting part: a GET goes to a **CDN edge** which uses a **pull-through** pattern — the first request fetches from object storage (origin) and caches at the edge; subsequent reads serve from the edge; cold pastes naturally fall out of the cache. This matches the pastebin access pattern perfectly (a paste is read a handful of times shortly after creation, then largely forgotten), so a modest edge cache yields a high hit ratio without explicit eviction tuning. **Expiration** is enforced both by a read-cache TTL (~1 day) and a periodic **cleanup job** (`DELETE WHERE expires_at < now − 1 day` plus blob deletion) with a grace buffer. Visibility: public pastes are listable/indexable; **unlisted** relies on an unguessable random URL; private requires an auth check on read.

### Deep dives
1. **Blob-vs-metadata split + the size threshold.** Keeping large text out of the primary DB is the core scaling decision: object storage is 5–15× cheaper per GB, scales to petabytes, and offloads serving to the CDN, while the DB holds only small, queryable metadata (~200 bytes) for listing/expiry/auth. The refinement is the **inline threshold**: for very small pastes (<~1KB), storing the content inline in the metadata row avoids a second round-trip to the blob store on read — a latency win for the common short-paste case. The Staff+ point: pick the storage tier per object size, and measure the threshold against the read-latency budget.
2. **CDN pull-through cache matched to the access pattern.** Pastebin is the textbook read-heavy-with-cold-tail workload: most reads happen right after creation, then drop off. A CDN pull-through cache (fetch-on-first-miss, serve-from-edge thereafter, LRU-evict cold objects) captures this for free — no precompute, no warming. Contrast with a system that needs explicit cache management; here the natural hot/cold distribution does the work. Cache key = paste_id; TTL aligned to paste expiry; private pastes bypass the shared edge cache (cache only public/unlisted).
3. **ID generation + collision handling.** Random base62 (8 chars ⇒ 62⁸ ≈ 218T) makes IDs unguessable (good for unlisted privacy) and keeps collision probability negligible; collisions are caught at DB insert (unique constraint) and resolved by retry. Contrast with a monotonic counter (sequential, guessable — bad for unlisted) — the random scheme trades a tiny retry cost for unguessability. Namespace custom aliases separately (e.g. require length ≥9 or special chars) so they can't collide with the random keyspace.

## Known failure modes
1. **Hot paste (viral) stampede on cache miss.** A paste goes viral; when its edge entry expires, many requests miss simultaneously and hit the origin. Production answer: request coalescing / single-flight at the edge, stale-while-revalidate, and TTL jitter so popular entries don't all expire at once.
2. **Expired-paste leakage / storage bloat.** Pastes past their expiry remain readable or pile up in storage. Production answer: enforce expiry on both the read path (TTL + check expires_at) and a periodic cleanup job (with a grace buffer) that deletes both the metadata row and the blob; never rely on the cache TTL alone for deletion.
3. **Abuse / write flood.** Bots create millions of pastes (spam, illegal content). Production answer: per-IP/per-user write rate limiting at the gateway, size caps (10MB), content scanning for known-bad, and abuse-report + takedown workflow.

## (Delineation note)
`pastebin` is the read-heavy-storage + CDN-edge-cache application. The object store itself is infra-primitives `s3`; building the cache engine is `memcached` — reference, don't re-derive. Closely mirrors `tinyurl` (this archetype) but with large blobs + CDN instead of tiny key-value mappings.

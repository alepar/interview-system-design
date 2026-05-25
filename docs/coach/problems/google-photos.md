---
slug: google-photos
archetype: ugc-pipeline
sources:
  gphotos_storage_policy: blog.google/products/photos/storage-changes/
  gphotos_quality: support.google.com/photos/answer/6220791
  gphotos_resumable: developers.google.com/photos/library/guides/resumable-uploads
  gphotos_dedup: github.com/rclone/rclone/issues/4587
  gphotos_face: levelup.gitconnected.com/ai-in-google-photos-how-face-recognition-and-object-tagging-work-37dec5c313b0
---

# Google Photos (photo/video backup + dedup at scale)

## Bar anchors
- **Mid-level (L4/E4):** Uploads and stores photos. Doesn't address backup reliability, dedup, compression tiers, or scale.
- **Senior (L5/E5):** Resumable upload, store originals or compressed, dedup duplicates, generate thumbnails, ML tagging for search (light). Knows the scale is huge. May not articulate the two-step upload API, byte-exact hash dedup and its fragility, the compression tiers, or face-clustering pipeline mechanics.
- **Staff+ (L6/E6+):** Drives proactively. Designs backup-on-upload at extreme scale (**4 trillion photos, ~28 billion uploaded/week**) via a **two-step upload API** (upload bytes → get an upload token; create media item with the token) over a **resumable session URL** (chunked, 256KiB-multiple chunks, session expires 7 days / token 1 day, resume via Range). Implements **byte-exact hash dedup** (a per-file hash detects an already-uploaded identical file and skips re-storing it) and knows its **fragility** (any edit — crop/touch-up/EXIF change — changes the hash → treated as new). Offers **compression tiers** (Storage saver: >16MP→16MP, >1080p→1080p, lossy, may convert to .jpg; Express: 3MP/480p; Original: unchanged) as the storage-vs-quality knob. Runs an **async ML feature pipeline** (CNN face detection → 128-d embedding → cluster into people; object/scene tags for search) — referenced lightly (the model serving is AI-infra; search is the search archetype). Tiers storage (recent hot, old cold).

## Canonical decomposition

### Requirements
**Functional:**
- Back up photos/videos reliably on upload; never lose an original (per tier)
- Dedup so the same photo isn't stored twice; offer compression tiers
- Generate thumbnails/derivatives; extract ML features (faces/objects) async for search
- Resumable upload on flaky mobile networks

**Non-functional (with numbers):**
- 4 trillion photos stored; ~28 billion uploaded/week
- Resumable session URL (7-day expiry), upload token (1-day), 256KiB-multiple chunks
- Compression tiers: Storage saver 16MP/1080p (lossy), Express 3MP/480p, Original unchanged
- Byte-exact hash dedup (edit → new hash → re-upload)

### Core entities
- **Media item:** the photo/video (binary in object storage) + metadata
- **Upload token:** returned from uploading bytes; used to create the media item
- **Content hash:** per-file hash for byte-exact dedup
- **ML features:** face embeddings (128-d), object/scene tags (async pipeline)

### API
- two-step: `POST /uploads` (bytes) → upload token; `POST /mediaItems:batchCreate` (token) → media item
- resumable: `X-Goog-Upload-URL` session; chunked PUT (256KiB-aligned), Range-based resume
- dedup: hash incoming file; if seen for this account, skip re-upload/re-store
- async: ML pipeline extracts face embeddings + tags → index for search

### HLD
The pipeline is **backup → dedup → store → (async) enrich → serve**, at staggering scale (4T photos, ~28B/week). **Upload** is a **two-step API** for reliability: first upload the file bytes to get an **upload token**, then create the media item referencing that token — decoupling the byte transfer from the catalog write. Large files use a **resumable session URL** (`X-Goog-Upload-URL`): chunked uploads aligned to a 256KiB granularity, resumable via the Range header (the session URL expires after 7 days, the upload token after 1 day), so a dropped mobile connection resumes from the last acknowledged byte rather than restarting — critical for the mobile-photo workload.

**Dedup** is **byte-exact**: a per-file content hash identifies an already-uploaded identical file and skips re-storing it (per account). The Staff+ nuance is its **fragility** — any modification (crop, touch-up, sticker, even a changed/corrupt EXIF or timezone) changes the hash, so the "same" photo edited is treated as new and re-uploaded. (Contrast with `content-addressed-dedup`'s block-level/perceptual approaches — Google Photos' simple per-file hash is deliberate, trading some missed near-dups for simplicity.) **Compression tiers** are the storage-vs-quality knob: **Storage saver** (resize >16MP→16MP and >1080p→1080p, lossy, may convert to .jpg), **Express** (3MP/480p, more aggressive), or **Original** (unchanged) — and both Original and Storage saver now count against the account quota. Binaries go to **tiered object storage** (recent/hot vs old/cold).

Asynchronously, an **ML feature pipeline** enriches the library: a CNN detects faces, aligns them, and extracts a **128-d embedding**; photos with similar embeddings cluster into a "person"; object/scene classifiers tag content for search. This runs off the upload path (the model serving is the AI-infra concern; the resulting search index is the search archetype) — referenced here as the enrichment stage of the pipeline, not re-derived.

### Deep dives
1. **Two-step resumable upload for mobile reliability.** Photos upload from phones on unreliable networks, so the upload must be **resumable**: the two-step API (bytes → token → media item) separates the fragile byte transfer from the catalog write, and the **resumable session URL** (256KiB-aligned chunks, Range-based resume, 7-day session) lets a dropped upload continue from the last acknowledged byte rather than restarting a multi-GB video. Clients run a few parallel chunk requests to use bandwidth. The token's 1-day validity and session's 7-day expiry bound server-side state. The Staff+ point: at billions of uploads/week from mobile, resumability isn't a nicety — it's the difference between completing or endlessly retrying uploads.
2. **Byte-exact hash dedup and its deliberate limits.** Google Photos dedups by a **per-file hash**: if the exact bytes were already uploaded for the account, it's the same media item — no re-upload, no double storage. This is cheap and exact, but **brittle**: any edit (crop, filter, sticker) or even an EXIF/timezone change alters the hash, so the edited photo is a new item (and re-uploaded). This is a deliberate simplicity tradeoff — full **content-defined or perceptual** dedup (catching resaved/edited near-dups) costs index complexity and false-positive risk (see `content-addressed-dedup`), which Google Photos avoids at the cost of missing edited duplicates. Naming the tradeoff (exact-hash simplicity vs perceptual-dedup coverage) is the depth signal; it also explains why users see "duplicate" photos that differ by one byte.
3. **Compression tiers + async ML enrichment.** **Compression tiers** are the explicit storage-vs-quality decision: Storage saver (lossy downscale to 16MP/1080p) trades quality for space, Express goes further (3MP/480p), Original preserves exactly — all counting against quota now. This is the UGC analog of transcoding ladders for photos. Separately, the **async ML pipeline** is where Photos differentiates: faces → 128-d embeddings → clustering into people, plus object/scene tagging — all run *off the upload path* (eventual, retriable) and feed a search index. The boundary matters for the interview: the **pipeline** stages (enqueue feature-extraction jobs, store embeddings/tags) are this problem; the **model serving** is AI-infra; the **search** is the search archetype. The framing: backup + dedup + tiered storage is the durable core, and ML enrichment is an async derivative-generation stage layered on top.

## Known failure modes
1. **Upload fails on a large video over mobile.** A drop restarts a multi-GB upload. Production answer: resumable session URL (256KiB-aligned chunks, Range resume) + two-step token API; resume from the last acknowledged byte.
2. **Duplicate storage / missed dedup.** Either store the same photo twice, or fail to catch an edited near-duplicate. Production answer: byte-exact per-file hash dedup (cheap, exact) — accept that edits create new items; perceptual dedup only if the missed-near-dup cost justifies the index complexity.
3. **ML enrichment overload / lag.** Face/object extraction at billions/week can't be synchronous. Production answer: async feature pipeline off the upload path (queue + workers, retriable, idempotent), prioritized, with the search index updated eventually; the upload/backup path never blocks on ML.

## (Delineation note)
`google-photos` is the **backup + dedup + tiered-storage** UGC pipeline at extreme scale. Perceptual/block dedup depth is `content-addressed-dedup`; derivative generation is `image-derivatives`; the ML model serving is AI-infra (`embedding-service-at-scale`); photo *search* is the search archetype (`image-search`); the object store is infra-primitives `s3`. Reference, don't re-derive.

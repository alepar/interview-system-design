---
slug: instagram-upload
archetype: ugc-pipeline
sources:
  intervu_instagram: intervu.dev/blog/photo-sharing-feed-instagram-system-design/
  fb_ig_video_94: engineering.fb.com/2022/11/04/video-engineering/instagram-video-processing-encoding-reduction/
  ig_storage: scaleyourapp.com/instagram-architecture-how-does-it-store-search-billions-of-images/
  presigned_url: medium.com/@arc.shukla/system-design-concept-1-presigned-url-b90c0fe23661
  ig_stats: demandsage.com/instagram-statistics/
---

# Instagram Upload (photo/video upload → process → store → serve)

## Bar anchors
- **Mid-level (L4/E4):** Uploads a photo, stores it, shows it. Doesn't address generating multiple sizes, the async pipeline, EXIF stripping, or serving via CDN.
- **Senior (L5/E5):** Upload to object storage, generate thumbnails/sizes, strip EXIF, store metadata separately, serve via CDN; async processing. Knows reads dominate (feed). May not articulate direct-to-storage presigned upload, event-triggered async derivative generation, the video repackaging optimization, or the storage math.
- **Staff+ (L6/E6+):** Drives proactively. Uses **direct-to-S3 via presigned URLs** (the Upload API validates and returns a presigned URL; the client uploads binary **directly to object storage**, bypassing the app tier — the server handles a tiny string, not gigabytes), with **async derivative generation triggered by an object-store event** (S3 event / SQS) rather than synchronously. Generates a fixed set of **resolution variants** (e.g. thumbnail 150×150, feed 640×640, full 1080×1080; resize >1080px down to 1080; re-encode JPEG ~q70–75 ≈ 13× smaller; **strip EXIF**) written back with CDN-friendly URLs. Stores **binaries in object storage, metadata in Cassandra/Postgres** (the app layer holds only CDN URLs, never bytes; 11-nines durability). For video, knows Instagram's **94% basic-ABR compute cut** by repackaging progressive-encoding frames into an ABR container instead of re-transcoding (86.17s→0.36s for a 23s 720p clip). Quotes scale (95M media/day; ~109PB primary / ~220PB replicated at 100M/day) and budgets (<5s upload, feed p99 <200ms, post visible in ~30s). References feed fan-out to the fan-out archetype.

## Canonical decomposition

### Requirements
**Functional:**
- Upload photos/videos; process into multiple sizes/formats; strip metadata; serve via CDN
- Async processing (immediate upload ack); generate derivatives for feed/thumbnail/full
- Fan the post into followers' feeds (reference fan-out archetype)

**Non-functional (with numbers):**
- ~95M photos/videos/day; massively read-skewed (feed)
- Variants: 150×150 / 640×640 / 1080×1080; resize >1080 → 1080; JPEG q70–75 (~13× smaller)
- Upload <5s end-to-end; feed API p99 <200ms; post visible in ~30s
- Binaries in object storage (11-nines); ~109PB primary / ~220PB replicated at 100M/day

### Core entities
- **Media upload:** the raw photo/video (direct-to-S3 via presigned URL)
- **Derivatives:** the generated variant set (thumbnail/feed/full), CDN-URL'd
- **Metadata:** post record (author, caption, CDN URLs) in Cassandra/Postgres — never the bytes
- **Processing event:** S3 event/SQS message triggering async derivative generation

### API
- `POST /upload/init` → validate → presigned S3 URL → client uploads bytes directly to S3
- S3 `ObjectCreated` → SQS → derivative-generation worker → write variants + metadata
- `GET /feed` → returns posts with CDN URLs (binaries served from CDN, not the app)

### HLD
Upload is **direct-to-object-storage**: the client calls the Upload API, which validates and returns a **presigned S3 URL**; the client then uploads the binary **directly to S3**, so the app server never touches the gigabytes (it handles a tiny URL string) — essential at 95M media/day. Completing the upload fires an **object-store event** (S3 event notification → SQS) that **triggers async derivative generation** — the processing is decoupled from the request path, so the user gets an immediate ack and the post appears once processing finishes (~30s). A **derivative worker** generates the fixed variant set (thumbnail 150×150, feed 640×640, full 1080×1080; anything wider than 1080px is resized down to 1080; re-encoded to JPEG at ~q70–75, ~13× smaller; **EXIF stripped** from the served file), writing each back to object storage with **stable CDN-friendly URLs**.

The storage split is strict: **binaries live in object storage** (S3-class, 11-nines durability, multi-AZ — ~109PB primary / ~220PB replicated at 100M/day), while **metadata** (author, caption, the *CDN URLs* of the variants) lives in **Cassandra/Postgres** — the app layer stores only URLs, never image bytes. Serving is **CDN-fronted** and read-dominated (the feed pulls derivatives; binaries come from the CDN). For **video**, Instagram's published optimization is illustrative: rather than transcoding twice, it **repackages progressive-encoding video frames into an ABR-capable container**, cutting basic-ABR encode compute **94%** (86.17s CPU → 0.36s for a 23s 720p clip), freeing compute to raise advanced-encoding coverage. The post then **fans out** to followers' feeds — that fan-out (write vs read, celebrity problem) is the fan-out archetype, referenced not re-derived here.

### Deep dives
1. **Direct-to-storage presigned upload + event-triggered async processing.** Routing 95M media/day of binary through the app servers would be absurd, so the upload goes **direct to object storage via a presigned URL** — the app only issues a short-lived signed URL and validates; the bytes never traverse the app tier. Upload completion emits an **object-store event** (S3 → SQS) that triggers the processing pipeline asynchronously, so the user isn't blocked on resizing/encoding and the post publishes when ready (~30s). This is the canonical UGC-upload pattern (also `youtube-upload`, `google-photos`): presigned direct-to-storage + event-driven async derivative generation. The Staff+ point: keep the app servers out of the byte path and the processing off the request path.
2. **Derivative generation + the storage split.** A photo isn't served as one file — it's a **set of derivatives** (thumbnail/feed/full) generated once at upload, sized for different surfaces, re-compressed (JPEG q70–75, ~13×), EXIF-stripped (privacy + size), and stored with CDN URLs. The architectural rule is the **binary/metadata split**: bytes in object storage (11-nines, cheap, CDN-served), metadata + the variant **URLs** in Cassandra/Postgres — the app never stores or serves image bytes, only URLs. This keeps the metadata DB small and the hot read (feed) a cheap URL lookup that the client resolves against the CDN. (On-demand vs precompute for derivatives is the `image-derivatives` deep-dive; Instagram precomputes a small fixed set.) Naming the binary/metadata separation and the derivative set is the core.
3. **Video repackaging + the upload:read asymmetry.** Instagram's published 94%-compute-cut is a great Staff+ beat: most uploaded videos get few views, so spending full transcode compute on every upload's basic ABR is wasteful — instead they **repackage** the already-progressive-encoded frames into an ABR-capable container (no re-encode: 86.17s→0.36s for a 23s clip), reserving expensive advanced encoding for content that's actually watched. This embodies the **upload:read asymmetry** (cheap, fast processing on upload; expensive optimization deferred/targeted to popular content) and the broader theme that UGC pipelines must process at write-scale (95M/day) but optimize for read-scale (feed). The feed fan-out itself (hybrid push/pull, celebrity problem) is the fan-out archetype — reference it; here the boundary is "produce the derivatives + metadata that fan-out then distributes."

## Known failure modes
1. **App tier as the byte bottleneck.** Routing all upload bytes through app servers saturates them. Production answer: presigned direct-to-S3 upload (app issues URLs only); event-triggered async processing off the request path.
2. **Synchronous processing blocking the user / publish.** Resizing/encoding inline makes upload slow and fragile. Production answer: object-store event → queue → async derivative workers; immediate upload ack; status/eventual publish (~30s); retries + DLQ.
3. **Wasted transcode compute on rarely-watched video.** Full ABR transcode of every upload burns compute on content few will watch. Production answer: repackage progressive frames into ABR (no re-encode, 94% cut), reserve advanced encoding for content that gains views; the upload:read asymmetry justifies deferring expensive work.

## (Delineation note)
`instagram-upload` is the **photo/video UGC pipeline** (presigned upload → async derivatives → object-store + metadata split → CDN). On-demand derivative generation is `image-derivatives`; large-scale photo backup+dedup is `google-photos`; feed **fan-out** is the fan-out archetype; the object store is infra-primitives `s3`. Reference, don't re-derive.

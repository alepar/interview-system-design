---
slug: youtube-upload
archetype: ugc-pipeline
sources:
  hi_youtube: hellointerview.com/learn/system-design/problem-breakdowns/youtube
  bytebytego_youtube: bytebytego.com/courses/system-design-interview/design-youtube
  netflix_encoding_scale: netflixtechblog.com/high-quality-video-encoding-at-scale-d159db052746
  fb_ig_video_94: engineering.fb.com/2022/11/04/video-engineering/instagram-video-processing-encoding-reduction/
  temporal_workflow: docs.temporal.io/workflow-execution
---

# YouTube Upload (video upload → transcode → store → serve pipeline)

## Bar anchors
- **Mid-level (L4/E4):** Uploads a file, stores it, serves it back. Knows transcoding to multiple resolutions exists. Doesn't address resumable upload, the async processing pipeline, parallel transcoding, or the upload:view asymmetry.
- **Senior (L5/E5):** Resumable/chunked upload to object storage, an async transcoding pipeline (queue + workers) producing multiple renditions, CDN for delivery, status tracking. Knows reads ≫ writes. May not articulate the DAG/parallel-segment transcoding, orchestration, or per-stage failure handling.
- **Staff+ (L6/E6+):** Drives proactively. Lays out the **upload→process→store→serve pipeline**: **resumable/chunked upload** (5–10MB fingerprinted chunks via S3 multipart / presigned URLs direct-to-storage; `ObjectCreated` event triggers processing) → an **event-driven async pipeline** (immediate "upload successful" response; heavy work in the background) → **transcoding modeled as a DAG** (split with ffmpeg into independent segments → transcode in **parallel** across a worker fleet → reassemble; a 2-hr 4K serial 8hr+ encode drops to ~30min parallel) orchestrated by **Temporal**-class durable workflow → store renditions + manifests in object storage → CDN. Quotes the **upload:view asymmetry** (YouTube: ~500 hours uploaded/min vs ~1B watch-hours/day — reads dominate, justifying heavy CDN). Handles **per-stage failure** (transcode error → retry; preprocessor error → regenerate DAG), status tracking (pending→processing→ready→failed), and references the transcoding compute itself to `video-transcoding`, VOD delivery to `vod-delivery`.

## Canonical decomposition

### Requirements
**Functional:**
- Upload large videos reliably (resumable on failure); process into multiple renditions; serve on demand
- Async processing with status visibility (the user doesn't wait for transcoding)
- Generate thumbnails/metadata; eventually publish

**Non-functional (with numbers):**
- ~500 hours uploaded/min (YouTube); ~1B watch-hours/day (upload:view hugely read-skewed)
- Videos up to tens of GB; resumable upload (only failed chunks retried)
- Transcoding parallelized: a 2-hr 4K encode ~8hr serial → ~30min parallel
- Pipeline status: pending → processing → ready → failed

### Core entities
- **Upload session:** chunks (5–10MB, fingerprinted), part numbers + ETags, resume state
- **Raw asset:** the stored original (object storage) — the processing input
- **Processing DAG:** split → transcode segments (parallel) → reassemble → manifest → thumbnails
- **Rendition + manifest:** the ABR outputs + playlist (served via CDN)

### API
- resumable upload: init → `PUT` part (presigned URL, returns ETag) → complete-multipart → `ObjectCreated` event
- `GET /videos/:id/status` → pending|processing|ready|failed
- internal: orchestrator builds the DAG, assigns segments to workers, passes intermediate data via object-storage URLs
- serve: manifest + segments via CDN (see `vod-delivery`)

### HLD
The pipeline is **upload → process → store → serve**, decoupled by async events. **Upload**: large videos use **resumable/chunked upload** — the client splits the file into ~5–10MB chunks (each fingerprinted), uploads them (often via **S3 multipart** with presigned URLs so bytes go **directly to object storage**, bypassing the app server; each part returns a number + ETag), and can **resume** after a drop by re-sending only missing chunks. Completing the multipart upload emits an `ObjectCreated` event that **triggers** the processing pipeline, and the user immediately gets "upload successful" — the heavy work happens asynchronously. **Process**: the raw asset enters a **DAG of tasks** — split into independent segments (ffmpeg) → **transcode each segment in parallel** across a worker fleet → reassemble, plus thumbnail/metadata extraction and (optionally) a moderation scan (`content-moderation-pipeline`). Segment-parallelism is the key lever: a 2-hour 4K video transcoded serially can take 8+ hours, but split into segments and fanned across workers it drops to ~30 minutes. A **durable workflow orchestrator** (Temporal-class) builds the DAG, assigns segments to workers at the right time, passes intermediate data via object-storage URLs, and provides retries + status. **Store**: renditions + manifests land in object storage. **Serve**: the heavily read-skewed delivery path is CDN-fronted (see `vod-delivery`).

A **completion queue** decouples "transcode done" from metadata updates: completion-handler workers drain it and update the metadata DB/cache, flipping status to `ready`. **Per-stage failure handling** is explicit (transcode error → retry the segment; preprocessor error → regenerate the DAG; scheduler error → reschedule), and the orchestrator's durability means a crash resumes where it left off rather than restarting the whole job.

### Deep dives
1. **Resumable/chunked upload + direct-to-storage.** Tens-of-GB videos over flaky networks can't be a single PUT — a drop would restart the whole thing. Chunked upload (S3 multipart: 5MB+ parts, up to 10,000, returning per-part ETags) lets the client upload parts in parallel and **resume** by re-sending only the parts that failed (track per-chunk status). **Presigned URLs** send bytes **directly to object storage**, so the app server handles only a small string, not gigabytes — critical at YouTube scale. Completion emits an event that triggers processing, decoupling upload from the pipeline. The Staff+ point: the upload is resumable, parallel, direct-to-storage, and event-triggering — not a synchronous file POST through the app tier.
2. **Transcoding as a parallelized DAG.** The expensive stage is transcoding, and the win is **parallelism via segmentation**: split the video into independent segments (no inter-segment dependency), transcode them concurrently across many workers/cores, and reassemble — turning a serial 8-hour 4K encode into ~30 minutes. This is naturally a **DAG** (split → N parallel transcode tasks → join → package → thumbnails), and a **durable orchestrator** (Temporal) manages it: building the graph, assigning work, retrying failed segments, and surviving crashes by resuming from the last completed task rather than redoing the whole job. (The transcoding *compute* — ABR ladders, codecs, per-title encoding — is the `video-transcoding` problem; here it's the pipeline shape.) Intermediate segment data is passed via object-storage URLs, not in-memory, so workers are stateless and scalable.
3. **Async orchestration, status, and the upload:view asymmetry.** The user shouldn't block on transcoding, so the pipeline is event-driven: immediate "uploaded" ack, background processing, **status tracking** (pending→processing→ready→failed) the client polls, and a **completion queue** that updates metadata when renditions are ready. Failure handling is per-stage (retry the failed unit, not the whole pipeline) with dead-letter for poison jobs. Underlying all of it is the **upload:view asymmetry**: YouTube ingests ~500 hours/min but serves ~1B watch-hours/day — reads dominate by orders of magnitude, so the *serve* side is CDN-heavy and read-optimized while the *process* side is a compute-heavy batch pipeline. Naming this asymmetry (write-once, read-many; expensive async processing, cheap cached serving) frames the whole design.

## Known failure modes
1. **Upload fails partway on a huge file.** A network drop on a 20GB upload restarts everything. Production answer: resumable chunked upload (S3 multipart) — track uploaded parts, resume by sending only missing chunks; presigned URLs direct-to-storage to keep the app server out of the byte path.
2. **A transcode segment fails / a worker crashes.** One bad segment shouldn't fail the whole video. Production answer: per-segment retry, a durable orchestrator (Temporal) that resumes from the last completed task, dead-letter for repeatedly-failing segments, and per-stage error handling (regenerate DAG / reschedule).
3. **Processing backlog under upload spikes.** A surge of uploads overwhelms the worker fleet. Production answer: queue-based decoupling with autoscaled workers, priority (e.g. shorter videos / premium first), backpressure, and async status so users aren't blocked while the backlog drains.

## (Delineation note)
`youtube-upload` owns the **end-to-end UGC video pipeline shape** (resumable upload → DAG transcode → store → serve). The transcoding *compute* is `video-transcoding`; VOD packaging/delivery is `vod-delivery`; short-video specifics are `tiktok-upload`; the object store is infra-primitives `s3`; LIVE streaming is the messaging archetype. Reference, don't re-derive.

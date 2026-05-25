---
slug: tiktok-upload
archetype: ugc-pipeline
sources:
  tiktok_arch: asyncthinking.com/p/tiktok-architecture-secrets
  fastpix_shortvideo: fastpix.io/blog/strategies-to-optimize-performance-of-short-video-apps
  mux_jit_transcode: mux.com/blog/how-to-transcode-video-100x-faster-or-a-gordian-knot-cut
  tiktok_stats: sidesmedia.com/how-many-tiktoks-are-posted-a-day/
  hi_youtube: hellointerview.com/learn/system-design/problem-breakdowns/youtube
---

# TikTok Upload (short-video pipeline, fast feed turnaround)

## Bar anchors
- **Mid-level (L4/E4):** Same as a generic video upload. Doesn't recognize what short-video changes (fast turnaround, mobile-first, feed-readiness, aggressive compression).
- **Senior (L5/E5):** Upload → transcode → ready-for-feed, with a latency target and mobile-first upload. Knows short clips transcode fast. May not articulate the sub-10s turnaround, region-sharded edge ingest, JIT transcoding, ladder trimming, or the ~500ms playback expectation.
- **Staff+ (L6/E6+):** Drives proactively. Frames short-video's distinct goal: **minimize upload→ready-for-feed latency** (sub-10s transcode targeting 720p-first for immediate availability; full-resolution in the background) because the clip must be **feed-ready fast** and playback must start in **~500ms** (scroll-aware preloading: thumbnail + first segment pre-warmed before the clip is in view). Uses **region-sharded edge ingest** (upload to edge servers / regional API gateways, into a distributed FS, queued in **Kafka** so each region processes locally to cut latency). Trims the pipeline for short clips: a **few-second segment length** parallel-transcodes well, **ladder trimming** (skip intermediate rungs) cuts startup latency 15–25%, and **just-in-time transcoding** defers rarely-watched renditions. Tiers storage by virality (hot/viral on NVMe SSD ~48h → cold object store). Quotes scale (~34M TikTok uploads/day ≈ 272/sec). Reuses `youtube-upload`'s chunked-resumable-upload + DAG-transcode but optimized for speed-over-perfect-quality.

## Canonical decomposition

### Requirements
**Functional:**
- Upload short videos (mobile-first); process to feed-ready fast; serve in an infinite-scroll feed
- Minimize upload→playable latency; pre-warm so playback starts instantly on scroll
- Handle viral spikes (a clip blows up) with storage tiering

**Non-functional (with numbers):**
- Sub-10s transcode to feed-ready (720p-first); ~500ms playback start on scroll
- ~34M uploads/day (~272/sec); region-sharded edge ingest
- Ladder trimming cuts startup latency 15–25%; JIT transcode for cold renditions
- Hot/viral on NVMe SSD ~48h → cold object store

### Core entities
- **Short clip:** the uploaded video (seconds–minutes), mobile-captured
- **Feed-ready rendition:** the first/primary rendition (e.g. 720p) needed to appear in feed
- **Edge ingest:** regional upload endpoint + Kafka queue for local processing
- **Storage tier:** hot (NVMe, ~48h) vs cold (object store) by virality

### API
- upload to nearest edge/regional gateway → distributed FS → Kafka (regional)
- transcode worker: produce 720p-first quickly → mark feed-ready → full renditions in background
- feed: scroll-aware preload of thumbnail + first segment (playback ~500ms)

### HLD
Short-video upload is `youtube-upload`'s pipeline **optimized for turnaround**: the clip must be **feed-ready within seconds**, so the design trades perfect quality for speed on the critical path. Upload is **mobile-first and region-sharded**: the client uploads to the nearest **edge server / regional API gateway**, the bytes land in a distributed file system, and a **Kafka** queue feeds **local** (in-region) transcode workers — keeping the upload→process loop within one region to cut latency. Transcoding targets **720p first** for immediate feed availability (sub-10s), with full-resolution and additional renditions produced **in the background**; for short clips a **few-second segment length** parallel-transcodes efficiently, and **trimming the ladder depth** (skipping intermediate rungs) cuts startup latency 15–25%. **Just-in-time transcoding** defers generating a rendition until someone actually requests it — sensible because most short clips get few views, so you don't pre-encode a 1080p version no one plays.

Delivery is built for the **~500ms playback expectation** of an infinite-scroll feed: the client **pre-warms** the thumbnail and first segment of upcoming clips (scroll-aware preloading) so a clip is "ready to play" by the time it's in view. **Storage tiers by virality**: recently-uploaded/viral clips sit on **NVMe SSD (~48h)** for fast serving, then tier down to a cheaper object store once they cool — a hot/cold policy matched to short-video's spike-then-decay access pattern. At scale (~34M uploads/day ≈ 272/sec, serving >1B views/day), the pipeline is the same chunked-resumable-upload + DAG-transcode shape as `youtube-upload`, with every knob turned toward **low upload→ready latency and fast feed playback** rather than maximal quality.

### Deep dives
1. **Optimizing for upload→feed latency (the short-video distinction).** Long-form (YouTube) can take minutes to fully process; short-video can't — the clip is meant to be scrolled to *now*, so the critical path is **upload→feed-ready**. The design: transcode a **720p-first** rendition fast (sub-10s) to make the clip appear, then generate full quality/other renditions in the **background**; **trim the ABR ladder** (fewer rungs, skip intermediates) to cut startup latency 15–25%; and **region-shard** ingest (edge upload + in-region Kafka + local workers) so the loop doesn't cross regions. The Staff+ point: short-video flips the quality/latency tradeoff toward latency on the path to feed-readiness, deferring full-quality work — a different objective than `youtube-upload`'s thorough processing.
2. **JIT transcoding + storage tiering for the view distribution.** Short-video has an extreme view distribution (a few clips go viral; most get almost no views), so pre-encoding every rendition for every clip is wasteful. **Just-in-time transcoding** generates a rendition only when first requested (so an unwatched clip's 1080p is never produced), and **storage tiers by virality** keep hot/viral clips on **NVMe SSD (~48h)** for fast serving while cold clips move to a cheaper object store (promoted back if they trend). This is the short-video instance of the on-demand-vs-precompute + hot/cold-tiering theme (`vod-delivery`, `image-derivatives`), tuned to spike-then-decay. The framing: match processing and storage cost to the steep popularity skew — cheap/fast for the common cold case, full treatment for the viral few.
3. **~500ms feed playback via preloading.** The product bar is brutal: in an infinite-scroll feed, playback should start in ~500ms, so the clip must be **ready to play before it's in view**. The client does **scroll-aware preloading** — fetching the thumbnail and first segment(s) of the next clips ahead of time — and the pipeline ensures the feed-ready rendition + first segment are CDN-warm and small (trimmed ladder, fast start). This couples the *upload pipeline* (produce a feed-ready rendition fast) with the *delivery/feed* (preload it), and is why short-video pipelines optimize first-segment availability over full-asset completeness. The Staff+ point: the upload pipeline's latency target is set by the feed's playback expectation, end-to-end.

## Known failure modes
1. **Clip not feed-ready fast enough.** Full transcode on the critical path delays the clip's appearance. Production answer: 720p-first sub-10s transcode → mark feed-ready → background full quality; trim ladder; region-local processing.
2. **Wasted transcode/storage on cold clips.** Pre-encoding every rendition for clips no one watches. Production answer: JIT transcoding (encode a rendition on first request); storage tiering (NVMe hot ~48h → cold object store), promote on virality.
3. **Slow feed playback.** A clip isn't ready when scrolled to. Production answer: scroll-aware preloading of thumbnail + first segment; small feed-ready rendition + CDN warm; target ~500ms start.

## (Delineation note)
`tiktok-upload` is the **short-video** variant of the UGC video pipeline — `youtube-upload`'s shape optimized for upload→feed latency and ~500ms playback. The transcoding compute is `video-transcoding`; VOD delivery is `vod-delivery`; the *recommendation* feed (For You ranking) is the ml-in-loop archetype; the object store is infra-primitives `s3`. Reference, don't re-derive.

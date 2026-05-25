---
slug: video-transcoding
archetype: ugc-pipeline
sources:
  netflix_encoding_scale: netflixtechblog.com/high-quality-video-encoding-at-scale-d159db052746
  netflix_per_title: streaminglearningcenter.com/encoding/how-netflix-pioneered-per-title-video-encoding-optimization.html
  netflix_dynamic_optimizer: netflixtechblog.com/dynamic-optimizer-a-perceptual-video-encoding-optimization-framework-e19f1e3a277f
  mux_abr: mux.com/articles/adaptive-bitrate-streaming-guide
  youtube_argos: streaminglearningcenter.com/encoding/asics-vs-software-based-transcoding-an-analysis-of-youtubes-argos-transcoder.html
---

# Video Transcoding (ABR ladder, chunked parallel encoding)

## Bar anchors
- **Mid-level (L4/E4):** Converts a video to a few resolutions. Doesn't address the ABR ladder rationale, parallel/chunked encoding, codec tradeoffs, or compute cost.
- **Senior (L5/E5):** Produces an **adaptive bitrate (ABR) ladder** (multiple resolution/bitrate renditions), segments each, knows H.264/H.265/VP9/AV1 exist, and parallelizes by splitting the video into chunks. May not articulate per-title/per-scene encoding, the chunked-MapReduce architecture with per-chunk QC, the codec efficiency-vs-compute tradeoff, or hardware acceleration.
- **Staff+ (L6/E6+):** Drives proactively. Designs the **ABR ladder** (e.g. 240p@400kbps → 1080p@5Mbps → 4K@15–25Mbps; each rendition segmented into 2–10s chunks so players switch rungs at boundaries) and the **chunked/parallel (MapReduce-style) encoding** (split into ~30s–2min chunks → encode independently across hundreds of instances → reassemble; **verify each chunk immediately** so a faulty one is re-triaged without redoing the whole video). Knows **per-title encoding** (Netflix: analyze each title's complexity, pick an optimal ladder via a convex hull, ~20% bitrate savings) and **per-scene/per-shot** (Dynamic Optimizer under VMAF, ~30%). Reasons about the **codec efficiency-vs-compute tradeoff** (VP9 ~30–50% better than H.264; AV1 a further ~20–30% — but AV1 software encode is ~5–10× slower) and **hardware acceleration** (GPU/NVENC ~order-of-magnitude faster; YouTube's **Argos VCU ASIC** 20–33× more efficient than CPU, one ASIC server replacing ~10 CPU transcode servers). Quotes encode-time-vs-realtime (4K HEVC slow preset 10–50× realtime) and that a title can fan out to 1,000+ files.

## Canonical decomposition

### Requirements
**Functional:**
- Transcode an uploaded video into an ABR ladder of renditions (resolutions × bitrates × codecs)
- Segment each rendition for adaptive streaming
- Do it fast (parallel) and cost-efficiently (right ladder, right hardware)

**Non-functional (with numbers):**
- ABR ladder rungs 240p@400kbps … 1080p@5Mbps … 4K@15–25Mbps; segments 2–10s
- Chunked encoding: ~30s–2min chunks across hundreds of instances; per-chunk QC
- Per-title ~20% / per-scene ~30% bitrate savings at equal quality
- Encode cost: 4K HEVC slow preset 10–50× realtime (CPU); GPU/ASIC order(s) of magnitude faster

### Core entities
- **Source/mezzanine:** the high-quality input to encode
- **Ladder rung:** a (resolution, bitrate, codec) rendition
- **Chunk:** an independently-encoded segment of the video (parallel unit)
- **Encode task:** a node in the transcode DAG (chunk × rung)

### API
- internal: `split(source) → chunks`; `encode(chunk, rung) → encoded_chunk`; `reassemble → rendition`
- per-chunk QC: verify each encoded chunk on completion; re-triage failures
- output: ABR renditions + per-rendition segments (handed to `vod-delivery`)

### HLD
Transcoding turns one source into an **adaptive bitrate ladder** — multiple renditions at increasing resolution/bitrate (240p@400kbps up to 4K@15–25Mbps) — so a player can pick a rung matching the viewer's bandwidth/device and switch rungs at segment boundaries (each rendition is cut into 2–10s segments). The compute is heavy (4K HEVC at a slow preset runs 10–50× realtime), so the architecture is **chunked / MapReduce-style**: split the source into ~30s–2min **chunks**, **encode each chunk independently in parallel** across hundreds of instances, then **reassemble** into the full rendition. A key resilience trick: **verify each encoded chunk immediately** after it finishes, so a faulty chunk is re-triaged on its own without waiting for (or redoing) the whole video.

Two optimizations distinguish a strong answer. **Per-title encoding** (Netflix): instead of one fixed ladder for all content, analyze each title's complexity (motion, detail) and compute an **optimal per-title ladder** via a convex hull of test encodes — ~20% bitrate reduction at equal quality; doing it **per-scene/per-shot** under VMAF (Dynamic Optimizer) reaches ~30%. **Codec + hardware** choices: VP9 is ~30–50% more efficient than H.264 and AV1 a further ~20–30%, but AV1 software encode is ~5–10× slower — so the ladder/codec mix trades compression against encode cost and device support; **hardware acceleration** (GPU/NVENC ~order-of-magnitude faster; YouTube's purpose-built **Argos VCU ASIC** 20–33× more efficient than CPU, replacing ~10 CPU servers with one) is how high-volume platforms make it affordable. A single popular title can fan out to **1,000+** encoded files across resolutions, codecs, and device profiles.

### Deep dives
1. **The ABR ladder + chunked parallel encoding.** The ladder exists so playback adapts to bandwidth: more rungs = smoother adaptation but more encode/storage. Each rendition is segmented (2–10s) so the player switches quality at boundaries without restarting. The compute is the bottleneck, solved by **chunked encoding** — split → encode chunks in parallel across a fleet → reassemble (MapReduce for video). Per-chunk QC (verify each on completion) makes it resilient: a corrupt chunk is re-encoded in isolation, not the whole 2-hour film. This is the same parallel-DAG idea as `youtube-upload`'s pipeline, here focused on the encode compute. The Staff+ point: transcoding throughput comes from segment-level parallelism + immediate per-chunk validation, not a faster single encoder.
2. **Per-title / per-scene encoding (the quality-per-bit win).** A fixed ladder over-spends bits on simple content and under-serves complex content. **Per-title** encoding runs test encodes at multiple resolution/bitrate points, plots the quality (PSNR/VMAF) convex hull, and picks the optimal ladder for *that* title — Netflix reports ~20% bitrate savings at equal perceptual quality, and ~30% doing it per-scene/per-shot (Dynamic Optimizer driven by **VMAF**). At Netflix/YouTube delivery scale, 20–30% fewer bits is enormous CDN-egress and storage savings (egress dominates cost). The tradeoff: per-title/per-scene encoding costs *more* compute up front (many test encodes / shot analysis) to save bandwidth forever — worth it for popular, long-lived content, less so for the cold long tail. Naming this compute-now-to-save-bandwidth-later tradeoff is the depth signal.
3. **Codec + hardware tradeoffs.** Codec choice is a three-way trade of compression efficiency, encode cost, and device support: H.264 (universal, cheap, least efficient) → VP9 (~30–50% better) → AV1 (~40–50% better than H.264, but software encode ~5–10× slower and newer device support). You often encode multiple codecs per title and serve the best the client supports. **Hardware acceleration** changes the economics: GPU/NVENC is ~an order of magnitude faster than slow CPU presets (slightly lower efficiency), and purpose-built ASICs (YouTube **Argos VCU**: 20–33× more efficient, one ASIC server ≈ 10 CPU servers, 4K@60fps per core) make web-scale transcoding affordable. The Staff+ framing: pick the ladder + codec mix + hardware to minimize total cost (encode + storage + egress) for the content's popularity and the audience's devices — not "transcode to everything."

## Known failure modes
1. **Transcoding too slow / backlog under load.** Serial or under-parallelized encoding can't keep up with uploads. Production answer: chunked parallel encoding across an autoscaled fleet (and/or GPU/ASIC acceleration); prioritize short/popular videos; per-chunk QC so failures don't restart whole jobs.
2. **A corrupt/failed chunk.** One bad segment risks the whole rendition. Production answer: verify each encoded chunk immediately on completion and re-triage just that chunk; idempotent encode tasks so retries are safe.
3. **Over-spending compute/storage/egress.** Encoding a fixed maximal ladder + every codec for cold content wastes money. Production answer: per-title/per-scene ladders (fewer bits at equal quality), encode the long tail lazily / fewer rungs, choose codecs/hardware by audience and popularity; egress is the dominant cost, so optimize bits-per-quality.

## (Delineation note)
`video-transcoding` is the **compute core** of the UGC video pipeline. The end-to-end upload pipeline is `youtube-upload`; VOD packaging/delivery is `vod-delivery`; GPU-cluster scheduling for the transcode fleet borders infra-primitives `kubernetes-scheduler`. LIVE transcoding is the messaging archetype. Here it's the ABR ladder + chunked parallel encode + per-title/codec/hardware tradeoffs.

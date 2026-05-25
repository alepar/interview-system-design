---
slug: vod-delivery
archetype: ugc-pipeline
sources:
  mux_hls: mux.com/articles/hls-ext-tags
  ottverse_jitp: ottverse.com/what-is-just-in-time-packaging-jitp-benefits/
  blazingcdn_vod: blog.blazingcdn.com/en-us/content-delivery-network-best-practices-scalable-vod-delivery
  netflix_open_connect: blog.blazingcdn.com/en-us/cdn-bandwidth-understanding-costs-and-how-to-optimize-usage
  drm_cenc: doverunner.com/blogs/widevine-playready-fairplay-drm-comparison/
---

# VOD Delivery (packaging + CDN delivery of processed video)

## Bar anchors
- **Mid-level (L4/E4):** Stores the video file and serves it. Doesn't address segmenting, manifests, adaptive streaming, or CDN caching.
- **Senior (L5/E5):** Serves HLS/DASH segments via CDN with a manifest, knows segment duration and that popular videos cache well. May not articulate just-in-time vs pre-packaging, storage tiering by popularity, the ABR long-tail cache problem, egress economics, or multi-DRM.
- **Staff+ (L6/E6+):** Drives proactively. Packages processed renditions into **HLS/DASH** (segments ~6s — Apple default, configurable 2–10s; a **two-tier manifest**: master playlist of variants + per-rendition media playlists of segment URLs) and chooses **just-in-time (JIT) packaging** (store one mezzanine/MP4 per bitrate, transmux to HLS/DASH + manifest on request — saves storage, good to several-thousand concurrent) **vs pre-packaging** (write every format×bitrate up front — e.g. HLS+DASH×4 = 12 stored copies). Tiers **storage by popularity** (hot on SSD/standard, long-tail to Glacier Instant Retrieval — ms access — promoted back if views climb). Names the **ABR long-tail cache problem** (HLS+DASH × N profiles = ~8 separately-cached copies per video, so each quality URL needs enough independent hits to stay warm; cache-key tuning lifts hit 60%→90%+). Frames **egress as the dominant cost** (~$0.085/GB CloudFront; streaming >65% of internet traffic) → CDN offload + tiered cache + Netflix **Open Connect** (ISP-embedded appliances, ~80% cheaper than commercial CDN). Adds **multi-DRM via CENC** (encrypt once in CMAF, serve Widevine/FairPlay/PlayReady — ~99% device coverage, 66% storage saving).

## Canonical decomposition

### Requirements
**Functional:**
- Serve already-processed VOD with adaptive bitrate to many concurrent viewers, low startup latency
- Support multiple delivery formats (HLS + DASH) and devices/DRM
- Keep storage + egress cost manageable across popular and long-tail content

**Non-functional (with numbers):**
- Segments ~6s (2–10s); two-tier manifest (master + media playlists)
- CDN hit ratio target 90%+; egress dominant cost (~$0.085/GB)
- Storage tiering: hot SSD/standard → cold Glacier Instant Retrieval (ms access)
- Multi-DRM: encrypt once (CENC/CMAF) → Widevine/FairPlay/PlayReady (~99% devices)

### Core entities
- **Segment:** a 2–10s media chunk of one rendition (the CDN-cached unit)
- **Manifest:** master playlist (variants) + media playlists (segment lists) — .m3u8 / MPD
- **Mezzanine/MP4:** the stored per-bitrate base (JIT transmuxes from this)
- **Packager:** produces HLS/DASH segments + manifest (pre or just-in-time)

### HLD
Processed renditions (from `video-transcoding`) are **packaged** for adaptive streaming: each rendition is segmented (~6s; Apple's HLS default, tunable 2–10s) and described by a **two-tier manifest** — a **master playlist** listing the available variants (bandwidth, resolution, codecs) and a **media playlist** per rendition listing its segment URLs. Players fetch the master, pick a rung, and request segments, switching rungs at boundaries. **Packaging strategy** is a key tradeoff: **pre-packaging** writes every format×bitrate combination to storage up front (HLS+DASH × 4 bitrates = 12 stored copies per video — multiplies storage), while **just-in-time (JIT) packaging** stores only a base format (one MP4 per bitrate) and **transmuxes to HLS/DASH + manifest on request** — far less storage, ideal up to several-thousand concurrent viewers, and the cost-effective way to support multiple formats.

**Delivery is CDN-fronted** and read-dominated. Because **egress is the dominant cost** (~$0.085/GB on CloudFront; streaming is >65% of internet traffic), the whole design optimizes **CDN offload**: segments cache at the edge (target 90%+ hit; cache-key tuning + per-segment caching can lift 60%→90%+), and at Netflix scale, **Open Connect** appliances embedded inside ISPs (pre-filled off-peak) eliminate commercial-CDN egress for that traffic (~80% cheaper). The subtlety is the **ABR long-tail cache problem**: with HLS and DASH each having ~4 profiles, one video is ~8 separately-cached objects, so each quality URL must be requested enough times independently to stay warm — popular videos hit 90%+, but the cold long tail mostly misses. **Storage is tiered by popularity**: hot/recent videos on SSD/standard, long-tail demoted to **Glacier Instant Retrieval** (ms access, so a cold video's first segment is pulled and then cached), auto-promoted if view rate climbs. **Multi-DRM** uses **Common Encryption (CENC)**: encrypt once (AES in CMAF) and serve to Widevine (Android/Chrome), FairPlay (Apple/HLS), PlayReady (Windows/TV) — ~99% device coverage at ~66% less storage than per-system encryption.

### Deep dives
1. **JIT vs pre-packaging (the storage/compute tradeoff).** Pre-packaging materializes every format×bitrate to storage (12+ copies/video), giving lowest serve-time work but multiplying storage and forcing a re-package to add a format. JIT stores one mezzanine per bitrate and **transmuxes on request** to HLS or DASH + manifest, slashing storage and making "support HLS *and* DASH" nearly free — at the cost of per-request packaging CPU (fine up to several-thousand concurrent, cached at the CDN thereafter). The decision hinges on catalog size and popularity skew: JIT for huge catalogs with long tails (most videos rarely watched, don't pre-package them), pre-package only the hottest content. This is the VOD analog of `image-derivatives`' on-demand-vs-precompute — name the parallel.
2. **CDN offload, the ABR long-tail, and egress economics.** Egress dominates VOD cost (transcoding and storage are secondary at scale), so the lever is **cache hit ratio**: 90%+ for popular content means the origin barely sees traffic. But ABR fragments the cache — HLS+DASH × N renditions = ~8 cached objects per video, each needing independent traffic to stay warm, so the long tail (rarely-watched videos, and unusual quality rungs) misses and hits origin/cold storage. Mitigations: cache-key hygiene + per-segment caching (60%→90%+), tiered cache / origin shield (request collapsing), and at the extreme, **Netflix Open Connect** (own CDN appliances inside ISPs, pre-filled off-peak — ~80% cheaper than commercial CDN). The Staff+ framing: VOD delivery is a caching/egress-cost optimization problem, and ABR multiplies the long-tail cache challenge.
3. **Storage tiering + multi-DRM.** Popularity is heavily skewed (a few videos get most views; most are rarely watched), so **tier storage**: hot/recent on SSD/standard for instant serve, long-tail on **Glacier Instant Retrieval** (millisecond access, so the first request still serves quickly and then caches at the CDN), with auto-promotion when a cold video trends. This trades storage cost against rare cold-fetch latency. **Multi-DRM** is solved with **CENC**: encrypt the content **once** (AES-CTR/CBC in CMAF) and package per-DRM init data, so one encrypted file-set works across Widevine, FairPlay, and PlayReady (~99% of devices) — vs encrypting separately per system (3× storage). The framing: serve the long tail cheaply via cold tiers + CDN caching, and cover all devices with one encryption pass.

## Known failure modes
1. **Storage blowup from pre-packaging everything.** Every format×bitrate stored for a huge catalog explodes cost. Production answer: JIT packaging (store one mezzanine, transmux on request), pre-package only hot content, cold-tier the long tail.
2. **Poor cache hit ratio / origin overload (ABR long tail).** Fragmented per-rendition caching misses on the long tail and hammers origin/cold storage. Production answer: cache-key tuning + per-segment caching, tiered cache/origin shield, Glacier Instant Retrieval + first-segment caching; accept that the cold tail can't be fully warm.
3. **Runaway egress cost.** Bandwidth is the dominant line at scale. Production answer: maximize CDN offload (90%+ hit), efficient codecs/per-title encoding (fewer bits), and ISP-embedded CDN (Open Connect) for the highest-volume traffic.

## (Delineation note)
`vod-delivery` is the **packaging + on-demand delivery** stage of the UGC video pipeline. The transcoding compute is `video-transcoding`; the upload pipeline is `youtube-upload`; generic CDN/edge-cache mechanics are caching `cdn-edge-cache`; the object store is infra-primitives `s3`. LIVE streaming (segment ingest in real time) is the messaging archetype. Here it's HLS/DASH packaging + JIT + tiering + egress optimization.

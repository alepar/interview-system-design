---
slug: twitch-streaming
archetype: realtime-messaging
sources:
  twitch_engineering_overview: blog.twitch.tv/en/2015/12/18/twitch-engineering-an-introduction-and-overview
  twitch_low_latency: blog.twitch.tv 2021-10-25 "Low Latency, High Reach" (Yueshi Shen)
  cloudinary_ll_comparison: cloudinary.com/guides/live-streaming-video/low-latency-hls-ll-hls-cmaf-and-webrtc
  apple_hls: developer.apple.com/streaming
---

# Twitch streaming — low-latency live video to millions of concurrent viewers

## Bar anchors
- **Mid-level (L4/E4):** Treats live video as "RTMP in, HLS out via CDN." Doesn't address transcoding economics, bitrate ladders, or the latency-vs-fan-out trade-off.
- **Senior (L5/E5):** Names RTMP ingest, transcoding ladder, HLS via CDN. Discusses ABR. May or may not surface LL-HLS vs LL-CMAF vs WebRTC trade-off, hardware transcoding economics, or origin-shielding patterns.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the **LL-HLS vs LL-CMAF vs WebRTC trade-off**: WebRTC <1s but doesn't fan out economically past ~100K viewers on one stream; LL-HLS 2-8s; LL-CMAF 3-5s; for 2M+-concurrent streams, must accept ≥2s latency for CDN cacheability. Cites **Twitch's in-house hardware transcoders**: per Yueshi Shen (blog.twitch.tv 2021), *"At the time I joined Twitch, we were only able to offer transcoding to 2 percent or 3 percent of our channels. Our video team has built a hardware-based transcoder solution… We're expanding our capacity by 10 times, at only two times the cost."* Names the **bitrate ladder** (source / 1080p60 / 720p60 / 720p / 480p / 360p / audio-only). Articulates **origin shielding** at PoPs and the **IRS metric** deciding capacity reach by % of users at each quality. Stretch (Sr Staff bar): articulates the LHLS (Community-LHLS) → AWS IVS lineage; explains why Twitch parented this protocol rather than waiting for Apple LL-HLS standardization.

## Canonical decomposition

### Requirements
**Functional:**
- Ingest hundreds of thousands of concurrent RTMP/SRT broadcasters
- Transcode each to a 5-step bitrate ladder
- Deliver via HLS/LL-HLS to viewers globally
- <5s glass-to-glass latency target
- Adaptive bitrate per viewer

**Non-functional (with numbers):**
- 2M+ concurrent live streams peak (blog.twitch.tv 2015)
- 10B+ chat messages/day platform-wide (chat detailed in `twitch-chat`)
- Web APIs ~50K req/sec average
- Bitrate ladder: 5 quality levels
- LL-HLS latency: 2-8s; LL-CMAF: 3-5s; WebRTC: <1s
- Hardware transcoder: 10× capacity at 2× cost (Yueshi Shen 2021)

### Core entities
- **Stream:** stream_key, broadcaster_id, channel_id, ingest_pop, source_bitrate
- **TranscodingJob:** stream_id, ladder[], hw_transcoder_id, status
- **HLSSegment:** (stream_id, bitrate, segment_id, duration); cached at PoP
- **Viewer:** viewer_id, current_bitrate, pop_id, last_segment_fetched
- **OriginShield:** PoP-level shield for hot streams

### API
- Ingest: `rtmp://ingest-{pop}.twitch.tv/live/{stream_key}` (or SRT for low-latency ingest)
- Playback: HLS manifest `GET /hls/{stream}/master.m3u8` → per-bitrate manifests → segments
- LL-HLS partial segments via HTTP/2 push or preload hints
- Stats: server-side viewer telemetry per segment (used for capacity decisions)

### HLD
**Ingest** at PoP edge: broadcaster's encoder pushes RTMP (or SRT) to nearest ingest PoP; ingest server validates stream_key, forwards source bitstream to **origin transcoder pool** (regional fan-in). **Hardware transcoder** (Twitch's in-house ASIC) transcodes source → 5 bitrate ladder rungs (e.g., source 1080p60 → 1080p60 / 720p60 / 720p / 480p / 360p / audio-only); LL-HLS partial segments (200-400ms duration) emitted continuously; full HLS segments (2-6s) aggregated. **CDN distribution**: PoPs cache HLS segments keyed by `(stream, bitrate, segment_id)`; viewer's player negotiates the manifest, fetches segments via HTTP/2 (LL-HLS partial-segments via preload hints). **Origin shielding**: each PoP designates a small set of "shield" nodes that handle origin pulls; non-shield nodes hit shield instead of origin; absorbs viral-stream spike. **IRS (infrastructure-replication metric)** tracks % of users served at each quality level; decisions on whether to add capacity or drop quality based on IRS.

### Deep dives
1. **LL-HLS vs LL-CMAF vs WebRTC — the latency-vs-fan-out trade-off.** **WebRTC**: <1s glass-to-glass; but fan-out via SFU caps at ~1-10K viewers per channel economically (each viewer is a unicast UDP stream from SFU; bw scales with viewer count linearly). **LL-HLS** (Apple's standard, HTTP-based): 2-8s; full CDN-cacheable; partial-segment chunking via HTTP/2 preload hints reduces latency vs traditional HLS (10-30s). **LL-CMAF** (chunked CMAF over DASH or HLS): 3-5s; similar pattern, chunks emitted as the encoder produces them; supports both DASH and HLS manifests. Twitch's choice: **LL-HLS / LHLS** for the long tail (millions of viewers, CDN-cacheable); WebRTC tested for sub-second but doesn't scale economically. AWS IVS (descended from Twitch's LHLS) targets 2-3s latency for sub-100K viewer streams.

2. **Hardware transcoder economics.** Software transcoding every Twitch channel was untenable: top channels need 5-ladder transcoding (e.g., source 1080p60 + 4 lower rungs), but with millions of concurrent streams and ~10K active transcoded streams concurrently, software CPU cost was prohibitive ("transcoding to 2-3% of channels" — Yueshi Shen 2021). Hardware ASIC transcoders: purpose-built H.264/H.265 transcoder chips; 10× throughput at 2× cost vs CPU; deployable in dense racks. Result: Twitch can offer transcoded ladders to nearly all channels (not just partner+ tier), improving stream quality for low-bandwidth viewers. Trade: ASIC less flexible than CPU (can't easily add new codecs like AV1 without hardware refresh); mitigated by hybrid pool (ASIC for established codecs, CPU for new codec rollouts).

3. **CDN architecture + origin shielding + IRS.** PoPs cache HLS segments keyed by `(stream, bitrate, segment)`. Cache key chosen carefully: per-bitrate-per-segment ensures cache-friendly URL pattern. **Origin shielding**: viral-stream goes from 1K → 1M viewers in minutes; each PoP's cache misses cascade to origin; origin saturates. Mitigation: per-PoP shield (small set of nodes that handle origin pulls); non-shield nodes hit shield instead of origin; shield warms up quickly and absorbs the spike. **IRS metric**: tracks % of users served at each quality level globally; if IRS for 1080p drops below threshold, decision rule is "do we add capacity or temporarily reduce upper ladder rung?" — capacity-vs-quality trade decided programmatically.

## Known failure modes
1. **Origin overload during viral event** (stream goes from 1K to 1M viewers in minutes). Production answer: PoP-level origin shielding + warm caches; IRS metric drives capacity decisions; for predictable events (tournaments), pre-warm.

2. **Bitrate-ladder mismatch** (viewer bandwidth between rungs → constant buffer-then-step rebuffering). Production answer: more ladder rungs (5 → 7 for hot streams); smaller LL-HLS partial-segment chunks to limit rebuffer window; client-side ABR algorithm tuning (more conservative ladder-step-down).

3. **Sub-second latency demand vs CDN cacheability conflict.** Esports broadcasters want <1s latency to compete with TV; CDN-cacheable LL-HLS is 2-5s. Production answer: explicit decision to keep LL-HLS at 2-5s for the long tail (cost-optimal); offer WebRTC tier for premium broadcasters at sub-second (AWS IVS supports this); communicate the trade-off clearly in broadcaster tooling.

## Notes for the coach
- **Asked-confirmed at Twitch and YouTube Live.** Hello Interview, ByteByteGo Vol 2, AlgoMaster carry this canonically. **Plausibly-asked** at Meta Live, Snap Spotlight Live.
- **The hardware transcoder + 10× capacity at 2× cost number is the canonical economics anchor.** Yueshi Shen 2021 is the primary source.
- **The latency-vs-fan-out trade-off is the Staff+ framing test.** Candidates who pick one (e.g., "we use WebRTC for everyone") miss the trade; candidates who articulate "hybrid: WebRTC for premium low-latency tier + LL-HLS for the long tail" demonstrate the right framework.
- **Adversarial probe: "we want sub-second for every viewer — why not?"** Strong answer: per-viewer unicast WebRTC bw at 1M viewers = millions × 3 Mbps = petabit-class outbound; CDN can't cache because UDP/SRTP is per-viewer; cost math kills it. Weak answer: "WebRTC doesn't scale" without the unicast-vs-cacheable framing.

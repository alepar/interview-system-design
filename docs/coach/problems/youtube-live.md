---
slug: youtube-live
archetype: live-media-broadcast
sources:
  youtube_live_dash: developers.google.com/youtube/live-streaming
  dash_if_ll: dashif.org "Low-Latency Live Streaming with MPEG-DASH and CMAF"
  jiocinema_record: Public engineering claims around JioCinema IPL 2024 32M-concurrent record
---

# YouTube Live — DASH+QUIC live streaming at 32M-concurrent scale

## Bar anchors
- **Mid-level (L4/E4):** Treats live as a generic "RTMP in, HLS out." Doesn't differentiate DASH vs HLS or QUIC vs TCP.
- **Senior (L5/E5):** Names DASH manifests, ABR, multi-CDN. Discusses transcoding ladder. May or may not address QUIC's mobile-handoff benefit, multi-language audio pipelines, or the JioCinema 32M-concurrent capacity validation.
- **Staff+ (L6/E6+):** Drives proactively. Articulates why **DASH+QUIC** vs LL-HLS for unbounded fan-out: QUIC's loss-recovery beats HLS-over-TCP for mobile (which is the dominant viewer platform); chunked-CMAF over DASH gives sub-5s glass-to-glass. Articulates the **multi-language pipeline** (concurrent transcoded audio tracks + auto-CC inference as audio-track-equivalent in the DASH manifest). Cites the **JioCinema IPL 2024 32M-concurrent record** (public engineering claim) and describes multi-CDN aggregation (Akamai + Google CDN + custom edge), origin-shielding, pre-warming on event-start. Names **SCTE-35 markers** for live ad insertion. Stretch (Sr Staff bar): articulates QUIC connection-migration for mobile handoff (cell tower → WiFi without reconnecting); explains why YouTube Live diverges from Twitch's LL-HLS choice (DASH heritage + HTTP/3 substrate).

## Canonical decomposition

### Requirements
**Functional:**
- Live ingest at RTMP/SRT scale; transcoding ladder
- DASH+QUIC delivery for low-latency tier; HLS for compatibility
- Multi-language audio tracks (10+ per stream)
- Auto-caption inference per language
- SCTE-35 ad insertion with per-viewer ad-pod routing
- Support 32M concurrent viewers per single event (JioCinema record)

**Non-functional (with numbers):**
- JioCinema IPL 2024: 32M concurrent record (public engineering claim)
- DASH chunks via QUIC (HTTP/3) at low-latency mode 2-5s
- 10+ audio tracks per stream concurrent
- Auto-CC at 100K+ streams concurrent
- Multi-CDN aggregation (Akamai + Google + custom edge)

### Core entities
- **Stream:** stream_id, ingest_endpoint, transcoding_ladder[], language_tracks[]
- **EncoderJob:** per-language audio track + auto-CC inference + video bitrate ladder
- **DASHManifest:** dynamic MPD with chunked CMAF; audio adaptation set per language + CC track
- **CDNNode:** PoP cache for DASH chunks; QUIC-capable; falls back to HTTP/2 for non-QUIC clients
- **AdPod:** server-side ad insertion via SCTE-35 markers in encoder; per-viewer ad-pod selection

### API
- Ingest: RTMP/SRT to regional ingest endpoints
- Playback: DASH manifest `GET /dash/{stream}/manifest.mpd` (HTTP/3 preferred); HLS fallback
- HLS: `GET /hls/{stream}/master.m3u8`
- Stats: per-viewer telemetry to feed ABR + capacity decisions

### HLD
**Ingest** at edge: broadcaster pushes RTMP/SRT to nearest regional ingest; ingest validates + forwards to **encoder pool**. Encoder produces (a) video bitrate ladder (e.g., 1080p60 / 720p60 / 480p / 360p / audio-only), (b) multi-language audio tracks (each language is its own encoded stream, often via re-encoded post-source via translation or live dub), (c) auto-CC inference (STT per language, output as CMAF caption tracks). All outputs are **chunked CMAF** (~200-500ms chunks). **DASH manifest** describes the available representations + chunk URLs; dynamic MPD updates as new chunks arrive. **CDN distribution**: PoPs cache CMAF chunks; HTTP/3 (QUIC) preferred for mobile (loss-recovery + connection-migration); HTTP/2 fallback. **Multi-CDN aggregation** (JioCinema style): pre-event traffic split across Akamai + Google CDN + custom edge; viewer's client picks the best CDN per-region (latency-based DNS or client-side probe). **SCTE-35** markers embedded in encoder output trigger ad-pod insertion at CDN-side (server-side ad insertion — SSAI — splices ad chunks into the stream for each viewer).

### Deep dives
1. **DASH+QUIC vs LL-HLS — why YouTube diverges.** **DASH** (MPEG-DASH, ISO/IEC standard): codec-agnostic, supports CMAF chunks for low-latency; YouTube's heritage protocol. **HLS** (Apple): ubiquitous on iOS but TCP-based; LL-HLS partial segments via HTTP/2 preload hints (Twitch's choice). **QUIC** (HTTP/3): UDP-based; built-in loss-recovery + connection migration (cell→WiFi without reconnecting); fewer head-of-line-blocking issues for mobile. YouTube's choice: DASH+QUIC for the modern tier (mobile-first, HTTP/3 substrate); HLS for compatibility. Trade-off vs Twitch's LL-HLS: DASH+QUIC requires HTTP/3-capable clients (most modern browsers + Android, iOS partial), but YouTube's scale and Google's substrate (already running QUIC for search/maps) makes it viable.

2. **JioCinema 32M-concurrent architecture.** Public engineering claim: 32M concurrent during IPL 2024 finals. Architecture inference (not all publicly published): multi-CDN aggregation (Akamai + Google CDN + custom edge); origin-shielding at CDN tier (most viewers hit CDN cache; misses cascade to a small set of shield nodes; shield warms origin); pre-warming on event-start (toss-time spike); per-region traffic distribution (Indian regions dominate; carve out per-region capacity); aggressive QUIC adoption (mobile-dominant audience). Failure modes: spike at event-start (toss, big-wicket moment) → pre-warm + multi-CDN burst capacity; auto-caption STT inference saturating GPU pool → backpressure + degraded captions; QUIC connection migration failures → TCP fallback.

3. **Multi-language audio + auto-caption pipeline.** YouTube serves a global audience; live streams often need 10+ language tracks. **Audio tracks**: each language is its own encoded stream (raw studio dub re-encoded, or live AI translation+TTS); embedded in DASH manifest as an audio adaptation set per language; client picks one at play time. **Auto-CC inference**: STT (Whisper-class) per language; output as CMAF caption tracks (WebVTT-in-ISOBMFF or TTML); integrated as text tracks in DASH manifest. **Inference at scale**: 100K+ streams × 10 languages × continuous inference = millions of GPU-hours; batched STT (28× speedup with VAD pre-segmentation per multimodal-realtime-serving doc); fallback to no-CC on saturation.

## Known failure modes
1. **Spike at event start** (IPL toss, major moment). Production answer: pre-warm origin + edge before scheduled start; multi-CDN burst capacity; for predictable events, scheduled capacity reservation across CDN providers.

2. **Auto-caption lag** (STT inference behind real-time; viewers see captions 30s late). Production answer: backpressure on STT inference (drop low-priority languages first); degrade gracefully to subtitles-disabled for languages where STT can't keep up; surface "captions delayed" in UI.

3. **QUIC connection-migration failures** (client switches from cell → WiFi mid-stream; QUIC migration should be transparent but sometimes fails). Production answer: client falls back to TCP HTTP/2; loss of QUIC's mobile-handoff benefit but functional; per-session telemetry to identify systematic QUIC migration failures (often due to UDP-blocking middleboxes).

## Notes for the coach
- **Asked-confirmed at YouTube/Google.** JioCinema 32M-concurrent is publicly cited. **Plausibly-asked** at any live-streaming shop.
- **The DASH+QUIC vs LL-HLS framing is the Staff+ unlock.** Candidates who can articulate the protocol-choice trade-off (mobile-handoff, loss-recovery, head-of-line-blocking) demonstrate substrate awareness; candidates who say "HLS or DASH, doesn't matter" miss the operational difference.
- **The 32M-concurrent anchor differentiates YouTube Live from Twitch.** Twitch's published max is lower (~2M concurrent streams, but each ~1K-100K viewers); YouTube/JioCinema scale is one single stream at tens of millions.
- **Adversarial probe: "you have 32M viewers — what's the dominant cost?"** Strong answer: outbound CDN bandwidth (TB/sec class); multi-CDN aggregation distributes; pre-warm and origin-shielding absorb spike. Weak answer: "transcoding" — not at 32M viewers of a single stream (transcoding cost is per-stream, not per-viewer).

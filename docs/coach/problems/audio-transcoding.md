---
slug: audio-transcoding
archetype: ugc-pipeline
sources:
  ffmpeg_mp3: trac.ffmpeg.org/wiki/Encode/MP3
  loudnorm: ayosec.github.io/ffmpeg-filters-docs/8.0/Filters/Audio/loudnorm.html
  lufs_targets: matlefflerschulman.com/mastering-articles/loudness-targets-and-mastering-for-streaming-platforms
  soundcloud_hls: developers.soundcloud.com/blog/api-streaming-urls/
  bbc_audiowaveform: github.com/bbc/audiowaveform
---

# Audio Transcoding (podcast/music upload → process → serve)

## Bar anchors
- **Mid-level (L4/E4):** Stores the uploaded audio and serves it. Doesn't address transcoding to multiple formats/bitrates, loudness, waveforms, or streaming packaging.
- **Senior (L5/E5):** Transcode to MP3/AAC at a few bitrates, segment for HLS streaming, extract metadata. Knows loudness normalization exists. May not articulate LUFS targets/two-pass loudnorm, the chunked-parallel processing, waveform generation, or the async pipeline.
- **Staff+ (L6/E6+):** Drives proactively. Transcodes to multiple **formats/bitrates** (MP3/AAC/Opus; 128–320kbps; ffmpeg can map several codecs/bitrates in one pass) and **packages HLS audio ABR** (segments 2–6s; ladder e.g. 32–48kbps HE-AAC speech → 64–96 music → 128–192 AAC-LC; SoundCloud serves ~64kbps Opus free / 256kbps AAC paid, migrating to AAC HLS). Applies **loudness normalization** to platform LUFS targets (Spotify −14 LUFS/−1 dBTP, Apple −16, EBU R128 −23) via **ffmpeg `loudnorm` two-pass** (measure → apply with measured I/LRA/TP; 192kHz upsample in dynamic mode). Generates **waveform data** (BBC `audiowaveform`: mono mix, min/max over N samples → .dat/JSON for Peaks.js) and extracts **ID3** metadata. Knows **Opus** efficiency (64kbps ≈ MP3 128kbps; 24–32 speech / 96–128 music). Runs it as an **async chunked pipeline** (ffmpeg is single-core per encode → chunk long files / parallelize across workers; S3-event → queue → workers → DLQ + idempotent retries).

## Canonical decomposition

### Requirements
**Functional:**
- Transcode uploaded audio to multiple formats/bitrates; package for adaptive streaming
- Normalize loudness to a consistent target; generate waveforms + extract metadata
- Process asynchronously and at scale

**Non-functional (with numbers):**
- Bitrates 128–320kbps (MP3/AAC); Opus 24–32 speech / 96–128 music
- LUFS targets: Spotify −14/−1 dBTP, Apple −16, EBU R128 −23
- HLS audio segments 2–6s; ladder 32–192kbps
- ffmpeg single-core/encode → chunk + parallelize long files

### Core entities
- **Source audio:** the uploaded file (object storage)
- **Rendition:** a (format, bitrate) output; segmented for HLS
- **Loudness metadata:** measured LUFS/LRA/true-peak → gain applied
- **Waveform + ID3:** visualization data + extracted tags

### API
- S3 `ObjectCreated` → queue → transcode worker (ffmpeg) → renditions + HLS segments + waveform
- loudnorm two-pass: measure (print_format=json) → apply (measured_I/LRA/TP)
- `GET /audio/:id` → HLS manifest + AAC/Opus segments (CDN-served)

### HLD
The pipeline is **upload → (async) process → store → serve**, like video but lighter. On upload (resumable, direct-to-storage), an **S3 event** enqueues a transcode job for a **worker pool** running **ffmpeg**. Processing produces multiple **renditions** (MP3/AAC/Opus at 128–320kbps; ffmpeg can emit several codec/bitrate streams in one command) and packages an **HLS audio ABR** (2–6s segments; a ladder like 32–48kbps HE-AAC for speech/podcasts up to 128–192kbps AAC-LC for music, each rendition with its own playlist; SoundCloud serves ~64kbps Opus to free listeners and 256kbps AAC to paid, migrating to AAC HLS). **Loudness normalization** is the audio-specific must: platforms target a consistent perceived loudness (**Spotify −14 LUFS / −1 dBTP, Apple Music −16, broadcast EBU R128 −23**), achieved with ffmpeg's **`loudnorm` filter in two passes** — a measurement pass (outputs measured integrated loudness, loudness range, true peak as JSON) then an application pass using those measured values for accurate gain (dynamic mode upsamples to 192kHz to catch true peaks; linear mode preserves dynamics for mastered music).

Two more outputs: **waveform data** for the scrubber UI (BBC **audiowaveform**: mix to mono, compute min/max sample values over groups of N samples controlled by a zoom level, output binary .dat or JSON consumed by renderers like Peaks.js), and **ID3/metadata** extraction (title/artist/album via Mutagen/TagLib/ffprobe). Codec choice favors **Opus** where supported (64kbps ≈ MP3 128kbps; 24–32kbps for speech, 96–128 for music) for bandwidth, with AAC/MP3 for compatibility. Operationally, **ffmpeg is single-core per encode**, so throughput comes from **chunking long files** (e.g. 20-min/32kbps segments) and **parallelizing across workers** (GNU parallel / a worker fleet), wired as a standard **async pipeline** (queue, idempotent workers, retries with backoff, **dead-letter queue** for poison files).

### Deep dives
1. **Loudness normalization (the audio-specific core).** Unlike video, audio has a hard cross-platform expectation: **consistent loudness** so tracks don't jump in volume. Platforms publish LUFS targets (Spotify −14 / −1 dBTP true-peak, Apple −16, EBU R128 −23 for broadcast), and the pipeline measures + adjusts each upload to the target. ffmpeg's **`loudnorm`** does this in **two passes**: pass 1 measures integrated loudness (LUFS), loudness range (LRA), and true peak; pass 2 applies gain using those measured values for accuracy (one-pass is approximate). Dynamic mode upsamples to 192kHz to detect inter-sample true peaks; linear mode preserves the master's dynamics. This is the distinctive audio stage — naming LUFS targets + two-pass loudnorm (and that one-pass is inaccurate) is the Staff+ signal that separates audio transcoding from "just run ffmpeg."
2. **HLS audio ABR + codec choice.** Like video, streamed audio uses an **adaptive bitrate ladder** segmented for HLS (2–6s segments, per-rendition playlists), so a player adapts to bandwidth — but the rungs are audio-shaped (32–48kbps HE-AAC for speech/podcasts, 64–96 for music radio, 128–192 AAC-LC top). **Codec choice** drives the ladder: **Opus** is markedly more efficient (64kbps ≈ MP3 128kbps; ideal 24–32kbps speech / 96–128 music) but AAC/MP3 win on device compatibility, so platforms serve tiers by client (SoundCloud: 64kbps Opus free, 256kbps AAC paid; migrating to AAC HLS). The framing mirrors `video-transcoding`'s ladder/codec tradeoff at audio scale — fewer bits, but the same adaptive-streaming + codec-efficiency-vs-compatibility logic.
3. **Waveform/metadata + async chunked processing.** Beyond playable renditions, the pipeline produces **derived artifacts**: a **waveform** for the scrubber (BBC audiowaveform mixes to mono and stores min/max over N-sample groups as compact .dat/JSON — precomputed so the client doesn't decode the whole file to draw it) and **ID3 metadata** (title/artist/album, extracted via Mutagen/ffprobe). Operationally, **ffmpeg encodes single-core**, so a long podcast is **chunked** (e.g. 20-min segments) and processed in parallel across workers, then stitched — the same chunked-parallel idea as video, plus standard async-pipeline hygiene (queue, idempotent retries, DLQ for files ffmpeg can't decode). The Staff+ point: audio transcoding is a multi-output async pipeline (renditions + loudness + waveform + metadata), parallelized by chunking around a single-threaded encoder.

## Known failure modes
1. **Inconsistent loudness across tracks.** Volume jumps between uploads. Production answer: two-pass loudnorm to a platform LUFS target (measure then apply with measured values); one-pass is inaccurate.
2. **Transcode backlog on long files.** A 3-hour podcast on a single-core encoder is slow. Production answer: chunk long files + parallelize across workers (GNU parallel / fleet), then stitch; queue + autoscale; DLQ for undecodable files.
3. **Playback fails on some devices / over slow networks.** A single codec/bitrate doesn't fit all clients. Production answer: multi-codec renditions (AAC/MP3 for compatibility, Opus for efficiency) + HLS ABR ladder so the player adapts; serve tiers by client/subscription.

## (Delineation note)
`audio-transcoding` is the **audio** member of the UGC media pipeline (renditions + loudness + waveform + HLS), sibling to `video-transcoding`. Live audio rooms are the messaging archetype (`audio-rooms`); the object store is infra-primitives `s3`. Here it's loudness normalization + HLS audio ABR + waveform/metadata + chunked async processing.

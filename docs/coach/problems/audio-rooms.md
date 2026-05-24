---
slug: audio-rooms
archetype: realtime-messaging
sources:
  discord_stages_10k: Medium "How Discord Stage Channels Handle 10,000 People"
  twitter_spaces_til: Simon Willison TILs on Twitter Spaces HLS architecture
  clubhouse_5k: revive.social (Clubhouse architecture overview)
---

# Audio rooms — Twitter Spaces / Clubhouse / Discord Stages with hybrid SFU + HLS

## Bar anchors
- **Mid-level (L4/E4):** Treats audio rooms as "WebRTC for everyone." Doesn't address the speaker/listener asymmetry or the fan-out economics past 1K listeners.
- **Senior (L5/E5):** Names SFU for speakers, mentions HLS for listeners. Discusses raise-hand → promote. May or may not articulate the two-tier delivery split or recording-as-HLS-replay.
- **Staff+ (L6/E6+):** Drives proactively. Recognizes the **two-tier delivery split** as the architectural trick: speakers go through WebRTC SFU (sub-second), listeners receive an HLS/LL-HLS mux of the speaker streams (3s, cheap to fan out via CDN). Articulates **tier promotion** (raise-hand → promote-to-speaker reassigns listener's connection from CDN-pull HLS to SFU-WebRTC, ideally <1s; pre-warm WebRTC offer during raise-hand state). Names **Discord Stage Channels pure-SFU** alternative (handles up to ~10K listeners per SFU node by leveraging asymmetric load: few streams in, many out). Articulates **recording as HLS replay** (same HLS chunks serve live + post-event playback; Twitter Spaces uses Periscope's backend with Fastly CDN). Stretch (Sr Staff bar): articulates moderation primitives (instant kick → SFU drops speaker stream; key rotation in MLS group if E2E); per-speaker audio-level RTP extension for prioritization.

## Canonical decomposition

### Requirements
**Functional:**
- ~10 speakers per room (Twitter Spaces caps 11 including host; Discord Stages ~10)
- Up to 10K-100K listeners per room
- Sub-second audio latency for speakers
- ≤3s latency for listeners (asymmetry is the architectural trick)
- Real-time reactions (emoji), raise-hand → promote-to-speaker, recording for replay
- Recording retention: 30-90 days per platform policy

**Non-functional (with numbers):**
- Discord Stage Channels: ~10 speakers + up to 10K listeners per channel
- Twitter Spaces: 11 speakers (10 + host); listeners unbounded; HLS .aac chunks via Fastly CDN
- Clubhouse: up to 5K listeners per room
- Codec: Opus speaker ~32 kbps; listener-side AAC over HLS

### Core entities
- **Room:** room_id, host_id, speakers[], listeners (counted), recording_enabled, state
- **SpeakerStream:** WebRTC connection to SFU; participant_id; audio-level
- **ListenerSession:** HLS playback client (Twitter Spaces) OR SFU listener (Discord Stages)
- **PromotionRequest:** (room_id, user_id, requested_at); approved → tier-switch
- **Recording:** persisted HLS chunks (Twitter Spaces) OR persistent SFU recording (Discord)

### API
- `POST /rooms/{id}/join` — listener joins; gets HLS manifest URL (or SFU endpoint for Stages)
- `POST /rooms/{id}/raise-hand` — request to speak
- `POST /rooms/{id}/promote` — host approves; client tier-switches
- WebRTC signaling for speakers; HLS playback for listeners (Spaces)
- `GET /rooms/{id}/replay` — recorded HLS manifest, post-event

### HLD
**Speaker side**: 10 speakers connect to a WebRTC SFU (one SFU per room, or shared SFU pool); SFU mixes speaker audio (for Spaces) or selectively forwards (for Discord Stages). Mixed/forwarded audio is encoded as **HLS .aac chunks** and pushed to CDN (Spaces uses Periscope's backend with Fastly). **Listener side (Spaces)**: clients fetch HLS chunks from CDN (5-15s behind live depending on chunk-duration + buffer); millions of listeners fan-out via CDN cache (90%+ offload typical). **Listener side (Discord Stages)**: pure SFU — same code path as voice channels; capacity ~10K listeners per SFU node (asymmetric: few streams in + many streams out keeps per-node load tractable). **Tier promotion**: listener clicks raise-hand; host approves; listener's client switches from HLS playback (or SFU-listener) to WebRTC speaker; brief 1-2s silence (Spaces) or seamless (Stages with pre-warmed connection). **Recording**: HLS chunks persist after live; manifest converted from dynamic (live) to static (on-demand) post-event; Spaces retains 30 days normal / 90 if reported.

### Deep dives
1. **The hybrid WebRTC + HLS split (Twitter Spaces pattern).** **Speaker tier**: ~11 speakers in WebRTC SFU; mixed/forwarded audio re-encoded as HLS .aac chunks; pushed to CDN. **Listener tier**: clients fetch HLS chunks from CDN; 5-15s lag is acceptable for passive listening; CDN absorbs unlimited fan-out cheaply. **Tier promotion** (the critical handoff): listener clicks raise-hand → request to host → host approves → listener's client tears down HLS playback, opens WebRTC connection to SFU, joins as speaker. **Brief silence at handoff** (1-2s): client switches transport; cannot publish until SFU connection is established. **Pre-warm trick**: listener's client opens WebRTC connection to SFU on raise-hand (doesn't publish until approved); handoff is near-instant on approval. Trade: hybrid wins on cost (CDN fan-out cheap, SFU handles only speakers); HLS lag means listeners see reactions later than speakers say things.

2. **Discord Stage Channels pure-SFU.** Same SFU code path as Discord voice channels; role gating on who can speak. Asymmetric load: "a few streams in (10 speakers) + 10K streams out (listeners)." Per-SFU node: well-suited because outbound forwarding is cheap per stream (no decode/encode per receiver); inbound encoding/mixing only on speakers. Trade vs hybrid: lower latency end-to-end (all WebRTC, sub-500ms vs HLS 5-15s) but capacity-capped at ~10K per channel; for mega-Stages (50K+), would need cross-SFU forwarding (relay between SFU nodes — adds complexity). Discord's choice: optimize for sub-second interaction; cap at 10K listeners.

3. **Recording as HLS replay.** HLS .aac chunks written to CDN-cached origin at live time; chunks persist after event ends; post-event "VOD" is the same set of chunks with manifest converted from dynamic (live) to static (on-demand). Recording is "free" — no separate recording pipeline. **Editing recordings**: Spaces supports basic edit (trim start/end) by adjusting the manifest's first/last segment; full edit (cut middle) requires re-rendering. **Retention**: 30 days normal (Spaces); 90 days if reported (moderation hold). For Discord Stages, recording is a separate SFU-side capture (since pure-SFU has no HLS chunks naturally); more expensive to record + serve.

## Known failure modes
1. **Promotion latency.** Role transition causes 3-5s gap (HLS teardown + WebRTC setup); UX feels broken. Production answer: pre-warm WebRTC connection on raise-hand (client opens connection to SFU, doesn't publish until promoted); reduces silence to <1s.

2. **Listener-count explosion on viral moment.** Speaker says something noteworthy; listener count spikes from 5K to 100K in minutes. Production answer: pre-warm CDN cache; admission control on entry (rate-limit new listeners per second); for Discord Stages (pure SFU), capacity-cap with overflow to second SFU instance (cross-SFU relay).

3. **Single noisy speaker clipping others.** Production answer: server-side **audio-level RTP extension** lets muxer prioritize active speakers (top-3 loudest forwarded; quieter ones suppressed); spectrum-based noise suppression (Krisp-class) on client side.

## Notes for the coach
- **Plausibly-asked at Discord, Spotify (Greenroom successor), Twitter/X.** Discord blog confirms stage-channel architecture publicly. Twitter Spaces architecture inferred from third-party teardowns (Simon Willison's TIL on HLS chunk extraction) + Periscope's prior published architecture.
- **The two-tier split is the Staff+ unlock for the Spaces/Clubhouse pattern.** Candidates who articulate "speakers via SFU + listeners via HLS" demonstrate the cost-optimal hybrid; candidates who default to "all WebRTC" miss the CDN-fan-out economics.
- **The pure-SFU alternative (Discord Stages) is the depth probe.** Candidates who can compare hybrid vs pure-SFU with explicit criteria (latency vs capacity vs cost) demonstrate the framework; candidates who pick one without trade-offs miss the design space.
- **Adversarial probe: "I want sub-second latency for 100K listeners — what's the cost?"** Strong answer: cannot cheap-fan-out at sub-second (HLS too slow; WebRTC unicast bw at 100K = unaffordable); accept the 5-15s HLS lag or cap listener count. Weak answer: "we use a custom protocol" without acknowledging the bandwidth-vs-latency cost.

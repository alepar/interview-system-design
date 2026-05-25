---
slug: video-player
archetype: frontend
sources:
  shaka_player: github.com/shaka-project/shaka-player
  hlsjs_api: github.com/video-dev/hls.js/blob/master/docs/API.md
  mdn_mse_sourcebuffer: developer.mozilla.org/en-US/docs/Web/API/SourceBuffer/appendBuffer
  netflix_html5_ui: netflixtechblog.com/html5-video-playback-ui-62cfdd9b5d19
  netflix_modernizing: netflixtechblog.com/modernizing-the-web-playback-ui-1ad2f184a5a0
  webvtt_api: developer.mozilla.org/en-US/docs/Web/API/WebVTT_API
  pip_api: developer.mozilla.org/en-US/docs/Web/API/Picture-in-Picture_API
  drm_guide: castlabs.com/drm-guide/
---

# Video player — HTML5 video: MSE + HLS/DASH adaptive bitrate + EME DRM + dual-EWMA ABR + WebVTT captions + Picture-in-Picture

## Bar anchors
- **Mid-level (L4/E4):** Uses `<video src="...">` with single MP4. No adaptive bitrate; no DRM.
- **Senior (L5/E5):** Names MSE + HLS/DASH. Discusses captions. May or may not articulate dual-EWMA ABR, buffer policy, MSE invariant, or DRM multi-CDM.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Names (a) **protocol choice**: HLS via `hls.js` cross-browser (Chrome/Firefox lack native HLS); DASH via `dash.js`; both use MSE to push segments into SourceBuffer; (b) **ABR algorithm**: start at low rendition for fast first-frame, ramp up based on measured bandwidth + buffer health; switch down aggressively on stall; **hls.js dual EWMA**: fast EWMA reacts to drops, slow EWMA prevents premature upshifts, uses min of both; (c) **buffer policy**: hls.js `maxBufferLength` 30s forward, `maxBufferSize` 60 MB; **`backBufferLength` defaults to Infinity** — must override for low-memory devices; (d) **MSE invariant**: check `sourceBuffer.updating === false` before mutating; concurrent ops throw InvalidStateError; queue behind 'updateend'; (e) **DRM via EME**: Widevine (Chrome/Firefox/Android, Netflix/YouTube/Hulu), FairPlay (Safari/iOS), PlayReady (Edge/Windows); multi-DRM license server required. **Netflix em-unit pattern**: 1 em = 1% of container height so UI overlays scale proportionally. **YouTube DASH 2-10s segments**; min 1.1 Mbps 480p / 2.5 Mbps 720p / ≥5 Mbps HD.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Adaptive bitrate HLS/DASH playback
- Seekable timeline with thumbnail scrubbing
- Closed captions / subtitles
- Picture-in-Picture support
- DRM-protected content (Widevine + FairPlay + PlayReady)
- Keyboard shortcuts (space/k=pause, j/l=±10s, ←/→=±5s, m=mute, f=fullscreen, c=captions, 0-9=jump %)

**Non-functional:**
- YouTube/Netflix: hundreds of millions of concurrent streams
- Per-client: 4K ~25 Mbps, 1080p ~5 Mbps, 360p ~700 kbps
- Segment duration 2-10s
- Time-to-first-frame ≤2s broadband, ≤4s cellular
- INP ≤100ms on play/pause toggle
- Rebuffer ratio ≤0.5%

### Architecture (A)
**Layers**: Manifest parser (HLS/DASH) / ABR engine / Fragment loader / MSE SourceBuffer manager / EME DRM / Captions overlay / Controls UI (React).

### Data model (D)
- **Manifest**: list of renditions × segments with URLs
- **Buffer state**: `{forward: 30s, behind: 0s, totalBytes: <60MB}`
- **ABR state**: `{currentRendition, throughputEwmaFast, throughputEwmaSlow, bufferHealth}`
- **Cue track**: WebVTT cues `{start, end, payload, position}`

### Interface (I)
- HTML5 `<video>` element
- MSE API: `MediaSource`, `SourceBuffer.appendBuffer`, `'updateend'` event
- EME API: `navigator.requestMediaKeySystemAccess` + license server
- Track API: `<track>` for captions

### Optimization (O)
**Shaka Player workflow** (Google): parse DASH/HLS manifest → ABR picks bitrate → FragmentLoader XHRs segment → BufferController appends bytes to MSE SourceBuffer. Default `streaming.bufferingGoal = 10s`, `rebufferingGoal = 2s` before resuming.

**hls.js ABR with dual EWMA**: two EWMA bandwidth estimators with different half-lives — fast EWMA reacts to drops quickly, slow EWMA prevents premature upshifts; uses min of both. Picks highest bitrate whose expected fragment-load-time < current buffer depth - maxStarvationDelay.

**hls.js buffer defaults**: maxBufferLength 30s forward; maxBufferSize 60 MB (bytes-bound takes priority over time-bound); **backBufferLength defaults to Infinity** — memory grows unboundedly on long playback, must override for low-memory devices.

**MSE invariant**: before mutating `SourceBuffer.mode`, `timestampOffset`, `appendWindowStart/End` or calling `appendBuffer/remove`, check `sourceBuffer.updating === false` — concurrent ops throw InvalidStateError. Queue appends behind 'updateend'.

**DRM via EME**: three CDMs (Widevine, FairPlay, PlayReady); multi-DRM license server required to cover all browsers from one origin.

**Picture-in-Picture API**: `HTMLVideoElement.requestPictureInPicture()` Promise; enterpictureinpicture/leavepictureinpicture events; check `document.pictureInPictureEnabled` before invoking. **Document PiP** (Chrome) extends with `documentPictureInPicture.requestWindow()` for arbitrary HTML (used by Google Meet for floating call UI).

**WebVTT captions**: each cue has start/end time, payload, position/line/align/size settings. Track exposed via `HTMLMediaElement.textTracks`; styled via `::cue` pseudo-element.

**Netflix em-unit pattern**: 1 em = 1% of netflix-player container height so every UI overlay (controls, captions, badges) scales proportionally regardless of where player is embedded.

**Netflix React rewrite lesson**: first React playback UI regressed both startup latency AND dropped-frame counts vs prior custom framework — component-tree reconciliation in playback hot path is perf risk; mitigation = one top-level container synchronizing state in single UI update cycle.

**YouTube DASH** (Google): segments 2-10s; recommends 1.1 Mbps for 480p, 2.5 Mbps for 720p, ≥5 Mbps for HD. Watch-page lab LCP cut from ~4.6s → ~1.6s desktop by rendering player HTML before interactivity script.

## Known failure modes
1. **Rebuffer cascade** when ABR over-commits right before bandwidth drop. Production answer: conservative initial estimate + quick step-down; dual EWMA mitigates.
2. **DRM key-rotation mid-playback fails** on some Android Chromiums. Production answer: surface clean error UX; fallback rendition.
3. **Caption drift** on long videos (no monotonic correction). Production answer: periodic re-sync against `video.currentTime`.
4. **Memory leak from never-released SourceBuffers** when user switches videos in an SPA. Production answer: explicit `mediaSource.removeSourceBuffer()` on teardown.
5. **Fullscreen API permission denied silently** on iframes without `allowfullscreen`. Production answer: declare `allowfullscreen` in iframe; surface error to user.

## Notes for the coach
- **Asked-confirmed at YouTube, Netflix, Vimeo, Twitch, Hulu, Disney+.** GreatFrontEnd "Video streaming (Netflix)" canonical.
- **MSE invariant + dual-EWMA ABR are the canonical Staff+ unlocks.** Both demonstrate video-specific operational knowledge that mid-senior candidates miss.
- **The backBufferLength Infinity default is the deep-cut.** Memory leak waiting to happen on long-playback sessions; production must override.
- **Adversarial probe: "user opens 4K video on 4G cellular — what happens in first 5 seconds?"** Strong answer: start at low rendition (360p or 480p) for fast first-frame; measure throughput per segment; dual-EWMA estimates; ramp up to 1080p if buffer health allows; never start at 4K. Weak answer: "ABR figures it out" without articulating the initial-rendition cold-start policy.

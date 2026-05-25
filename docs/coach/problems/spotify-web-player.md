---
slug: spotify-web-player
archetype: frontend
sources:
  spotify_new_web_player: engineering.atspotify.com/2019/3/building-spotifys-new-web-player
  spotify_web_playback_sdk: developer.spotify.com/documentation/web-playback-sdk
  web_audio_intro: web.dev/articles/webaudio-intro
  spotify_q3_2025_6k: Spotify Q3 2025 SEC Form 6-K (Oct 2025)
---

# Spotify web player — audio streaming + EME-protected playback + persistent player across SPA navigation + Web Audio gapless

## Bar anchors
- **Mid-level (L4/E4):** `<audio>` element in current page; re-creates on every nav. No queue persistence.
- **Senior (L5/E5):** Names persistent player + Media Session API. May or may not articulate Web Audio gapless, equal-power crossfade, or EME for DRM-protected audio.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Audio looks simpler than video but deep cuts bite: (a) **persistent player across navigations** — when user clicks Album→Track→Profile, audio cannot blip; lives at App root, communicated via context/portal; (b) **gapless playback** — famously hard; Spotify's web player publicly doesn't support it because Web Audio/`<audio>` transitions introduce ~10ms perceptible gap; **Web Audio API for true gapless** requires sample-accurate (sub-ms) scheduling; (c) **equal-power crossfade**: schedule gain ramps via AudioParam ramps (`linearRampToValueAtTime`, `setValueCurveAtTime`); equal-power curve avoids perceived volume dip of naive linear crossfade; (d) **Media Session API** for OS-level controls (Play/Pause on AirPods, lockscreen art); (e) **EME for protected audio**: replaced Flash with EME in modern browsers per 2019 rewrite; Web Playback SDK requires iframes to declare `allow='encrypted-media; autoplay'` cross-origin.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Audio streaming with adaptive bitrate
- Queue management (current + upcoming + history)
- Persistent player across SPA route navigation
- Crossfade between tracks
- Gapless playback (between album tracks)
- Cross-device queue sync via Spotify Connect

**Non-functional:**
- Per Spotify Q3 2025 SEC Form 6-K (Oct 2025): **713M MAU + 281M Premium Subscribers** as of Sept 30 2025
- Web player 96-320 kbps Ogg Vorbis / AAC
- INP ≤100ms
- Memory player + queue ~50 MB ceiling

### Architecture (A)
**Root-level player**: React context with imperative ref API; audio element mounted at App root outside route subtree (or in portal/iframe).

**Layers**: Audio engine (Web Audio API or HTMLAudioElement) / Queue manager / Spotify Connect sync / Media Session API integration.

### Data model (D)
- **Track**: `{id, src, durationMs, gaplessNext?: TrackId, drmKeyId}`
- **Queue**: `{currentIndex, tracks: TrackRef[], shuffle, repeat}`
- **Player state**: `{playing, currentTimeMs, volume, crossfadeMs}`

### Interface (I)
- Imperative player API: `player.play()`, `player.pause()`, `player.skip(n)`, `player.seek(ms)`
- Spotify Connect WebSocket: queue diffs, transfer-playback events
- Media Session API: navigator.mediaSession.setActionHandler('play', ...)

### Optimization (O)
**Root-level player + React context**: mount audio element in root layout outside route subtree (or in portal/iframe); drive playback from global store (Redux/Zustand); route changes don't unmount media element and tear down buffer.

**2019 architecture rewrite** (Spotify): React + Redux on Web Playback SDK; replaced Flash with EME for protected audio playback in modern browsers; packaged as PWA on Chrome OS.

**Web Playback SDK iframe**: appears in Spotify Connect as new device; requires iframes to declare `allow='encrypted-media; autoplay'` for cross-origin embedding (Widevine + EME-bound playback gated by Premium).

**Gapless playback via Web Audio API**: must be sample-accurate (sub-millisecond precision). Each `AudioBufferSourceNode` is one-shot; preload next track to AudioBuffer; create new SourceNode; `start(currentTime + remainingDuration)` before current ends.

**Equal-power crossfade**: schedule gain ramps via AudioParam (`linearRampToValueAtTime` / `setValueCurveAtTime`) on outgoing/incoming GainNodes. Equal-power curve avoids the perceived volume dip of a naive linear crossfade. Typical crossfade window 25-50ms (gap removal) to 3-12s (DJ-style).

**Cross-device queue sync** via Spotify Connect: client maintains authoritative local queue (reorder, drag-drop) + posts mutations to server; server pushes queue diffs over WebSocket/long-poll to other devices on same account. **Conflict policy LWW per slot with monotonic version counter**.

**Lossless / lossy quality**: stream different bitrates based on subscription tier.

## Known failure modes
1. **Audio cuts on tab discard** (memory pressure). Production answer: listen for `freeze`/`resume` events.
2. **Autoplay-policy blocks first play** because no user gesture. Production answer: gate behind explicit click; UX warns "Tap to start music."
3. **Audio plays muted** because user has tab muted via Chrome tab-mute (no API to detect). Production answer: surface "tab muted" UI hint if user clicks play and no progress.
4. **Queue desync between devices** because client doesn't fetch on focus. Production answer: refetch queue on `visibilitychange` to foreground; monotonic version reconciliation.
5. **Spotify web player historically lacks gapless playback and crossfade** — recurring user complaint reflects EME-gated audio chunking + HTMLAudioElement transitions don't give sample-accurate scheduling the native client gets.

## Notes for the coach
- **Asked-confirmed at Spotify** per engineering blog. Plausibly Apple Music web, YouTube Music, Amazon Music.
- **The persistent-player-across-nav is the canonical Staff+ unlock.** Mid-senior candidates re-mount audio per page; Staff+ candidates mount at root + drive via global store.
- **The Web Audio sample-accurate scheduling for gapless is the depth probe.** HTMLAudioElement transitions introduce ~10ms gap; only Web Audio API can achieve true gapless.
- **Adversarial probe: "user is on Premium and clicks Album → Track → Profile while music plays. What breaks if you don't think about it?"** Strong answer: audio element re-mounts on each route → buffer tears down → audio cuts. Fix: mount audio in root layout outside route subtree; drive via context. Weak answer: "we use a portal" without explaining why route-level mounting is broken.

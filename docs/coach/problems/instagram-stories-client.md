---
slug: instagram-stories-client
archetype: frontend
sources:
  react_insta_stories: github.com/mohitk05/react-insta-stories
  meta_stories_500m: Meta / Statista (Jan 2019; no newer official disclosure)
---

# Instagram stories client — full-screen sequential viewer + preload-N pipeline + gesture model + rAF progress bar

## Bar anchors
- **Mid-level (L4/E4):** Renders fullscreen `<img>` with `setInterval` timer; click changes index. No preload, no gestures.
- **Senior (L5/E5):** Names preload-next + tap-to-skip. May or may not articulate rAF-based progress bar, video-buffer-pauses-progress, or per-story ring buffer.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Articulates the intersection of media-player UX + feed pagination. Names **preload pipeline**: story N playing → story N+1 fully prefetched (image cached, video first segment in `MediaSource` buffer) → N+2 metadata only; on tap-next swap with zero perceived delay. Cites **images preloaded by default; video preloading opt-in** due to bandwidth cost. Names **gesture model**: GestureDetector with tap-region (left=prev, right=next), swipe-down=dismiss, swipe-horizontal=next-user, long-press=pause + freeze video, resume on release. Names **per-story ring buffer** within user's ring; advance to next user automatically on completion. Articulates **video-vs-image branching**: image gets fixed 5s timer via `requestAnimationFrame` (NOT `setInterval` which drifts); video bound to `video.currentTime` so progress = actual playback position; **progress bar must pause during video buffering** (not just on user hold) so partially-buffered stories don't appear to finish early.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Full-screen vertical scroll user-by-user
- Within user, sequential auto-advance story-by-story
- Tap-to-skip, hold-to-pause, swipe-dismiss
- Image stories (5s default) + video stories (length-bound)
- Reactions, replies, polls overlaid on story
- Deep-link to individual story for sharing

**Non-functional:**
- Per Meta (Statista, Jan 2019): **500M Instagram Stories DAU** (no newer official figure published by Meta)
- Per-session ~20 stories
- Image story ~150 KB (1080p AVIF); 5-15s video ~1-4 MB
- Preload-N+1 budget ≤4 MB on cellular
- INP ≤50ms on tap-next
- Modern story-viewer React components ship ~75KB (20KB gzipped)

### Architecture (A)
Viewer container + StoryRing children + Story (image or video) + Overlay layer + GestureDetector.

### Data model (D)
- **Ring**: `{userId, stories[], currentIndex}`
- **Story**: `{id, type: 'image'|'video', src, duration_ms, overlays[]}`
- **Player state**: `{playingIndex, paused, bufferingProgress, lifecycleState}`

### Interface (I)
- Gesture events: `onTapLeft`, `onTapRight`, `onSwipeDown`, `onSwipeLeft`, `onSwipeRight`, `onLongPressStart`, `onLongPressEnd`
- Lifecycle: `onPause` / `onResume` (lifecycle-aware playback for backgrounding)

### Optimization (O)
**rAF progress bar**: frame-locked, not interval-locked, so animation matches refresh rate (60/90/120 Hz); `setInterval` drifts.

**Picture-in-Picture + fullscreen API** for video stories; honor PiP denials.

**Reduced-motion**: for users with OS preference, replace auto-advance with explicit tap.

**Memory cleanup**: `URL.revokeObjectURL` on Blob URLs created for preloaded videos; pause + clear src on unmount.

**Smart progress bar**: pauses during video buffering AND on user hold; lifecycle-aware playback ties pause/resume to onPause/onResume for backgrounding (tab hidden, app switched).

**Analytics**: view-complete (≥80% watched) vs skipped events on each transition.

**Deep-link routing**: URL routing per story for share-deep-linking individual stories.

## Known failure modes
1. **Story timer continues** when phone screen locks. Production answer: pause on `visibilitychange` event.
2. **Audio plays after user backs out** (video element retained). Production answer: `.pause()` + `.src = ''` on unmount; revoke Blob URLs.
3. **Preload N+1 over-fetches** when user rapidly swipes. Production answer: AbortController on swipe-past.
4. **Gesture conflict** with vertical scroll on parent feed. Production answer: explicit gesture priority resolution; `touch-action` CSS to disambiguate.

## Notes for the coach
- **Plausibly-asked at Meta** (Instagram, Facebook), Snap (user's prior shop). Reference impls: react-insta-stories, react-instagram-stories.
- **The rAF-vs-setInterval distinction is the canonical Staff+ unlock for the progress bar.** setInterval drifts; rAF locks to display refresh rate.
- **The video-buffer-pauses-progress is the depth probe.** Without it, partially-buffered stories appear to finish early because the timer doesn't know the video stalled.
- **Adversarial probe: "user holds finger to pause a video story for 30 seconds — what happens to memory?"** Strong answer: video stays loaded but paused; preloaded N+1 stays loaded; if N+2 was started, abort; on release, resume video + progress; memory bounded by current + N±1 retention policy. Weak answer: "we pause" without addressing memory cleanup of preloaded videos.

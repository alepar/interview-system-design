---
slug: snap-map
archetype: geo-proximity
sources:
  snap_newsroom_400m: newsroom.snap.com/2025-snap-map-mau
  mapbox_snap: blog.mapbox.com/mapbox-helps-power-snap-map-4ced4fb3176a
  streetcred: labusinessjournal.com/news/2021/apr/27/snap-acquires-3d-map-developer-8-million/
  snap_help_lazy: help.snapchat.com/hc/en-us/articles/7012280385684-How-long-does-my-location-stay-on-Snap-Map
  snap_ghost_mode: help.snapchat.com/hc/en-us/articles/7012322854932-How-do-I-turn-on-Ghost-Mode
  snap_live_location: airdroid.com/parent-control/what-does-live-mean-on-snapchat/
  imobie_lowpower: imobie.com/location-change/fix-snapchat-location-not-updating.htm
  promoted_places: campaignme.com/snap-launches-promoted-places-transforming-the-snap-map-into-real-world-discovery/
---

# Snap Map — 400M MAU (May 2025) on Mapbox tile infrastructure (Outdoors vector + Satellite raster + Geocoding) + Docker on AWS with multi-layer cache autoscaling + custom OpenGL/GL shaders on Mapbox-GL for heatmap (without inflating app size or battery) + lazy/on-demand updates (location updates ONLY when app opened in foreground; last position visible up to 8hr) + Live Location separate opt-in continuous 15min/1hr/8hr + Ghost Mode default-on privacy (location STILL uploaded to Snap but suppressed from friend visibility; timer 3hr/24hr/until-disabled) + heatmap aggregation over public Our Story Snap submissions (pre-aggregated server-side, not computed per-viewer) + StreetCred ($8M, 2021) acquisition + Promoted Places monetization

## Bar anchors
- **Mid-level (L4/E4):** Designs continuous-ping friend location; no privacy modes; no heatmap.
- **Senior (L5/E5):** Names Mapbox + Ghost Mode. May or may not articulate lazy-update model as deliberate UX decision, Ghost Mode uploaded-but-hidden distinction, heatmap pre-aggregation, or iOS low-power throttling.
- **Staff+ (L6/E6+):** Names (a) **400M MAU (May 2025)** — ~44% of Snapchat ~900M total / >84% of ~474M DAU; (b) **Mapbox tile infrastructure** (Outdoors vector + Satellite raster + Geocoding); Docker on AWS with multi-layer cache autoscaling; (c) **Custom OpenGL/GL shaders** on Mapbox-GL for heatmap rendering without inflating app size or battery; (d) **Lazy/on-demand updates**: location updates ONLY when app opened in foreground; last position visible up to 8hr before vanishing; (e) **Live Location** separate opt-in continuous-sharing 15min/1hr/8hr per friend; green ring indicator; (f) **Ghost Mode** default-on privacy primitive: location STILL uploaded to Snap but suppressed from friend visibility; timer presets 3hr/24hr/until-disabled — **uploaded-but-hidden, NOT not-uploaded**; (g) **Heatmap aggregation** over public Our Story Snap submissions; geocoded server-side; hotspot color (blue → orange → red) maps to Snap-density buckets PRE-AGGREGATED rather than computed per-viewer; (h) **StreetCred** ($8M, 2021) acquisition for 3D city models + Places listings supplementing Mapbox; (i) **iOS low-power mode** forcibly throttles Snap background refresh, "completely freezes Live Location avatar" — looks like bug but OS-enforced; (j) **Promoted Places** monetization: sponsored business pins ranked by viewer proximity + friend-pin proximity — ad-tile insertion into Mapbox tile stack.

## Canonical decomposition

### Requirements
**Functional:**
- View friend locations on map (lazy default)
- Live Location continuous sharing (opt-in)
- Ghost Mode (default-on privacy)
- Heatmap of public Snap density
- Place + Promoted Places overlay

**Non-functional:**
- 400M MAU (May 2025)
- Lazy default: 8hr stale visibility max
- Live Location 15min/1hr/8hr
- Mapbox tiles via Docker on AWS

### Core entities
- **FriendLocation:** {friend_user_id, lat/lon, last_updated} (lazy default)
- **LiveLocationShare:** {sender, recipient, ttl ∈ {15min, 1hr, 8hr}, started_at}
- **GhostModeState:** {user_id, timer ∈ {3hr, 24hr, indefinite}}
- **HeatmapBucket:** (s2_cell, time_window) → Snap density

### API
- Internal: `POST /location_update` (only on app foreground)
- Internal: `POST /live_location/start` body={recipient, ttl}
- Internal: `POST /ghost_mode/enable` body={timer}
- Internal: `GET /heatmap?bbox=` (returns pre-aggregated tiles)

### HLD
Location ingest: client posts location only when app foregrounded (lazy default) — eliminates continuous-ping battery cost. Server records {user_id, lat/lon, ts}; per-friend visibility window 8hr; after that, location vanishes from map.

Live Location: separate opt-in. Sender client posts continuous updates while Live Location active (TTL 15min/1hr/8hr); recipient sees green ring + moving avatar.

Ghost Mode: location STILL uploaded by client; server suppresses from friend visibility (privacy gate at read time, not write time). Timer 3hr/24hr/until-disabled.

Map rendering: Mapbox Outdoors vector + Satellite raster + Geocoding reverse-geocode. Docker on AWS with multi-layer cache autoscaling for traffic spikes. Custom OpenGL/GL shaders on Mapbox-GL for heatmap rendering.

Heatmap: server-side aggregation of public Our Story submissions; geocode at submission time; aggregate per (S2 cell, time-window) bucket; client requests pre-aggregated tiles. NOT computed per-viewer.

Promoted Places: ad-tile insertion into Mapbox tile stack; pins ranked by viewer proximity + friend-pin proximity.

### Deep dives
1. **Mapbox tile infrastructure + custom GL shaders.** Mapbox Outdoors vector + Satellite raster + Geocoding. Docker on AWS with multi-layer cache autoscaling. Custom OpenGL/GL shaders on Mapbox-GL for heatmap — keeps app size + battery bounded. StreetCred acquisition for 3D models.
2. **Lazy-update + Live Location + Ghost Mode.** Lazy default: location only when app foregrounded; 8hr visibility. Live Location separate opt-in 15min/1hr/8hr with green ring. Ghost Mode default-on: location uploaded to Snap but suppressed from friends; 3hr/24hr/until-disabled. **Ghost Mode is uploaded-but-hidden, not not-uploaded** — important privacy distinction.
3. **Heatmap aggregation + Promoted Places monetization.** Heatmap aggregation over public Our Story; geocoded server-side; pre-aggregated density buckets. Promoted Places: sponsored business pins ranked by viewer proximity + friend-pin proximity; ad-tile insertion into Mapbox tile stack.

## Known failure modes
1. *iOS low-power mode throttles background refresh* + "freezes Live Location avatar". Production answer: surface in UI ("Snap Map updates paused — low power mode"); update on foreground reactivation.
2. *Ghost Mode "uploaded but hidden"* surprise — users assume Ghost = not uploaded. Production answer: explicit privacy disclosure in onboarding.
3. *Promoted Places visual clutter* in dense urban areas. Production answer: cap concurrent visible pins per tile; A/B revenue-vs-engagement.

## Notes for the coach
- **Plausibly-asked at Snap.** Mapbox engineering post + Snap newsroom + StreetCred press are public. Snap Engineering blog limited on Snap Map internals.
- **Cross-coverage** with `find-my-friends` + `life360` (this archetype; competing location-sharing models). With frontend (Mapbox-GL rendering).
- **User has Snapchat-side intuition** — surface as adjacent reference; don't drill.
- **The lazy-update model as deliberate product+architecture choice (NOT a battery limit) is the canonical Staff+ unlock.** Mid-senior candidates assume continuous ping; Staff+ candidates recognize lazy = explicit UX-priority + cost trade.
- **Adversarial probe: "Make Snap Map real-time."** Strong answer: 400M MAU × continuous-ping = orders-of-magnitude more location writes (analogous to Life360's "stalkerware" backlash); battery cost on user devices; bandwidth cost. Counter-proposal: SSE push only to currently-foreground users + lazy 8hr for everyone else (current model). For Live Location specifically, opt-in continuous is acceptable because user explicitly enabled. The lazy default is a deliberate choice, not a tech limitation. Weak answer: "scale WebSockets" without the explicit cost framing.

---
slug: spotify-discover
archetype: ml-in-loop
sources:
  spotify_q3_2025_6k: Spotify Q3 2025 Form 6-K SEC filing (713M MAU, 281M Premium as of Sept 30, 2025)
  annoy_repo: github.com/spotify/annoy
  voyager_blog: engineering.atspotify.com/2023/10/introducing-voyager-spotifys-new-nearest-neighbor-search-library
  bart_calibration_2025: research.atspotify.com/2025/9/calibrated-recommendations-with-contextual-bandits-on-spotify-homepage
  van_den_oord_2013: NIPS 2013 "Deep content-based music recommendation" (Spotify audio CNN lineage)
---

# Spotify Discover Weekly — multi-model blend + Annoy/Voyager ANN + BaRT contextual bandits

## Bar anchors
- **Mid-level (L4/E4):** "Collaborative filtering over user-track matrix." No cold-start path; no audio features; no playlist coherence.
- **Senior (L5/E5):** Names CF + content features + ANN serving. Discusses cold-start. May or may not address audio-CNN embeddings, playlist-level coherence, contextual bandits.
- **Staff+ (L6/E6+):** Drives proactively. Articulates three architectural differences from video reco: (1) **re-consumption is normal** — users re-listen tracks; novelty + familiarity are competing objectives, not diversity tax; (2) **bimodal cold-start** — new tracks have no behavioral signal but rich content (audio + lyrics + metadata) so audio-CNN pathway and CF pathway must be unified; (3) artifact is a **playlist** (batch-generated 30 tracks updating weekly), not a feed — session-level features stale by construction; trades real-time freshness for offline optimization of playlist coherence. Names **Annoy** (Spotify open-source) random-projection-tree index with disk-mmap so multiple processes share index without RAM duplication. Names **Voyager** (Oct 2023) HNSW successor preserving disk-mmap property. Cites **BaRT** contextual bandits on homepage; March 2025 calibration A/B: +36.6% podcast impression→stream rate, +3.93% overall impression→stream. Stretch (Sr Staff bar): distinguishes playlist-level objectives (transition smoothness, energy arc) from per-track click prediction.

## Canonical decomposition

### Requirements
**Functional:**
- Weekly Discover Weekly playlist of 30 tracks per user
- Daily Mix per genre/mood (multi-playlist for contextual variety)
- Cold-start coverage for new tracks (audio-CNN pathway)
- Playlist-level coherence optimization (transition smoothness, energy arc)
- Contextual-bandit homepage ranking with explicit exploration

**Non-functional (with numbers):**
- 713M MAU, 281M Premium Subscribers as of Sept 30, 2025 [Spotify Q3 2025 Form 6-K]
- Discover Weekly: 30-track playlist × MAU × week → ~20B+ playlist slots/week
- Track catalog 100M+ tracks
- 700M+ user-curated playlists as CF training ground truth
- Audio CNN embeddings via spectrograms (Spotify-pioneered lineage)
- BaRT March 2025: +36.6% podcast impression→stream rate

### Core entities
- **User vector:** CF embedding from co-listening on 700M+ playlists
- **Track vector:** CF embedding + audio CNN embedding (mel-spectrogram → CNN) + NLP embedding (lyrics + descriptions)
- **Playlist:** ordered 30 tracks with coherence score
- **ANN index:** Annoy (random-projection trees, disk-mmap) → Voyager (HNSW, disk-mmap)
- **BaRT context:** (item, explanation, surface, user_context)

### API
- `GET /discover_weekly/{user_id}` → 30-track playlist (refreshed weekly)
- `GET /daily_mix/{user_id}/{mood}` → contextual playlist
- `GET /home_recommendations/{user_id}/{surface}` → ranked shelves via BaRT
- Internal: ann.search(user_emb, k) → candidates; coherence_optimizer.order(candidates) → playlist

### HLD
**Hybrid recommendation**: three pathways. **CF pathway** = matrix factorization on user × track co-listening from 700M+ playlists. **NLP pathway** = legacy Echo Nest web crawls + modern lyrics/descriptions text embeddings. **Audio CNN pathway** = mel-spectrogram → CNN → 50-d audio embedding (Spotify-pioneered post van den Oord 2013). All three produce track embeddings in shared geometry. **Weekly batch pipeline** (Spark/Beam): per-user candidate gen from CF neighborhood + content similarity + radio extensions; per-user **playlist coherence optimization** (smoothness loss over track sequence); A/B-driven blending weights. **ANN serving** for similar-track / similar-playlist lookups: Annoy (disk-mmap'd random-projection-trees; multiple processes share one on-disk index without RAM duplication; `search_k` runtime accuracy/latency knob) → migrating to Voyager (HNSW with same disk-mmap property). **Homepage ranking via BaRT**: contextual bandit scoring (item, explanation, surface, user_context) triples; epsilon-greedy explores alternatives 5-10% of time.

### Deep dives
1. **Hybrid CF + content recommendation with cold-start unlock.** **CF**: strong for popular content with rich listener data; suffers cold-start. **NLP**: bridges new artists with existing listener affinities. **Audio CNN**: **the cold-start escape** — brand-new track without listener data still gets an embedding from its audio. At ranking time, scores blended (weighted sum or stacked meta-model). Per Spotify content-based analysis: "Unlike collaborative filtering, audio analysis doesn't depend on a song being popular. So it helps solve the cold start problem."

2. **Annoy + Voyager ANN serving (disk-mmap).** Unusual design choice: build random-projection-tree index, save to disk, mmap on read. Multiple processes (one per CPU core) share same on-disk index without RAM duplication; OS page cache handles hot pages. Makes single-host serving efficient even when index size > RAM. `search_k` parameter: more checked nodes = more accurate but slower (runtime knob). **Voyager (Oct 2023)**: HNSW-based replacement; better accuracy/speed at same disk-mmap property. Trade vs FAISS/ScaNN: Annoy/Voyager simpler to operate but less accurate per byte; for Spotify's catalog the operational simplicity outweighed the recall delta.

3. **BaRT contextual bandits for homepage.** Spotify's homepage isn't a list — it's 2D grid of shelves (rows) with items + explanations ("Made for you", "Because you liked X"). BaRT scores each (item, explanation, shelf-context) triple; epsilon-greedy explores alternatives 5-10% of time. **March 2025 calibration A/B**: +36.6% podcast impression→stream rate, +3.93% overall impression→stream, +1.28% consumption, +1.54% activity. Trade: bandit handles explore/exploit explicitly; A/B tests measure incremental lift over bandit baseline.

## Known failure modes
1. **Popularity bias in CF.** CF pushes every Discover Weekly toward same top tracks. Production answer: IPS or popularity-debiased training; explicit content-channel quota; freshness target (fraction of tracks user hasn't heard).

2. **Annoy/Voyager index drift.** Embedding model retrained but ANN index not rebuilt synchronously → embeddings live in different geometries. Production answer: atomic dual-version pinning of model + index; canary on index rebuild before flip.

3. **Playlist-level coherence regression.** Per-track CTR improves but listeners skip more because playlist arc destroyed. Production answer: playlist-level metric (avg dwell, completion rate) alongside per-track CTR; A/B on full playlist not single tracks.

## Notes for the coach
- **Plausibly-asked at Spotify, Apple Music, YouTube Music, Amazon Music.** Spotify Engineering blog + Spotify Research papers are explicit interview-prep canon.
- **The three-pathway hybrid with audio-CNN cold-start is the Staff+ unlock.** Candidates who default to "matrix factorization" miss the cold-start architecture entirely.
- **The Annoy disk-mmap design is the deep-cut.** Most candidates assume FAISS-class in-memory ANN; Annoy's mmap choice is Spotify-specific and operationally distinctive.
- **Adversarial probe: "I want Discover Weekly to update intraday, not weekly — what breaks?"** Strong answer: weekly cadence is UX ritual (subscribers expect Monday morning); intraday would conflict; if you go intraday, Daily Mix already serves that purpose with shorter-horizon context. Weak answer: "we just retrain hourly" without addressing the product surface.

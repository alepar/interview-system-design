---
slug: discord-voice
archetype: interactive-messaging
sources:
  discord_2_5m_voice: discord.com/blog/how-discord-handles-two-and-half-million-concurrent-voice-users-using-webrtc
  discord_dave: discord.com/blog/meet-dave-our-new-end-to-end-encryption-for-audio-video
  discord_dave_enforcement: Discord support page on DAVE enforcement (March 2026)
  webrtc_rfc8825: datatracker.ietf.org/doc/rfc8825
---

# Discord voice — WebRTC SFU + DAVE E2E for 2.5M concurrent users

## Bar anchors
- **Mid-level (L4/E4):** Treats voice as P2P WebRTC mesh. Doesn't address SFU vs MCU vs mesh trade-off. No region routing.
- **Senior (L5/E5):** Names SFU pattern, per-region servers, simulcast. Discusses NAT traversal via STUN/TURN. May or may not address why Discord skips ICE/SDP, per-user volume control as a defining UX constraint, or DAVE E2E rollout.
- **Staff+ (L6/E6+):** Drives proactively. Articulates why Discord **doesn't use ICE** (every client connects to a media relay, no peer discovery) and **doesn't use SDP per-call** (fixed ~1KB control payload replaces ~10KB SDP). Defends SFU choice with per-user volume control as the UX constraint that kills MCU. Names **client-side VAD** so silent participants don't send Opus frames (25-person channel ≈ 2 active speakers). Articulates **region selection** (Elixir signal-plane picks least-utilized voice server in user's region at join; reconnect to fresh server on failure with no state migration because voice is ephemeral). Names **DAVE protocol** — MLS-based group key for the call, server forwards opaque ciphertext frames, key rotation on join/leave; tension with SFU's traditional layer-drop ability (still possible — layer metadata in unencrypted RTP header extensions). Cites **DAVE enforcement: March 1-2, 2026** — clients without DAVE support cannot participate. Stretch (Sr Staff bar): articulates the 10K-listener Stage Channel asymmetric SFU pattern (a few streams in + 10K streams out per SFU node).

## Canonical decomposition

### Requirements
**Functional:**
- Join voice channel (up to ~25 active participants typical; Stage Channels up to 10K listeners)
- Sub-200ms one-way audio latency
- Per-user volume control (defining UX feature)
- E2E encryption via DAVE protocol (MLS-based)
- Work behind enterprise NAT/firewalls
- Survive client-side packet loss up to 20-30%

**Non-functional (with numbers):**
- 2.5M+ concurrent voice users globally
- Per-channel: 25 audio/video participants typical; 10K listeners for Stage Channels
- Codec: Opus 20-30 kbps voice
- Control payload at join: ~1KB (vs ~10KB SDP)
- DAVE enforcement: March 1-2, 2026 (Discord engineering blog + support page)

### Core entities
- **VoiceChannel:** channel_id, voice_region, active_members[], permissions, dave_epoch
- **MediaRelay:** SFU instance; assigned to a voice region; forwards RTP between participants
- **SignalPlane:** Elixir-based; picks least-utilized media relay; manages join/leave
- **DAVEGroup:** MLS group with members = current voice-channel participants; epoch rotates on join/leave
- **SimulcastStream:** per-sender: 2-3 quality layers; SFU picks per-receiver based on RTCP feedback

### API
- WebSocket signaling: `WSS /voice` — join_channel, leave_channel, mute, deafen, screen-share
- Media plane: client opens UDP socket to assigned media relay; RTP/SRTP with DAVE-encrypted payload
- Internal: `signal.select_relay(user_region, channel_id)` → least-utilized media relay endpoint
- DAVE: clients exchange MLS Welcome/Commit via signaling channel; server cannot decrypt

### HLD
**Signaling plane** (Elixir) terminates client WebSockets; on `join_channel`, picks the least-utilized media relay in the user's voice region (defaulting to user's closest region, overridden by channel's voice_region setting for moderation reasons). **Media relay (SFU)** receives RTP streams from each client (one UDP socket per client per channel); forwards each stream to all other participants in the channel. **Skip-ICE design**: client knows the relay's public IP+port; opens UDP directly; if NAT/firewall blocks UDP, falls back to TCP-over-443 or HTTP CONNECT. **Client-side VAD**: client doesn't send Opus frames while silent (saves bw + SFU forwarding work); SFU forwards a "talking" indicator separately for UI. **Simulcast**: sender encodes 2-3 quality layers (e.g., 32 kbps + 64 kbps); SFU drops layers per receiver based on RTCP feedback. **DAVE E2E**: client opens MLS group with current channel members; encrypts each Opus frame under the MLS group key; SFU forwards ciphertext blindly. Key rotation on join/leave via MLS Commit. **Stage Channels (10K listeners)**: same SFU code path with role gating (speakers publish, listeners only receive); asymmetric load (few streams in, many out per SFU node).

### Deep dives
1. **SFU vs MCU vs Mesh — why SFU wins for Discord.** **Mesh** (every client sends to every other client): O(N) upstream per peer; breaks past 4-5 participants (uplink saturates). **MCU** (server mixes audio): one downlink per client (cheap); but centralizes mixing (high server CPU); **kills per-user volume control** because the mix is decided server-side. **SFU** (forwards individual streams): N downlinks per client (more bw than MCU); but preserves per-stream control client-side — user can adjust volume per participant. Discord's choice: SFU, because per-user volume control is a defining UX feature ("I want to hear my friend, mute the loud streamer"). Trade: more downlink bw vs MCU; mitigated by simulcast layer-drop and client-side VAD.

2. **Skip-ICE design + NAT traversal.** Standard WebRTC uses ICE for peer discovery (gather host/srflx/relay candidates; pair; connectivity checks). Discord skips ICE entirely: server publishes a single public IP+port for the media relay; client connects directly. Reduces join latency (no candidate-gathering RTT); hides client IPs from peers (anti-DDoS — critical for streamers); simpler protocol. NAT traversal: server's public IP is reachable from any client behind any NAT (since server is on public internet); for UDP-blocked enterprise networks, **TCP fallback over TLS 443** or **HTTP CONNECT** through proxies. Trade vs P2P-ICE: server pays bw cost (no direct P2P even when possible); but P2P wasn't viable anyway with N>4.

3. **DAVE protocol — MLS-based group E2E for voice.** Pre-DAVE: server could decrypt audio (subject to subpoena). Post-DAVE: client encrypts each Opus frame under an MLS group key; SFU forwards opaque ciphertext frames. **MLS group** = the current channel participants (managed via MLS Welcome/Commit messages exchanged through signaling); rotates epoch on every join/leave (post-compromise security: a kicked user cannot decrypt subsequent audio). **Tension with SFU layer-drop**: traditionally, SFU drops simulcast layers based on RTCP feedback — but if the payload is encrypted, SFU can't peek. Resolution: layer metadata (which-layer-this-packet-is) carried in **unencrypted RTP header extensions**; SFU drops based on header without decrypting payload. **Enforcement**: per Discord's support page, *"Starting March 1st 2026, clients and apps without DAVE support will no longer be able to participate in Discord calls."* Enforcement landed March 2, 2026.

## Known failure modes
1. **NAT/firewall blocking UDP.** Enterprise network blocks UDP entirely; client cannot reach media relay. Production answer: TCP fallback over TLS 443; HTTP CONNECT through proxies; auto-detect and switch on connection failure.

2. **Region capacity exhaustion during outage.** One voice region's media-relay fleet saturated. Production answer: client reconnect to nearest healthy region; voice_region channel setting can override user latency for moderation reasons (e.g., a US-based moderator joining an EU channel). On reconnect, no state migration needed (voice is ephemeral; lost frames just drop).

3. **Single noisy participant clipping others** (loud background, microphone too hot). Production answer: per-stream RTCP receiver reports + adaptive bitrate; server-side **audio-level RTP extension** lets the receiver prioritize streams by audio level; client-side noise suppression (Krisp-class) + auto-gain control.

## Notes for the coach
- **Asked-confirmed at Discord** (voice infra team hires for this profile; engineering blogs are primary). **Plausibly-asked** at Zoom, Meet, Snap (for RTC roles).
- **Highest deep-cut signal alongside `discord-presence`** given the user's Snapchat background does not include WebRTC SFU routing or DAVE-class E2E.
- **The skip-ICE design is the canonical Staff+ trick that distinguishes Discord-voice from generic-WebRTC answers.** Candidates who default to "we use ICE/STUN/TURN" miss the Discord-specific design.
- **Adversarial probe: "DAVE encrypts the payload — how can the SFU still drop simulcast layers for slow receivers?"** Strong answer: layer metadata in unencrypted RTP header extensions; SFU drops by header without peeking at payload. Weak answer: "we trust the SFU" — but then it's not E2E.

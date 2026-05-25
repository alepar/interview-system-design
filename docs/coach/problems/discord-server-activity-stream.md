---
slug: discord-server-activity-stream
archetype: fan-out
sources:
  discord_5m: discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users
  discord_midjourney: discord.com/blog/maxjourney-pushing-discords-limits-with-a-million-plus-online-users-in-a-single-server
  discord_gateway_events: docs.discord.com/developers/events/gateway-events
  discord_gateway: discord.com/developers/docs/events/gateway
  discord_voice: discord.com/blog/how-discord-handles-two-and-half-million-concurrent-voice-users-using-webrtc
---

# Discord server (guild) activity stream — single Elixir GenServer per guild fans out every event to per-user session processes + quadratic scaling (1K online = 1M notifs/sec, 10K online = 100M notifs/sec) + relay processes for guilds >15K sessions (Midjourney 1M+ concurrent in single guild) + Manifold "send-many" amortizes 30-70µs Erlang send/2 by grouping PIDs by remote node + Gateway Intents bitwise-OR flags (GUILDS bundles GUILD_CREATE/UPDATE/CHANNEL_*/THREAD_*) + bot sharding at 2,500 guilds with shard_id = (guild_id >> 22) % num_shards + PRESENCE_UPDATE highest-frequency event (broadcasts to all guilds user is member of, often 20-100) + large_threshold=250 lazy-loads member lists + Rust+Tokio gateway migration + 2.6M concurrent voice users across 850+ servers in 13 regions

## Bar anchors
- **Mid-level (L4/E4):** Treats as N-to-N pub/sub; doesn't address mega-guild quadratic problem.
- **Senior (L5/E5):** Names guild-process + WebSocket gateway. May or may not articulate relays, Manifold, Intents, sharding formula, or PRESENCE_UPDATE dominance.
- **Staff+ (L6/E6+):** Names (a) **single Elixir GenServer per guild** as central routing point; every online user has separate session process; guild process fans out to relevant session processes which push over WebSocket; (b) **quadratic scaling**: 1K online = 1M notifs/sec; 10K = 100M — forced introduction of relays; (c) **relay processes** between guild process and user sessions; each handles fanout + permission checks for **up to 15K sessions**; one guild scales across many BEAM processes; (d) **Midjourney guild**: 10M+ total members, 1M+ concurrent online in single guild via relay; ~90% sessions passive (cuts effective fan-out); (e) **Manifold "send-many"** amortizes Erlang's expensive send/2 (30-70µs due to BEAM descheduling) by grouping PIDs by remote node + dispatching ONE cross-node message per node; consistent hashing via `:erlang.phash2/2`; (f) **lazy member-list loading** when guild size > `large_threshold=250` — only online + roled + nicknamed + in-voice pushed on connect; rest chunk-requested by client; (g) **Gateway Intents** bitwise OR'd flags: GUILDS (1<<0) bundles GUILD_CREATE/UPDATE/CHANNEL_*/THREAD_*; disabling unneeded intents significantly increases performance; (h) **bot sharding at 2,500 guilds** with `shard_id = (guild_id >> 22) % num_shards`; bots in 150K+ guilds get large-bot sharding; (i) **PRESENCE_UPDATE highest-frequency** — single user status change broadcasts to every guild they're in (often 20-100); guilds >75K members or bots without GUILD_PRESENCES intent only get presence for bot + voice-channel users; (j) **gateway migration to Rust+Tokio** with sharded ownership of guilds; combined with SFU voice cluster (2.6M concurrent voice users across 850+ servers in 13 regions).

## Canonical decomposition

### Requirements
**Functional:**
- WebSocket gateway per session
- Per-guild event broadcast (MESSAGE_CREATE, PRESENCE_UPDATE, GUILD_*)
- Bot Gateway Intents subscription
- Member-list loading with lazy chunking
- Voice connection signaling (separate SFU plane)

**Non-functional:**
- 5M+ concurrent users; Midjourney 1M+ concurrent in single guild; 2.6M voice users
- 15K sessions/relay capacity
- Manifold amortizes 30-70µs send/2
- bot sharding at 2,500 guilds

### Core entities
- **GuildProcess:** Elixir GenServer per guild
- **SessionProcess:** per-(user, connection) BEAM process holding WebSocket
- **RelayProcess:** intermediate fan-out tier between GuildProcess and Sessions
- **GatewayIntents:** bitfield subscription flags
- **PresenceState:** per-(user, guild) status

### API
- WebSocket: `GATEWAY OP 2 IDENTIFY` with intents
- WebSocket: `GUILD_CREATE`, `MESSAGE_CREATE`, `PRESENCE_UPDATE` event frames
- HTTP: REST API for read/CRUD

### HLD
Connection: client → gateway server (Rust+Tokio per migration) → spawns SessionProcess (BEAM) holding WebSocket. Session subscribes to GuildProcesses for member's guilds (with intents filter).

Guild process: holds membership + permission state. On event (message, presence change, channel update): fans out to relevant sessions. Above 15K sessions, fan-out goes through RelayProcesses (15K sessions/relay) — one guild spans many BEAM processes.

Manifold dispatch: for cross-node fan-out, groups PIDs by remote node via consistent-hash; sends ONE cross-node message per node carrying recipient list; remote receives + dispatches locally — amortizes 30-70µs send/2.

Intents: Sessions specify bitfield at IDENTIFY; GuildProcess filters events accordingly. GUILDS = bundle of GUILD_*+CHANNEL_*+THREAD_*; GUILD_PRESENCES separate (heavy).

Lazy members: large_threshold=250; above, only online/roled/nicknamed/in-voice pushed on connect; rest via REQUEST_GUILD_MEMBERS chunks.

Bot sharding: `shard_id = (guild_id >> 22) % num_shards`; at 2,500 guilds, large bots split across shards.

### Deep dives
1. **Guild-process + relay (celebrity-equivalent for mega-guilds).** Single Elixir GenServer per guild = central routing. Quadratic: 1K online = 1M notifs/sec. Relay processes between guild and sessions; 15K sessions/relay; one guild across many BEAM processes. Midjourney 1M+ concurrent in single guild. ~90% passive cuts effective fan-out.
2. **Manifold + Gateway Intents + bot sharding.** Manifold groups PIDs by remote node, dispatches ONE cross-node message per node. Amortizes 30-70µs send/2. Gateway Intents bitwise OR'd flags reduce per-bot fan-out. Bot sharding at 2,500 guilds: `(guild_id >> 22) % num_shards`; 150K+ guilds get large-bot sharding.
3. **Lazy members + PRESENCE_UPDATE dominance + Rust gateway.** large_threshold=250 lazy-loads members. PRESENCE_UPDATE broadcasts to every guild user is in (20-100 typically) — dominates fan-out budget. Guilds >75K members suppress presence except bot + voice. Rust+Tokio gateway with sharded guild ownership; SFU voice cluster as separate plane.

## Known failure modes
1. *Quadratic fan-out collapse at mega-guild* — 10K online = 100M notifs/sec. Production answer: relay architecture (15K sessions/relay).
2. *Manifold cross-node overhead* — Erlang send/2 30-70µs amortized but still expensive. Production answer: relay batches local-node sends; cross-node minimized.
3. *PRESENCE_UPDATE storm* on user status change. Production answer: per-guild presence suppression for >75K guilds (only bot + voice).

## Notes for the coach
- **Asked-confirmed at Discord.** Engineering blogs (Maxjourney, 5M concurrent, Gateway docs) are canon.
- **Cross-coverage** with messaging `discord-presence` (in archetype #3; same Manifold + GenStage primitives). With messaging `discord-voice` (SFU substrate). With messaging `slack` (channel-scoped alternative).
- **The relay-process tier (15K sessions/relay) is the canonical Staff+ unlock for mega-guild fan-out.** Mid-senior candidates name single guild process; Staff+ candidates name the relay tier that bypasses the quadratic limit.
- **Adversarial probe: "Midjourney guild hits 5M concurrent (5× current). What breaks first?"** Strong answer: relay capacity at 15K sessions/relay → 333 relays per guild; Manifold cross-node messaging dominates (3 cross-node sends per event per pair of relay-hosting BEAM nodes); PRESENCE_UPDATE storm becomes intractable; need to suppress presence + lazy-load member chunks aggressively; SFU voice plane separately scales; gateway connection saturation pre-relay. Production answer: per-guild presence suppression hard cap; Intent-based pruning of CHANNEL_* events for spectator-class users; relay sharding by channel within guild. Weak answer: "add more relays" without naming the 15K cap or Manifold cost.

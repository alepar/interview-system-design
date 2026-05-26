---
slug: discord-presence
archetype: interactive-messaging
sources:
  discord_5m_elixir: discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users
  discord_rust_sorted_set: discord.com/blog/using-rust-to-scale-elixir-for-11-million-concurrent-users
  discord_genstage_push: discord.com/blog/how-discord-handles-push-request-bursts-of-over-a-million-per-minute-with-elixirs-genstage
  elixir_lang_discord: elixir-lang.org/blog/2020/10/08/real-time-communication-at-scale-with-elixir-at-discord
  discord_manifold: github.com/discord/manifold
---

# Discord presence — guild presence + member-list fan-out at 200K+ active members

## Bar anchors
- **Mid-level (L4/E4):** Treats presence as a pub-sub broadcast. Doesn't address mailbox-blowup or the 200K-active-member viewport. Doesn't size the fan-out cost of a single rename.
- **Senior (L5/E5):** Names per-guild process, WebSocket gateway sharding, pub-sub bus. Discusses presence soft-state. May or may not surface the Erlang `send/2` cost or the need for a custom data structure for the member list.
- **Staff+ (L6/E6+):** Drives proactively. Cites the canonical naive-fanout-broken data point: *"the time of a single send/2 call could vary from 30μs to 70μs due to de-scheduling of the calling Erlang process. This meant that during peak hours, publishing an event from a large guild could take from 900ms to 2.1s!"* Invents or rediscovers **Manifold** (batch send by remote-node — group PIDs by their remote node, send once to a Manifold.Partitioner per node), **FastGlobal** (zero-copy global read for frequently-read static config), **Semaphore** via ETS atomics for load shedding, and Rust-via-Rustler **SortedSet NIF** for member-list mutation (naive List @250K = ~170,000μs/op → SortedSet 0.61-3.68μs across 5K-1M items). Names the **range-subscription trick**: clients subscribe to a viewport range of the member list (visible scroll window), not the full 600K members — what makes mega-guilds tractable. Stretch (Sr Staff bar): articulates GenStage demand-driven backpressure for the >1M push/min surge path.

## Canonical decomposition

### Requirements
**Functional:**
- Broadcast presence (online/away/dnd) + activity (game rich-presence) to every connected client in a guild
- Member-list mutations (join/leave/role/rename) propagate to viewers <1s
- Support 600K-member guilds with 200K active concurrent users
- Member-list scroll viewport on client (clients view a window, not all members)

**Non-functional (with numbers):**
- 12M+ concurrent WebSocket users globally
- 26M+ WebSocket events/sec to clients
- 400-500 Elixir chat machines; 5-engineer infra team
- Largest guilds: 600K members, 200K active
- Member-list mutation: <5ms at 1M-element SortedSet (Rust NIF)
- Push burst capacity: >1M push/min (GenStage)

### Core entities
- **GuildSession:** Erlang process per guild; aggregates member sessions; holds SortedSet of members
- **MemberSession:** WebSocket-attached client; holds viewport range subscription
- **PresenceState:** per-member soft-state (status, activity); replicated across regions, LWW
- **ManifoldBatch:** outbound event grouped by destination Erlang node; one cross-node send per node per batch
- **Semaphore:** ETS-atomic counter capping inflight events per process

### API
- WebSocket: `WSS /gateway` — clients connect, subscribe to guilds, subscribe to member-list viewport ranges
- Internal: `cluster.send_many(events, pids)` — Manifold-style batched send; groups by remote node
- Internal: `GuildSession.update_member(member_id, op)` — mutates SortedSet via Rust NIF; broadcasts delta to subscribers

### HLD
**WebSocket gateway** shards clients consistently-hashed onto Elixir gateway nodes; each client connects to one gateway. **GuildSession** (one Erlang process per guild) is the authoritative aggregator for that guild's member list + presence state; lives on a node determined by consistent-hash of `guild_id`. On member mutation (rename, status, join, leave): GuildSession applies the mutation to its Rust-backed SortedSet (O(log N) via NIF), computes the delta, and broadcasts to all member sessions subscribed to a viewport containing the changed member. Broadcast uses **Manifold**: group destination PIDs by their remote node; send one batched payload to `Manifold.Partitioner` on each remote node, which then distributes locally. Cross-node sends collapse from N to one-per-node. **Semaphore** caps per-GuildSession inflight events: when downstream is slow, Semaphore rejects new events (or queues with bound); prevents process-mailbox unbounded growth. **GenStage** for the push fan-out path: demand-driven backpressure between event collector and APNs/FCM transport; absorbs >1M push/min bursts.

### Deep dives
1. **Manifold — batched send by remote node.** Naive: `for pid in pids: send(pid, event)` — each `send/2` to a remote PID involves cross-node serialization + transport; at 200K subscribers across 100 nodes, that's 200K cross-node sends. Manifold: group `pids` by `node(pid)`; send one payload to `Manifold.Partitioner` on each remote node (200K sends → 100 sends); partitioner on the destination node distributes locally. The 30-70μs/send Erlang cost still applies per local send, but cross-node hops are minimized. Open-sourced at github.com/discord/manifold. Trade: adds a routing layer (Manifold.Partitioner) on every node; one process-restart per node's Partitioner can interrupt fan-out (mitigation: supervision, monitoring).

2. **Rust-via-Rustler SortedSet NIF for member-list mutation.** Naive List @ 250K elements = ~170,000μs per insertion; Erlang ordsets ~27,000μs; pure-Elixir OrderedSet (skip-list) 4-640μs; **Rust SortedSet NIF: 0.61-3.68μs across 5K-1M items**. The NIF is a native shared library callable from Erlang; runs on the BEAM scheduler's thread (dirty NIFs for long-running calls to avoid blocking the scheduler). Trade: NIF crashes can crash the whole BEAM VM (mitigation: Rust's safety + careful audit; dirty-NIF isolation for risky operations). Per Discord blog: *"Today, the Rust backed SortedSet powers every single Discord guild: from the 3 person guild planning a trip to Japan to 200,000 people enjoying the latest, fun game."*

3. **Range-subscription viewport for member-list.** Naive: client subscribes to all 600K members; receives every mutation; client CPU + bandwidth saturate. Range-subscription: client subscribes to a window (e.g., members 1000-1100, the currently-rendered scroll viewport); GuildSession only sends mutations affecting that range; on scroll, client updates subscription. This collapses fan-out from O(members_in_guild) to O(visible_viewport) per client. The trick that makes mega-guilds tractable. Staff+ commit: viewport-range subscription protocol, what happens on scroll (re-subscribe), what happens when a member outside the viewport joins (no broadcast to that client).

## Known failure modes
1. **Username change cascades.** One rename in a 200K-active-guild → naively 200K WS events. Production answer: range-subscriptions so only currently-rendering viewers receive; coalescing of rapid mutations (rate-limit per-member rename); Manifold collapses cross-node sends.

2. **Erlang process mailbox unbounded.** Slow consumer (network-laggy client) → upstream queues; GuildSession mailbox grows; BEAM memory blowup. Production answer: ETS-counter Semaphore caps inflight; drop events past threshold (presence is soft-state, drop is OK); GenStage demand-driven for harder-to-drop paths.

3. **Hot guild on a single Erlang node.** Mega-guild's GuildSession process is the bottleneck on one BEAM node. Production answer: Manifold partitions outbound work; consistent-hash guild→node with re-hashing on node loss; for truly mega-guilds, split GuildSession into sub-processes by member range (sharded GuildSession).

## Notes for the coach
- **Asked-confirmed at Discord** (Staff+ candidate reports on Blind; Discord engineering blog posts are explicit interview-prep material). **Plausibly-asked** at Snap, Slack, Meta where presence-at-scale matters.
- **This is the highest-signal problem in the catalog for the user given Snapchat background.** Surface is unfamiliar (Erlang/BEAM, Manifold, SortedSet NIF, ETS Semaphore) and primitives are all named & published.
- **The 30-70μs send/2 number is the canonical anchor.** Candidates who cite it (or rediscover the math: 30μs × 200K = 6s) demonstrate Discord-blog literacy; candidates who default to "we use Kafka" miss the Erlang-process-mailbox constraint entirely.
- **Adversarial probe: "OK we use Rust SortedSet, but BEAM is single-threaded per process — how do you scale beyond one core?"** Strong answer: per-guild process, consistent-hash partitioning across BEAM nodes, Manifold collapses cross-node sends; weak answer: "we use more cores" without addressing the per-guild-process bottleneck.

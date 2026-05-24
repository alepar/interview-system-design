---
slug: slack
archetype: realtime-messaging
sources:
  slack_flannel: slack.engineering/flannel-an-application-level-edge-cache-to-make-slack-scale
  slack_shared_channels: slack.engineering/how-slack-built-shared-channels
  bing_wei_infoq: infoq.com/presentations/slack-scaling-2018 (Bing Wei "Scaling Slack")
---

# Slack — workspace messaging with edge cache + Enterprise Grid shared channels

## Bar anchors
- **Mid-level (L4/E4):** Treats Slack as one big chat. Doesn't address per-workspace sharding or the bootstrap problem on connect.
- **Senior (L5/E5):** Names per-workspace shard, WebSocket gateway, channels nested under workspace. Discusses threaded replies. May or may not address the Flannel edge cache pattern or the Enterprise Grid cross-workspace channel problem.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the **Flannel edge-cache pattern**: bootstrap a 32K-user-workspace client without shipping 32K user objects on connect (44× payload reduction reported). Names Flannel's responsibilities: holds team metadata, serves lazy `find-as-you-type` queries, pre-pushes user info inline with mentions before the mention itself arrives. Articulates the **workspace-as-shard-boundary** invariant — and then how Enterprise Grid Shared Channels **break it**, requiring per-user-per-channel visibility rules and external-org metadata loading. Names **4M simultaneous connections / 600K client QPS** at peak; **10 edge regions**; **5-min reconnect SLO** via admission control + circuit breakers + auto-scaling. Stretch (Sr Staff bar): articulates the pre-Flannel naive bootstrap as O(team_size) per reconnect and why this collapses at 32K users; explains the 5× presence-event reduction via pub-sub.

## Canonical decomposition

### Requirements
**Functional:**
- Per-workspace channels (public + private + DMs)
- Threaded replies as first-class
- Message search (separate indexed pipeline)
- Shared channels across workspaces (Enterprise Grid)
- Real-time delivery via WebSocket; presence; typing; read receipts

**Non-functional (with numbers):**
- 4M simultaneous WebSocket connections at peak; 600K client QPS (Bing Wei InfoQ)
- 32K-user workspaces supported
- Flannel deployed across 10 edge regions
- 5-min reconnect SLO (admission control + circuit breakers + auto-scaling)
- Bootstrap payload reduction: 7× on 1.5K-user team, 44× on 32K-user team

### Core entities
- **Workspace:** team_id, member_count, owner_org_id
- **Channel:** channel_id, team_id (or shared_channel_orgs[]), kind (public|private|DM|MPIM)
- **User:** user_id, primary_team_id, member_of_teams[]
- **Flannel:** edge cache holding team metadata + user objects + channel memberships per (team, region)
- **SharedChannel:** channel_id, participating_org_ids[]; per-user visibility based on (user_org, channel_orgs)

### API
- WebSocket: `WSS /websocket` — clients connect, subscribe to channels they're viewing
- `GET /flannel/users/find?team=X&q=ali` — typeahead via Flannel
- `GET /flannel/team-bootstrap?team=X` — lazy bootstrap delta (not full team)
- `POST /messages` — write to channel; server delivers via WebSocket to subscribed clients
- Search: separate REST API backed by Solr (historically) / OpenSearch

### HLD
**WebSocket gateway** terminates client connections; consistent-hash by team_id onto gateway pods. **Flannel** (edge cache) sits in front of the gateway in 10 edge regions; holds team metadata + user objects + channel memberships keyed by (team_id, region). On client connect, Flannel serves a **lazy bootstrap** (not full team state): channels the client subscribes to, with users referenced by mentions pre-pushed inline; typeahead queries served from Flannel without hitting backend. **Origin backend** holds authoritative state (Postgres-sharded-by-team for channels/messages; Vitess/MySQL historically); writes flow origin → Flannel invalidation. **Pub-sub bus** between origin and gateways: instead of every client receiving every team event, clients subscribe to channels they're viewing (presence reduced 5× post-pub-sub-migration). **Enterprise Grid Shared Channels** break the team_id partition: a channel can span multiple orgs; visibility rules become per-user-per-channel; Flannel extended to load external-user metadata when shared-channel join occurs.

### Deep dives
1. **Bootstrap problem + Flannel.** Pre-Flannel: client connects → downloads full team state (every user object, every channel, every membership) → O(team_size) per reconnect. At 32K users, this is megabytes of payload + seconds of latency, and re-fetches on every reconnect (deploy, network blip). Flannel = stateful edge cache that holds team metadata; on connect, ships only what the client needs immediately (channels currently viewed, with mentioned users pre-pushed); typeahead `find-as-you-type` served from Flannel's in-memory index without backend hit. Result: 7× payload reduction on 1.5K-user team, 44× on 32K-user team. Trade: Flannel must be kept fresh (invalidations from origin on user/channel mutations); cache coherence is the cost.

2. **Consistent-hash team→Flannel host + rebalance.** Each team_id consistently hashes to one Flannel host per region (cache locality + memory efficiency — team's data lives in one place). On Flannel node failure, affected teams re-hash to surviving nodes; brief cache miss but no correctness issue (Flannel rebuilds from origin). Trade vs replication-across-Flannel: consistent-hash is simpler but a node failure causes a brief warm-up period; alternative is replication (more memory, more invalidation traffic).

3. **Enterprise Grid Shared Channels — breaking workspace = shard boundary.** Original invariant: team_id is the partition key for everything (channels, users, messages, Flannel cache, gateway routing). Shared Channels: a channel belongs to ≥2 orgs; messages from org A must be visible to org B members in that channel. Naive: replicate the channel across both orgs' shards (cost: double-write, divergence risk). Slack's approach (slack.engineering): per-user-per-channel visibility rules; channel has `participating_org_ids[]`; on read, visibility check joins user's org with channel's orgs. Flannel extended to load external-user metadata when shared-channel join occurs (external user's profile, presence-availability if permitted). Trade: per-message permission check is more expensive than per-team partition routing; cached per-channel external-org list amortizes.

## Known failure modes
1. **Reconnect storm after deploy / network blip.** Millions of clients reconnect; pre-Flannel, each reconnect re-bootstraps full team state. Production answer: Flannel serves cold reconnects from cache, shielding origin; admission control + circuit breakers in Flannel; auto-scaling on connection-rate trigger.

2. **O(n) visibility checks under Shared Channels.** Per-message permission check iterates participating orgs; at 100+ orgs in a mega-grid channel, this is expensive. Production answer: per-channel cached external-org list; per-user cached org-membership; eliminate iterations on hot path.

3. **Single-region failure.** Slack's published in-progress state (Bing Wei InfoQ): regional failover with admission control and 5-min reconnect SLO. Production answer (target): clients hold a refresh token; on region failure, client redirected to next-closest healthy region; Flannel in healthy region warm-loads team data from origin; admission control rate-limits reconnects to prevent stampede.

## Notes for the coach
- **Asked-confirmed at Slack** (engineering blog is interview canon; Bing Wei InfoQ talk publicly outlines). **Plausibly-asked** at any enterprise-messaging shop.
- **The Flannel pattern is the Staff+ unlock.** Candidates who name "stateful edge cache that pre-pushes referenced users inline with mentions" demonstrate Slack-blog literacy; candidates who default to "we use a CDN" miss the pre-push + typeahead pattern.
- **The Enterprise Grid Shared Channels wrinkle is the deeper Staff+ probe.** Candidates who articulate "workspace was the shard boundary, but Shared Channels break it" demonstrate architectural-evolution thinking; candidates who don't recognize the invariant change miss the design pressure.
- **Adversarial probe: "Flannel adds complexity — why not just CDN the bootstrap response?"** Strong answer: typeahead + dynamic invalidations require statefulness, not just caching; Flannel coordinates with origin via pub-sub for cache coherence; static CDN can't serve `find-as-you-type` queries. Weak answer: "CDN doesn't handle WebSockets" — true but misses the stateful-cache point.

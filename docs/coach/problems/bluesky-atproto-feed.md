---
slug: bluesky-atproto-feed
archetype: fan-out
sources:
  bsky_federation: docs.bsky.app/docs/advanced-guides/federation-architecture
  atproto_repo: atproto.com/specs/repository
  bsky_relay_ops: docs.bsky.app/blog/relay-ops
  jetstream: jazco.dev/2024/09/24/jetstream/
  bsky_relay_rollout: docs.bsky.app/blog/relay-rollout
  bsky_custom_feeds: docs.bsky.app/docs/starter-templates/custom-feeds
  bsky_algo_choice: bsky.social/about/blog/3-30-2023-algorithmic-choice
---

# Bluesky AT Protocol feed — 4-tier decomposition (PDS / Relay / AppView / Feed Generators) + user repo as Merkle Search Tree with CID multihashes + bsky.network relay sustains 2K+ events/sec firehose / hundreds of consumers + Jetstream JSON+zstd dictionary compresses 232 GB/day raw → 18 GB/day or 850 MB/day posts-only (>99% reduction) + 200K evt/sec / 12 consumers / $5 VPS / <16MB RAM single Jetstream node + cursor-based subscribeRepos with per-account rev for dedup + Feed Generators as third-party HTTP services identified by DID + Labeler system as parallel third-party tier

## Bar anchors
- **Mid-level (L4/E4):** Treats as monolithic Twitter-style service.
- **Senior (L5/E5):** Names PDS/Relay/AppView decomposition. May or may not articulate MST, Jetstream compression, cursor reconnection, or Feed Generators as open marketplace.
- **Staff+ (L6/E6+):** Names (a) **4-tier protocol decomposition**: PDS (per-user data repo, signs writes) + Relay (aggregates PDS firehoses into one global stream) + AppView (consumes firehose, builds indexed timelines/feeds) + Feed Generators (third-party algorithmic feeds); fundamentally different from ActivityPub instance-as-monolith; (b) **Merkle Search Tree** repo: content-addressed, balanced, key-sorted tree; every record has CID multihash; tamper-evident; efficient diff-based sync; (c) **bsky.network relay** sustains 2K+ events/sec firehose with hundreds of active consumers; DID as natural sharding key for future horizontal scaling; (d) **Jetstream** (JSON projection with zstd dictionary compression): raw CBOR+CAR firehose 232 GB/day during viral events → 18 GB/day all-events or 850 MB/day posts-only (>99% reduction; 3.16 TB/mo → 25.5 GB/mo); single node 200K evt/sec / 12 consumers / $5/mo VPS / <16MB RAM; (e) **firehose consumers reconnect** via `com.atproto.sync.subscribeRepos` with cursor (sequence number); fan-out servers maintain local backfill window; cursors interchangeable across relays; **per-account `rev` field for dedup** rather than global sequence; reconnect at ~couple-minutes-back to overlap streams across relay cutover; (f) **Feed Generators** as third-party HTTP services identified by DID; users "pin" a feed; AppView calls generator with user identity, receives ordered list of post URIs, hydrates from indexed firehose data; (g) **Labeler system**: parallel third-party tier; any actor publishes content labels (NSFW/spoiler/misinformation) keyed by post CID; users subscribe to labelers; client overlays — decoupled moderation; (h) **Bluesky scale**: 10M (Sep 2024) → 40M (Nov 2025) = 302% in 14 months; ~1,800 new registrations/hour during peak surge.

## Canonical decomposition

### Requirements
**Functional:**
- Post (record signed by user's PDS)
- Follow remote actor (DID-addressed)
- View timeline (default chronological reverse OR algorithmic Feed Generator)
- Pin / subscribe to custom Feed Generator
- Subscribe to Labeler

**Non-functional:**
- Relay: 2K+ events/sec firehose / hundreds of consumers
- Jetstream: 200K evt/sec local / 99%+ reduction / 232 GB/day → 850 MB/day posts-only
- Per-account `rev` for dedup; cursor reconnect ~2 min back

### Core entities
- **PDS Repo:** MST keyed by record path; each record = CID multihash
- **Commit:** signed root MST CID; per-account `rev` monotonically increasing
- **FirehoseFrame:** `{seq, did, rev, ops[]}` (CBOR+CAR or Jetstream JSON)
- **FeedGenerator:** DID + HTTP endpoint serving `getFeedSkeleton`
- **Labeler:** DID publishing labels keyed by post CID

### API
- AT Proto: `com.atproto.repo.applyWrites` (write to PDS)
- Firehose: `com.atproto.sync.subscribeRepos?cursor=<seq>`
- AppView: `app.bsky.feed.getTimeline`
- Feed Generator: `app.bsky.feed.getFeedSkeleton?feed=<DID>&cursor=<>`

### HLD
Write path: client → PDS → MST update + commit signing + per-account `rev` bump → emits to local PDS firehose → Relay aggregates from all PDS firehoses into global firehose.

Indexing path: AppView consumes global firehose; builds per-user timeline index + global indexes (likes, reposts, follows).

Read path: client requests timeline. Default = AppView returns chronological reverse from indexed firehose data. Algorithmic = AppView calls user's pinned Feed Generator (third-party HTTP) with user DID → receives ordered post URIs → hydrates from indexed data.

Jetstream path: separate JSON+zstd projection of firehose for low-resource consumers; 99%+ reduction.

Labelers: parallel tier; any actor publishes labels; client overlays based on user's labeler subscriptions.

### Deep dives
1. **4-tier decomposition + MST repo.** PDS hosts user repo + signs; Relay aggregates; AppView indexes; Feed Generators are third-party algorithmic. MST = content-addressed Merkle tree; CID multihash per record; tamper-evident + diff-based sync.
2. **Firehose distribution + Jetstream compression + cursor reconnection.** Relay sustains 2K+ evt/sec; DID as natural sharding key. Jetstream zstd dictionary 99%+ reduction. Cursor reconnection with per-account rev for dedup; backfill window for ~2-minutes-back overlap on relay cutover.
3. **Feed Generators + Labelers (open marketplaces).** Feed Generators: third-party HTTP services identified by DID; users pin; AppView hydrates. Labeler: parallel third-party tier; publishes labels keyed by post CID; users subscribe; client overlays — decoupled moderation.

## Known failure modes
1. *Centralized relay bottleneck* — bsky.network is single point. Production answer: DID sharding for future horizontal scaling; AppViews can re-derive from any relay (open backfill model).
2. *Firehose lag during viral events* — 232 GB/day raw on Brazil exodus. Production answer: Jetstream as compressed projection; consumer chooses level (raw CBOR / JSON all / posts-only).
3. *Per-account rev vs global sequence* — sequence numbers may not be unique across relays. Production answer: per-account rev as dedup key; cursor reconnection at ~2-min-back overlap.

## Notes for the coach
- **Plausibly-asked at Bluesky/atproto teams.** AT Protocol spec + Jetstream blog + relay docs are public.
- **Cross-coverage** with `mastodon-federated-feed` (alternative federation protocol). With infra-primitives `kafka` (firehose substrate). With ML-in-loop (Feed Generators are user-pluggable rankers).
- **The 4-tier decomposition with Feed Generators as open marketplace is the canonical Staff+ unlock.** Mid-senior candidates draw monolith; Staff+ candidates name the PDS/Relay/AppView/FeedGen split + the algorithmic-choice product implication.
- **Adversarial probe: "How does this scale to 1B users like Twitter?"** Strong answer: DID-shard the relay (atproto roadmap); multiple AppViews consuming from sharded relays; Feed Generators federate naturally (any operator can run one); per-account rev for cross-shard dedup. Bottlenecks: AppView indexing storage scales with global firehose volume (compress via Jetstream); Feed Generator latency budget bounds algorithmic-feed experience; PDS storage = O(user repos), naturally sharded. Weak answer: "we'd scale the relay" without naming DID-shard or AppView/FeedGen federation.

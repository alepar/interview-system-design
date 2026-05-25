---
slug: mastodon-federated-feed
archetype: fan-out
sources:
  mastodon_security: docs.joinmastodon.org/spec/security/
  mastodon_webfinger: docs.joinmastodon.org/spec/webfinger/
  w3c_activitypub: w3.org/TR/activitypub/
  shared_inbox_discussion: github.com/mastodon/mastodon/discussions/18389
  mastodon_scaling: docs.joinmastodon.org/admin/scaling/
  hazel_scaling: hazelweakly.me/blog/scaling-mastodon/
  pleroma_relay: git.pleroma.social/pleroma/relay
  backfill_pr: github.com/mastodon/mastodon/pull/32634
---

# Mastodon federated feed — ActivityPub HTTP-POST-per-follower-instance with HTTP signatures (RSA-SHA256, 12h Date-header expiry) + WebFinger required for actor resolution + sharedInbox optimization (collapse to one POST per receiving instance) + 5 Sidekiq queues (default / push / pull / mailers / scheduler) with pull+default as bottlenecks under federation load + 12K-follower account = 12K POSTs without sharedInbox + 200K+ Sidekiq job-queue depth under viral load + relays as fan-in/fan-out hubs (Pleroma/LitePub) + backfill-on-follow via paged outbox collection + non-atomic post creation causes nginx 60s timeout + retry storms

## Bar anchors
- **Mid-level (L4/E4):** Designs as monolith inside one instance; no federation protocol.
- **Senior (L5/E5):** Names ActivityPub + sharedInbox. May or may not articulate HTTP signatures, Sidekiq queue topology, relay role, or non-atomic-post failure mode.
- **Staff+ (L6/E6+):** Names (a) **ActivityPub HTTP signatures** (draft-cavage) on every inter-instance POST; receiver fetches actor + public key on first contact; RSA-SHA256 verify; reject Date >12h old; (b) **WebFinger required** — search/persist remote actors fails without acct:user@domain resolution; (c) **sharedInbox optimization** collapses N-followers-on-instance to ONE POST to that instance's sharedInbox; without it, 12K-follower account = 12K POSTs per post; (d) **5 Sidekiq queues**: default (timeline build), push (outbound fed), pull (inbound fed fetch), mailers, scheduler; push conquered early; **pull + default bottleneck** under federation load; (e) **Sidekiq queue depth 200K+** under viral load; (f) ActivityPub spec silent on retry policy — Mastodon retries with exponential backoff for ~8 attempts over ~2 days; (g) **relays** (Pleroma/LitePub): fan-in/fan-out hubs; small instances subscribe to relay actor; receive aggregated public stream instead of direct follower-graph federation — prevents isolation; (h) **backfill-on-follow** via paged ActivityPub outbox collection (bounded cost, not per-status); (i) **non-atomic post creation** failure: 6+ steps + nginx 60s timeout fires while Rails continues → retry storms + duplicate work.

## Canonical decomposition

### Requirements
**Functional:**
- Post (toot)
- Follow remote actor (cross-instance)
- View home timeline (per-instance, includes federated posts)
- Receive federation events from peer instances

**Non-functional:**
- Sidekiq tuning rule: 1 worker process (5 threads) per 500K jobs/day
- Main Sidekiq process single-core; dispatch bottleneck at ~100% CPU
- ActivityPub 12h Date-header expiry
- Backfill paged (not per-status fetches)

### Core entities
- **Actor:** acct:user@domain, public_key, inbox, outbox, sharedInbox?
- **Activity:** Create/Follow/Like/Announce; signed JSON-LD
- **HomeTimeline:** Redis ZSET per local user
- **SidekiqJob:** queue ∈ {default, push, pull, mailers, scheduler}

### API
- ActivityPub: `POST /inbox` (per-actor) or `POST /sharedInbox`
- WebFinger: `GET /.well-known/webfinger?resource=acct:user@domain`
- Internal: standard Mastodon REST API

### HLD
Local post path: client → Rails API → Postgres write (Account/Statuses) → DistributionService enqueues to push queue. Push worker per-follower: groups followers by instance; **emits ONE POST per remote instance to its sharedInbox** (signed with author's private key + Date header). Local followers: distribute to home timelines (Redis ZSET).

Federation receive path: remote instance POSTs to /inbox or /sharedInbox. Authentication: fetch actor's public key; verify HTTP signature; reject if Date >12h. Pull queue worker: backfills inReplyTo chain + missing attachments via inbox-secondary fetches. Default queue: builds recipient timelines.

Backfill-on-follow: on new follow, fetch paged outbox collection (bounded). For high-follower accounts, paged collection avoids fetching every status individually.

Relay path (optional): small instance subscribes to Relay actor's Announce stream; receives aggregated public posts → ingested through pull queue.

### Deep dives
1. **ActivityPub HTTP signatures + WebFinger + sharedInbox.** Every inter-instance POST signed. 12h expiry. WebFinger resolves acct:user@domain. sharedInbox collapses N-followers-on-instance to ONE POST. **Per-instance not per-follower fan-out**: 500K-follower account spread across 10K instances = ~10K POSTs (not 500K).
2. **5 Sidekiq queues + queue depth under viral load.** default = timeline build; push = outbound fed; pull = inbound fed fetch; mailers; scheduler. Push conquered early; pull + default bottleneck because every incoming federation event requires DB work + timeline rebuild. Under viral load, queues balloon to 200K+ jobs, minutes-to-hours latency. Main Sidekiq single-core dispatch → multi-process required at scale.
3. **Relays + backfill + non-atomic post creation.** Relays = fan-in/fan-out hubs (Pleroma innovation); small instances subscribe to aggregated public stream. Backfill-on-follow paged outbox (bounded). Non-atomic post failure: 6+ steps + nginx 60s timeout + Rails continues → retry storms.

## Known failure modes
1. *Sidekiq queue collapse under viral load* — 200K+ jobs, minutes-to-hours latency. Production answer: queue-per-priority workers; backpressure (drop low-priority); admin alert.
2. *Instance churn drops federation events* — peer goes offline, queue grows, eventual drop. Production answer: per-destination retry + eventual abandonment (~8 attempts / 2 days); admin observability into affected rooms/users.
3. *Retry storm from non-atomic post creation* — nginx 60s timeout + Rails continues + client retries. Production answer: dedup-key check first; idempotency token; observability into duplicate work.

## Notes for the coach
- **Plausibly-asked at Mastodon Foundation, fediverse engineering teams.** W3C ActivityPub + Mastodon docs + GitHub PRs/discussions are public.
- **Cross-coverage** with messaging `matrix` (federated messaging analog). With `bluesky-atproto-feed` (alternative federation protocol).
- **The per-instance-not-per-follower sharedInbox optimization is the canonical Staff+ unlock.** Mid-senior candidates draw N POSTs per follower; Staff+ candidates name sharedInbox + the 500K→10K reduction math.
- **Adversarial probe: "Eugen posts and 1M follow him across 50K instances. What happens?"** Strong answer: ~50K signed POSTs via sharedInbox (not 1M); push queue absorbs; multi-worker scaling rule = 1 worker per 500K jobs/day → ~3 workers minimum; on each receiving instance pull queue refetches inReplyTo if any; default queue builds timelines for local followers; if any peer is offline, exponential backoff over 2 days. Weak answer: "1M POSTs" without sharedInbox.

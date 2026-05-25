---
slug: reddit-feed
archetype: fan-out
sources:
  reddit_arch: github.com/reddit-archive/reddit/wiki/Architecture-Overview
  bbg_reddit: blog.bytebytego.com/p/reddits-architecture-the-evolutionary
  reddit_ranking: medium.com/hacking-and-gonzo/how-reddit-ranking-algorithms-work-ef111e33d0d9
  reddit_newsletter: newsletter.systemdesign.one/p/reddit-architecture
---

# Reddit feed — subreddit-scoped fan-out (NOT follower-graph) + per-(subreddit, sort, time-bucket) listing cache + vote queues sharded by subreddit_id + log-weighted hot ranking + Wilson-score best comments

## Bar anchors
- **Mid-level (L4/E4):** Pattern-matches to Twitter follower-graph fan-out; designs per-user inbox push. Misses the architectural alternative entirely.
- **Senior (L5/E5):** Recognizes subreddit-scoped delivery. May or may not articulate the listing-cache topology, vote-queue isolation, or hot vs best ranking shapes.
- **Staff+ (L6/E6+):** Names (a) **listing service**: list of post IDs + ranks on memcache; pre-computed via job queue; popular lists persisted in Cassandra; (b) **per-(subreddit, sort-order, time-bucket) cache key** — hot/new/top × day/week/month/all variants; (c) **vote-processing queues sharded by subreddit_id (mod N)** via RabbitMQ + Zookeeper locks for atomic read-mutate-write on score — isolates hot subreddit's vote-storm; (d) **"hot" ranking** with log10(|score|) so first 10 votes count as next 100; ~12.5h time constant — 24h-old post needs ~10× score of fresh post; (e) **"best" comment ranking via Wilson score confidence interval** (not raw upvote ratio) so low-vote-count comments aren't promoted above well-tested ones; (f) **architectural advantage**: home feed = O(S) memcache GETs for S subscribed subreddits + merge-sort by hot-score; **subscribe-to-new-subreddit is O(1)** (no inbox backfill).

## Canonical decomposition

### Requirements
**Functional:**
- Post link/text/image to a subreddit
- Vote (up/down) on posts and comments
- View home feed (merged top-N across subscribed subreddits)
- View subreddit feed (single-subreddit top-N with sort variants)
- View r/all (top across default subs)

**Non-functional:**
- ~1.2B unique monthly visitors; 469M posts in 2023; 2.84B comments/interactions/year
- Hot listing TTL ~minute; top listings hourly refresh
- Vote-storm isolation: hot subreddit cannot degrade rest of platform
- "Hot" formula log-weighted + 12.5h constant; "best" Wilson-score

### Core entities
- **Post:** post_id, subreddit_id, author_id, created_at, score, hot_score
- **Vote:** user_id, post_id, vote (±1)
- **Listing:** (subreddit_id, sort, time_bucket) → list of post_ids + ranks
- **Subscription:** user_id, subreddit_id

### API
- `POST /r/:sub/submit` → {post_id}
- `POST /r/:sub/posts/:id/vote` body={vote: ±1}
- `GET /r/:sub?sort=hot&t=day&cursor=<>` → {posts[], next_cursor}
- `GET /` (home) → merged top-N across user's subscriptions

### HLD
Write path: Post Service writes to Postgres (sharded by subreddit_id). Vote Service publishes vote to RabbitMQ sharded by `subreddit_id mod N`. Async Vote Workers (per shard) acquire Zookeeper lock on (subreddit_id, post_id), read current score, apply delta, write back. After score update, recompute hot_score; update per-(subreddit, sort, time-bucket) listings in memcache + Cassandra.

Read path: Listing Service serves cached lists. Per-subreddit: single memcache GET on key (subreddit_id, sort, time_bucket). Home feed: O(S) parallel memcache GETs for S subscribed subreddits + merge-sort by hot_score at request time. r/all: separate pre-computed listing refreshed periodically.

### Deep dives
1. **Subreddit-scoped fan-out + listing cache.** Posts written into subreddit (not author outbox / follower inboxes). Listing service maintains per-(subreddit, sort, time-bucket) top-N. **Subscribe = O(1)**: add subreddit_id to subscription set; next read pulls cached listing. Architectural alternative to follower-graph fan-out.
2. **Vote-processing queues sharded by subreddit_id.** RabbitMQ sharded `subreddit_id mod N`; hot subreddit's vote-storm isolated. Zookeeper lock for atomic read-mutate-write. Async deferral. **Celebrity mitigation at community level** — viral subreddit doesn't degrade rest.
3. **Hot + Best ranking shape the inbox.** Hot: log10(|score|) + time-decay (12.5h constant); first 10 upvotes = next 100; 24h post needs ~10× score of fresh. Shapes what enters the listing cache. Best (comments): Wilson score confidence interval (accounts for both ratio AND total votes) — low-vote-count comments don't promote above well-tested ones.

## Known failure modes
1. *Listing cache invalidation race on viral post* — multiple writers race on memcache update. Production answer: Zookeeper lock + async job-queue update; eventual consistency on score; users see slightly-stale top-N for a few seconds.
2. *r/all computation expensive* — merge of many listings. Production answer: pre-computed r/all listing cached separately; periodic refresh, not on every post.
3. *Subreddit-following experiment regressed* — Reddit reportedly tried per-user-follow style feed and rolled back because it reintroduced celebrity-fanout problem. Reaffirms community-scoped fan-out as architectural sweet spot.

## Notes for the coach
- **Asked-confirmed at Reddit.** Architecture wiki + ByteByteGo breakdown are interview-prep canon.
- **Architectural alternative** to `instagram-feed`, `linkedin-feed`, `twitter-timeline`. Drill these four to teach the full topology space.
- **The subreddit-scoped framing is the canonical Staff+ unlock.** Mid-senior candidates default to follower-graph; Staff+ candidates recognize that Reddit's fan-out primitive is community-scoped.
- **Adversarial probe: "Add a per-user 'following' feature to Reddit. What breaks?"** Strong answer: reintroduces celebrity-fanout problem subreddit-scoped model avoids; per-user inbox storage explodes; hot creators saturate fan-out workers; production answer = pull-merge celebrity creators at read time (Twitter/Instagram pattern). Weak answer: "just add an inbox table" without naming the celebrity problem.

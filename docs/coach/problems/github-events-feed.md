---
slug: github-events-feed
archetype: fan-out
sources:
  retention_change: github.blog/changelog/2024-11-08-upcoming-changes-to-data-retention-for-events-api-atom-feed-timeline-and-dashboard-feed-features/
  events_api: docs.github.com/en/rest/activity/events
  webhook_payloads: docs.github.com/en/webhooks/webhook-events-and-payloads
  event_types: docs.github.com/en/rest/using-the-rest-api/github-event-types
  notifications: docs.github.com/en/subscriptions-and-notifications/concepts/about-notifications
  mergify: articles.mergify.com/handling-300k-github-events-per-day/
---

# GitHub events feed — pure-pull Events API (NOT push) + 30-day retention (reduced from 90 Jan 2025) + ETag 304 doesn't consume rate-limit + X-Poll-Interval dynamic cadence + PushEvent native commit-batching (≤2048 commits/payload) + >5000-branch + >3-tag load-shed at event creation + ~16 public event types curated from 100+ webhook types + Notifications/Watching/Starring three subscription surfaces

## Bar anchors
- **Mid-level (L4/E4):** Assumes push delivery; per-event WebSocket or polling without rate-limit awareness.
- **Senior (L5/E5):** Names pull + retention. May or may not articulate the X-Poll-Interval, PushEvent batching, or load-shed at event creation.
- **Staff+ (L6/E6+):** Names (a) **30-day retention** (reduced from 90 Jan 2025) driven by scale; (b) **pure pull**: "not built to serve real-time use cases"; event latency 30s-6h; (c) **PushEvent native commit batching** — N commits = SINGLE event with up to 2048 commits embedded; (d) **load-shed boundary at event creation**: PushEvents NOT created if >5000 branches pushed at once; create/delete events suppressed when >3 tags created/deleted at once; (e) **public Events API exposes ~16 event types** (PushEvent, PullRequestEvent, CommitCommentEvent, etc.) — curated subset of 100+ internal webhook event types; (f) **three subscription surfaces**: Watching (repo activity), Starring (bookmark), Notifications (third independent surface); auto-subscribe on side-effects (creating repo, being assigned, commenting, @mention) + manual per-activity-type granularity (CI/issues/PRs/releases/security/discussions) + independently-selectable delivery channels (web/email/mobile); (g) **rate-limit awareness**: ETag-based 304 Not Modified doesn't consume 5K/hr quota; X-Poll-Interval header dynamically dictates polling cadence — Mergify reports handling 300K GH events/day grew 10× in a year via one Redis Stream per org with serial worker per org.

## Canonical decomposition

### Requirements
**Functional:**
- Pull events feed for user / org / repo
- Webhook delivery (push, full event surface)
- Subscribe to repo (Watching / Notifications / Starring)
- Per-activity-type subscription granularity (CI / issues / PRs / releases / security / discussions)

**Non-functional:**
- 30-day retention (reduced from 90 Jan 2025); pagination 100/page, 300 max
- Notification retention 3 months (reduced from 5 Apr 2026); saved indefinitely
- Mergify: 300K events/day grew 10× in a year via per-org Redis Stream + serial worker
- GH Archive: 5B+ events / 267M+ repositories / 51M+ users; single-day single-type ~159K PushEvents (Nov 1 2014)

### Core entities
- **Event:** event_id, type, actor, repo, payload, created_at
- **Subscription:** user_id, repo_id, type ∈ {watching, notifications}
- **NotificationPreference:** user_id, activity_type, channels[] ⊆ {web, email, mobile}
- **WebhookConfig:** repo_id, url, events[], secret

### API
- `GET /events` (public timeline; pull)
- `GET /users/:user/events` (per-user)
- `GET /repos/:owner/:repo/events` (per-repo)
- `PUT /repos/:owner/:repo/subscription` body={subscribed, ignored}
- Webhook: GitHub POST to configured URL on event

### HLD
Event creation: action services (push, PR, issue) write canonical record to per-entity store + emit event record to Events stream. **Load-shed at creation**: producer suppresses PushEvent if branches_changed > 5000; suppresses create/delete events if tags_changed > 3. PushEvent producer batches up to 2048 commits into single event payload.

Event delivery (pull side): Events API serves from 30-day-retained Events store. ETag computed on event-list snapshot; client request with `If-None-Match` returns 304 (no quota cost). Server emits X-Poll-Interval header dynamically based on load.

Event delivery (push side / webhooks): Webhook Worker reads from per-repo queue; POSTs payload to configured URLs; signs with HMAC-SHA256 using webhook secret; retries on 5xx with exponential backoff.

Notifications: Notification Service consumes from Events stream; routes per (user, repo, activity_type) subscription matrix to web/email/mobile delivery channels.

### Deep dives
1. **Pure pull + retention + load-shedding.** Events API explicitly pull-only with 30s-6h latency. 30-day retention (was 90 pre-Jan-2025). Pagination 100/page max 300. **PushEvent native batching** N commits = 1 event with up to 2048 in payload. **Load-shed**: >5000-branch push = NO events; >3 tags = NO events. Dedup at event creation not post-hoc collapse.
2. **Subscription topology + auto-subscribe + granularity.** Watching, Starring, Notifications are three independent surfaces. Auto-subscribe on side-effects (creating repo, assignment, comment, @mention). Manual per-activity-type granularity. Delivery channels independently selectable. **GC**: watches on archived repos auto-pruned after 6 months inactivity (non-collaborators).
3. **Rate-limit awareness + per-org serial workers.** ETag-based 304 doesn't consume 5K/hr quota. X-Poll-Interval dynamically dictates polling cadence (server can raise under load). **Mergify pattern**: per-org Redis Stream with serial worker per org to comply with per-user/per-client-ID serial request rule.

## Known failure modes
1. *Bulk operation generates millions of events* — handled by explicit load-shed (>5000-branch / >3-tag = no events). Trade: loss of fidelity for bulk operations acceptable; subscribers don't want them.
2. *Polling client hits rate limit on tight loop* — mitigated by ETag 304 + X-Poll-Interval. Production answer: respect X-Poll-Interval; cache ETags; serial per-org workers.
3. *Event-type proliferation* — 100+ webhook events but only ~16 in public Events API. Production answer: curated subset preserves API stability; webhook delivery for full surface.

## Notes for the coach
- **Asked-plausibly at GitHub/Microsoft.** Docs + Mergify scaling case study are public.
- **Cross-coverage** with messaging `push-notification` (webhook delivery). With infra-primitives `kafka` (Redis Stream per-org is per-tenant queue pattern).
- **The pull-only + ETag + X-Poll-Interval triad is the canonical Staff+ unlock.** Mid-senior candidates assume push or unbounded poll; Staff+ candidates name the explicit rate-limit-aware client protocol.
- **Adversarial probe: "Why doesn't GitHub use WebSockets for live events?"** Strong answer: scale (5B+ events, 51M users) makes per-user persistent connection cost-prohibitive; 30-day retention + pull model lets clients reconcile at their own cadence; webhook for explicit push integrations; ETag 304 makes polling cheap for active clients. Weak answer: "WebSockets are hard" without quantifying the connection-tax.

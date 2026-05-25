---
slug: feature-flags
archetype: caching-read-heavy
sources:
  ld_edge: launchdarkly.com/blog/flag-delivery-at-edge/
  ld_storing_data: launchdarkly.com/docs/sdk/features/storing-data
  ld_polling_streaming: launchdarkly.com/blog/launchdarklys-evolution-from-polling-to-streaming/
  ld_percentage_rollouts: launchdarkly.com/docs/home/releases/percentage-rollouts
  streaming_vs_polling: featbit.co/blogs/streaming-vs-polling-for-feature-flags
---

# Feature-Flag Service (read-heavy config eval with near-real-time propagation)

## Bar anchors
- **Mid-level (L4/E4):** Stores flags in a DB and queries them per request. Doesn't see the per-request eval load, the need to propagate changes fast, or client-side caching.
- **Senior (L5/E5):** Caches flag rulesets in the client SDK, evaluates locally, and pushes/poll updates; supports percentage rollouts. Knows every request evaluates flags (huge read load) and changes must propagate quickly. May not articulate in-process eval with no-TTL push cache, streaming vs polling tradeoffs, or deterministic bucketing.
- **Staff+ (L6/E6+):** Drives proactively. Puts flag **evaluation in-process in the SDK** against an **in-memory ruleset cache** — a flag check is a local function call (nanoseconds–microseconds), **no network call on the request critical path**. Keeps the cache fresh by **push, not TTL** (LaunchDarkly: cached values have **no TTL**; updated via a persistent **SSE stream** when a flag changes — sub-second propagation), with **polling (30–60s) as the fallback/hybrid**. Distributes rulesets via **edge/CDN** (LaunchDarkly: 100+ PoPs, <200ms global propagation, 98% edge hit, ~25ms init) and serves **45T evals/day** at this scale. Implements **percentage rollouts** via **deterministic hash bucketing** (hash(context key + kind + flag salt) into 100,000 partitions ⇒ sticky, idempotent assignment). Splits **server-side SDK (full ruleset local) vs client-side SDK (resolved values only, rules stay server-side for security/bandwidth)**. Accepts **eventual consistency** of flag state across instances (the polling/streaming staleness window).

## Canonical decomposition

### Requirements
**Functional:**
- Evaluate feature flags per request (targeting rules, percentage rollouts) with negligible latency
- Propagate a flag change to all clients in near-real-time
- Support percentage rollouts with sticky, consistent per-user assignment
- Keep targeting rules / sensitive data server-side for client apps

**Non-functional (with numbers):**
- Eval is in-process: nanoseconds–microseconds, no per-eval network call
- Propagation: SSE streaming <1s (sub-200ms at edge); polling fallback 30–60s
- Scale: LaunchDarkly ~45T evals/day; 100+ edge PoPs; 98% edge hit; ~25ms SDK init
- Eventual consistency of flag state across app instances (bounded staleness)

### Core entities
- **Flag + ruleset:** targeting rules, variations, rollout percentages, salt
- **SDK in-memory cache:** the ruleset (server-side SDK) or resolved values (client-side SDK)
- **Stream/poll channel:** delivers ruleset changes to SDKs (SSE push / polling)
- **Context:** the user/request attributes a flag is evaluated against

### API
- `variation(flagKey, context) → value` → local in-process evaluation (no network)
- SDK ← SSE stream of flag-change events (or periodic poll) → update in-memory ruleset
- edge/CDN serves the ruleset to SDKs on init + as a streaming source

### HLD
The defining move is **in-process evaluation**: the SDK holds the **ruleset in memory** and `variation(flag, context)` is a **local function call** (nanoseconds–microseconds) — flags are checked on potentially every request, so a network call per eval would be fatal. The cache is kept fresh **by push, not by TTL**: LaunchDarkly's SDKs hold flags with **no expiration** and update them via a persistent **Server-Sent Events (SSE)** stream whenever a flag rule changes on the dashboard, giving **sub-second propagation**. This replaced a **polling** model that risked a stampede (a million clients polling at once) and is offered as a **hybrid** (streaming with automatic fallback to polling for reliability; polling default 30–60s). Rulesets are distributed via a global **edge/CDN** (100+ PoPs, <200ms global propagation, 98% edge hit, ~25ms init), serving ~45T evals/day.

**Percentage rollouts** use **deterministic hash bucketing**: hash `(context key + context kind + flag salt)` into **100,000 partitions**; "50% to variation A" serves A to partitions 1–50,000 — so a given user **sticks** to the same variation across sessions (idempotent, not random per call) as long as inputs/percentages are unchanged. **SDK type** matters for security and bandwidth: **server-side SDKs** receive the *full ruleset* and evaluate locally; **client-side SDKs** receive only *resolved values* (the rules and user segments stay server-side, preserving sensitive targeting data and bandwidth). Flag state is **eventually consistent** across instances — different app instances may briefly hold different flag states (the streaming/polling staleness window), which is acceptable for flags (users won't perceive a sub-second-to-30s delay) but is the consistency tradeoff to name.

### Deep dives
1. **In-process eval + push-not-TTL caching.** The read-heavy crux: flags are evaluated constantly, so evaluation must be a local in-memory lookup with no network on the critical path. The cache is kept correct not by expiring (TTL would mean either staleness or constant refetch) but by **pushing changes** — an SSE stream delivers flag-rule updates in sub-second, so the in-memory ruleset is always near-current with zero per-eval cost. This is the canonical "cache with no TTL, invalidated by push" pattern, and it's why a flag service scales to trillions of evals/day. The Staff+ point: when the read is on every request, move eval to the client and keep the cache fresh by push.
2. **Streaming vs polling propagation.** Polling (every 30–60s) is simple and resilient but stale and risks a **thundering herd** if a million clients poll together; streaming (**SSE**) gives sub-second propagation but requires holding a persistent connection (and the client's context in memory) for millions of clients. Production systems run a **hybrid**: streaming for freshness with automatic fallback to polling for reliability, plus **edge/CDN distribution** so SDK init and ruleset fetch hit a nearby PoP (98% hit, ~25ms init). The tradeoff to articulate: propagation latency (sub-1s streaming vs 30–60s polling) vs connection cost and operational simplicity; most flags tolerate seconds, so the choice is driven by the few that need instant kill-switch behavior.
3. **Deterministic percentage rollouts.** A rollout must be **sticky** (a user keeps the same variation across requests/sessions) and **consistent across SDKs**, which rules out per-call randomness. The solution is **deterministic hashing**: hash `(context key + context kind + flag salt)` into a fixed partition space (100,000), and map percentage ranges to partition ranges (50% ⇒ partitions 1–50,000). The same user hashes to the same partition everywhere, so every SDK independently computes the same variation with no coordination — and changing the percentages re-buckets predictably. The salt per flag ensures independent bucketing across flags (a user isn't always in the "first 10%" for every flag). This is the same consistent-bucketing idea as consistent hashing, applied to experiment assignment.

## Known failure modes
1. **Stale flag state after a change (esp. a kill switch).** An instance keeps serving the old variation because its cache didn't update. Production answer: SSE push for sub-second propagation (not TTL); polling fallback bounds worst-case staleness; for safety-critical kill switches, prefer streaming and verify propagation.
2. **Polling thundering herd.** A million SDKs poll simultaneously and overwhelm the backend. Production answer: streaming (persistent connections, push only on change) + edge/CDN distribution; if polling, jitter the intervals.
3. **Leaking targeting rules / sensitive segments to clients.** A client-side SDK shipping full rulesets exposes who-gets-what and bloats payloads. Production answer: client-side SDKs receive only resolved values; full rules + segments stay server-side (security + bandwidth).

## (Delineation note)
`feature-flags` is the read-heavy config-evaluation + near-real-time-propagation problem; it shares the push-vs-poll and client-cache patterns with `distributed-config`. The coordination primitive (etcd/zookeeper) and experiment *analysis* (ml-in-loop) are elsewhere. Here it's in-process eval + push-fresh cache + deterministic rollout bucketing.

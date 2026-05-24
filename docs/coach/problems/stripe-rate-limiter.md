---
slug: stripe-rate-limiter
archetype: infra-primitives
sources:
  stripe_blog: stripe.com/blog/rate-limiters
  brandur_gcra: brandur.org/rate-limiting
  cloudflare_counters: blog.cloudflare.com/counting-things-a-lot-of-different-things/
  cloudflare_durable_objects: developers.cloudflare.com/durable-objects/
  hello_interview: hellointerview.com/learn/system-design/problem-breakdowns/distributed-rate-limiter
---

# Stripe-class API rate limiter (token-bucket + GCRA + multi-region)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic Redis-backed counter: `INCR` + `EXPIRE` per (tenant, window) key; fixed window or sliding window log. Names rate limiter as a middleware on the request path; returns HTTP 429 on quota exceeded. Doesn't address Redis failure semantics, global vs regional limits, cost-based limiting, or atomicity beyond "use a Lua script."
- **Senior (L5/E5):** Names token-bucket vs leaky-bucket vs sliding-window-counter algorithms with one-line trade-offs. Identifies central-Redis vs per-host enforcement as a real architecture choice and articulates the consistency/latency trade-off. Discusses sharding by tenant_id to avoid hot keys. Mentions HTTP 429 with `Retry-After` header. May or may not surface fail-open semantics on its own.
- **Staff+ (L6/E6+):** Drives the session proactively. Quantifies the hot-path latency budget: rate limiter sits on every request, so the canonical bar is <5ms p99 added latency (Stripe's published constraint). Names GCRA (Generic Cell Rate Algorithm) as Stripe's specific token-bucket variant — single Theoretical Arrival Time (TAT) field per key, atomic Lua mutation collapses read-compute-write into one server-side op. Identifies fail-open as the production answer for user-facing APIs ("if Redis were to go down, requests wouldn't be affected" — Stripe blog) and fail-closed for billing/payment-critical paths. Articulates the cost-based variable-debit problem: rate-limit by token-cost not request count when per-request cost varies 100× (LLM inference, GPU-seconds, expensive API calls); requires reservation-then-refund pattern with timeout-based orphan cleanup. For global limits across N regions, names three architectures with criteria: static partitioning (simple, wastes burst capacity), central authority with cross-region RTT (high tail latency), eventually-consistent reconciliation with over-admission bound = drift × refill rate (Cloudflare's per-PoP Memcached counters). Names Cloudflare Durable Objects as the strongly-consistent alternative: single location-bound singleton per key, accepts higher latency for global correctness. Stretch (Sr Staff bar): distinguishes rate limiter from load shedder (Stripe runs four limiter types in production — request-rate limiter, concurrent-requests limiter, fleet-usage load shedder, worker-utilization limiter — they're separate primitives with different decision criteria).

## Canonical decomposition

### Requirements
**Functional:**
- Reject or allow each incoming API request based on per-tenant rate limits
- Support multiple limit dimensions: requests/second, requests/minute, concurrent requests, token-cost-based (variable debit)
- Configurable burst capacity (bucket fills faster than steady-state to absorb spikes)
- Return HTTP 429 with `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`, `Retry-After` headers on rejection
- Per-tenant configurable policy: rate, burst, fail-open vs fail-closed
- Global (cross-region) limits where required

**Non-functional (with numbers):**
- 10M+ active tenant keys
- 100K+ rate-limit decisions/sec aggregate
- <5ms p99 added latency on the hot path (Stripe's published constraint)
- Fail-open default for user-facing APIs; fail-closed for billing/payment paths
- Cloudflare global rate limiter operates at "tens of millions of QPS class"
- Stripe-published claim: limiter is "the first line of defense" against bursty/abusive clients
- Cost-based limiting: per-request cost can vary 100× (cheap API call vs expensive LLM inference)
- For multi-region: bound over-admission to ≤2× nominal rate during the reconciliation window

### Core entities
- **Tenant:** tenant_id, plan_tier, rate_limit_config (rate, burst, dimension), policy (fail_open | fail_closed), region_assignment
- **Bucket state:** key (tenant_id + dimension), `tat` (theoretical arrival time, GCRA), or `(tokens, last_refill_ts)` (token bucket), or `(window_count, window_start)` (sliding window)
- **Reservation:** request_id, tenant_id, reserved_tokens, expires_at (for cost-based mode)
- **Limit decision event:** request_id, tenant_id, decision (allow | reject), reason, latency_ms (for observability)

### API
- Internal middleware API: `check(tenant_id, dimension, cost=1) → (allow | reject, retry_after_seconds)` — sub-5ms p99
- For cost-based: `reserve(tenant_id, estimated_cost) → reservation_id`; `confirm(reservation_id, actual_cost)` or `refund(reservation_id)` on completion
- Admin: `POST /v1/tenants/:id/limits` body={dimension, rate, burst, policy} → updated limit config
- `GET /v1/tenants/:id/usage` → real-time consumption (per dimension, per window)
- HTTP response on reject: `429 Too Many Requests` with `X-RateLimit-*` headers + `Retry-After: N`

### HLD
The rate limiter is a stateless middleware library embedded in every gateway pod. On request, it (1) extracts tenant_id from auth context, (2) builds the bucket key `(tenant_id, dimension)`, (3) calls the **bucket store** (Redis cluster) with an atomic Lua script that runs GCRA or token-bucket math server-side, (4) on allow, proceeds; on reject, returns 429 with headers; on timeout/error, applies the per-route fail-open or fail-closed policy. The **Redis cluster** is sharded by `hash(tenant_id)` with consistent hashing to avoid hot keys; replication factor 3 with `acks=all`-equivalent persistence (AOF + replica failover) for state durability. For **cost-based limiting** (LLM token cost, GPU-second cost), the limiter reserves `max_cost` worth of bucket tokens at admission; the request handler calls `confirm(actual_cost)` or `refund` at completion; orphaned reservations time out after a TTL.

For **multi-region global limits**, the architecture forks: (a) **central authority** — one global Redis cluster, cross-region RTT on every check (~50-200ms across continents) → too slow for hot path; (b) **regional with reconciliation** — each region runs local Redis, periodically reconciles counters against a global sink (Kafka stream + aggregator), accepts brief over-admission bounded by `drift_window × steady_state_rate` (Cloudflare's per-PoP Memcached counters via Twemproxy); (c) **strongly-consistent location-bound singleton** — one node owns the key globally, all requests route there (Cloudflare Durable Objects pattern), trades latency for correctness. Stripe production uses regional + reconciliation by default with central authority for billing-critical keys.

**Load shedder** is a separate primitive layered on top: rate limiter rejects on per-tenant quota; load shedder rejects on aggregate fleet utilization (when total in-flight requests exceed safe capacity, shed low-priority traffic regardless of per-tenant quota). Stripe runs both.

### Deep dives
1. **Central token-bucket-in-Redis (Lua-atomic) vs per-host leaky-bucket with periodic reconciliation vs sliding-window-log (ZSET) vs GCRA.** Central Redis-Lua: one Redis cluster holds all buckets; gateway pod calls Lua script atomically (`GET tat → check → update if allowed → return`). Pros: strongly consistent, no over-admission. Cons: every request pays a Redis RTT (~1-3ms within a DC); Redis cluster failure modes propagate to gateway availability. Per-host leaky-bucket: each gateway pod tracks bucket locally, periodically reconciles with a central store. Pros: sub-ms decisions, survives central-store outage. Cons: brief over-admission during reconciliation lag; harder to enforce hard caps. Sliding-window-log with Redis ZSET: maintains a sorted-set of request timestamps per key, ZREMRANGEBYSCORE old + ZCARD + ZADD new in one Lua. Pros: exact accuracy. Cons: O(log n) per operation, memory grows with window × rate. **GCRA** (Stripe's choice): collapses token-bucket math into a single TAT (Theoretical Arrival Time) field per key — `if now >= tat - burst*emission_interval: tat = max(now, tat) + emission_interval × cost; allow` — atomic in one Lua call, O(1) memory per key, mathematically equivalent to token bucket in steady state. Staff+ commit: pick one with criteria; for Stripe-class API gateway, GCRA on central Redis is the canonical answer; for sub-ms inner-loop limits, per-host with reconciliation; for billing-critical hard caps, accept the latency cost of central authority.

2. **Cost-based variable-debit limiting with reservation-confirm-refund.** Naive token-bucket assumes fixed cost per request. Real-world primitives (LLM inference billed by token count, GPU-second-based quotas, API calls with variable downstream cost) require variable debit. Production pattern: at admission, estimate maximum cost (e.g., `max_tokens` for LLM, request body size for proxied APIs) and reserve that quantity from the bucket; on request completion, `confirm` with actual cost (refunds the delta) or `refund` on failure. Reservation has a TTL (typically 60s-5min) to prevent orphans from crashed handlers. Atomicity: the reserve-confirm-refund pair must use idempotent operations (reservation_id as the dedup key) since either side can retry. Failure mode: client crashes mid-request → reservation orphaned → TTL expires → tokens released. Staff+ commit: TTL choice (long enough to cover p99 request latency, short enough to bound orphan-tied-up-tokens), refund semantics (atomic decrement with floor at zero), what happens when reservation > current bucket capacity (deny at admission, don't reserve negative).

3. **Multi-region global limits and the over-admission budget.** "Customer X has a 1000 RPS global limit" with 8 regions has three production architectures. **Static partitioning** (125 RPS per region) is simplest but wastes burst capacity — if customer's traffic concentrates in one region they get rejected despite global headroom. **Central authority** (one global Redis) gives exact enforcement but cross-continent RTT (50-200ms) blows the hot-path budget. **Eventually-consistent reconciliation** (each region runs local Redis, periodic global sync via Kafka or a state-replication service) is the production sweet spot: over-admission bound = `drift × refill_rate` (e.g., 1s drift × 1000 RPS = 1000 extra requests admitted in worst case). Cloudflare's published architecture uses per-PoP Memcached counters with Twemproxy consistent-hash distribution and a few-seconds-class drift window. **Cloudflare Durable Objects** is the strongly-consistent alternative: one node globally owns each key, all requests route there via Anycast; accepts higher latency (10-50ms) for global correctness. Staff+ commit: pick architecture with criteria — billing-critical hard caps need central authority or Durable Objects; user-facing fairness limits tolerate eventually-consistent reconciliation.

## Known failure modes
1. **Redis cluster outage during failover.** Mid-failover, Redis primary is unreachable; reads/writes fail. Fail-open policy: gateway admits all requests until Redis recovers (Stripe's published behavior — "requests wouldn't be affected") — preferred for user-facing APIs because a brief over-admission window is better than total outage. Fail-closed policy: gateway rejects all requests until Redis recovers — preferred for billing-critical paths where over-admission is a financial risk. Production answer: per-route policy declaration in middleware config; AOF persistence + replica failover on Redis side to minimize the window; instrumentation that distinguishes "rate-limited" from "Redis-down-fail-open" in metrics so SREs see the latter immediately.

2. **Hot key (single tenant dominates traffic).** One tenant accounts for 30% of traffic; their bucket key hashes to one Redis shard; that shard saturates while others sit idle. Production answer: secondary sharding within tenant — hash on `(tenant_id, sub_key)` where sub_key is derived from request hash so one tenant's traffic spreads across multiple shards; periodic merge of per-shard sub-counters via background job to maintain accurate quota. For very-hot tenants, dedicated Redis shard (or Durable Object) with that tenant pinned. Anti-pattern: hash-by-tenant alone gives uniform distribution only when tenants are uniformly sized.

3. **Reservation leak in cost-based mode.** Client crashes after reserving 1000 tokens but before calling confirm or refund; tokens orphaned until TTL expires (5 min). At high reservation rate, orphan accumulation eats real budget. Production answer: short TTL (matching p99 request latency + small margin, e.g., 60s for most APIs); idempotent confirm/refund keyed by reservation_id; alerting on reservation-leak-rate (rate of expired-without-confirm reservations); for high-leak-rate tenants, server-side switch to post-debit accounting (debit actual cost only, skip pre-reservation) at the cost of brief over-admission.

## Notes for the coach
- **This is the canonical L6+ infra interview prompt.** Multi-source asked-confirmed (Stripe, Cloudflare, AWS, Google, Meta per IGotAnOffer and Hello Interview Staff catalog). Stripe's engineering blog (Tarjan, 2017) is the implicit "model answer" interviewers benchmark against. Citing the Stripe blog by name + the GCRA algorithm + the fail-open quote is the literacy signal.
- **Hello Interview note:** "Staff+ candidates often aren't asked this specific question because these concepts come naturally at this level" — when asked, the bar shifts to multi-region consistency, cost-based limiting, gradual rollouts, and operational failure modes rather than the algorithm choice itself. The candidate who only debates token-bucket vs sliding-window is at Senior; the candidate who articulates multi-region trade-offs and load-shedder-vs-rate-limiter separation is at Staff+.
- **Cross-coverage with AI-infra `ai-gateway-token-quota`:** this generic version tests request-count + cost-based limiting on commodity workload. The AI version layers on token-cost dimension (input ≠ output, prompt-cache discount), multi-provider failover with per-provider key pools, and 4-tier budget hierarchy. Coach should announce "no AI-specific framing" up front for this primitive version. If the candidate drifts into LLM-token semantics, redirect: "let's stay on the generic API primitive — assume cost is just a number per request."
- **Stripe runs FOUR limiter types in production**, not one (request-rate, concurrent-requests, fleet-usage load shedder, worker-utilization). A candidate who articulates this distinction unprompted is at Sr Staff bar. The coach should not require it but reward it.
- **Cloudflare Durable Objects** as the strongly-consistent global-counter answer is a 2025+ literacy signal. Candidates anchoring only on "central Redis vs CRDT" without naming Durable Objects are missing the current frontier.

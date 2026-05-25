---
slug: session-store
archetype: caching-read-heavy
sources:
  session_tradeoffs: skycloak.io/blog/session-management-distributed-systems-cookies-vs-tokens-vs-server-side-sessions/
  redis_session: oneuptime.com/blog/post/2026-03-31-redis-how-to-build-a-scalable-session-store-with-redis/view
  sticky_sessions: designgurus.io/course-play/grokking-scalable-systems-for-interviews/doc/what-are-sticky-sessions-session-affinity-and-when-should-i-avoid-them
  jwt_revocation: oneuptime.com/blog/post/2026-02-02-jwt-revocation/view
  meta_memcached: imaginarycloud.com/blog/redis-vs-memcached
---

# Session Store (read-heavy auth/session lookups)

## Bar anchors
- **Mid-level (L4/E4):** Stores sessions in the app server's memory. Doesn't see that this breaks horizontal scaling/failover or that every request reads the session.
- **Senior (L5/E5):** Externalizes sessions to Redis with TTL, or uses stateless JWTs; knows every authenticated request reads the session (huge read load) and stateless-vs-stateful is a tradeoff. May not articulate the revocation tradeoff, sticky-session pitfalls, or read-scaling via replicas.
- **Staff+ (L6/E6+):** Drives proactively. Frames the core axis as **stateful session store vs stateless token**: a server-side store (Redis/Memcached, sub-ms reads, native TTL) gives **immediate revocation** but every request does a store lookup (and `touch()` resets TTL ⇒ a *write* too) — scaled by **async read replicas** and eviction policy choice; **JWT** is stateless and removes the per-request lookup (each service verifies with a public key/shared secret) but **revocation is hard** — the standard fix is **short-lived access tokens (5–15 min) + refresh tokens (7–14 days)**, accepting a bounded revocation window, since a blacklist re-introduces a per-request stateful lookup. Rejects **sticky sessions** (load imbalance, per-server SPOF for those sessions) in favor of externalized **session replication**. Notes JWT size (1–2KB carried client-side per request) and extreme scale (Meta ~5B Memcached req/sec).

## Canonical decomposition

### Requirements
**Functional:**
- Authenticate every request by validating a session/token
- Support logout / revocation (immediately or within a bounded window)
- Scale to read on every authenticated request; survive server failover

**Non-functional (with numbers):**
- Every authenticated request reads the session (read:request ≈ 1:1, huge volume)
- Redis session: sub-ms reads, native TTL; scale reads via async replicas
- JWT: 1–2KB client-carried; access TTL 5–15 min, refresh 7–14 days
- Extreme scale anchor: Meta ~5B Memcached requests/sec

### Core entities
- **Session:** session_id → {user_id, roles, expiry, …} in the store (stateful model)
- **Token (JWT):** signed claims carried by the client (stateless model)
- **Refresh token:** long-lived token to mint new short-lived access tokens
- **Revocation list (optional):** blacklist for immediate stateful revocation

### API
- stateful: `GET session:{id}` per request (→ {user, roles}); `touch()` resets TTL
- stateless: verify JWT signature + expiry locally (no store lookup)
- `logout()`: delete session (stateful) or revoke refresh token / blacklist (stateless)

### HLD
Sessions in app-server memory don't survive horizontal scaling or failover, so the session is **externalized**. The two models:

**Stateful (server-side store):** session data lives in **Redis/Memcached** keyed by `session_id`; every authenticated request **reads** it (sub-ms) to get the user/roles, and middleware typically **`touch()`es** it to reset the TTL on activity — so each request is a read *and* a small write. This gives **immediate revocation** (delete the key = instant logout everywhere) and centralizes session state, but the store must absorb a read on *every* request — scaled by **async read replicas** (reads fan out to replicas; writes to primary) and an appropriate eviction policy (Redis offers six; Memcached LRU-only). It also needs **GC** of expired sessions (Redis native TTL handles this; otherwise a purge job).

**Stateless (JWT):** the client carries a **signed token** (1–2KB) with its claims; each service **verifies it locally** with a public key/shared secret — **no store lookup**, so it scales trivially across microservices. The cost is **revocation**: you can't un-issue a token, so the standard pattern is **short-lived access tokens (5–15 min) + long-lived refresh tokens (7–14 days)** — logout/revoke invalidates the refresh token, and the access token dies within minutes (a bounded revocation window). A blacklist gives immediate revocation but **re-introduces a per-request stateful lookup**, defeating the point.

**Sticky sessions** (route a user to one server holding their in-memory session) are an anti-pattern at scale: load imbalance (a new server gets no traffic until new sessions arrive) and a **per-server SPOF** (that server dies → those users lose their sessions). Externalized **session replication** (or stateless tokens) is preferred so any server can handle any request.

### Deep dives
1. **Stateful vs stateless: the revocation/scale tradeoff.** This is the whole problem. Stateful = a read (and TTL-touch write) on every request, but instant revocation and easy session mutation; scale the read with replicas + a fast in-memory store (Redis/Memcached). Stateless = zero store lookup (verify locally), trivial horizontal scale, but revocation is hard and the token is carried on every request (1–2KB header overhead). The Staff+ synthesis: short-lived access + refresh tokens get *most* of stateless's scale with a *bounded* revocation window; reach for a stateful store (or a hybrid blacklist) only when you need *immediate* global revocation (e.g. security-sensitive logout-everywhere).
2. **Scaling the per-request read.** Because every authenticated request reads the session, the store is on the hottest path. Mitigations: an in-memory store (sub-ms), **async read replicas** to fan out reads (write to primary, read from replicas — accept tiny replica lag), client-side/edge caching of the validated session for a short window, and choosing the eviction policy (Redis's volatile-lru/allkeys-lru/etc. vs Memcached's LRU-only) to keep hot sessions resident. The extreme scale (Meta ~5B Memcached req/sec) shows this is a solved-but-real read-amplification problem. The `touch()`-resets-TTL detail matters: naively it makes every read a write — batch/throttle TTL refreshes if write volume bites.
3. **Sticky sessions vs replication, and GC.** Sticky sessions seem to avoid the shared store but trade it for load imbalance and a per-server SPOF (server restart = lost sessions, and scale-out is slow because new servers get no existing sessions). The cloud-preferred answer is **externalized session state** (replicated store) so the fleet is stateless and any server serves any user — at the cost of the per-request store read (deep-dive 2). **GC** is the operational tail: expired sessions must be reaped (Redis native TTL is the clean answer; otherwise a background purge job, or unbounded growth). The framing: keep app servers stateless, put session state in a fast replicated store with TTL, and don't paper over it with stickiness.

## Known failure modes
1. **Session store as a single hot dependency.** Every request reads it; if it's slow/down, auth fails fleet-wide. Production answer: in-memory store + async read replicas + short edge/client cache of validated sessions; HA store with failover; circuit-breaking to a degraded mode.
2. **Can't revoke a leaked JWT.** A stolen stateless token stays valid until expiry. Production answer: short access-token TTL (5–15 min) + refresh-token revocation; a blacklist only for high-value immediate revocation (accepting the per-request lookup it adds).
3. **Sticky-session server loss.** A server restart drops all sessions pinned to it and scale-out is uneven. Production answer: externalize sessions (replicated store) so servers are stateless; reserve stickiness for cases that truly need server affinity.

## (Delineation note)
`session-store` is the read-heavy per-request session/auth lookup problem. Building Redis/Memcached is infra-primitives; the OAuth/identity protocol details are out of scope. Here it's the stateful-vs-stateless tradeoff + read-scaling the per-request lookup + revocation.

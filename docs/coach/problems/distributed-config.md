---
slug: distributed-config
archetype: caching-read-heavy
sources:
  archaius_features: github.com/Netflix/archaius/wiki/Features
  etcd_watch: svalle.ru/posts/kubernetes/etcd-to-watch/
  aws_appconfig: aws.amazon.com/blogs/aws/safe-deployment-of-application-configuration-settings-with-aws-appconfig/
  consul_gossip: aws.amazon.com/blogs/architecture/microservices-discovery-using-amazon-ec2-and-hashicorp-consul/
  config_mgmt: codelit.io/blog/distributed-configuration-management
---

# Distributed Config (read-heavy config distribution with near-real-time propagation)

## Bar anchors
- **Mid-level (L4/E4):** Reads config from a DB or a file on each use. Doesn't address per-request read load, propagating changes to many clients, or local caching.
- **Senior (L5/E5):** Clients cache config locally and refresh by polling or watch; changes propagate in near-real-time; supports safe rollout. Knows reads dominate and a central store is the source of truth. May not articulate the client-local-cache + watch fanout, the consistency choice, or local-file fallback resilience.
- **Staff+ (L6/E6+):** Drives proactively. Serves config to many clients via a **client-local cache** refreshed by **poll or push/watch** (Netflix **Archaius**: poll a source at a fixed interval — default ~10 min, configurable to seconds — or push; **DynamicProperty** caches the resolved value so frequent reads are local, not a hierarchy walk; **local-file fallback** if the central source is unreachable). For push, references **etcd's `Watch()` gRPC stream** (push, not pull, from a revision) and **Kubernetes' watch cache** as the **read-fanout layer** that lets thousands of watchers subscribe without overloading etcd. Quotes propagation/consistency: AWS **AppConfig** deploys in **seconds** (Lambda cache eventual-consistency window 0–15 min depending on TTL); **eventual consistency is fine for most config, strong consistency only for security-critical values**. Notes **Consul gossip** scaling to thousands of nodes as a P2P alternative to centralized watch streams.

## Canonical decomposition

### Requirements
**Functional:**
- Distribute configuration to many client services; reads are frequent (per request/operation)
- Propagate config changes to all clients in near-real-time
- Survive the central config service being unreachable (clients keep running)
- Choose consistency per value (eventual for most; strong for security-critical)

**Non-functional (with numbers):**
- Reads dominate (config read constantly); each read should be a local cache hit
- Propagation: AppConfig deploys in seconds; Archaius poll default ~10 min (tunable to seconds)
- Watch fanout to thousands of watchers without overloading the store (K8s watch cache)
- Eventual consistency acceptable for most config (bounded staleness window)

### Core entities
- **Config item:** key → value (+ version/revision)
- **Client-local cache:** the resolved value held in-process (DynamicProperty-style)
- **Watch / poll channel:** delivers changes (etcd Watch stream / periodic poll)
- **Watch cache / fanout layer:** sits between the store and many watchers

### API
- `get(key) → value` → in-process cache hit (no network on the hot path)
- client ← watch stream (etcd `Watch()` from a revision) or periodic poll → update cache
- change callback: code registers to react when a watched value changes
- local-file fallback: load cached config from disk if the central source is down

### HLD
Config is read **constantly** (on requests, in hot loops), so the read must be a **local in-process cache hit**, not a network call. Netflix **Archaius** is the canonical app-layer pattern: a client either **polls** a config source at a fixed interval (`FixedDelayPollingScheduler`, default ~10 min, configurable down to seconds) or has changes **pushed**; the resolved value is cached in a **DynamicProperty** so frequent reads don't re-walk the config hierarchy, and code can **register callbacks** to react to changes without a restart. For resilience, clients load from a **local cached file first** and fall back to the central source only if the cache is absent — so config distribution survives the central service being unreachable.

For **push-based** propagation, **etcd's `Watch()` gRPC stream** is the coordination primitive: clients watch from a revision and receive pushed PUT/DELETE events (push instead of pull). But a popular config watched by thousands of clients can't all hammer etcd, so Kubernetes inserts a **watch cache** between etcd and clients — the **read-fanout layer** that lets every kubelet/controller/`kubectl -w` subscribe without overloading the store. **AWS AppConfig** shows the managed pattern: deploy a config change that propagates in **seconds**, with clients (e.g. Lambda) caching it (eventual-consistency window 0–15 min depending on the cache-TTL setting). The **consistency choice** is explicit: **eventual consistency is fine for most config/flags** (a brief staleness window is harmless), but **strong consistency may be required for security-critical values** (a credential rotation, a kill switch) — and the propagation mechanism is pull (poll), push (watch/subscribe), or hybrid. **Consul's gossip** protocol is the P2P alternative — distribute to thousands of nodes with minimal overhead without a centralized watch stream.

### Deep dives
1. **Client-local cache + change propagation (poll vs watch).** Because config is read on the hot path, every client caches the resolved value in-process (Archaius DynamicProperty) so `get(key)` is a local lookup. Freshness comes from either **polling** (simple, resilient, but stale up to the interval and load-bumping at scale) or **watch/push** (etcd `Watch()` stream — sub-second, but requires the store to push to every watcher). The choice mirrors `feature-flags`' streaming-vs-polling tradeoff: poll for simplicity/robustness when seconds-to-minutes staleness is fine; watch/push when changes must land fast. Hybrid (push with poll fallback) is common. The Staff+ point: the read is always a local cache hit; the design question is purely *how fresh* and *how it's invalidated*.
2. **Watch fanout without overloading the store.** A naive design has every client watch etcd directly; at thousands of watchers this overloads the store (etcd is a consensus store, not a fanout engine). Kubernetes solves it with a **watch cache** in the API server — one component watches etcd, then fans changes out to all client watchers from an in-memory cache. This is the read-fanout layer: it decouples "how many clients watch" from "how much load etcd sees," exactly the read-amplification problem this archetype is about. The framing: put a caching/fanout tier between the durable source of truth and the many readers, so the source scales with *changes*, not *watchers*.
3. **Consistency choice + resilience (local-file fallback).** Not all config is equal: most (timeouts, feature toggles, tuning) tolerates **eventual consistency** with a bounded staleness window (AppConfig's 0–15 min Lambda window, Archaius's poll interval); a few (credentials, security kill switches) need **strong consistency / fast guaranteed propagation**. Match the mechanism to the value. Resilience is the other half: a client must keep running if the central config service is down, so it loads from a **local cached file** first and treats the central source as a refresh, not a hard dependency (Archaius pattern). The Staff+ judgment: pick the consistency/propagation per value class, and never let config distribution become a hard runtime dependency that takes the fleet down with it.

## Known failure modes
1. **Stale config after a change.** Clients keep using old values past the acceptable window. Production answer: watch/push (etcd Watch / streaming) for fast propagation where it matters; bounded poll intervals elsewhere; change callbacks so clients react without restart.
2. **Watch fanout overloads the store.** Thousands of clients watching etcd directly overwhelm it. Production answer: a watch-cache / fanout tier (K8s-style) between the store and watchers; the store scales with changes, not watcher count.
3. **Central config service outage takes down clients.** Clients can't start/serve without config. Production answer: local-file fallback (load last-known-good from disk), treat central as refresh-only, and bake safe defaults into the client.

## (Delineation note)
`distributed-config` is the read-heavy config-distribution + propagation problem; it shares push-vs-poll + client-cache patterns with `feature-flags`. The underlying coordination/consensus store (etcd, ZooKeeper, Consul) is infra-primitives — referenced, not re-derived. Here it's the client-local cache + watch fanout + consistency-per-value-class.

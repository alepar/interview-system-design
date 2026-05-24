# Reliability, Observability, Operations

Pattern reference for `/study-patterns 3K`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3K.

## SLI / SLO / SLA and Error Budgets

**Definition.** A Service Level Indicator (SLI) is a measured metric (e.g., request success rate); an SLO is the target value for that metric; an SLA is the contractual commitment; and an error budget is the allowed failure headroom (1 − SLO) consumed to gate deployment velocity.

**Canonical use.** Teams freeze feature releases and prioritize reliability work when the monthly error budget is exhausted, using SLOs as an objective arbiter between product and engineering.

**Production systems.** Google SRE (originator of the practice), PagerDuty for alerting against SLO burn rates.

**Alternatives.** Apdex score (simpler single-number satisfaction index); uptime-only SLAs (cruder, hides tail latency).

## Metrics, Logging, and Distributed Tracing

**Definition.** Metrics capture numeric time-series (counters, gauges, histograms); logs record discrete events with context; distributed tracing links spans across services via propagated trace IDs to reconstruct end-to-end request paths.

**Canonical use.** Use metrics for alerting and dashboards, logs for root-cause investigation, and traces for latency attribution across microservice call chains — the "three pillars of observability."

**Production systems.** OpenTelemetry (unified instrumentation standard), Jaeger and Zipkin (open-source trace backends), Prometheus + Grafana (metrics + dashboards).

**Alternatives.** Datadog, New Relic, Honeycomb (commercial all-in-one observability platforms); AWS X-Ray (managed tracing).

## Heartbeats and Gossip Protocols

**Definition.** Heartbeats are periodic liveness signals sent to a coordinator; gossip (SWIM-style) is a decentralized protocol where nodes randomly exchange membership state, propagating failures in O(log N) rounds without a central point of failure.

**Canonical use.** Use gossip-based failure detection in large clusters where a central health-checker would become a bottleneck or SPOF, tolerating O(1) false-positive rate with configurable suspicion windows.

**Production systems.** Apache Cassandra (SWIM gossip for ring membership), HashiCorp Consul (Serf/SWIM for cluster membership and health).

**Alternatives.** Centralized heartbeat to a ZooKeeper/etcd leader (simpler, SPOF risk); Phi Accrual failure detector (probabilistic, used in Akka/Cassandra for adaptive suspicion).

## Service Discovery

**Definition.** Service discovery is the mechanism by which clients locate healthy service instances at runtime, either via DNS (TTL-based) or a registry that services register with and clients query directly.

**Canonical use.** Use registry-based discovery (Consul, etcd) when you need sub-second propagation of instance failures; use DNS-based discovery when clients are heterogeneous and simplicity outweighs staleness.

**Production systems.** HashiCorp Consul (registry + health checks + DNS interface), etcd + CoreDNS (Kubernetes service discovery), AWS Route 53 health-check DNS.

**Alternatives.** Client-side load balancing with Eureka (Netflix OSS); service mesh sidecar discovery (Envoy/Istio) which moves discovery out of application code.

## Disaster Recovery: RTO/RPO and Active-Active vs Active-Passive

**Definition.** Recovery Time Objective (RTO) is the maximum acceptable downtime; Recovery Point Objective (RPO) is the maximum acceptable data loss window; active-active runs traffic in multiple regions simultaneously while active-passive keeps a standby that takes over on failure.

**Canonical use.** Choose active-active for near-zero RTO and RPO at the cost of cross-region write coordination complexity; choose active-passive when the application cannot tolerate split-brain and brief failover downtime is acceptable.

**Production systems.** AWS Route 53 + Aurora Global Database (active-passive failover), Google Spanner (active-active multi-region with external consistency).

**Alternatives.** Backup-and-restore (cheapest, highest RTO/RPO); warm standby (intermediate); pilot-light (minimal running standby, fast to scale up).

## Canary, Blue-Green, Feature Flags, and Progressive Rollout

**Definition.** Canary releases route a small traffic percentage to a new version; blue-green keeps two identical environments and switches all traffic atomically; feature flags decouple code deployment from feature activation; progressive rollout gradually widens the canary percentage.

**Canonical use.** Use canary + automated rollback triggered by SLO breach to catch regressions before they affect the full user population, making deployments a risk-management decision rather than a calendar event.

**Production systems.** LaunchDarkly (feature flags), Argo Rollouts (Kubernetes canary/blue-green), Meta's Gatekeeper (internal progressive rollout + kill-switch).

**Alternatives.** Shadow / dark traffic deployment (mirrors live traffic to new version without serving responses, zero user impact); A/B testing (canary for measuring business metrics, not just error rates).

## Chaos Engineering

**Definition.** Chaos engineering is the practice of intentionally injecting failures (instance kills, network delays, dependency outages) into production or staging to discover weaknesses before they cause unplanned outages.

**Canonical use.** Run steady-state chaos experiments (e.g., kill 10% of pods) with a defined hypothesis about system behavior, halting automatically if SLOs degrade beyond the error budget.

**Production systems.** Netflix Chaos Monkey / Chaos Gorilla / ChAP (originator), AWS Fault Injection Simulator (managed chaos experiments).

**Alternatives.** Tabletop failure-mode exercises (cheaper, no real risk, but misses unknown unknowns); game days (scheduled manual failure injection with on-call present).

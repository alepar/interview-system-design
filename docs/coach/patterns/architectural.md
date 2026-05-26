# Architectural Patterns

Source: `staff-engineer-study-guide.md`.

## Monolith vs Microservices vs Modular Monolith vs Service-Oriented

**Definition.** A monolith deploys all functionality as a single process; microservices decompose the system into independently deployable services with explicit API boundaries; a modular monolith enforces module isolation within one process (good encapsulation, simpler ops); service-oriented architecture (SOA) is a coarser-grained predecessor to microservices, typically using shared WSDL/SOAP contracts and an ESB.

**Canonical use.** A startup begins with a modular monolith to iterate quickly, then extracts high-scale or independently-deployed modules (e.g., the checkout payment flow) into microservices only when the deployment or scaling boundaries justify the operational cost.

**Production systems.** Shopify (modular Rails monolith), Netflix (microservices, ~700 services), Amazon (SOA → microservices transition post-2002 Bezos API mandate).

**Alternatives.** Serverless functions (extreme decomposition, event-driven, no server management); mini-services (coarser than microservices, shares databases within a bounded context).

## Client-Server vs Peer-to-Peer

**Definition.** Client-server assigns asymmetric roles — clients request, servers respond — centralizing state and control; peer-to-peer (P2P) treats all nodes as equals that can both request and serve data, distributing load and eliminating centralized infrastructure.

**Canonical use.** BitTorrent uses P2P to distribute file chunks across all downloaders (seeders/leechers), so a popular Linux ISO download accelerates as more peers acquire pieces, eliminating the need for a central high-bandwidth server; a live-streaming relay uses a hybrid CDN-P2P model to off-load edge bandwidth.

**Production systems.** BitTorrent (pure P2P), WebRTC P2P mesh for small video calls (Zoom/Meet fall back to SFU for > ~4 participants), IPFS (content-addressed P2P storage).

**Alternatives.** Hybrid CDN-P2P (Akamai, Peer5) for large-scale streaming; gossip-protocol cluster membership (P2P discovery within otherwise client-server systems, e.g., Cassandra).

## Event-Driven Architecture and Event Sourcing

**Definition.** Event-driven architecture decouples producers and consumers via an event bus — services react to domain events rather than calling each other directly; event sourcing stores the full sequence of immutable domain events as the system of record, deriving current state by replaying them rather than overwriting rows in place.

**Canonical use.** An e-commerce order service publishes `OrderPlaced` events to Kafka; inventory, fulfillment, and billing services subscribe independently, enabling each to scale and deploy without coordinating with the others; event sourcing allows replaying events to rebuild a read model or audit the complete history.

**Production systems.** Axon Framework (event sourcing + CQRS in Java), EventStoreDB, Confluent Platform (event-driven microservices on Kafka).

**Alternatives.** Request-driven (synchronous REST/gRPC calls, simpler but tighter coupling); change data capture (CDC) as a pragmatic event-sourcing approximation from an existing OLTP database.

## CQRS (Command Query Responsibility Segregation)

**Definition.** CQRS separates the write model (commands that mutate state) from the read model (queries that return data), allowing each side to be scaled, optimized, and deployed independently.

**Canonical use.** A social feed system writes posts via a command service that appends to an event log, and serves reads from a denormalized feed-cache (Redis or Cassandra) maintained by a projection consumer — the read model is optimized for low-latency fan-out queries, not normalized for writes.

**Production systems.** Microsoft Azure architecture guidance (CQRS + event sourcing reference pattern), Greg Young's original formulation (DDD community), used in high-scale read-heavy services at LinkedIn and Twitter feed systems.

**Alternatives.** Traditional CRUD with read replicas (simpler, same schema, limited optimization potential per side); materialized views (DB-native read-side optimization without full CQRS complexity).

## Strangler Fig Migration Pattern

**Definition.** The Strangler Fig pattern incrementally migrates a legacy monolith to a new architecture by routing individual features to new services one at a time, keeping the legacy system running throughout, until it can be fully decommissioned.

**Canonical use.** A team migrates a Rails monolith to microservices by placing a reverse proxy in front; new user-profile requests route to the new Go service while all other requests still hit the monolith, allowing independent release cadence and rollback per feature.

**Production systems.** Used extensively during Amazon's transition from monolith to SOA (2002–2007) and at many enterprise migrations documented in Martin Fowler's catalog.

**Alternatives.** Big-bang rewrite (high risk, long freeze); branch-by-abstraction (feature-toggle based in-process migration before deploying the replacement service).

## Lambda vs Kappa Architecture

**Definition.** Lambda architecture maintains two parallel pipelines — a batch layer for accurate historical computation and a speed layer for low-latency approximate results — merging both into a serving layer; Kappa architecture eliminates the batch layer by treating the event log as the single source of truth and reprocessing historical data by replaying the stream when corrections are needed.

**Canonical use.** A real-time analytics platform initially uses Lambda (Spark batch + Flink streaming) but migrates to Kappa (Flink only, Kafka log retention) to eliminate the dual-codebase maintenance burden once Flink's exactly-once semantics mature enough to trust for batch-equivalent accuracy.

**Production systems.** Netflix (Lambda-style with Spark batch + Flink streaming), LinkedIn (Kappa-style with Kafka + Samza), Twitter (migrated toward Kappa with Kafka Streams).

**Alternatives.** Pure batch (simpler, high latency); micro-batch (Spark Structured Streaming as a middle ground with mini-batches instead of true streaming).

## Domain-Driven Design (DDD) Boundaries

**Definition.** DDD organizes complex systems around bounded contexts — explicit linguistic and code boundaries within which a domain model is consistent — connected via well-defined context maps (shared kernel, customer/supplier, anti-corruption layer) to prevent model leakage between teams.

**Canonical use.** At a large e-commerce platform, the "Order" concept in the fulfillment bounded context (picking, packing, shipping) has different attributes and behavior than "Order" in the billing context (invoice, payment), so each context owns its own model and translates at the boundary via an anti-corruption layer.

**Production systems.** Described in Eric Evans' *Domain-Driven Design* (2003); widely adopted at Uber (domain ownership), Spotify (squad/tribe model aligns to bounded contexts), and Zalando (API-first bounded context teams).

**Alternatives.** Shared database with a single canonical model (simpler for small teams, causes coupling at scale); schema-per-service with no explicit DDD framing (microservice isolation without formal bounded-context design).

## Sidecar / Service Mesh (Envoy, Istio, Linkerd)

**Definition.** A sidecar is a co-deployed proxy container (e.g., Envoy) that intercepts all inbound/outbound traffic for a service, offloading cross-cutting concerns (mTLS, retries, circuit breaking, tracing) from application code; a service mesh coordinates a fleet of sidecars with a control plane (Istio, Linkerd) to provide cluster-wide policy, observability, and traffic management.

**Canonical use.** Lyft introduced Envoy as a sidecar so that service-to-service mTLS, distributed tracing (via x-trace headers), and circuit breaking were applied uniformly across all services without each team modifying their application code.

**Production systems.** Envoy proxy (Lyft, Cloudflare), Istio service mesh (Google, Salesforce), Linkerd (CNCF, lighter-weight Rust data plane), AWS App Mesh (Envoy-based managed mesh).

**Alternatives.** Client-side libraries (Netflix Hystrix, Ribbon — same features in-process, language-specific, harder to update uniformly); API gateway (handles north-south traffic but not east-west service-to-service).

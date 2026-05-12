# Trade-offs to Argue Both Sides Of

Pattern reference for `/study-patterns 3O`. Each entry is a trade-off pair. Field mapping: Definition = 1-sentence statement of what's being traded against what; Canonical use = 2-sentence summary of when each side wins; Production systems = examples of each side in production; Alternatives = related trade-offs to consider together.

Source: `staff-engineer-study-guide.md` §3O.

## SQL vs NoSQL

**Definition.** SQL databases offer relational schemas, ACID transactions, and expressive queries at the cost of horizontal write scalability; NoSQL databases sacrifice schema rigidity and often full ACID for horizontal scale, flexible data models, and high write throughput.

**Canonical use.** Choose SQL when data relationships are complex, transactions span multiple entities, or query patterns are unpredictable. Choose NoSQL when writes are massive, the data model is well-understood and denormalized (key-value, wide-column, document), or schema flexibility is required for rapid iteration.

**Production systems.** SQL: PostgreSQL (OLTP at scale with Citus sharding), Google Cloud Spanner (global SQL with strong consistency). NoSQL: Cassandra (wide-column, high write throughput), DynamoDB (key-value, managed, auto-scaling).

**Alternatives.** Strong vs eventual consistency (closely coupled — NoSQL choices often imply eventual consistency); NewSQL (e.g., CockroachDB, TiDB — SQL semantics at NoSQL scale, worth naming as a middle path).

## Strong vs Eventual Consistency

**Definition.** Strong (linearizable) consistency guarantees every read sees the most recent write, at the cost of higher latency and reduced availability under partitions; eventual consistency guarantees replicas converge given no new writes, allowing lower latency and higher availability.

**Canonical use.** Choose strong consistency for financial ledgers, inventory deduction, or any system where stale reads cause correctness violations. Choose eventual consistency for social feeds, caches, DNS, or shopping carts where brief staleness is acceptable and availability is paramount.

**Production systems.** Strong: Google Spanner, etcd, AWS Aurora (multi-AZ). Eventual: Cassandra (tunable, default eventual), DynamoDB (default eventually consistent reads), Amazon S3 (now offers strong read-after-write, historically eventual).

**Alternatives.** SQL vs NoSQL (overlapping concern); CAP/PACELC theorem (the theoretical frame for this trade-off); session consistency / monotonic reads (intermediate models worth naming).

## Push vs Pull / Fan-out-on-Write vs Fan-out-on-Read

**Definition.** Fan-out-on-write (push) pre-computes and delivers content to all followers' feeds at write time; fan-out-on-read (pull) aggregates a user's feed at read time by querying followed accounts.

**Canonical use.** Fan-out-on-write gives fast reads at the cost of write amplification (prohibitive for celebrities with millions of followers); fan-out-on-read is cheap to write but slow to read for users following many accounts. A hybrid approach pushes to most followers but pulls celebrity posts at read time.

**Production systems.** Fan-out-on-write: early Twitter home timeline (Memcached pre-populated per user). Fan-out-on-read: Instagram (pulls at read time). Hybrid: Twitter post-2013 timeline (celebrity pull + regular-user push).

**Alternatives.** Strong vs eventual consistency (fan-out-on-read naturally produces eventual consistency in feeds); push notifications vs polling (related delivery trade-off).

## Long Polling vs WebSockets vs Server-Sent Events (SSE)

**Definition.** Long polling holds an HTTP request open until the server has data (then client re-connects); WebSockets establish a full-duplex TCP connection for bidirectional streaming; SSE is a unidirectional server-to-client HTTP stream using chunked transfer.

**Canonical use.** Use WebSockets for bidirectional real-time communication (chat, multiplayer games, collaborative editing) where both client and server push frequently. Use SSE for server-to-client streams where client-to-server messages are infrequent (live dashboards, notifications); prefer long polling as a fallback when WebSocket infrastructure is unavailable or for infrequent updates.

**Production systems.** WebSockets: Slack, Discord, Figma (collaborative canvas). SSE: GitHub Copilot streaming responses, OpenAI API streaming. Long polling: legacy Comet-style systems, JIRA activity streams (historical).

**Alternatives.** gRPC bidirectional streaming (binary, efficient, service-to-service); MQTT (pub/sub over TCP, preferred in IoT); Push notifications (APNs/FCM — for mobile, app need not be in foreground).

## Stateful vs Stateless Services

**Definition.** Stateless services hold no session state between requests (any instance can handle any request); stateful services maintain in-memory or local session state, requiring clients to be routed to the same instance (sticky sessions) or state to be replicated.

**Canonical use.** Default to stateless for the web/API tier to enable free horizontal scaling and zero-downtime deploys; accept statefulness for performance-critical components (in-memory caches, game servers, streaming aggregators) where network round-trips to an external state store are too costly.

**Production systems.** Stateless: AWS Lambda (stateless by design), containerized microservices behind ALB. Stateful: Redis (in-memory state store), Kafka consumer groups (partition assignment is stateful), Apache Flink (stateful stream processing with checkpointed operator state).

**Alternatives.** Vertical vs horizontal scaling (stateful services resist horizontal scaling — related concern); session consistency (middle path: stateless service + external session store like Redis).

## Batch vs Stream Processing

**Definition.** Batch processing runs computation over a bounded, stored dataset on a schedule; stream processing continuously ingests and processes unbounded event streams with low latency.

**Canonical use.** Choose batch for periodic ETL, large-scale historical analytics, and ML training where latency requirements are measured in hours. Choose stream processing for real-time fraud detection, live dashboards, recommendation freshness, or any use case requiring sub-second reaction to new events.

**Production systems.** Batch: Hadoop MapReduce, Apache Spark (also supports streaming). Stream: Apache Flink (stateful, exactly-once), Apache Kafka Streams, Google Dataflow (unified batch/stream on Apache Beam).

**Alternatives.** Lambda architecture (batch layer for accuracy + speed layer for freshness — complex, mostly superseded); Kappa architecture (stream-only, reprocess from Kafka log — simpler operational model).

## Read-Through vs Write-Through Caching

**Definition.** Read-through caching loads data into the cache on a cache miss (lazy population); write-through caching writes to both the cache and the backing store synchronously on every write, keeping cache and DB always in sync.

**Canonical use.** Use read-through for read-heavy workloads where cache population on first miss is acceptable; use write-through when stale reads are unacceptable and writes are infrequent enough that the synchronous DB write cost is tolerable. Combine with write-behind (async write to DB) to reduce write latency when some data loss risk is acceptable.

**Production systems.** Read-through: AWS ElastiCache with application-managed cache-aside (equivalent pattern), DAX (DynamoDB Accelerator — managed read-through for DynamoDB). Write-through: Redis with a write-through proxy (e.g., Twemproxy configured for write-through); CPU L1/L2 caches (hardware write-through mode).

**Alternatives.** Write-behind / write-back (async DB write, risks data loss on cache failure); cache-aside / lazy loading (application manages cache explicitly — most common in practice, not strictly read-through).

## REST vs gRPC vs GraphQL

**Definition.** REST uses HTTP verbs and resource URLs with JSON payloads (flexible, human-readable, widely supported); gRPC uses HTTP/2 with Protocol Buffers for typed, binary, low-latency RPC (efficient, strongly typed, ideal for service-to-service); GraphQL lets clients specify exactly which fields they need in a single query (flexible, avoids over/under-fetching, complex server-side).

**Canonical use.** Use REST for public-facing APIs where broad client compatibility and cacheability matter. Use gRPC for internal microservice communication requiring low latency, strong typing, and streaming. Use GraphQL for mobile or frontend clients with diverse, evolving data needs to reduce over-fetching and round trips.

**Production systems.** REST: Stripe API, Twitter/X public API. gRPC: Google internal APIs, etcd API, Kubernetes API (uses protobuf internally). GraphQL: GitHub API v4, Shopify Storefront API, Meta's internal graph queries.

**Alternatives.** WebSockets (for bidirectional streaming — orthogonal but sometimes replaces REST for real-time); tRPC (type-safe RPC for TypeScript full-stack without code generation); Thrift (Facebook's binary RPC, predates gRPC).

## Vertical vs Horizontal Scaling

**Definition.** Vertical scaling (scale-up) adds CPU, RAM, or faster storage to a single machine; horizontal scaling (scale-out) adds more machines and distributes load across them.

**Canonical use.** Choose vertical scaling for stateful systems (databases with shared state) where horizontal distribution adds unacceptable coordination complexity, or when you need a fast short-term fix. Choose horizontal scaling for stateless tiers, when you need commodity hardware economics, geographic distribution, or fault isolation — and whenever vertical scaling hits the hardware ceiling.

**Production systems.** Vertical: large PostgreSQL primaries (up to 192-core cloud instances), Redis single-node (scales vertically before sharding). Horizontal: Cassandra (designed for horizontal scale-out), Kubernetes stateless deployments, CDN edge nodes.

**Alternatives.** Read replicas (horizontal read scaling without full scale-out complexity); database sharding (horizontal for stateful storage — highest complexity).

## Monolith vs Microservices

**Definition.** A monolith deploys all functionality as a single unit (simple ops, tight coupling, hard to scale independently); microservices decompose the system into independently deployable services (loose coupling, independent scaling, high operational complexity).

**Canonical use.** Start with a monolith (or a modular monolith) until team/organizational boundaries and independent scaling needs are proven — premature decomposition introduces distributed systems complexity with no benefit. Decompose into microservices when specific components have genuinely different scaling requirements, failure domains, or team ownership boundaries that a monolith cannot accommodate.

**Production systems.** Monolith: Shopify (modular Rails monolith at massive scale), Stack Overflow (monolith by choice). Microservices: Netflix (~700 microservices), Amazon (SOA/microservices mandate since 2002).

**Alternatives.** Service-oriented architecture (SOA — larger grained than microservices, SOAP-era predecessor); modular monolith (strong internal module boundaries without network boundaries — best of both for many teams); strangler fig pattern (incremental migration from monolith to microservices).

## Build vs Buy

**Definition.** Building a component in-house gives maximum control and competitive differentiation potential; buying (SaaS, open-source, or managed cloud service) provides faster time-to-value, proven reliability, and shifts operational burden to the vendor.

**Canonical use.** Buy (or use managed services) for undifferentiated infrastructure — databases, queues, auth, observability — unless scale, cost, or competitive need justify the engineering cost of ownership. Build only when the capability is core to your competitive advantage, vendor lock-in risk is unacceptable, or off-the-shelf options cannot meet your requirements.

**Production systems.** Buy: Twilio (SMS/voice), Stripe (payments), Datadog (observability) — adopted by most startups and mid-size companies. Build: Uber building its own dispatch engine (competitive core), Google building Spanner (no external option met requirements), Netflix building its own CDN (Open Connect) after outgrowing commercial CDNs.

**Alternatives.** Open-source as a middle path (control + community, but still own operations); hybrid (buy the generic version, extend for differentiation — e.g., use Kafka but write custom connectors).

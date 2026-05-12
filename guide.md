# The Staff Engineer's System Design Interview Study Guide

**TL;DR**
- The modern FAANG system design bank can be compressed to ~10 archetypes (caching/read-heavy, fan-out, real-time messaging, concurrent contention, UGC pipelines, geo/proximity, search/indexing, collaborative/conflict-resolution, ML-in-the-loop, and infrastructure primitives); a focused ~100-question shortlist organized this way covers almost every prompt asked at Meta, Google, Amazon, Uber, Stripe, OpenAI, and similar firms.
- Evaluation at every top company rolls up to four common dimensions — Problem Navigation, Solution Design, Technical Excellence, and Communication — but the *bar* slides by level: L4/E4 = correct high-level architecture, L5/E5 = unprompted deep dives on 2–3 components with named technology trade-offs, L6/E6+ = drive the conversation through operational concerns, cost, multi-region failure modes, and build-vs-buy reasoning.
- Mastery of roughly 30 distributed-systems patterns (consistent hashing, CRDT/OT, geohashing/H3, fan-out variants, LSM-tree vs B-tree, idempotency keys, CDC, two-phase commit/saga, leader election, etc.) is what enables you to *compose* answers across the question bank rather than memorize them.

---

## SECTION 1 — Comprehensive Question Bank (organized by category)

Sources surveyed: Hello Interview's 28 published breakdowns and community list; donnemartin/system-design-primer; ashishps1/awesome-system-design-resources; AlgoMaster; ByteByteGo / Alex Xu's *System Design Interview* Vols. 1–2 (16 chapters in V1); Educative's "Grokking" catalog; Exponent's per-company question lists (curated lists of "62 [questions] for Google alone, with similar coverage for Amazon, Meta, and Microsoft"); IGotAnOffer and Onsites.fyi guides; and candidate reports on Blind, LeetCode Discuss, and 1Point3Acres. Where a question spans categories I tag the secondary category in brackets.

### Category 1 — High-throughput read systems with caching
| # | Prompt | Companies reported | Notes |
|---|---|---|---|
| 1.1 | Design TinyURL / Bitly (URL shortener) | Google, Amazon, Uber, Stripe, Microsoft, Atlassian, Pinterest | Most common entry-level prompt; Hello Interview's "Easiest" of 28 breakdowns |
| 1.2 | Design a Content Delivery Network (CDN) | Akamai, Cloudflare, Meta | Often a follow-up |
| 1.3 | Design DNS / a hierarchical name resolution service | Google, Cloudflare | Recursion, caching, anycast |
| 1.4 | Design Search Autocomplete / Typeahead | Google, Meta, Amazon (Alexa), LinkedIn | Trie + top-k; Alex Xu Ch. 13 |
| 1.5 | Design a Pastebin | Generic | donnemartin primer canonical |
| 1.6 | Design a Distributed Cache (Redis/Memcached clone) | Meta E6+ ("Design Memcached"), Amazon | Hello Interview Hard |
| 1.7 | Design a Price-Tracking Service (CamelCamelCamel) | Amazon | Hello Interview Medium |
| 1.8 | Design a News Aggregator (Google News) | Google | Hello Interview Easy [also Cat 7] |
| 1.9 | Design a Stock Price Quote Distribution System | Robinhood, trading firms | Hello Interview Hard ("Robinhood") |
| 1.10 | Design a Top-K Most-Viewed YouTube Videos service | Amazon, Bloomberg, Meta, Pinterest, YouTube | Hello Interview Hard [also Cat 9] |

### Category 2 — Fan-out / feed systems
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 2.1 | Design Twitter / X timeline | Meta, Twitter, generic | Canonical fan-out-on-write vs fan-out-on-read hybrid |
| 2.2 | Design Facebook News Feed | Meta | Hello Interview Medium; EdgeRank scoring [+ Cat 9] |
| 2.3 | Design Instagram (feed + posting) | Meta, Pinterest | Hello Interview Hard [also Cat 5] |
| 2.4 | Design a Notification System (push/SMS/email) | Amazon (Bar Raiser), Twilio, Meta | Alex Xu Ch. 10 |
| 2.5 | Design Reddit (threaded comments + hot-sort) | Reddit, generic | Time-decay scoring |
| 2.6 | Design "People You May Know" / friend suggestion | Meta, LinkedIn | Graph traversal [+ Cat 9] |
| 2.7 | Design Live Comments for Facebook Live | Meta | Hello Interview Medium |
| 2.8 | Design YouTube/Twitch Live-Chat for 1M concurrent viewers | YouTube, Twitch, Discord | Hierarchical fan-out [Cat 3] |
| 2.9 | Design Pinterest home feed | Pinterest | Multi-stage retrieval + ranking [Cat 9] |
| 2.10 | Design TikTok For-You page | ByteDance, Meta | Cat 9 dominant |

### Category 3 — Real-time messaging / streaming
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 3.1 | Design WhatsApp / Messenger (1:1 + group chat) | Meta, Microsoft, generic | Hello Interview Medium; Alex Xu Ch. 12 |
| 3.2 | Design Slack | OpenAI, Coinbase, Databricks | Hello Interview community; channels + threads + presence |
| 3.3 | Design Discord (channels with hundreds of thousands of members) | Discord | Per Discord's own engineering blog *How Discord Stores Trillions of Messages* (2023): "At the beginning of 2022, it had 177 nodes with trillions of messages" on Cassandra, before migrating to 72 ScyllaDB nodes — reducing node count by ~59% |
| 3.4 | Design Zoom / Google Meet (group video conferencing) | Zoom, Google, generic | SFU vs MCU, WebRTC, UDP fallback |
| 3.5 | Design a Live Streaming service (Twitch, YouTube Live, FB Live) | Meta, Twitch, YouTube | HLS/DASH, encoder farm, edge cache |
| 3.6 | Design a Real-time Collaborative Whiteboard | Excalidraw, Miro | [Also Cat 8] |
| 3.7 | Design a Push Notification delivery backbone | Apple APNs / Firebase | Last-mile delivery, retries |
| 3.8 | Design Strava activity sharing / live-tracking | Strava | Hello Interview Medium |
| 3.9 | Design FB Live Comments with 1M viewers | Meta | Hello Interview Medium |
| 3.10 | Design an Online Multiplayer Game / chess service | Lichess | Hello Interview community |

### Category 4 — Concurrent access to limited resources
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 4.1 | Design Ticketmaster / BookMyShow | Amazon, Meta, generic | Hello Interview Medium; OCC vs pessimistic lock vs Redis distributed lock |
| 4.2 | Design a Hotel-booking / Airbnb reservation system | Airbnb, Booking.com | Calendar overlap, inventory locking |
| 4.3 | Design a Flash Sale system (limited inventory drop) | Amazon, Shopify, Alibaba | Token issuance + queue + idempotency |
| 4.4 | Design Uber/Lyft ride-matching (driver dispatch) | Uber, Lyft, DoorDash | [Also Cat 6] |
| 4.5 | Design an Online Auction (eBay) | eBay | Hello Interview Medium; bid ordering, OCC |
| 4.6 | Design an Online Stock Exchange / Matching Engine | Robinhood, trading firms | Microsecond latency, deterministic ordering |
| 4.7 | Design a Parking Lot reservation system | Generic | Often LLD/OOD-flavored |
| 4.8 | Design a Flight Booking system | Generic | Multi-leg consistency |
| 4.9 | Design a Distributed Locking service (Chubby/ZooKeeper-style) | Google | Hello Interview Hard |
| 4.10 | Design a Distributed Counter / Like Counter (sharded counters) | YouTube, Meta | Sharded counters; prevents hot rows |

### Category 5 — User-generated content pipelines
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 5.1 | Design YouTube (video upload + streaming) | YouTube, Meta, Amazon | Hello Interview Hard; transcoding ladder + CDN |
| 5.2 | Design Instagram photo upload + feed | Meta, Pinterest | Hello Interview Hard |
| 5.3 | Design Dropbox / Google Drive (file sync + share) | Dropbox, Google, Meta, Microsoft, OCI | Hello Interview Easy; chunking + dedup |
| 5.4 | Design Spotify / a music streaming service | Spotify | AlgoMaster Medium |
| 5.5 | Design Netflix | Netflix | Adaptive bitrate streaming |
| 5.6 | Design TikTok upload pipeline | ByteDance | Cat 5 + Cat 9 |
| 5.7 | Design Distributed Cloud Storage / S3 | Amazon, generic | Hello Interview Hard equivalent |
| 5.8 | Design a Photo-sharing service (Flickr) | Meta | donnemartin primer |
| 5.9 | Design GitHub / a Git hosting service | GitHub, GitLab | Cat 5 + Cat 8 |
| 5.10 | Design GitHub Actions (CI/CD orchestrator) | GitHub | Hello Interview community Hard |

### Category 6 — Geo / proximity systems
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 6.1 | Design Uber / Lyft / DoorDash (full ride or delivery) | Uber, Lyft, DoorDash, Meta | Hello Interview Hard; H3 / geohash + WebSocket |
| 6.2 | Design Yelp / Nearby places search | Yelp, generic | Hello Interview Medium; quadtree / geohash |
| 6.3 | Design Google Maps (routing + ETA) | Google | Road graph + Dijkstra / contraction hierarchies |
| 6.4 | Design Find My Friends / Nearby Friends | Meta | Privacy + last-known-location indexing |
| 6.5 | Design a Local Delivery Service (Gopuff) | Gopuff | Hello Interview Easy |
| 6.6 | Design Tinder (proximity + matching) | Match Group | Hello Interview Medium |
| 6.7 | Design a Real-time Surge-Pricing engine | Uber | Senior SDE example reported on Medium |
| 6.8 | Design a Real-time GPS tracking system at scale | Uber, Tesla | ~250K writes/sec design target |
| 6.9 | Design a Geofencing system | Generic | Cat 6 + Cat 9 |
| 6.10 | Design a Smart-parking system | Generic | System Design Space catalog |

### Category 7 — Search and indexing
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 7.1 | Design a Web Crawler | Google, Meta, Amazon, eBay, Datadog, Atlassian | Hello Interview Hard; URL frontier + politeness |
| 7.2 | Design Google Search (end-to-end) | Google | Inverted index + BM25 + PageRank, document partitioning |
| 7.3 | Design Elasticsearch / a distributed search cluster | Generic | Lucene segments, refresh interval |
| 7.4 | Design Facebook Post Search | Meta | Hello Interview Medium |
| 7.5 | Design Twitter Search / Earlybird | Twitter | Real-time tweet search, sub-10s latency |
| 7.6 | Design a Code Search system | GitHub, Google | Token + n-gram indexing |
| 7.7 | Design an E-commerce Product Search & autocomplete | Amazon, Shopify | Cat 7 + Cat 1 + Cat 9 |
| 7.8 | Design Twitter Trending Topics | Twitter | Top-K + windowed counts |
| 7.9 | Design a Log Search system (Splunk/Datadog Logs) | Datadog, Splunk | Time-partitioned shards |
| 7.10 | Design a Vector / Semantic Search system | OpenAI, Pinecone | ANN, HNSW; Cat 7 + Cat 9 |

### Category 8 — Conflict resolution / collaborative systems
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 8.1 | Design Google Docs (real-time collaborative editor) | Google, Meta, Dropbox | Hello Interview Hard; OT (current Google Docs) vs CRDT trade-off |
| 8.2 | Design Figma | Figma | CRDT + multiplayer cursors |
| 8.3 | Design a Collaborative Whiteboard (Miro/Excalidraw) | Miro, Atlassian | CRDT-friendly |
| 8.4 | Design Notion-style block-based docs | Notion | Block CRDTs |
| 8.5 | Design a distributed Git / version-control backend | GitHub, GitLab | Content-addressed storage + merge |
| 8.6 | Design a Collaborative Code Editor (VS Code Live Share / Replit) | Replit, Microsoft | Yjs/CRDT |
| 8.7 | Design an Online Code Editor / Sandbox (LeetCode) | LeetCode | Hello Interview Medium; container orchestration [+ Cat 4] |
| 8.8 | Design a Wiki / Wikipedia | Wikimedia | Last-writer-wins + edit history |
| 8.9 | Design Multi-master Replication for an ACID DB | Google, Cloudflare | Spanner-style consensus |
| 8.10 | Design Calendar with shared editing | Google, Microsoft | Conflict windows + invites |

### Category 9 — ML-in-the-loop serving
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 9.1 | Design a YouTube/TikTok recommendation engine | YouTube, ByteDance, Meta | Two-tower retrieval + reranker |
| 9.2 | Design Instagram/Pinterest home-feed ranking | Meta, Pinterest | Candidate-gen → ranking → re-rank funnel |
| 9.3 | Design an Ad Click Prediction / CTR system | Google, Meta | DLRM-style models, online learning |
| 9.4 | Design an Ad Click Aggregator (Google AdSense-style) | Google | Hello Interview Hard; exactly-once + late events with Flink |
| 9.5 | Design a Fraud Detection system (Stripe) | Stripe, banks | Velocity features + graph features |
| 9.6 | Design a Content Moderation / harmful-content system | Meta, TikTok, OpenAI | Multimodal classification |
| 9.7 | Design a Spam / "is this a bot" detection system | Meta, X | Imbalanced classification |
| 9.8 | Design a Search Ranking system | Google, Amazon, Meta | LambdaMART → BERT rerank |
| 9.9 | Design an Evaluation Framework for Ranking models (A/B) | Meta | "ads ranking evaluation" prompt |
| 9.10 | Design ChatGPT / a chatbot or RAG service | OpenAI | Hello Interview community Hard; vector DB + LLM serving |

### Category 10 — Infrastructure primitives
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 10.1 | Design a Distributed Rate Limiter | Stripe, Cloudflare, Meta | Hello Interview Medium; token bucket + Redis |
| 10.2 | Design a Unique ID Generator (Snowflake) | Twitter, Instagram | Alex Xu Ch. 7 |
| 10.3 | Design a Distributed Message Queue (Kafka/SQS) | Amazon, LinkedIn, Meta | Hello Interview deep-dive |
| 10.4 | Design a Distributed Task / Job Scheduler | Apache Airflow, Meta | Hello Interview Hard |
| 10.5 | Design an API Gateway | AWS, generic | Hello Interview deep-dive |
| 10.6 | Design a Distributed Key-Value Store (DynamoDB clone) | Amazon, Meta | Alex Xu Ch. 6 |
| 10.7 | Design a Metrics / Monitoring system (Datadog) | Datadog | Hello Interview Hard |
| 10.8 | Design a Distributed Logging / Tracing system | Datadog, Lightstep | Cat 10 + Cat 7 |
| 10.9 | Design a Feature Flag / A/B test platform | LaunchDarkly, Meta | Cat 10 + Cat 9 |
| 10.10 | Design a Payments / Wallet system (Stripe) | Stripe, PayPal | Hello Interview Hard; idempotency keys + double-entry ledger |
| 10.11 | Design a Distributed Locking Service (Chubby/ZooKeeper) | Google | Cat 10 + Cat 4 |
| 10.12 | Design a Code Deployment / Blue-Green system | Generic | AlgoMaster Hard |

### Cross-category meta-questions
- **"Design for 10× traffic"** — appears as a follow-up on Amazon SDE2/SDE3 loops.
- **"Reverse system design"** — Meta occasionally asks candidates to critique an existing architecture rather than build one (interviewing.io reports this for E6).
- **Low-level/infrastructure variants** at E6+ Meta and L6+ Google: "Design Memcached," "Design Redis," "Design Kafka," "Design Cassandra/DynamoDB," "Design a TCP load balancer." Per interviewing.io quoting an active Meta interviewer: *"In E6 or above interviews, you will most likely be asked 'Design Redis', or 'Design Kafka', or 'Design Memcached.'"*

---

## SECTION 2 — Evaluation Dimensions

### The Four Universal Competencies

Across Meta, Google, Amazon, and (per Hello Interview's published framework, written by ex-Meta/Amazon hiring managers) virtually every major employer, the rubric collapses to four buckets even when the wording differs:

1. **Problem Navigation** — how you decompose an ambiguous prompt into prioritized functional and non-functional requirements, ask clarifying questions, and identify the core hard problem before drawing boxes. Per FAANGPath's reproduction of Meta interviewer briefings: *"How do you approach a high-level problem while being mindful of the constraints, resources, objectives, and bottlenecks? Are you asking the right questions and identifying the correct elements to reduce ambiguity?"*
2. **Solution Design** — your ability to build a workable, scalable, resilient architecture that satisfies the requirements while balancing performance, scalability, maintainability, and cost. Per FAANGPath: *"how you consider the bigger pictures when trying to determine a workable solution for your question."*
3. **Technical Excellence** — depth of knowledge: choosing concrete technologies (PostgreSQL vs DynamoDB, Kafka vs SQS, Redis vs Memcached), reasoning about CAP/PACELC trade-offs, anticipating failure modes, and dive-deeping into 2–3 components. Per IGotAnOffer: *"your ability to dive deep into technical details, identify multiple options, assess trade-offs, explain your choices given the requirements, and also point out possible points of failure."*
4. **Technical Communication & Collaboration** — clarity of explanation, responsiveness to interviewer feedback, ability to be hinted toward a better answer without becoming defensive, drawing legible diagrams quickly. Hello Interview explicitly names *"being defensive or argumentative when receiving feedback"* as a common failure mode.

Approximate rubric weights (per Design Gurus Substack's published synthesis, written by FAANG-aligned coaches): Requirements Gathering ≈ 10-15%, High-Level Architecture ≈ 20-25%, Deep Dive ≈ 30% (the single highest-weighted dimension), Trade-offs & Failure Modes ≈ 15-20%, Communication ≈ 10-15%.

### Company-Specific Mechanics

**Meta** — Officially calls the round either "System Design" (infrastructure SWEs) or "Product Architecture" (product SWEs); both use the same four-competency rubric. Each interviewer records a binary Hire / No Hire with a confidence note, which aggregates into the familiar Strong Hire / Hire / Weak Hire / No Hire / Strong No Hire labels at debrief. The loop lead (your behavioral interviewer) drives the hiring committee submission. E5 candidates get one system design round; E6 gets two; at Staff (E6+) the mandate per interviewing.io is *"At Staff level and above, it's a mandate that candidates can't get hired if they don't pass both system design rounds."* E6 candidates who fail one round but ace others can get a "mulligan" — an extra round to resolve split panels. Down-leveling from E6 to E5 is common; the most-cited cause is "specific technical depth concerns in system design rounds." Meta added an **AI-assisted coding round in October 2025**; per an internal Meta message reported by 404 Media (Oct 2025): *"a new type of coding interview in which candidates have access to an AI assistant. This is more representative of the developer environment that our future employees will work in, and also makes LLM-based cheating less effective."*

**Google** — System design is graded primarily against two of Google's four published signals: **Role-Related Knowledge (RRK)** and **General Cognitive Ability (GCA)**. Leadership and Googleyness signals come more from behavioral and coding rounds. A former Google engineer confirmed on Quora that the historical numeric scale ran 1.0–4.0: *"We used to have a numeric scale instead, going from 1.0 to 4.0 (with 4.0 standing for Chuck Norris-like superhuman abilities), and innumerable engineer hours were lost discussing the semantics of that or another score on that scale."* It was replaced by a six-bucket scale: **Strong No Hire / No Hire / Lean No Hire / Lean Hire / Hire / Strong Hire**. Per interviewing.io's *Senior Engineer's Guide to Google Interviews*: *"Google's hiring committee consists of four to five engineers and engineering managers who have not interviewed you, with the intent of making hiring decisions as objective as possible."* L3 candidates typically skip system design entirely; L4 sometimes gets a scoped version; L5 gets one mandatory round; L6+ gets multiple. The committee is also where leveling decisions are made. interviewing.io quotes an active Google interviewer: *"Getting five scores of 'Leaning Hire' is most likely to result in a 'No Hire' decision. I have seen many cases where the candidates got five scores of 'Leaning Hire', and the recruiter gave them positive feedback too, but the candidate got rejected."*

**Amazon** — Uniquely, there is **no separate system-design rubric**; every interviewer is assigned 1–3 of the 16 Leadership Principles and judges the candidate "below the bar / meets the bar / raises the bar" against the 50th-percentile-of-current-Amazon-employees benchmark (per Carrus.io citing John Vlastelica, the original Bar Raiser program designer). The **Bar Raiser** — an externally-trained interviewer from outside the hiring team with typically 100+ interviews under their belt — has veto power and effectively decides level (Blind: *"Level is determined by the bar raiser, non negotiable"*). Common LP mappings for the system design round: *Are Right A Lot*, *Invent and Simplify*, *Dive Deep*, *Insist on the Highest Standards*. Strong design answers are paired with explicit metric-backed Leadership Principle stories ("we reduced p99 latency from 800ms to 120ms by …").

### Level-Specific Expectations (synthesized across companies)

| Level | Google / Meta / Amazon equivalents | What a "Strong Hire" looks like |
|---|---|---|
| **Junior (L3/E3/SDE1)** | New-grad to ~2 YOE | System design is often skipped or scoped tiny; show structured thinking (requirements → entities → API → diagram), pick one reasonable database with one-sentence justification, *admit knowledge gaps* honestly. |
| **Mid (L4/E4/SDE2)** | ~3–5 YOE | Clean high-level diagram, functional API contract, identifies obvious bottlenecks, articulates one good and one bad trade-off per major decision. Per Hello Interview's Ticketmaster bar: *"clearly defined the API endpoints and data model, landed on a high-level design that is functional… solve the No Double Booking problem with at least the Good Solution."* |
| **Senior (L5/E5/SDE3)** | ~5–8 YOE | Drives the design independently, *proactively* dives deep on 2-3 components, names specific technologies with justified trade-offs (e.g., "Redis sorted set for geospatial because we need 250K writes/sec and TTL cleanup"), discusses failure modes. Per Design Gurus: *"The deep dive is what separates L5 from L4."* |
| **Staff (L6/E6/Principal)** | ~8+ YOE | Drives the entire conversation. Proactively raises operational concerns (monitoring, deployment, rollback, on-call), cost reasoning ("this costs ~$50K/mo in cloud; the biggest lever is batching the analytics pipeline"), multi-region failure, build-vs-buy. May get low-level infrastructure prompts ("Design Memcached," "Design Kafka") instead of product prompts. |
| **Principal / Distinguished (L7+/E7+)** | 10+ YOE | Defines the problem before solving it, pushes back on requirements that don't make engineering sense, designs for organizational structure ("this needs to be a platform that 10+ teams use without stepping on each other"). |

**The single most common reason for downleveling** at Staff is delivering an L5-quality answer at L6 — i.e., producing a clean architecture but waiting for the interviewer to *ask* about failure scenarios, cost, and operations. The L6 bar requires you to volunteer those topics unprompted.

### Common Failure Modes (red flags)
- Skipping requirements/clarifying questions and jumping straight to drawing boxes ("memorized template" signal).
- Naming technologies without justification ("I'll use Kafka" with no follow-up on why over SQS or Kinesis).
- Defensiveness when challenged. Hello Interview lists *"being defensive or argumentative when receiving feedback"* as the most common communication failure.
- Going too deep too early on a non-critical component.
- Ignoring back-of-envelope numbers entirely.
- At L6+, *failing to lead* — waiting for the interviewer to drive the deep dives.

---

## SECTION 3 — Comprehensive Patterns & Concepts Reference

Each pattern is tagged with the categories (1–10) where it most commonly applies.

### 3A. Core Concepts (every interview)
- **Scalability** (vertical vs horizontal; stateless services) — all
- **Availability vs Consistency vs Partition Tolerance** (CAP) and **PACELC** — all
- **Latency vs Throughput vs Bandwidth** — all
- **SPOF (Single Points of Failure) and Fault Tolerance** — all
- **Numbers to know** (Jeff Dean's latency table; "1MB sequential read from memory ≈ 250µs, SSD ≈ 1ms, disk ≈ 20ms"; cross-DC RTT ≈ 50–150ms) — all
- **Back-of-envelope estimation** (QPS, storage, bandwidth, cache size) — all

### 3B. Networking and Transport
- **DNS** including anycast and TTL trade-offs — Cat 1, 10
- **TCP vs UDP**; **QUIC** for low-latency — Cat 3, 6
- **WebSocket vs Long Polling vs SSE** — Cat 2, 3, 6, 8
- **WebRTC** and **SFU vs MCU** for media — Cat 3
- **HTTP/1.1 vs 2 vs 3**, gRPC, REST vs GraphQL vs RPC — all
- **TLS termination, mTLS** — Cat 10
- **CDN** (push vs pull, edge invalidation) — Cat 1, 5
- **Reverse proxy / API Gateway** (auth, rate-limit, request shaping) — Cat 10

### 3C. Load Balancing
- **L4 vs L7 load balancers** — all
- **Algorithms**: round-robin, weighted RR, least-connections, least-response-time, IP hash, consistent-hash — all
- **Anycast routing**, GeoDNS, latency-based routing — Cat 1, 6
- **Sticky sessions and the cost of breaking statelessness** — Cat 3

### 3D. Storage and Databases
- **SQL (B-tree storage engines: PostgreSQL, MySQL InnoDB)** — default unless you can justify otherwise — Cat 4, 5, 8, 10
- **NoSQL families**: key-value (Redis, DynamoDB), document (MongoDB), wide-column LSM-tree (Cassandra, ScyllaDB, BigTable, HBase), graph (Neo4j) — Cat 1-10 depending
- **Newer**: time-series (InfluxDB, Prometheus TSDB, TimescaleDB), search (Elasticsearch/OpenSearch), vector (Pinecone, Weaviate, pgvector, Milvus), columnar OLAP (ClickHouse, Snowflake, Redshift), geospatial (PostGIS, Redis Geo) — Cat 1, 7, 9
- **ACID vs BASE**; isolation levels (Read Committed, Repeatable Read, Snapshot, Serializable) — Cat 4, 10
- **Indexes**: B-tree, hash, GiST/SP-GiST, GIN (inverted), bitmap, covering indexes — Cat 4, 7
- **Sharding strategies**: range, hash, geo, directory; resharding pain — Cat 1-10
- **Replication**: leader-follower, multi-leader, leaderless (Dynamo-style), sync vs async; read replicas — all
- **Federation / partitioning by feature** — Cat 5
- **Denormalization** for read paths — Cat 2
- **Materialized views, CQRS** — Cat 2, 9
- **Two-phase commit (2PC), Saga (choreography/orchestration), outbox pattern** — Cat 4, 10

### 3E. Caching
- **Where to cache**: client, CDN, reverse proxy, app server, distributed cache, DB query cache, object cache — all
- **Strategies**: cache-aside, write-through, write-behind/write-back, refresh-ahead — Cat 1, 2
- **Eviction**: LRU, LFU, FIFO, TTL, random, ARC; size-tiered for large objects — Cat 1
- **Stampede protection**: request coalescing, probabilistic early expiration, locks — Cat 1, 4
- **Hot-key mitigation**: sharded counters, jittered TTL, replication of hot keys — Cat 2, 10
- **Consistent hashing with virtual nodes** for cache topology changes — Cat 1, 10

### 3F. Asynchronous / Streaming
- **Message queue vs publish-subscribe** — Cat 2, 4, 10
- **Kafka**: partitions for ordering, consumer groups, log compaction, ISR, exactly-once semantics — Cat 9, 10
- **At-least-once + idempotent handler** as the practical replacement for "exactly-once" — Cat 4, 9, 10
- **Stream processing**: Flink, Spark Streaming, Kinesis; **windows** (tumbling, sliding, session), watermarks, late events — Cat 9
- **Change Data Capture (CDC)** with Debezium / Kafka Connect — Cat 5, 9, 10
- **Backpressure and dead-letter queues** — Cat 3, 10
- **Circuit breaker, bulkhead, retry-with-exponential-backoff-and-jitter** — Cat 10

### 3G. Consistency / Coordination
- **Quorum reads/writes (R + W > N)** — Cat 10
- **Vector clocks, version vectors** — Cat 5, 8
- **Hinted handoff, read repair, anti-entropy / Merkle trees** — Cat 5, 10
- **Consensus protocols**: Paxos, Raft (etcd, Consul, CockroachDB), ZAB (ZooKeeper) — Cat 4, 8, 10
- **Leader election**, fencing tokens — Cat 4, 10
- **Distributed locking** (Redis Redlock with caveats, ZooKeeper, Chubby) — Cat 4
- **Lease, write-ahead log, segmented log, high-water mark, generation clocks** — Cat 10
- **Operational Transform (OT)** vs **CRDTs** (state-based and op-based; Yjs, Automerge) — Cat 8
- **Optimistic vs pessimistic concurrency control (OCC vs row-level locks)** — Cat 4

### 3H. Data Structures Worth Naming
- **Bloom filter** (membership; LSM-tree read optimization; web-crawler URL seen-set) — Cat 1, 5, 7
- **Count-min sketch, HyperLogLog** (approximate cardinality / top-K with bounded memory) — Cat 1, 9
- **Skip list** (Redis sorted sets, LevelDB memtable) — Cat 1, 4, 6
- **Trie / suffix tree / FST** (autocomplete; Lucene term dictionary) — Cat 1, 7
- **Inverted index, posting lists with BM25 scoring** — Cat 7
- **Geohash, S2 cells, Uber H3 hexagons, quadtree, R-tree, k-d tree** — Cat 6
- **LSM-tree vs B-tree** as the fundamental write-vs-read storage trade-off — Cat 5, 10
- **Merkle tree** (anti-entropy, content-addressed storage, Git) — Cat 5, 8
- **Consistent hash ring** — Cat 1, 10
- **Roaring bitmaps** (large set membership) — Cat 7
- **HNSW / IVF-PQ** (approximate nearest-neighbor for vector search) — Cat 7, 9

### 3I. API and Idempotency Patterns
- **Idempotency keys** (Stripe pattern: client UUID, server dedup table with TTL) — Cat 4, 10
- **Optimistic concurrency with version numbers / ETags** — Cat 4, 8
- **Pagination**: offset, cursor, keyset — Cat 1, 2, 7
- **Webhooks vs polling vs SSE vs WebSockets** — Cat 3
- **API versioning** (URI, header, content-negotiation) — Cat 10

### 3J. Architectural Patterns
- **Monolith vs microservices vs modular monolith vs service-oriented** — all
- **Client-server, peer-to-peer (BitTorrent / live-streaming relay)** — Cat 3, 5
- **Event-driven architecture**, event sourcing — Cat 9, 10
- **CQRS** — Cat 2, 9
- **Strangler Fig** migration pattern — Staff-level discussion
- **Lambda vs Kappa architecture** (batch + stream vs stream-only) — Cat 9
- **Domain-Driven Design boundaries** — Staff-level
- **Sidecar / service mesh (Envoy, Istio, Linkerd)** — Cat 10

### 3K. Reliability, Observability, Operations (heavily weighted at L6+)
- **SLI / SLO / SLA**, error budgets — all (L6+)
- **Metrics, logging, distributed tracing** (OpenTelemetry, Jaeger, Zipkin) — Cat 10
- **Heartbeats, gossip protocols** (SWIM-style: Cassandra, Consul) — Cat 10
- **Service discovery** (DNS-based, registry-based: Consul, etcd) — Cat 10
- **Disaster recovery, RTO/RPO**, multi-region active-active vs active-passive — Cat 5, 9 (L6+)
- **Canary, blue-green, feature flags, progressive rollout** — Cat 10
- **Chaos engineering** — L6+ talking point

### 3L. Security and Privacy (often a senior-level differentiator)
- **AuthN/AuthZ**: OAuth 2.0, OIDC, JWT (and pitfalls), session cookies — Cat 10
- **Rate limiting, DDoS protection, WAF** — Cat 10
- **Encryption at rest and in transit; envelope encryption with KMS** — Cat 5, 10
- **PII handling, k-anonymity, differential privacy** — Cat 9
- **End-to-end encryption** (Signal protocol; double-ratchet) — Cat 3
- **Audit logging** — Cat 10

### 3M. ML-Specific (for Category 9)
- **Two-tower / dual-encoder retrieval** — Cat 9
- **Multi-stage funnel**: candidate generation → light ranking → heavy ranking → re-ranking — Cat 9
- **Feature store** (online vs offline parity; Feast, Tecton) — Cat 9
- **Model registry, versioning, shadow deployment, canary** — Cat 9
- **Offline metrics** (AUC, NDCG, Recall@K, MAP) **vs online metrics** (CTR, watch time, revenue) and **A/B testing** — Cat 9
- **Concept drift, data drift; PSI / KL divergence monitoring** — Cat 9
- **Online learning vs batch retraining** cadence — Cat 9
- **Cold start**: heuristic fallback, popularity prior, content features — Cat 9
- **LLM serving**: KV cache, speculative decoding, RAG with vector DB, prompt-caching — Cat 9

### 3N. Key Distributed-Systems Papers Worth Naming
- Google File System (2003), MapReduce (2004), BigTable (2006), Chubby (2006), Spanner (2012)
- Amazon Dynamo (2007)
- Kafka (2011)
- ZooKeeper (2010), Paxos (Lamport 1998), Raft (2014)
- The LSM-Tree (O'Neil 1996)
- Kleppmann, *Designing Data-Intensive Applications* — the canonical book reference

### 3O. Trade-offs You Should Be Ready to Argue Both Sides Of
- SQL vs NoSQL — Cat 1, 5
- Strong vs eventual consistency — all
- Push vs pull / fan-out-on-write vs fan-out-on-read (hybrid for celebrities) — Cat 2
- Long polling vs WebSockets vs SSE — Cat 3
- Stateful vs stateless services — all
- Batch vs stream processing — Cat 9, 10
- Read-through vs write-through caching — Cat 1, 2
- REST vs gRPC vs GraphQL — Cat 10
- Vertical vs horizontal scaling — all
- Monolith vs microservices — Staff-level
- Build vs buy — Staff-level

---

## Recommendations (staged study plan)

**Phase 1 — Foundations (weeks 1-2).** Read the donnemartin/system-design-primer index and Hello Interview's "System Design in a Hurry" core concepts; memorize Jeff Dean's latency numbers; do 3 back-of-envelope estimation drills daily. Threshold to move on: you can describe consistent hashing, CAP/PACELC, LSM-tree vs B-tree, and the four cache-write strategies from memory without notes.

**Phase 2 — Pattern fluency (weeks 3-4).** Work through Section 3 above one subsection at a time, writing your own one-paragraph summary of each pattern with one concrete system that uses it. Threshold: for every pattern in 3D-3H, you can name a real production system that uses it and one alternative pattern.

**Phase 3 — Question bank (weeks 5-8).** Solve the top-15 problems first: TinyURL, Twitter, WhatsApp, Uber, Ticketmaster, Dropbox, YouTube, Instagram, Google Docs, web crawler, rate limiter, key-value store, news feed, Yelp, ad click aggregator. For each, do it cold on a whiteboard, then read Hello Interview's or Alex Xu's solution, then redo it explaining the trade-offs aloud. Threshold to move on: you finish a problem end-to-end in 35 minutes with at least one deep-dive on a self-identified hardest component.

**Phase 4 — Level calibration (weeks 9-10).** Adopt the L6 mindset even if interviewing at L5: in *every* practice problem, force yourself to bring up failure modes, cost, and operations *before the interviewer asks*. Do 4-6 mock interviews on Hello Interview, Exponent, or interviewing.io against a real FAANG interviewer at your target level.

**Phase 5 — Company-specific final week.** For Meta: brush up on low-level designs (Redis, Kafka, Memcached) if you're at E6+, and rehearse demonstrating that you can simplify rather than ask "are we sure we need scale?". For Google: prepare to *prove correctness without prompting* and discuss design alternatives explicitly. For Amazon: prepare 5-7 metric-backed Leadership Principle stories that map cleanly onto Are Right A Lot / Dive Deep / Insist on the Highest Standards / Invent and Simplify, and weave them naturally into the design discussion.

**Benchmarks that should change your plan:**
- If after Phase 3 you cannot finish a problem in 35 minutes, you have a *time-management* problem, not a knowledge problem — practice with a strict timer and aggressive scope-cutting.
- If you can build the architecture but freeze on deep dives, your *Technical Excellence* dimension is weak — drill Section 3D-3H and 3M.
- If mock-interview feedback consistently flags "didn't drive the conversation," you are mis-calibrated for your target level — explicitly study the L5 vs L6 grading examples on Design Gurus Substack.

---

## Caveats

- **Internal rubrics are not published.** The specific 0–4 anchor cells in Meta's, Google's, and Amazon's rubrics are not public. Everything in Section 2 is reconstructed from (a) Hello Interview's framework written by ex-Meta/Amazon hiring managers, (b) interviewing.io and IGotAnOffer interviews with current FAANG interviewers, (c) Exponent's Google coding rubric (which Google uses as a near-template for design — four dimensions × 1–4 score: Algorithms, Coding, Communication, Problem-solving), and (d) candidate reports on Blind, Quora, and 1Point3Acres. Treat anchor language as directionally correct, not verbatim Meta/Google/Amazon text.
- **Companies update interviews frequently.** Meta added the AI-assisted coding round in October 2025; some E6 loops now include a Leadership Assessment between phone and onsite. Google's coding scale has changed at least twice (1.0–4.0 → six-bucket). Confirm format with your recruiter.
- **Question lists are noisy.** Reported question prompts on Glassdoor and Blind are often paraphrased and re-asked across companies, so a question reported as "asked at Google" probably also appears at Meta and Amazon in similar form.
- **The mapping of one question to one category is an oversimplification.** Real prompts (Uber, YouTube, Instagram, ChatGPT) blend 3–5 categories. The 10-category framework is a study heuristic, not a taxonomy of prompts.
- **Some sources are commercial.** Hello Interview, Exponent, ByteByteGo, AlgoMaster, and Design Gurus all sell prep courses, which biases their content toward emphasis on framework adherence and may overstate how reliably interviewers grade on neat frameworks.
- **ML system design is a separate interview at some companies.** At Meta, ML system design is its own round; this guide includes ML-in-the-loop prompts because they appear in general SWE loops at Google, Amazon, and many other companies, but if you have a dedicated ML-SD round, study Chip Huyen's *Designing Machine Learning Systems* and the alirezadir/Machine-Learning-Interviews repo as primary references.
- **Numbers in the question-bank tables are illustrative.** The "QPS / writes-per-second" figures (e.g., Uber's ~250K location writes/sec) come from secondary engineering blogs and prep-course write-ups; use them as order-of-magnitude anchors, not authoritative production numbers.

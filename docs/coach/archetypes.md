# Archetypes

Index of the 12 system-design problem archetypes the coach reasons over.
Canonical content lives in `staff-engineer-study-guide.md` §1; the new
v1 archetypes (11 and 12) are documented inline below pending guide updates.

## 1. High-throughput read systems with caching

**Summary.** Read-dominated systems where the design pressure is caching topology, hot-key handling, and consistency on cache miss. Canonical pattern: CDN + multi-tier cache (browser → reverse proxy → app server → distributed cache → DB).

**Top-3 prompts.** Design TinyURL · Design a Distributed Cache · Design Search Autocomplete.

**Patterns.** See `docs/coach/patterns/3E-caching.md` and `3B-networking-transport.md`.

## 2. Fan-out / feed systems

**Summary.** Producer-to-many-consumer systems where the design pressure is fan-out strategy (write vs read) and the celebrity problem.

**Top-3 prompts.** Design Twitter timeline · Design Facebook News Feed · Design Instagram feed.

**Patterns.** See `docs/coach/patterns/3F-async-streaming.md`.

## 3. Real-time messaging / streaming

**Summary.** Sub-second delivery with high concurrency. Design pressure: connection model (WebSocket vs SSE vs long-poll), presence, group fan-out at scale.

**Top-3 prompts.** Design WhatsApp · Design Discord · Design a Live Streaming service.

**Patterns.** See `docs/coach/patterns/3B-networking-transport.md`.

## 4. Concurrent access to limited resources

**Summary.** N consumers competing for M units of inventory. Design pressure: OCC vs pessimistic lock vs distributed lock; idempotency.

**Top-3 prompts.** Design Ticketmaster · Design a Flash Sale system · Design an Online Auction.

**Patterns.** See `docs/coach/patterns/3G-consistency-coordination.md` and `3I-api-idempotency.md`.

## 5. User-generated content pipelines

**Summary.** Upload → process → store → serve. Design pressure: chunking, dedup, transcoding ladders, CDN.

**Top-3 prompts.** Design YouTube · Design Dropbox · Design Instagram upload.

**Patterns.** See `docs/coach/patterns/3D-storage-databases.md`.

## 6. Geo / proximity systems

**Summary.** Spatial queries at scale. Design pressure: geo indexing (H3, geohash, quadtree), real-time location updates, dispatch.

**Top-3 prompts.** Design Uber · Design Yelp · Design Find My Friends.

**Patterns.** See `docs/coach/patterns/3H-data-structures.md`.

## 7. Search and indexing

**Summary.** Inverted-index systems with ranking. Design pressure: index sharding, refresh interval, query expansion.

**Top-3 prompts.** Design Google Search · Design a Web Crawler · Design Twitter Search.

**Patterns.** See `docs/coach/patterns/3H-data-structures.md`.

## 8. Conflict resolution / collaborative systems

**Summary.** Concurrent edits to shared state. Design pressure: OT vs CRDT; consistency vs availability under partition.

**Top-3 prompts.** Design Google Docs · Design Figma · Design a Wiki.

**Patterns.** See `docs/coach/patterns/3G-consistency-coordination.md`.

## 9. ML-in-the-loop serving

**Summary.** Production ML systems. Design pressure: candidate-gen → ranking → re-rank funnel; online vs offline features; eval.

**Top-3 prompts.** Design a YouTube recommendation engine · Design CTR prediction · Design Ad Click Aggregator.

**Patterns.** See `docs/coach/patterns/3M-ml-specific.md`.

## 10. Infrastructure primitives

**Summary.** "Design Kafka / Redis / Memcached / DynamoDB"-style prompts. Asked at L6+. Design pressure: building the primitive from scratch.

**Top-3 prompts.** Design a Distributed Rate Limiter · Design a Distributed Message Queue · Design a Distributed Key-Value Store.

**Patterns.** See `docs/coach/patterns/3D-storage-databases.md` and `3J-architectural.md`.

## 11. AI-Infrastructure (new for v1)

**Summary.** Inference-serving + training infrastructure. Asked at Anthropic, OpenAI, DeepMind, Mistral. 50–55 min round (vs standard 45). **Safety and cost are first-class SLIs** — *"a system that is fast but produces harmful outputs is considered broken."*

**Top-3 prompts.** Inference-batching API for a GPU cluster with priority queues + streaming · Distributed search over a billion documents at millions of QPS with KV-cache-aware routing · Safety/moderation pipeline layered with inference.

**Distinctive style.** Problems are *often novel* — the interviewer may not have a single correct answer in mind.

**Patterns.** See `docs/coach/patterns/ai-infra.md`.

## 12. Front-End / client system design (new for v1)

**Summary.** Client-side system design. Asked at Meta, Airbnb, Google, Atlassian, Uber, Apple. Canonical framework: **RADIO** (Requirements, Architecture, Data model, Interface, Optimization).

**Top-3 prompts.** Image carousel · Autocomplete with keyboard navigation · Collaborative spreadsheet (Sheets).

**Patterns.** See `docs/coach/patterns/frontend.md`.

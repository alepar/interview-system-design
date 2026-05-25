# Archetypes

Index of the 12 system-design problem archetypes the coach reasons over.
Canonical content lives in `staff-engineer-study-guide.md` §1; the new
v1 archetypes (11 and 12) are documented inline below pending guide updates.

## 1. High-throughput read systems with caching

**Summary.** Read-dominated systems where the design pressure is caching topology, hot-key handling, and consistency on cache miss. Canonical pattern: CDN + multi-tier cache (browser → reverse proxy → app server → distributed cache → DB).

**Top-3 prompts.** Design TinyURL · Design a Distributed Cache · Design Search Autocomplete.

**Patterns.** See `docs/coach/patterns/caching.md` and `networking-transport.md`.

**Problems in catalog.** `tinyurl`.

## 2. Fan-out / feed systems

**Summary.** Producer-to-many-consumer systems where the design pressure is fan-out strategy (write vs read) and the celebrity problem.

**Top-3 prompts.** Design Twitter timeline · Design Facebook News Feed · Design Instagram feed.

**Patterns.** See `docs/coach/patterns/async-streaming.md`.

**Problems in catalog.** `twitter-timeline`.

## 3. Real-time messaging / streaming

**Summary.** Sub-second delivery with high concurrency. Design pressure: connection model (WebSocket vs SSE vs long-poll), presence, group fan-out at scale.

**Top-3 prompts.** Design WhatsApp · Design Discord · Design a Live Streaming service.

**Patterns.** See `docs/coach/patterns/networking-transport.md`.

**Problems in catalog.** `whatsapp` · `messenger-multi-device-sync` · `telegram` · `discord-presence` · `discord-channels` · `discord-voice` · `slack` · `twitch-streaming` · `twitch-chat` · `youtube-live` · `zoom` · `webrtc-sfu` · `signal-protocol` · `mls-group` · `audio-rooms` · `twilio` · `push-notification` · `matrix` · `mqtt-broker`.

## 4. Concurrent access to limited resources

**Summary.** N consumers competing for M units of inventory. Design pressure: OCC vs pessimistic lock vs distributed lock; idempotency.

**Top-3 prompts.** Design Ticketmaster · Design a Flash Sale system · Design an Online Auction.

**Patterns.** See `docs/coach/patterns/consistency-coordination.md` and `api-idempotency.md`.

**Problems in catalog.** `ticketmaster`.

## 5. User-generated content pipelines

**Summary.** Upload → process → store → serve. Design pressure: chunking, dedup, transcoding ladders, CDN.

**Top-3 prompts.** Design YouTube · Design Dropbox · Design Instagram upload.

**Patterns.** See `docs/coach/patterns/storage-databases.md`.

**Problems in catalog.** `dropbox`.

## 6. Geo / proximity systems

**Summary.** Spatial queries at scale. Design pressure: geo indexing (H3, geohash, quadtree), real-time location updates, dispatch.

**Top-3 prompts.** Design Uber · Design Yelp · Design Find My Friends.

**Patterns.** See `docs/coach/patterns/data-structures.md`.

**Problems in catalog.** `uber`.

## 7. Search and indexing

**Summary.** Inverted-index systems with ranking. Design pressure: index sharding, refresh interval, query expansion.

**Top-3 prompts.** Design Google Search · Design a Web Crawler · Design Twitter Search.

**Patterns.** See `docs/coach/patterns/data-structures.md`.

**Problems in catalog.** `google-search` · `web-crawler` · `elasticsearch` · `twitter-search` · `autocomplete` · `log-search` · `github-code-search` · `image-search` · `enterprise-search` · `hybrid-search` · `incremental-indexing` · `amazon-product-search` · `spell-correction` · `geo-place-search`.

## 8. Conflict resolution / collaborative systems

**Summary.** Concurrent edits to shared state. Design pressure: OT vs CRDT; consistency vs availability under partition.

**Top-3 prompts.** Design Google Docs · Design Figma · Design a Wiki.

**Patterns.** See `docs/coach/patterns/consistency-coordination.md`.

**Problems in catalog.** `crdt-primitive` · `google-docs` · `collaborative-text-editor` · `yjs` · `figma` · `figjam-whiteboard` · `google-sheets` · `notion` · `shopping-cart-crdt` · `version-control-merge` · `local-first-sync` · `calendar-sync` · `multiplayer-game-sync` · `presence-awareness`.

## 9. ML-in-the-loop serving

**Summary.** Production ML systems. Design pressure: candidate-gen → ranking → re-rank funnel; online vs offline features; eval.

**Top-3 prompts.** Design a YouTube recommendation engine · Design CTR prediction · Design Ad Click Aggregator.

**Patterns.** See `docs/coach/patterns/ml-specific.md`.

**Problems in catalog.** `youtube-reco` · `instagram-reels-ranking` · `tiktok-foryou-ranking` · `spotify-discover` · `pinterest-pixie` · `netflix-homepage` · `ctr-prediction` · `ad-auction-rtb` · `web-search-ranking` · `airbnb-search-ranking` · `fb-news-feed` · `linkedin-pymk` · `uber-surge` · `stripe-fraud` · `spam-abuse-ranking` · `feature-store` · `model-rollout-shadow` · `autonomous-driving-inference` · `voice-assistant-routing`.

## 10. Infrastructure primitives

**Summary.** "Design Kafka / Redis / Memcached / DynamoDB"-style prompts. Asked at L6+. Design pressure: building the primitive from scratch.

**Top-3 prompts.** Design a Distributed Rate Limiter · Design a Distributed Message Queue · Design a Distributed Key-Value Store.

**Patterns.** See `docs/coach/patterns/storage-databases.md` and `architectural.md`.

**Problems in catalog.** `stripe-rate-limiter` · `kafka` · `dynamodb` · `zookeeper` · `memcached` · `kubernetes-scheduler` · `s3` · `stripe-payments` · `pulsar` · `spanner` · `aurora` · `google-pubsub` · `etcd` · `snowflake-id` · `prometheus` · `colossus` · `ad-click-aggregator`.

## 11. AI-Infrastructure

**Summary.** Inference-serving + training infrastructure. Asked at Anthropic, OpenAI, DeepMind, Mistral. 50–55 min round (vs standard 45). **Safety and cost are first-class SLIs** — *"a system that is fast but produces harmful outputs is considered broken."*

**Top-3 prompts.** Inference-batching API for a GPU cluster with priority queues + streaming · Distributed search over a billion documents at millions of QPS with KV-cache-aware routing · Safety/moderation pipeline layered with inference.

**Distinctive style.** Problems are *often novel* — the interviewer may not have a single correct answer in mind.

**Patterns.** See `docs/coach/patterns/ai-infra.md`.

**Problems in catalog.** `inference-batching` · `billion-doc-rag` · `gpu-cluster-scheduler` · `agentic-tool-orchestrator` · `safety-moderation-pipeline` · `training-cluster-fault-tolerance` · `sandboxed-agent-execution` · `prefill-decode-disaggregation` · `prompt-cache-infrastructure` · `model-cascade-router` · `embedding-service-at-scale` · `multi-tenant-lora-serving` · `long-context-kv-management` · `eval-pipeline-at-scale` · `multimodal-realtime-serving` · `ai-gateway-token-quota` · `moe-serving`.

## 12. Front-End / client system design

**Summary.** Client-side system design. Asked at Meta, Airbnb, Google, Atlassian, Uber, Apple. Canonical framework: **RADIO** (Requirements, Architecture, Data model, Interface, Optimization).

**Top-3 prompts.** Image carousel · Autocomplete with keyboard navigation · Collaborative spreadsheet (Sheets).

**Patterns.** See `docs/coach/patterns/frontend.md`.

**Problems in catalog.** `image-carousel` · `autocomplete-typeahead` · `infinite-scroll-feed` · `rich-text-editor` · `news-feed-client` · `pinterest-board-client` · `instagram-stories-client` · `google-docs-client` · `figma-canvas-client` · `slack-web-client` · `stock-trading-dashboard` · `datadog-dashboard` · `video-player` · `spotify-web-player` · `google-maps-client` · `airbnb-search-map` · `chatgpt-claude-chat-ui` · `copilot-inline-completions` · `stripe-checkout-flow`.

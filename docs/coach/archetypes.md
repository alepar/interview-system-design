# Archetypes

Index of the 13 system-design problem archetypes the coach reasons over.
Canonical content lives in `staff-engineer-study-guide.md` §1; the new
v1 archetypes (11, 12, and 13) are documented inline below pending guide updates.

## 1. High-throughput read systems with caching

**Summary.** Read-dominated systems where the design pressure is caching topology, hot-key handling, and consistency on cache miss. Canonical pattern: CDN + multi-tier cache (browser → reverse proxy → app server → distributed cache → DB).

**Top-3 prompts.** Design TinyURL · Design a Distributed Cache · Design Search Autocomplete.

**Patterns.** See `docs/coach/patterns/caching.md`, `networking-transport.md`, and `data-structures.md`.

**Problems in catalog.** `tinyurl` · `pastebin` · `dns` · `leaderboard` · `view-counter` · `top-k-trending` · `news-homepage` · `wikipedia` · `cdn-edge-cache` · `product-catalog` · `stock-ticker` · `session-store` · `feature-flags` · `distributed-config`.

## 2. Fan-out / feed systems

**Summary.** Producer-to-many-consumer systems where the design pressure is fan-out strategy (write vs read) and the celebrity problem.

**Top-3 prompts.** Design Twitter timeline · Design Facebook News Feed · Design Instagram feed.

**Patterns.** See `docs/coach/patterns/async-streaming.md`, `caching.md`, and `networking-transport.md`.

**Problems in catalog.** `twitter-timeline` · `instagram-feed` · `linkedin-feed` · `reddit-feed` · `pinterest-home` · `youtube-subscriptions` · `github-events-feed` · `spotify-friend-activity` · `medium-following-feed` · `notification-aggregation-service` · `email-digest-pipeline` · `breaking-news-fanout` · `inbox-zero` · `mastodon-federated-feed` · `bluesky-atproto-feed` · `sports-scores-fanout` · `stock-alert-fanout` · `geo-weather-alert-fanout` · `discord-server-activity-stream`.

> **Boundaries.** §9 (`ml-in-loop`) if a ranking / scoring / uplift model is the centerpiece (delivery substrate is incidental). §3 (`interactive-messaging`) if it's persistent-connection chat / multi-device sync (not a feed). §13 (`live-media-broadcast`) if it's media delivery (HLS/DASH/CDN) during a broadcast.

## 3. Interactive messaging

**Summary.** Persistent-connection messaging with multi-device sync. Design pressure: connection model (WebSocket vs SSE vs long-poll), presence, message ordering and delivery semantics across multiple devices, group fan-out at scale, end-to-end encryption.

**Top-3 prompts.** Design WhatsApp · Design Discord · Design Slack.

**Patterns.** See `docs/coach/patterns/networking-transport.md`.

**Problems in catalog.** `whatsapp` · `messenger-multi-device-sync` · `telegram` · `slack` · `discord-presence` · `discord-channels` · `discord-voice` · `zoom` · `matrix` · `push-notification` · `signal-protocol` · `mls-group`.

> **Boundary with §2 (`fan-out`).** Feed-style content distribution (one-to-many push of new items from many sources, e.g., timelines, news, notifications) belongs in §2. Interactive-messaging is persistent-connection chat with multi-device sync and presence — even when underlying tech overlaps (push notifications, server-side fan-out).

## 4. Concurrent access to limited resources

**Summary.** N consumers competing for M units of inventory. Design pressure: OCC vs pessimistic lock vs distributed lock; idempotency.

**Top-3 prompts.** Design Ticketmaster · Design a Flash Sale system · Design an Online Auction.

**Patterns.** See `docs/coach/patterns/consistency-coordination.md`, `api-idempotency.md`, and `admission-control.md`.

**Problems in catalog.** `ticketmaster` · `flash-sale` · `online-auction` · `sneaker-drop` · `airline-seat-booking` · `hotel-booking` · `ecommerce-inventory` · `coupon-redemption` · `appointment-booking` · `parking-garage` · `distributed-lock` · `idempotent-payment` · `stripe-payments` · `wallet-ledger` · `resource-pool`.

> **Boundary with §10 (`infra-primitives`).** If the prompt is to build a standalone primitive (distributed lock, rate limiter, ID generator) without an application context, see §10. Concurrent-resource problems may include such primitives as design components but the prompt is application-level — an app where N consumers compete for M units, or where exactly-once / idempotency must hold under concurrency.

## 5. User-generated content pipelines

**Summary.** Upload → process → store → serve. Design pressure: chunking, dedup, transcoding ladders, CDN.

**Top-3 prompts.** Design YouTube · Design Dropbox · Design Instagram upload.

**Patterns.** See `docs/coach/patterns/storage-databases.md` and `async-streaming.md`.

**Problems in catalog.** `dropbox` · `youtube-upload` · `video-transcoding` · `vod-delivery` · `instagram-upload` · `google-photos` · `image-derivatives` · `content-addressed-dedup` · `backup-incremental` · `resumable-upload` · `document-preview` · `audio-transcoding` · `tiktok-upload` · `content-moderation-pipeline`.

## 6. Geo / proximity systems

**Summary.** Spatial queries at scale. Design pressure: geo indexing (H3, geohash, quadtree), real-time location updates, dispatch.

**Top-3 prompts.** Design Uber · Design Yelp · Design Find My Friends.

**Patterns.** See `docs/coach/patterns/data-structures.md` and `optimization.md`.

**Problems in catalog.** `uber` · `lyft-dispatch` · `didi-dispatch` · `doordash-dispatch` · `instacart-batching` · `yelp-search` · `google-places` · `foursquare-checkin` · `find-my-friends` · `snap-map` · `life360` · `google-maps-routing` · `waze-traffic-update` · `last-mile-routing` · `geofence-notifications` · `snap-geofilter-fanout` · `bluetooth-beacon-proximity` · `h3-s2-spatial-index` · `geohash-design`.

> **Boundary with §9 (`ml-in-loop`).** Routing / dispatch / pricing problems where ML is a component but spatial indexing or dispatch is the structural pressure belong here (e.g., `last-mile-routing`, `instacart-batching`, `waze-traffic-update`). ML pricing/ranking *controllers* where the ML decision is the centerpiece (e.g., `uber-surge`) belong in §9.

## 7. Search and indexing

**Summary.** Inverted-index systems with ranking. Design pressure: index sharding, refresh interval, query expansion.

**Top-3 prompts.** Design Google Search · Design a Web Crawler · Design Twitter Search.

**Patterns.** See `docs/coach/patterns/search.md` and `data-structures.md`.

> **Note.** `spell-correction` and `incremental-indexing` are ~25-minute follow-up problems (best paired with a primary problem like `autocomplete` or `google-search`), not full 50-minute solo slots.

**Problems in catalog.** `google-search` · `web-crawler` · `elasticsearch` · `twitter-search` · `autocomplete` · `log-search` · `github-code-search` · `image-search` · `enterprise-search` · `hybrid-search` · `incremental-indexing` · `amazon-product-search` · `spell-correction` · `geo-place-search`.

## 8. Conflict resolution / collaborative systems

**Summary.** Concurrent edits to shared state. Design pressure: OT vs CRDT; consistency vs availability under partition.

**Top-3 prompts.** Design Google Docs · Design Figma · Design a Wiki.

**Patterns.** See `docs/coach/patterns/consistency-coordination.md`.

**Problems in catalog.** `crdt-primitive` · `google-docs` · `collaborative-text-editor` · `yjs` · `figma` · `figjam-whiteboard` · `google-sheets` · `notion` · `shopping-cart-crdt` · `version-control-merge` · `local-first-sync` · `calendar-sync` · `multiplayer-game-sync` · `presence-awareness`.

## 9. ML-in-the-loop

**Summary.** Production classical-ML systems (LLM / agent / GPU infra → §11). Four sub-types in the catalog: (a) **serving funnel** — candidate-gen → ranking → re-rank, the canonical pressure; (b) **ML platform infra** — feature stores, rollout/shadow systems; (c) **ML-data pipelines** — streaming-batch reconciliation feeding training data; (d) **embedded / safety-critical inference** — low-power, on-device, dual-SoC. Cross-cutting: online vs offline features, serving-latency vs ranking-quality, eval design.

**Top-3 prompts.** Design a YouTube recommendation engine · Design CTR prediction · Design Ad Click Aggregator.

**Patterns.** See `docs/coach/patterns/ml-specific.md`.

> Pattern coverage is currently funnel-centric. Sub-types (b), (c), and (d) are under-covered — see audit pattern-gap issues under epic `interview-system-design-ng1`.

> **Boundaries.** Three adjacent archetypes share fuzzy boundaries with ml-in-loop:
> - **§11 (`ai-infrastructure`)**: LLM / agent / GPU-cluster infrastructure goes there. ml-in-loop is *classical-ML* (recommendations, CTR, fraud, embedded inference).
> - **§2 (`fan-out`)**: when the dominant design pressure is the delivery substrate (fan-out-on-write/read, push gateway), it's fan-out. When the ranking/scoring/uplift model is the centerpiece, it's ml-in-loop.
> - **§6 (`geo-proximity`)**: when spatial indexing or dispatch is dominant, it's geo. When the ML pricing/ranking *controller* (e.g., `uber-surge`) is the focus, it's ml-in-loop.

**Problems in catalog.** `youtube-reco` · `instagram-reels-ranking` · `tiktok-foryou-ranking` · `spotify-discover` · `pinterest-pixie` · `netflix-homepage` · `ctr-prediction` · `ad-auction-rtb` · `ad-click-aggregator` · `web-search-ranking` · `airbnb-search-ranking` · `fb-news-feed` · `linkedin-pymk` · `uber-surge` · `stripe-fraud` · `spam-abuse-ranking` · `feature-store` · `model-rollout-shadow` · `autonomous-driving-inference` · `voice-assistant-routing`.

## 10. Infrastructure primitives

**Summary.** "Design Kafka / Redis / Memcached / DynamoDB"-style prompts. Asked at L6+. Design pressure: building the primitive from scratch.

**Top-3 prompts.** Design a Distributed Rate Limiter · Design a Distributed Message Queue · Design a Distributed Key-Value Store.

**Patterns.** See `docs/coach/patterns/storage-databases.md`, `architectural.md`, `consensus.md`, `time-and-clocks.md`, and `optimization.md`.

**Problems in catalog.** `stripe-rate-limiter` · `kafka` · `dynamodb` · `zookeeper` · `memcached` · `kubernetes-scheduler` · `s3` · `pulsar` · `spanner` · `aurora` · `google-pubsub` · `etcd` · `snowflake-id` · `prometheus` · `colossus` · `mqtt-broker` · `webrtc-sfu` · `twilio`.

> **Boundary with §4 (`concurrent-resource`).** If the prompt has an application context (N consumers competing for M units of inventory, payment workflows, booking flows), see §4. Infra-primitives is for prompts that are *entirely* about building a primitive — the candidate is asked to design the primitive's API + internals with no surrounding application.

## 11. AI-Infrastructure

**Summary.** Inference-serving + training infrastructure. Asked at Anthropic, OpenAI, DeepMind, Mistral. 50–55 min round (vs standard 45). **Safety and cost are first-class SLIs** — *"a system that is fast but produces harmful outputs is considered broken."*

**Top-3 prompts.** Inference-batching API for a GPU cluster with priority queues + streaming · Distributed search over a billion documents at millions of QPS with KV-cache-aware routing · Safety/moderation pipeline layered with inference.

**Distinctive style.** Problems are *often novel* — the interviewer may not have a single correct answer in mind.

**Patterns.** See `docs/coach/patterns/ai-infra.md` and `optimization.md`.

**Problems in catalog.** `inference-batching` · `billion-doc-rag` · `gpu-cluster-scheduler` · `agentic-tool-orchestrator` · `safety-moderation-pipeline` · `training-cluster-fault-tolerance` · `sandboxed-agent-execution` · `prefill-decode-disaggregation` · `prompt-cache-infrastructure` · `model-cascade-router` · `embedding-service-at-scale` · `multi-tenant-lora-serving` · `long-context-kv-management` · `eval-pipeline-at-scale` · `multimodal-realtime-serving` · `ai-gateway-token-quota` · `moe-serving`.

> **Boundary with §9 (`ml-in-loop`).** Classical ML systems (recommendations, ranking, CTR, fraud) and embedded / safety-critical inference (autonomous driving, on-device voice) belong in §9. This archetype is LLM-era inference and training infrastructure — KV-cache management, GPU cluster scheduling, agent platforms, multi-tenant serving, prompt caching.

## 12. Front-End / client system design

**Summary.** Client-side system design. Asked at Meta, Airbnb, Google, Atlassian, Uber, Apple. Canonical framework: **RADIO** (Requirements, Architecture, Data model, Interface, Optimization).

**Top-3 prompts.** Image carousel · Autocomplete with keyboard navigation · Collaborative spreadsheet (Sheets).

**Patterns.** See `docs/coach/patterns/frontend.md`.

**Problems in catalog.** `image-carousel` · `autocomplete-typeahead` · `infinite-scroll-feed` · `rich-text-editor` · `news-feed-client` · `pinterest-board-client` · `instagram-stories-client` · `google-docs-client` · `figma-canvas-client` · `slack-web-client` · `stock-trading-dashboard` · `datadog-dashboard` · `video-player` · `spotify-web-player` · `google-maps-client` · `airbnb-search-map` · `chatgpt-claude-chat-ui` · `copilot-inline-completions` · `stripe-checkout-flow`.

## 13. Live-media broadcast

**Summary.** One-to-many live media delivery during a broadcast. Design pressure: HLS/DASH adaptive bitrate, low-latency live (LL-HLS, CMAF-LL), CDN edge caching for live segments, SFU forwarding and simulcast, broadcast-scale companion chat.

**Top-3 prompts.** Design Twitch live streaming · Design YouTube Live · Design Twitter Spaces / Clubhouse audio rooms.

**Patterns.** See `docs/coach/patterns/networking-transport.md`.

**Problems in catalog.** `twitch-streaming` · `twitch-chat` · `youtube-live` · `audio-rooms`.

> **Boundary with §2 (`fan-out`).** Live *media* delivery (HLS/DASH/CDN segments for video and audio) belongs here. Live broadcast of *metadata / events* (sports scores, breaking news, stock alerts) belongs in §2 fan-out, even at high scale.

> This archetype is new (added 2026-05-25 via audit issue `interview-system-design-48c.1`); documented inline pending updates to `staff-engineer-study-guide.md`. Pattern coverage is currently thin — see audit issues under `audit:pattern-gap` for HLS/DASH and SFU coverage gaps.

## Cross-cutting pattern references

The pattern files below apply broadly across archetypes and are not pinned to any single one. They are loaded via `/study-patterns <name>` and referenced ad-hoc from problem files:

- `docs/coach/patterns/core-concepts.md` — scalability, CAP/PACELC, latency vs throughput vs bandwidth, SPOF and fault tolerance, BOE estimation, Jeff Dean numbers
- `docs/coach/patterns/load-balancing.md` — L4 vs L7, LB algorithms, anycast/GeoDNS, sticky sessions
- `docs/coach/patterns/reliability-observability.md` — SLI/SLO/SLA and error budgets, metrics/logging/tracing, gossip, service discovery, DR (RTO/RPO), canary/blue-green, chaos engineering
- `docs/coach/patterns/security-privacy.md` — AuthN/AuthZ (OAuth/OIDC/JWT), rate-limiting/WAF, encryption (at-rest, in-transit, envelope), PII / k-anonymity / DP, E2EE, audit logging
- `docs/coach/patterns/papers.md` — key distributed-systems papers (GFS, MapReduce, BigTable, Chubby, Spanner, Dynamo, Kafka, ZooKeeper, Paxos, Raft, etc.)
- `docs/coach/patterns/tradeoffs.md` — canonical trade-off pairs (SQL vs NoSQL, strong vs eventual, push vs pull, polling vs WebSockets vs SSE, stateful vs stateless, batch vs stream, etc.)

# Catalog cross-audit — findings

**Run:** `2026-05-25-0104` · **Spec:** `docs/specs/2026-05-25-catalog-cross-audit-design.md` · **bd epics:** `interview-system-design-ng1` (catalog-cross), `interview-system-design-48c` (taxonomy)

## Counts

- Per-archetype findings: **73** (resolved cross-archetype checks already applied)
- Cross-archetype duplicate candidates: **7** (most confirmed as intentional splits)
- Archetype pattern-ref issues: **0**
- Global index issues: **0**
- Orphan pattern files (no archetype references them): **6**
- Taxonomy findings: **7**

## Headline

- **`ad-click-aggregator` is filed under `infra-primitives` but listed as a top-3 prompt of `ml-in-loop` in `archetypes.md`.** Hard contradiction in the index. Move the file (frontmatter to `ml-in-loop` + update archetype 9's Problems-in-catalog list) or revise the §9 top-3.
- **`realtime-messaging` is doing three jobs** (interactive messaging, message-protocol primitives, live-media CDN). Recommend splitting.
- **`ml-in-loop` summary doesn't match its contents anymore** — `feature-store`, `model-rollout-shadow` are ML platform infra; `autonomous-driving-inference`, `voice-assistant-routing` are embedded inference. Redefine or relocate.
- **`infra-primitives` ↔ `concurrent-resource` boundary is fuzzy** — articulate a build-the-primitive vs. application-using-the-primitive rule in `archetypes.md`.

---

## Taxonomy findings (epic: `interview-system-design-48c`)

### [MEDIUM · conf:high] ml-in-loop and ai-infrastructure share a fuzzy boundary on inference-serving vs ML serving; same problems plausibly fit either.

**Finding ID:** `taxonomy-003` · **Category:** `archetype_taxonomy / boundary`
**Archetypes affected:** ml-in-loop, ai-infrastructure
**Impact:** medium

**Evidence:**  
> Bidirectional mis-cat pair (3 findings): ml-in-loop->ai-infrastructure {autonomous-driving-inference, voice-assistant-routing}; ai-infrastructure->ml-in-loop {safety-moderation-pipeline}. archetypes.md lists safety-moderation-pipeline as a top-3 ai-infra prompt; ai-infra Phase-1 finding-001 still flags it as boundary.

**Suggested fix:** Add an explicit boundary note in archetypes.md between §9 ml-in-loop and §11 AI-Infrastructure: 'ai-infrastructure is GPU/LLM-serving-stack-centric (inference-batching, KV cache, gang scheduling); ml-in-loop is product-ML-centric (ranking funnels, feature stores, drift). Embedded inference (autonomous driving, voice assistants) and safety moderation cross the line; current placement reflects whether the LLM-serving substrate or the ML-product lifecycle dominates.'

---

### [MEDIUM · conf:high] infra-primitives and concurrent-resource boundary: which is the 'application-using-the-primitive' archetype and which is the 'build-the-primitive' archetype? distributed-lock and idempotent-payment self-describe as primitives but sit in concurrent-resource; stripe-payments and kubernetes-scheduler sit in infra-primitives but are application-level.

**Finding ID:** `taxonomy-004` · **Category:** `archetype_taxonomy / boundary`
**Archetypes affected:** infra-primitives, concurrent-resource
**Impact:** medium

**Evidence:**  
> Bidirectional mis-cat pair (4 findings): infra-primitives->concurrent-resource {stripe-payments, kubernetes-scheduler}; concurrent-resource->infra-primitives {distributed-lock, idempotent-payment}. concurrent-resource summary: 'N consumers competing for M units of inventory. Design pressure: OCC vs pessimistic lock vs distributed lock; idempotency.' — exactly the primitives the cross-pointing problems formalize.

**Suggested fix:** Add a rule of thumb in archetypes.md: 'infra-primitives = the engine (Kafka, ZK, etcd, distributed-KV); concurrent-resource = the application of mutual exclusion to user-facing inventory.' Then either: (a) keep distributed-lock + idempotent-payment in concurrent-resource as 'cross-cutting application-level primitives' (current intent) and move kubernetes-scheduler/stripe-payments framing closer to primitive substrate — or (b) consider a dedicated 'coordination primitives' sub-archetype.

---

### [MEDIUM · conf:medium] ml-in-loop and geo-proximity share a fuzzy boundary on routing/dispatch/pricing problems with ML components.

**Finding ID:** `taxonomy-005` · **Category:** `archetype_taxonomy / boundary`
**Archetypes affected:** ml-in-loop, geo-proximity
**Impact:** medium

**Evidence:**  
> Bidirectional mis-cat pair (3 findings): geo-proximity->ml-in-loop {last-mile-routing, instacart-batching}; ml-in-loop->geo-proximity {uber-surge}. Pressures cross-cut: H3 streaming + ML quantile + LTR over geo-filtered candidates appear in problems on both sides.

**Suggested fix:** Add a boundary note: 'geo-proximity = spatial-index + dispatch matching + routing OR; ml-in-loop = the predictive/ranking layer over geo-filtered candidates.' Keep last-mile-routing and instacart-batching in geo-proximity (OR/optimization dominates); keep uber-surge in ml-in-loop (forecast + elasticity dominate). Consider adding an explicit 'routing/OR' pattern reference (already flagged in geo-proximity-001).

---

### [MEDIUM · conf:high] ml-in-loop summary is funnel-centric but archetype now includes ML-platform infra (feature-store, rollout-shadow) and embedded inference (autonomous-driving, voice-assistant). At least 4 of 19 problems do not match the summary.

**Finding ID:** `taxonomy-002` · **Category:** `archetype_taxonomy / redefine`
**Archetypes affected:** ml-in-loop
**Impact:** medium

**Evidence:**  
> archetypes.md §9 summary: 'Production ML systems. Design pressure: candidate-gen -> ranking -> re-rank funnel; online vs offline features; eval.' But ml-in-loop catalog includes feature-store ('point-in-time-correct joins + offline-online consistency + dual-store + streaming aggregations'), model-rollout-shadow ('shadow -> canary -> A/B + champion-challenger + three drift signals'), autonomous-driving-inference ('safety-critical embedded inference ... ASIL-D fail-operational'), and voice-assistant-routing ('classical voice-assistant stack as cascade of ML models'). Phase-1 ml-in-loop finding #007 explicitly flags this: 'feature-store and model-rollout-shadow are ML-platform infra problems (not product ranking systems)'.

**Suggested fix:** Broaden ml-in-loop summary in archetypes.md to: 'Production ML systems including (a) ranking/funnel serving, (b) ML-platform infra (feature stores, registries, rollout/shadow, drift), and (c) low-latency / embedded inference. Design pressure varies by sub-cluster but always centers on the model lifecycle in production.' Alternative: relocate embedded-inference problems to ai-infrastructure (closer to inference-batching/gpu-cluster-scheduler).

---

### [MEDIUM · conf:high] realtime-messaging contains three distinct design-pressure clusters (interactive messaging/connection-model; messaging primitives; live-media CDN broadcast); 42% of problems sit on the boundary.

**Finding ID:** `taxonomy-001` · **Category:** `archetype_taxonomy / split`
**Archetypes affected:** realtime-messaging
**Impact:** high

**Evidence:**  
> Phase-1 realtime-messaging envelope flags 8 of 19 problems (42%) as mis_categorization candidates, splitting into two distinct sub-clusters: (a) primitive-builds {mqtt-broker, webrtc-sfu, signal-protocol, mls-group, twilio, discord-channels-storage} pointing to infra-primitives; (b) live-video CDN broadcast {twitch-streaming, youtube-live, audio-rooms} pointing to ugc-pipeline. The archetype's stated summary is 'sub-second delivery with high concurrency. Design pressure: connection model (WebSocket vs SSE vs long-poll), presence, group fan-out at scale.' — which neither sub-cluster matches.

**Suggested fix:** Split realtime-messaging into (1) interactive-messaging (whatsapp, messenger-multi-device-sync, telegram[->fan-out?], slack, discord-presence, discord-channels[storage], discord-voice, zoom, push-notification, matrix) and (2) live-media-broadcast (twitch-streaming, twitch-chat, youtube-live, audio-rooms) — or move (2) into ugc-pipeline as a 'live' sub-section. Move the messaging-protocol primitives (mqtt-broker, webrtc-sfu, signal-protocol, mls-group, twilio) into infra-primitives or a new 'messaging-primitives' grouping.

---

### [low · conf:medium] ml-in-loop and fan-out overlap on feed/notification ranking problems where the fan-out substrate is real but ML uplift/ranking dominates the Staff+ bar.

**Finding ID:** `taxonomy-006` · **Category:** `archetype_taxonomy / boundary`
**Archetypes affected:** ml-in-loop, fan-out
**Impact:** low

**Evidence:**  
> Bidirectional mis-cat pair (3 findings): fan-out->ml-in-loop {inbox-zero, notification-aggregation-service}; ml-in-loop->fan-out {fb-news-feed for fan-out deep-dive overlap}.

**Suggested fix:** Add boundary note: 'fan-out = producer-to-many-consumer + celebrity problem + write-vs-read fan-out; ml-in-loop = the ranking/uplift model that runs on top.' inbox-zero leans ML (PA-II + 7-layer spam) — move to ml-in-loop; notification-aggregation-service is borderline (ML uplift + aggregation/dedup) — defensible either way.

---

### [low · conf:medium] Boundary between realtime-messaging (connection model + presence + push to many) and fan-out (producer-to-many-consumer feed) is real and bidirectional.

**Finding ID:** `taxonomy-007` · **Category:** `archetype_taxonomy / boundary`
**Archetypes affected:** realtime-messaging, fan-out
**Impact:** low

**Evidence:**  
> Bidirectional mis-cat pair (2 findings): realtime-messaging->fan-out {telegram broadcast}; fan-out->realtime-messaging {discord-server-activity-stream}.

**Suggested fix:** Move telegram (broadcast channels, fan-out-on-read) to fan-out; move discord-server-activity-stream (WebSocket gateway, GenServer-per-guild) to realtime-messaging. Both moves are individually defensible per Phase-1 evidence.

---

## Per-archetype findings (epic: `interview-system-design-ng1`)

### archetype: `ai-infrastructure` — 8 findings (0 high, 3 medium, 5 low)

### [MEDIUM · conf:high] Pattern file ai-infra.md has no entry for gang scheduling / topology-aware GPU scheduling or for training-cluster fault tolerance (async checkpointing, NCCL Flight Recorder, SDC defense). The Distributed-training entry mentions FSDP/Megatron but does not cover the scheduler or fault-tolerance design pressures.

**Finding ID:** `ai-infrastructure-004` · **Category:** `pattern_gap`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/gpu-cluster-scheduler.md`, `docs/coach/problems/training-cluster-fault-tolerance.md`

**Evidence:**  
> ai-infra.md sections are: Continuous batching, PagedAttention, Prefix caching, Speculative decoding, Model-router gateways, MoE, Semantic caching, Eval pipelines, Parallel Safety Pipelines, Distributed training.

**Suggested fix:** Phase 2: either add 'Gang scheduling + topology-aware GPU placement' and 'Async checkpoint + SDC defense' entries to ai-infra.md, or accept the gap and flag these two problems as exploration-stretch with no canonical pattern entry.

---

### [MEDIUM · conf:high] ai-infra.md PagedAttention entry covers KV-cache blocks but not the long-context techniques (MLA, Ring Attention/sequence parallelism, HEADINFER, chunked prefill, prefill/decode disaggregation, KV transfer plane) that two problems treat as Staff+ depth.

**Finding ID:** `ai-infrastructure-005` · **Category:** `pattern_gap`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/long-context-kv-management.md`, `docs/coach/problems/prefill-decode-disaggregation.md`

**Evidence:**  
> Names MLA (Multi-head Latent Attention, DeepSeek-V3) as the compression beyond GQA. Names sequence parallelism / Ring Attention for cross-GPU long-context attention. Names HEADINFER ... Names chunked prefill as the answer to long-prefill HOL blocking.

**Suggested fix:** Phase 2: add pattern entries for 'Chunked prefill + sequence parallelism', 'Prefill/decode disaggregation (DistServe/Splitwise + NIXL/MoonCake KV transport)', and 'MLA / GQA KV-cache compression' so these two problems have canonical pattern references.

---

### [MEDIUM · conf:high] ai-infra.md has no pattern entry for durable agent loops, MCP tool protocol, or sandbox isolation primitives (Firecracker / gVisor / bubblewrap). Two agent-related problems lean heavily on this material but it is not codified as a pattern.

**Finding ID:** `ai-infrastructure-006` · **Category:** `pattern_gap`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/agentic-tool-orchestrator.md`, `docs/coach/problems/sandboxed-agent-execution.md`

**Evidence:**  
> Names Anthropic's Managed Agents 3-tier architecture (Harness brain / Sandbox hands / Session log) ... MCP as the tool protocol with lazy tool-discovery ... Firecracker microVM for untrusted-code-execution tools (125ms cold start, hardware-virtualized isolation); gVisor or bubblewrap for tools with weaker threat models.

**Suggested fix:** Phase 2: add 'Durable agent loop + MCP tool protocol' and 'Sandbox isolation primitives for code-exec agents' to ai-infra.md, OR move these two agent problems to a new agent-platform sub-archetype.

---

### [low · conf:medium] model-cascade-router deep-dive #3 (MoE serving) is essentially a recap of moe-serving's central content (same DeepSeek-V3 numbers, same routing-collapse defense, same MoETuner anchor). Significant content overlap, though framing differs.

**Finding ID:** `ai-infrastructure-008` · **Category:** `duplicate`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/moe-serving.md`, `docs/coach/problems/model-cascade-router.md`

**Evidence:**  
> model-cascade-router deep-dive 3: 'MoE serving as intra-model routing. DeepSeek-V3: 671B total parameters, 37B activated per token, 58 MoE layers × 256 routed + 1 shared expert each → 14,848 routed experts ... routing collapse ... DeepSeek's defense: auxiliary-loss-free dynamic bias adjustment ... MoETuner reports 9.3-17.5% speedup'

**Suggested fix:** Phase 2: tighten model-cascade-router deep-dive #3 to focus on the cascade↔MoE-routing analogy (or replace it with a different deep-dive); avoid duplicating moe-serving's primary depth content.

---

### [low · conf:medium] inference-batching deep-dive #3 covers prompt-cache topology + per-tenant isolation + cross-version invalidation — substantially the same Staff+ content as prompt-cache-infrastructure's three deep-dives. Two problems should not have overlapping Staff+ commit points.

**Finding ID:** `ai-infrastructure-009` · **Category:** `duplicate`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/inference-batching.md`, `docs/coach/problems/prompt-cache-infrastructure.md`

**Evidence:**  
> inference-batching deep-dive 3: 'Prompt cache topology and per-tenant isolation (fleet) ... per-pod prefix tree (RadixAttention, SGLang) ... shared cache cluster ... cache_salt per tenant mixed into the cache key'

**Suggested fix:** Phase 2: either trim inference-batching deep-dive #3 to a one-paragraph pointer to prompt-cache-infrastructure, or refactor prompt-cache-infrastructure to focus on the parts not already in inference-batching (e.g., partial-cache-hits, multi-tier eviction).

---

### [low · conf:low] gpu-cluster-scheduler is a build-the-primitive problem (resource scheduler with gang/topology/preemption); shape mirrors the kubernetes-scheduler entry in infra-primitives. Could plausibly live there.

**Finding ID:** `ai-infrastructure-003` · **Category:** `mis_categorization`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/gpu-cluster-scheduler.md`

**Evidence:**  
> Produces a basic K8s + nvidia-device-plugin design: pods request `nvidia.com/gpu: 1`, default-scheduler bin-packs across nodes, autoscaler adds nodes when pending pods accumulate ... gang scheduling ... topology awareness (NVLink within node, InfiniBand / RoCE across)

**Suggested fix:** Phase 2: compare to `kubernetes-scheduler` (already in infra-primitives) and decide whether the GPU-specific framing (heterogeneous fleet, training↔inference borrowing) is enough to keep this in ai-infrastructure.

---

### [low · conf:high] inference-batching coach-notes reference `state/observed.md` (private state path) — likely fine internally, but worth confirming the file isn't expected to be public/repo-relative when the catalog ships outside the alexey branch.

**Finding ID:** `ai-infrastructure-010` · **Category:** `other`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/inference-batching.md`

**Evidence:**  
> Connection economics is the recurring gap (per `state/observed.md` from the uber session). At 11.4M concurrent connections (ChatGPT scale), per-connection memory in the gateway tier drives pod sizing

**Suggested fix:** Phase 2: verify whether the `state/observed.md` reference belongs in a published problem file or should be reworded to remove the cross-session-state mention.

---

### [low · conf:high] ai-infra.md does not cover multi-tenant LoRA serving (Unified Paging, SGMV), embedding-service scaling (Matryoshka, online/offline pool split), or realtime multi-modal serving (WebSocket voice, vision-token asymmetry) as distinct patterns.

**Finding ID:** `ai-infrastructure-007` · **Category:** `pattern_gap`
**Archetype:** `ai-infrastructure`
**Files:** `docs/coach/problems/multi-tenant-lora-serving.md`, `docs/coach/problems/embedding-service-at-scale.md`, `docs/coach/problems/multimodal-realtime-serving.md`

**Evidence:**  
> Names S-LoRA Unified Paging (base + adapter weights + KV cache in one memory pool) and Punica SGMV kernel ... Matryoshka truncation ... GPT-4o Realtime specifics: WebSocket persistent session, PCM16/24kHz/mono

**Suggested fix:** Phase 2: consider adding 'Multi-tenant LoRA serving (Unified Paging + SGMV)', 'Embedding service (online query vs offline corpus pools)', and 'Realtime multimodal session (WebSocket voice + vision tokens)' pattern entries; or accept that these three problems are exploration-stretch with no canonical pattern reference.

---

### archetype: `caching-read-heavy` — 3 findings (0 high, 1 medium, 2 low)

### [MEDIUM · conf:medium] stock-ticker's dominant pressure is push fan-out over WebSocket to many subscribers, not cache topology; reads as realtime-messaging or fan-out.

**Finding ID:** `caching-read-heavy-001` · **Category:** `mis_categorization`
**Archetype:** `caching-read-heavy`
**Files:** `docs/coach/problems/stock-ticker.md`

**Evidence:**  
> ingest connectors normalize exchange feeds into **Kafka partitioned by symbol** ... and **WebSocket gateways** subscribe and stream to clients (compute lives in aggregators, not gateways)

**Suggested fix:** Phase 2: review whether stock-ticker belongs in realtime-messaging (WebSocket gateway, snapshot+delta with sequence gaps) or fan-out (per-symbol Kafka -> many subscribers), not caching-read-heavy.

---

### [low · conf:low] view-counter's dominant pressure is write hot-key sharding + idempotent counting; arguably concurrent-resource or infra-primitives rather than caching-read-heavy.

**Finding ID:** `caching-read-heavy-003` · **Category:** `mis_categorization`
**Archetype:** `caching-read-heavy`
**Files:** `docs/coach/problems/view-counter.md`

**Evidence:**  
> Names the **hot-key problem** ... and the **sharded-counter fix** (split one counter into N sub-counters keyed by bucket; increment a random shard, **sum all N on read**

**Suggested fix:** Phase 2: check whether view-counter belongs in concurrent-resource (hot-key write contention + idempotency) or stays here for the read/display side.

---

### [low · conf:high] Archetype references only caching.md + networking-transport.md, but top-k-trending and view-counter lean centrally on Count-Min Sketch and HyperLogLog covered in data-structures.md (not referenced).

**Finding ID:** `caching-read-heavy-004` · **Category:** `pattern_gap`
**Archetype:** `caching-read-heavy`
**Files:** `docs/coach/problems/top-k-trending.md`, `docs/coach/problems/view-counter.md`

**Evidence:**  
> Solves heavy-hitters with a **Count-Min Sketch + min-heap of size K** ... a 10x4000 CMS approx 160KB vs ~4GB for an exact map  ; Uses **HyperLogLog** for unique-view cardinality (12KB, 0.81% error

**Suggested fix:** Add docs/coach/patterns/data-structures.md to this archetype's Patterns line (it already documents CMS/HLL/skiplist and is used by leaderboard/top-k-trending/view-counter).

---

### archetype: `concurrent-resource` — 7 findings (0 high, 1 medium, 6 low)

### [MEDIUM · conf:medium] Virtual waiting room / queued admission is a dominant design pressure in 4 problems but is not covered by either referenced pattern (consistency-coordination, api-idempotency)

**Finding ID:** `concurrent-resource-004` · **Category:** `pattern_gap`
**Archetype:** `concurrent-resource`
**Files:** `docs/coach/problems/flash-sale.md`, `docs/coach/problems/sneaker-drop.md`, `docs/coach/problems/ticketmaster.md`, `docs/coach/problems/coupon-redemption.md`

**Evidence:**  
> flash-sale.md: 'A **virtual waiting room** admits users at a controlled rate (~100k/s)'; sneaker-drop.md: 'a **virtual waiting room that gates before the site**'; ticketmaster.md: 'a virtual waiting room sits in front of the booking service'.

**Suggested fix:** Either add a waiting-room / admission-control entry to consistency-coordination.md (or load-balancing.md), or reference an additional pattern file (e.g. reliability-observability.md / load-balancing.md) from the archetype's Patterns line.

---

### [low · conf:medium] parking-garage and resource-pool are near-duplicates by self-declaration (physical-skinned vs abstract finite-pool allocation) — same canonical pressure, separated only by framing

**Finding ID:** `concurrent-resource-003` · **Category:** `duplicate`
**Archetype:** `concurrent-resource`
**Files:** `docs/coach/problems/parking-garage.md`, `docs/coach/problems/resource-pool.md`

**Evidence:**  
> parking-garage.md (delineation note): `parking-garage` is the canonical **finite-slot allocation** variant — the physical-skinned sibling of `resource-pool`'; resource-pool.md says `parking-garage` is its physical-skinned instance'.

**Suggested fix:** Keep both but ensure delineation is sharp (resource-pool = abstract semaphore + connection-pool sizing; parking-garage = OOD-flavored multi-gate skinned variant). Consider whether two files earn their keep or one should fold into the other as a 'variant note'.

---

### [low · conf:low] idempotent-payment reads as a cross-cutting primitive (idempotency keys + state machine + recovery) more than a concurrent-resource problem; could be considered an infra-primitives or pattern-anchor file

**Finding ID:** `concurrent-resource-008` · **Category:** `mis_categorization`
**Archetype:** `concurrent-resource`
**Files:** `docs/coach/problems/idempotent-payment.md`

**Evidence:**  
> idempotent-payment.md delineation note: 'idempotent-payment is the exactly-once-under-retries concurrency primitive underlying bookings, coupons, and orders across this archetype.' Bar-anchors emphasize idempotency keys, Stripe pattern, Orpheus — pattern coverage matches api-idempotency.md squarely.

**Suggested fix:** Phase 2 should decide whether this stays as a concurrent-resource problem or is repositioned as an api-idempotency pattern anchor / infra-primitive. Current placement is reasonable given the concurrency-on-same-key emphasis.

---

### [low · conf:high] ticketmaster.md is missing the '## (Delineation note)' section that every other concurrent-resource file uses

**Finding ID:** `concurrent-resource-001` · **Category:** `other`
**Archetype:** `concurrent-resource`
**Files:** `docs/coach/problems/ticketmaster.md`

**Evidence:**  
> ticketmaster.md ends at '## Known failure modes' (line 63) with no '## (Delineation note)' section, unlike all 13 other concurrent-resource files which include one.

**Suggested fix:** Add a '## (Delineation note)' to ticketmaster.md positioning it against flash-sale/sneaker-drop/airline-seat-booking/hotel-booking (already referenced by those files as the canonical seat-hold variant).

---

### [low · conf:high] ticketmaster.md has a single-source frontmatter while peers list 4-5 sources

**Finding ID:** `concurrent-resource-002` · **Category:** `other`
**Archetype:** `concurrent-resource`
**Files:** `docs/coach/problems/ticketmaster.md`

**Evidence:**  
> ticketmaster.md frontmatter `sources:` contains only one entry (`hello_interview`), whereas every other file in the archetype lists 4-5 sources.

**Suggested fix:** Backfill sources in ticketmaster.md (e.g. ByteByteGo / DDIA OCC chapter / Stripe idempotency docs) to match peer-file source density.

---

### [low · conf:medium] Bot mitigation / rate-limiting / behavioral biometrics is a first-class pressure in sneaker-drop (and present in flash-sale) but neither referenced pattern file covers it

**Finding ID:** `concurrent-resource-005` · **Category:** `pattern_gap`
**Archetype:** `concurrent-resource`
**Files:** `docs/coach/problems/sneaker-drop.md`, `docs/coach/problems/flash-sale.md`

**Evidence:**  
> sneaker-drop.md: 'bots as the dominant adversary (10–40% of Nike SNKRS submissions; one Supreme drop saw 1.9B purchase attempts, 97% inorganic)' — bot mitigation / behavioral biometrics is a first-class pressure.

**Suggested fix:** Add a pointer to security-privacy.md or a dedicated rate-limiting/anti-abuse pattern entry from the archetype's Patterns line; alternatively, accept it as a problem-specific concern.

---

### [low · conf:medium] Saga / compensating-transaction pattern is a recurring pressure across reservation+payment problems but is not surfaced in the referenced consistency-coordination or api-idempotency pattern files

**Finding ID:** `concurrent-resource-006` · **Category:** `pattern_gap`
**Archetype:** `concurrent-resource`
**Files:** `docs/coach/problems/ecommerce-inventory.md`, `docs/coach/problems/wallet-ledger.md`, `docs/coach/problems/idempotent-payment.md`

**Evidence:**  
> ecommerce-inventory.md: 'Payment failure triggers a saga: the order→payment→inventory chain compensates by releasing the reservation'; wallet-ledger.md: 'use a saga: debit A, then credit B, with a compensating credit-back'.

**Suggested fix:** Add a saga / compensating-transaction entry to consistency-coordination.md (it covers OT/CRDTs, OCC, fencing, leader election — sagas would fit), or reference architectural.md from the archetype.

---

### archetype: `conflict-resolution` — 6 findings (0 high, 2 medium, 4 low)

### [MEDIUM · conf:medium] Game netcode framed as CRDT-adjacent but its bar anchors are dominated by tick rate, UDP loss, lag compensation, and authoritative-server prediction — design pressures characteristic of realtime-messaging rather than conflict resolution.

**Finding ID:** `conflict-resolution-001` · **Category:** `mis_categorization`
**Archetype:** `conflict-resolution`
**Files:** `docs/coach/problems/multiplayer-game-sync.md`

**Evidence:**  
> `multiplayer-game-sync` is the hard-real-time member of this archetype: lockstep is a degenerate CmRDT (ops = inputs, the deterministic simulation is the "merge"); client-prediction + reconciliation is the same rebase pattern as `local-first-sync`.

**Suggested fix:** Phase 2: compare against realtime-messaging archetype (sub-second delivery, connection model, server-authoritative tick). If the dominant pressure is connection/transport rather than convergence semantics, relocate; otherwise keep but explicitly justify the CRDT framing in the spine note beyond a single sentence.

---

### [MEDIUM · conf:high] The single 'OT vs CRDTs' pattern entry covers two paragraphs but the 14 problems lean on specific sub-concepts not represented in the pattern: sequence CRDTs (RGA/Fugue), OR-Set add-wins, fractional indexing, awareness CRDT, movable-tree CRDT, rebase-style sync, sync-token incremental sync.

**Finding ID:** `conflict-resolution-004` · **Category:** `pattern_gap`
**Archetype:** `conflict-resolution`
**Files:** `docs/coach/patterns/consistency-coordination.md`

**Evidence:**  
> **Definition.** Operational Transform (OT) achieves convergence in collaborative editing by transforming concurrent operations against each other through a central server; CRDTs (Conflict-free Replicated Data Types) use mathematically designed state (state-based) or operation (op-based) structures that always merge deterministically without coordination.

**Suggested fix:** Expand consistency-coordination.md with at least: (a) sequence-CRDT family + interleaving anomaly, (b) OR-Set add-wins, (c) fractional indexing for ordering, (d) awareness CRDT (LWW-per-client + expiry), (e) rebase-style server-authoritative sync. Each is referenced by 3+ problems and is the load-bearing concept in its problem.

---

### [low · conf:low] Presence-awareness is a sibling of discord-presence (which lives in realtime-messaging); placing it in conflict-resolution turns on the 'awareness CRDT' framing, but the dominant design pressures are WebSocket fan-out + throttling + ephemeral broadcast.

**Finding ID:** `conflict-resolution-002` · **Category:** `mis_categorization`
**Archetype:** `conflict-resolution`
**Files:** `docs/coach/problems/presence-awareness.md`

**Evidence:**  
> **Delineates from `discord-presence`**: that is *connection-scale* online/offline with GenStage fan-out to millions; **this is document-scale** ephemeral editing state, capped at the editor limit (200 Figma / 100 Docs / 50 FigJam).

**Suggested fix:** Phase 2: verify the awareness-CRDT framing is load-bearing enough to anchor this in conflict-resolution. If a candidate could answer this problem competently without ever invoking CRDT machinery, consider relocating to realtime-messaging.

---

### [low · conf:medium] google-sheets and notion both explicitly flag that their core conflict-resolution model is inferred / not fully publicly confirmed; this is healthy honesty but worth tracking so coach prompts don't assert these as ground truth.

**Finding ID:** `conflict-resolution-006` · **Category:** `other`
**Archetype:** `conflict-resolution`
**Files:** `docs/coach/problems/google-sheets.md`, `docs/coach/problems/notion.md`

**Evidence:**  
> **Flags** that OT-on-grid and the dependency-DAG are inferred from the published Docs OT model, not Google-confirmed for Sheets.

**Suggested fix:** Phase 2: confirm both problems carry the 'flag this in a mock' caveat into the persona / bar-anchor prompts so the coach can't be cornered into asserting an unconfirmed claim.

---

### [low · conf:high] Strong, consistent inter-problem 'spine notes' across the archetype delineate ownership crisply. Worth noting as a positive signal — this archetype is internally well-structured and unlikely to have duplicates.

**Finding ID:** `conflict-resolution-007` · **Category:** `other`
**Archetype:** `conflict-resolution`
**Files:** `docs/coach/problems/figma.md`, `docs/coach/problems/figjam-whiteboard.md`, `docs/coach/problems/google-docs.md`, `docs/coach/problems/collaborative-text-editor.md`, `docs/coach/problems/yjs.md`, `docs/coach/problems/presence-awareness.md`, `docs/coach/problems/crdt-primitive.md`, `docs/coach/problems/shopping-cart-crdt.md`, `docs/coach/problems/local-first-sync.md`, `docs/coach/problems/notion.md`

**Evidence:**  
> `figma` owns server-authoritative LWW-per-property multiplayer for a structured document. The infinite-canvas/whiteboard variant (versionNonce LWW, P2P) is `figjam-whiteboard`; ephemeral cursors are `presence-awareness`; the OT and CRDT alternatives it rejected are `google-docs` and `collaborative-text-editor`/`crdt-primitive`.

**Suggested fix:** No action required. Use this archetype's spine-note discipline as a template for under-structured archetypes during taxonomy review.

---

### [low · conf:high] calendar-sync's central correctness story is HTTP conditional PUT / If-Match → 412 (record-level OCC with ETags). The pattern's OCC entry mentions ETags briefly but does not name 412 / RFC 6578 sync-tokens / record-level conflict UI, which is the spine of this problem.

**Finding ID:** `conflict-resolution-005` · **Category:** `pattern_gap`
**Archetype:** `conflict-resolution`
**Files:** `docs/coach/patterns/consistency-coordination.md`

**Evidence:**  
> ## Optimistic vs Pessimistic Concurrency Control

**Suggested fix:** Either add HTTP-native record-level OCC (If-Match → 412, sync-token) to the OCC entry, or accept that calendar-sync sits on an under-represented pattern surface and add a short reference there.

---

### archetype: `fan-out` — 7 findings (0 high, 4 medium, 3 low)

### [MEDIUM · conf:medium] inbox-zero dominant design pressure is per-user ML ranking (Priority Inbox PA-II) + threading + 7-layer spam stack, not producer-to-many-consumer fan-out.

**Finding ID:** `fan-out-001` · **Category:** `mis_categorization`
**Archetype:** `fan-out`
**Files:** `docs/coach/problems/inbox-zero.md`

**Evidence:**  
> Gmail Priority Inbox per-user logistic regression with online passive-aggressive PA-II + non-stationary noisy implicit labels + per-user higher regularization than global + cross-DC scoring

**Suggested fix:** Consider re-filing under ml-in-loop (Priority Inbox ranking) or keeping if 'unified inbox sync' is judged a fan-in/fan-out variant.

---

### [MEDIUM · conf:medium] Discord server activity stream is dominated by real-time messaging concerns (WebSocket gateway, presence, GenServer-per-guild) — overlaps strongly with archetype 3 realtime-messaging which already contains discord-presence/channels/voice.

**Finding ID:** `fan-out-002` · **Category:** `mis_categorization`
**Archetype:** `fan-out`
**Files:** `docs/coach/problems/discord-server-activity-stream.md`

**Evidence:**  
> single Elixir GenServer per guild fans out every event to per-user session processes ... WebSocket gateway per session ... 2.6M concurrent voice users across 850+ servers

**Suggested fix:** Verify whether mega-guild fan-out belongs here vs. realtime-messaging; the file itself notes 'Cross-coverage with messaging discord-presence ... same Manifold + GenStage primitives.'

---

### [MEDIUM · conf:medium] geo-weather-alert-fanout's dominant pressure is geo-targeted broadcast (polygons, FIPS codes, handset GPS filtering, cell-broadcast substrate) which fits the geo-proximity archetype more directly than producer-to-many feed fan-out.

**Finding ID:** `fan-out-003` · **Category:** `mis_categorization`
**Archetype:** `fan-out`
**Files:** `docs/coach/problems/geo-weather-alert-fanout.md`

**Evidence:**  
> CAP v1.2 OASIS XML envelope ... WEA cellular cell-broadcast ... enhanced 100% inside polygon / 0% >528ft outside via WEA 3.0 handset GPS filtering

**Suggested fix:** Check whether the geo-polygon and handset-side spatial-filter elements outweigh the fan-out framing; possibly belongs under geo-proximity.

---

### [MEDIUM · conf:high] Archetype references only async-streaming.md, but 9+ problems (twitter-timeline, instagram-feed, pinterest-home, reddit-feed, sports-scores-fanout) lean heavily on caching topology (Redis sorted sets, hot-celebrity key replication, listing cache, dual HBase cluster) which is owned by caching.md, not async-streaming.md.

**Finding ID:** `fan-out-005` · **Category:** `pattern_gap`
**Archetype:** `fan-out`
**Files:** `docs/coach/patterns/async-streaming.md`

**Evidence:**  
> Patterns. See docs/coach/patterns/async-streaming.md.

**Suggested fix:** Add docs/coach/patterns/caching.md to the archetype's 'Patterns' line (and consider data-structures.md for sorted-set / heap-merge content).

---

### [low · conf:medium] notification-aggregation-service is dominated by ML uplift modelling, multi-head ranking, and diversity demotion — bar-anchors read as ml-in-loop, with fan-out (aggregation) as a secondary concern.

**Finding ID:** `fan-out-004` · **Category:** `mis_categorization`
**Archetype:** `fan-out`
**Files:** `docs/coach/problems/notification-aggregation-service.md`

**Evidence:**  
> Pinterest NEP multi-head GBDT (push-open / email-click / unsub); Policy sends if utility > segment threshold; PID controller auto-tunes per-segment thresholds ... Instagram causal-inference uplift ui = Pr(active|do(send)) − Pr(active|do(drop))

**Suggested fix:** Phase 2 should decide whether this is fan-out (aggregation/dedup) or ml-in-loop (uplift+budget+diversity); arguments for either; keep here only if the aggregation framing is judged primary.

---

### [low · conf:high] Pinterest's Pixie appears in both pinterest-home (fan-out source) and pinterest-pixie (ml-in-loop). Not a duplicate — explicitly cross-coverage — but worth Phase-2 verification that the two files do not collide on canonical prompts.

**Finding ID:** `fan-out-007` · **Category:** `other`
**Archetype:** `fan-out`
**Files:** `docs/coach/problems/pinterest-home.md`, `docs/coach/problems/instagram-feed.md`

**Evidence:**  
> pinterest-home: 'Cross-coverage with ML-in-loop pinterest-pixie (Pixie graph is in both archetypes — fan-out source vs ML candidate generator).'

**Suggested fix:** Phase 2 cross-archetype duplicate check should confirm pinterest-home and ml-in-loop pinterest-pixie cover distinct prompts.

---

### [low · conf:medium] Push-notification gateway limits (APNs/FCM concurrent caps, collapse-id, HTTP/2 connection sizing) are recurring pressures across breaking-news / stock-alert / sports-scores / youtube-subscriptions but no pattern file is referenced for them.

**Finding ID:** `fan-out-006` · **Category:** `pattern_gap`
**Archetype:** `fan-out`
**Files:** `docs/coach/patterns/async-streaming.md`

**Evidence:**  
> breaking-news-fanout, stock-alert-fanout, sports-scores-fanout all rely on APNs/FCM gateway limits (1K concurrent fanouts/project, ~2K req/sec/HTTP2-connection, apns-collapse-id) — neither async-streaming.md nor any other referenced pattern covers push-gateway semantics.

**Suggested fix:** Either add networking-transport.md to the archetype reference set, or note that push-gateway specifics live in the realtime-messaging push-notification problem.

---

### archetype: `frontend` — 7 findings (0 high, 4 medium, 3 low)

### [MEDIUM · conf:medium] news-feed-client and infinite-scroll-feed substantially overlap on cursor pagination + virtualization + IntersectionObserver + scroll restoration; same primary source.

**Finding ID:** `frontend-001` · **Category:** `duplicate`
**Archetype:** `frontend`
**Files:** `docs/coach/problems/news-feed-client.md`, `docs/coach/problems/infinite-scroll-feed.md`

**Evidence:**  
> news-feed-client: 'Cursor-paginated infinite feed with virtualization ... WebSocket-pushed live updates'; infinite-scroll-feed: 'Infinite scroll fetching next page near bottom ... Variable-height items'. Both cite greatfrontend_news_feed.

**Suggested fix:** Either merge infinite-scroll-feed into news-feed-client as a sub-section, or sharpen scopes: infinite-scroll-feed = pure pagination/render mechanics primer; news-feed-client = end-to-end product (composer, optimistic create, ads, WS).

---

### [MEDIUM · conf:high] frontend.md has no entry for the ref-buffer + requestAnimationFrame flush / render-decoupling pattern despite being the canonical Staff+ unlock in 3 catalog problems.

**Finding ID:** `frontend-002` · **Category:** `pattern_gap`
**Archetype:** `frontend`
**Files:** `docs/coach/problems/chatgpt-claude-chat-ui.md`, `docs/coach/problems/stock-trading-dashboard.md`, `docs/coach/problems/copilot-inline-completions.md`

**Evidence:**  
> chatgpt-claude-chat-ui: 'ref-buffer + rAF flush architectural principle (verbatim): "your network layer should never directly drive React renders."' — pattern is the canonical Staff+ unlock across three problems but absent from frontend.md.

**Suggested fix:** Add a 'Ref-buffer + rAF render decoupling' (or 'High-frequency UI batching') section to docs/coach/patterns/frontend.md citing chatgpt-claude-chat-ui and stock-trading-dashboard as canonical uses.

---

### [MEDIUM · conf:high] frontend.md has no entry on Canvas/WebGL vs DOM renderer choice despite 4 catalog problems treating it as the Staff+ depth probe.

**Finding ID:** `frontend-003` · **Category:** `pattern_gap`
**Archetype:** `frontend`
**Files:** `docs/coach/problems/figma-canvas-client.md`, `docs/coach/problems/google-maps-client.md`, `docs/coach/problems/stock-trading-dashboard.md`, `docs/coach/problems/airbnb-search-map.md`

**Evidence:**  
> figma-canvas-client: 'entire rendering layer canvas/WebGL (NOT DOM)'; stock-trading-dashboard: 'DOM/SVG <1k elements; Canvas 2D for depth-of-book; WebGL via GPU sustains 60fps on 500K candlesticks'.

**Suggested fix:** Add a 'Canvas / WebGL rendering tier' section to docs/coach/patterns/frontend.md covering renderer-by-scale (DOM <1k / Canvas / WebGL >10k) with figma + maps + stock-dashboard as references.

---

### [MEDIUM · conf:high] frontend.md has no entry for MSE / EME / adaptive-bitrate streaming despite being core to two catalog problems (video-player, spotify-web-player).

**Finding ID:** `frontend-004` · **Category:** `pattern_gap`
**Archetype:** `frontend`
**Files:** `docs/coach/problems/video-player.md`, `docs/coach/problems/spotify-web-player.md`

**Evidence:**  
> video-player: 'HLS via hls.js cross-browser (Chrome/Firefox lack native HLS); DASH via dash.js; both use MSE to push segments into SourceBuffer' — MSE/EME/ABR is the entire Staff+ bar yet not in frontend.md.

**Suggested fix:** Add a 'Media streaming: MSE + EME + adaptive bitrate' section to docs/coach/patterns/frontend.md.

---

### [low · conf:high] airbnb-search-map's Staff+ bar leans heavily on backend ranking insights (neural location retrieval, two-view ranking) rather than client-side architecture; bar-anchors blur with ml-in-loop archetype.

**Finding ID:** `frontend-007` · **Category:** `other`
**Archetype:** `frontend`
**Files:** `docs/coach/problems/airbnb-search-map.md`

**Evidence:**  
> Bar anchors mention 'two-view ranking', 'neural location retrieval' — '2-layer NN outputs 4 floats defining lat/lng offsets'. These are server-side ranker/retrieval insights, not client architecture.

**Suggested fix:** Either tighten the Staff+ bar to client concerns (virtualization, viewport debounce, history.replaceState, marker clustering) and demote ranking notes to context, or accept the cross-cut framing explicitly.

---

### [low · conf:medium] frontend.md has no entry for cross-origin iframe sandbox + postMessage protocol (Stripe Elements pattern), the canonical Staff+ unlock for stripe-checkout-flow.

**Finding ID:** `frontend-005` · **Category:** `pattern_gap`
**Archetype:** `frontend`
**Files:** `docs/coach/problems/stripe-checkout-flow.md`

**Evidence:**  
> stripe-checkout-flow: 'iframe-based card collection — form contains iframe owned by Stripe; merchant receives only token (PaymentMethod ID); PCI-DSS scope reduces from SAQ D-Merchant ... to SAQ A'.

**Suggested fix:** Add an 'iframe sandbox + postMessage protocol' section to docs/coach/patterns/frontend.md, or accept the gap if checkout is the only problem needing it.

---

### [low · conf:medium] frontend.md covers WebSocket connection management but has no SSE / fetch+ReadableStream streaming pattern entry despite 3 problems naming it as the Staff+ unlock.

**Finding ID:** `frontend-006` · **Category:** `pattern_gap`
**Archetype:** `frontend`
**Files:** `docs/coach/problems/chatgpt-claude-chat-ui.md`, `docs/coach/problems/copilot-inline-completions.md`, `docs/coach/problems/datadog-dashboard.md`

**Evidence:**  
> chatgpt-claude-chat-ui: 'Browser EventSource insufficient: GET-only + no custom Authorization headers. Production uses fetch() + ReadableStream + manual SSE framing parser'; datadog-dashboard: 'Live-tail logs via SSE'.

**Suggested fix:** Either extend the existing 'WebSocket connection management' entry in docs/coach/patterns/frontend.md to cover SSE and fetch+ReadableStream, or add a dedicated 'SSE streaming + AbortController' entry.

---

### archetype: `geo-proximity` — 7 findings (0 high, 1 medium, 6 low)

### [MEDIUM · conf:high] Pattern file covers spatial indexes but not the VRP/CVRPTW/bipartite-matching solver patterns that dominate dispatch and routing problems.

**Finding ID:** `geo-proximity-001` · **Category:** `pattern_gap`
**Archetype:** `geo-proximity`
**Files:** `docs/coach/patterns/data-structures.md`, `docs/coach/problems/last-mile-routing.md`, `docs/coach/problems/instacart-batching.md`, `docs/coach/problems/doordash-dispatch.md`, `docs/coach/problems/lyft-dispatch.md`

**Evidence:**  
> data-structures.md geo entry covers only: 'Geohash, S2, H3, Quadtree, R-tree, k-d Tree'. No coverage of CVRPTW / MIP / Hungarian / LP-relaxation / ruin-and-recreate routing metaheuristics used in 5+ archetype problems.

**Suggested fix:** Either add a routing/optimization pattern file (or section in algorithms-patterns) covering CVRPTW, Hungarian/LP-relaxation, MIP solvers, ruin-and-recreate/LNS, or reference an existing patterns file from archetypes.md for routing-heavy problems.

---

### [low · conf:medium] Substantial overlap between bluetooth-beacon-proximity and find-my-friends on the Apple Find My rotating-P-224 protocol; both have it as a top Staff+ anchor.

**Finding ID:** `geo-proximity-006` · **Category:** `duplicate`
**Archetype:** `geo-proximity`
**Files:** `docs/coach/problems/find-my-friends.md`, `docs/coach/problems/bluetooth-beacon-proximity.md`

**Evidence:**  
> bluetooth-beacon-proximity Staff+: 'Apple Find My inverse-beacon: lost device advertises rotating P-224 public key; nearby Apple devices sniff + encrypt their location to that key + upload anonymously.' — near-verbatim of find-my-friends.

**Suggested fix:** Trim Find My content from bluetooth-beacon-proximity to a cross-ref; keep BLE/Eddystone/UWB content there. Find My protocol stays in find-my-friends.

---

### [low · conf:medium] instacart-batching design pressure is CVRPTW + ML quantile bounding; spatial index is not first-order.

**Finding ID:** `geo-proximity-003` · **Category:** `mis_categorization`
**Archetype:** `geo-proximity`
**Files:** `docs/coach/problems/instacart-batching.md`

**Evidence:**  
> Staff+ anchor leads with 'CVRPTW decomposes into clustering + shopper-assignment' and 'quantile regression q=0.9 predicts upper-bound delivery time' — pressures are batching/optimization + ML quantile, not spatial indexing.

**Suggested fix:** Consider whether ml-in-loop or a routing sub-archetype is a better fit; if kept, strengthen the geo-indexing thread.

---

### [low · conf:medium] find-my-friends design pressure is a cryptographic crowdsourced-finder protocol, not spatial indexing; geo is incidental payload.

**Finding ID:** `geo-proximity-004` · **Category:** `mis_categorization`
**Archetype:** `geo-proximity`
**Files:** `docs/coach/problems/find-my-friends.md`

**Evidence:**  
> Staff+ anchor names 'P-224 EC key pair generated on-device; private key + 256-bit seed SK0 NEVER leave devices' and 'Server-side encrypted reports indexed by SHA-256(P-224 public key)' — dominant pressure is privacy-preserving crypto protocol, not spatial query.

**Suggested fix:** Phase 2 review: keep in geo-proximity (location-sharing UX) or move to a security/privacy primitive archetype if one exists.

---

### [low · conf:low] bluetooth-beacon-proximity reads as a BLE-protocol primitive; spatial index appears only via cross-refs.

**Finding ID:** `geo-proximity-005` · **Category:** `mis_categorization`
**Archetype:** `geo-proximity`
**Files:** `docs/coach/problems/bluetooth-beacon-proximity.md`

**Evidence:**  
> Bar anchors center on 'iBeacon advertising packet 30 bytes...', 'Eddystone 4 frame types', 'Eddystone-EID rotates AES-encrypted 8-byte ID' — pressures are BLE protocol + crypto, not spatial indexing.

**Suggested fix:** Phase 2 review: confirm geo-proximity is the right home, or consider infra-primitives.

---

### [low · conf:low] waze-traffic-update has strong ugc-pipeline / ml-in-loop overtones (crowdsourced report verification, classifiers) on top of routing.

**Finding ID:** `geo-proximity-007` · **Category:** `mis_categorization`
**Archetype:** `geo-proximity`
**Files:** `docs/coach/problems/waze-traffic-update.md`

**Evidence:**  
> Bar anchors include 'DBSCAN clustering + Bayesian/ML classifiers to deduplicate co-located reports + selfish-routing Price of Anarchy = 4' — pressures are UGC moderation + ML fusion + game-theory externality.

**Suggested fix:** Phase 2 review: keep but acknowledge multi-archetype overlap; could justify an ml-in-loop or ugc-pipeline cross-ref.

---

### [low · conf:high] Several problems (lyft-dispatch, didi-dispatch, doordash-dispatch, instacart-batching, snap-map, life360, find-my-friends, google-maps-routing, waze-traffic-update, yelp-search, google-places, foursquare-checkin, snap-geofilter-fanout, geofence-notifications, bluetooth-beacon-proximity, h3-s2-spatial-index, geohash-design) use the H1 heading to enumerate the Staff+ anchor; inconsistent with uber.md which has a clean '# Uber (Ride-Sharing Dispatch)' title.

**Finding ID:** `geo-proximity-008` · **Category:** `other`
**Archetype:** `geo-proximity`
**Files:** `docs/coach/problems/lyft-dispatch.md`

**Evidence:**  
> H1 title is the entire Staff+ anchor: '# Lyft dispatch — Google S2 (not Uber H3) + geohash-level-5 cells (~1 km²) + Redis cluster sharded by S2 cell ID + sorted-sets w/ 30s stale-beacon expiration (15M QPS sustained) + bipartite matching via ILP/LP relaxation + ~30s batched window for Lyft Line + online RL agent considering long-horizon driver-income state + Marketplace Marginal Values (MMV) dual-variable debiasing + Kalman-filter real-time map-matching'.

**Suggested fix:** Cosmetic: decide on H1 convention across archetype (clean title vs. anchor-as-title) and apply consistently.

---

### archetype: `infra-primitives` — 7 findings (1 high, 2 medium, 4 low)

### [**HIGH** · conf:high] ad-click-aggregator is explicitly named as a top-3 prompt of archetype 9 (ML-in-the-loop) but filed in archetype 10 (infra-primitives); content is an application-level streaming-batch reconciliation pipeline, not a primitive build

**Finding ID:** `infra-primitives-001` · **Category:** `mis_categorization`
**Archetype:** `infra-primitives`
**Files:** `docs/coach/problems/ad-click-aggregator.md`

**Evidence:**  
> Top-3 prompts. Design a YouTube recommendation engine · Design CTR prediction · Design Ad Click Aggregator. (from archetypes.md §9 ML-in-the-loop serving)

**Suggested fix:** Move file to ml-in-loop archetype OR re-frame archetype 9's top-3 prompts to remove this. The file's own bar-anchors describe lambda-vs-kappa for ad billing (application-level), not a primitive build like 'design Kafka' or 'design Redis'.

---

### [MEDIUM · conf:medium] stripe-payments is an application-level exactly-once payment workflow (idempotency-key + double-entry ledger + webhooks + Saga), not a primitive build like Kafka/Redis/DynamoDB

**Finding ID:** `infra-primitives-002` · **Category:** `mis_categorization`
**Archetype:** `infra-primitives`
**Files:** `docs/coach/problems/stripe-payments.md`

**Evidence:**  
> Process a payment: charge user's payment method, credit merchant's balance, record the transaction ... Exactly-once execution despite network retries, client crashes, server crashes

**Suggested fix:** Consider concurrent-resource archetype (file uses idempotency keys + ledger writes, archetype 4's design pressure is exactly OCC/lock/idempotency for limited-resource contention) OR keep here but explicitly document the boundary that 'application-grade exactly-once systems' belong in infra-primitives.

---

### [MEDIUM · conf:high] Neither referenced pattern file covers consensus protocols (Raft/Paxos/Zab/Multi-Paxos) explicitly, yet etcd/zookeeper/spanner/kafka(KRaft)/aurora all depend on consensus as their substrate at Staff+ bar

**Finding ID:** `infra-primitives-004` · **Category:** `pattern_gap`
**Archetype:** `infra-primitives`
**Files:** `docs/coach/patterns/storage-databases.md`, `docs/coach/patterns/architectural.md`

**Evidence:**  
> Names ZooKeeper's Zab protocol (or Raft for etcd) for consensus ... articulates Multi-Paxos vs Raft vs Zab trade-offs (from zookeeper.md bar-anchors)

**Suggested fix:** Add a consensus section to architectural.md or storage-databases.md (Replication has one paragraph but doesn't cover Raft/Paxos/Zab as a substrate), or reference an additional pattern file. Several Staff+ bar-anchors in this archetype hinge on naming the consensus protocol.

---

### [low · conf:medium] s3.md and colossus.md cover storage substrates that are close in shape; both files explicitly call out the boundary, so they are distinct, but worth verifying coach notes consistency

**Finding ID:** `infra-primitives-007` · **Category:** `other`
**Archetype:** `infra-primitives`
**Files:** `docs/coach/problems/s3.md`, `docs/coach/problems/colossus.md`

**Evidence:**  
> No `colossus` overlap concern at L6+: the Colossus filesystem problem (file-system semantics: open/append/close + L4 SSD cache + 1MB chunks) is genuinely distinct from the S3 object-store problem (from s3.md coach notes)

**Suggested fix:** Not a real duplicate; both files explicitly distinguish object-store vs filesystem semantics. Phase 2 can confirm both are kept.

---

### [low · conf:medium] zookeeper.md and etcd.md cover overlapping consensus-KV substrate; both files explicitly call out the workload-framing distinction, but a reader could conflate them

**Finding ID:** `infra-primitives-008` · **Category:** `other`
**Archetype:** `infra-primitives`
**Files:** `docs/coach/problems/zookeeper.md`, `docs/coach/problems/etcd.md`

**Evidence:**  
> Distinct from `zookeeper` problem by workload framing. `zookeeper` is the coordination service (locks, leader election, fencing tokens with 93% KeepAlive workload); `etcd` is the configuration store (from etcd.md coach notes)

**Suggested fix:** Both files include redirect language for the coach; verify the distinction is sharp enough in Phase 2. Low priority — likely fine as-is.

---

### [low · conf:medium] Time/clock primitives (TrueTime, HLC, NTP-skew handling) are critical for spanner.md and snowflake-id.md Staff+ bar-anchors but not covered by either referenced pattern file

**Finding ID:** `infra-primitives-005` · **Category:** `pattern_gap`
**Archetype:** `infra-primitives`
**Files:** `docs/coach/problems/snowflake-id.md`, `docs/coach/problems/spanner.md`, `docs/coach/patterns/storage-databases.md`, `docs/coach/patterns/architectural.md`

**Evidence:**  
> TrueTime + commit-wait gives strict serializability at ~4ms commit-wait cost ... HLC structure: 48-bit physical timestamp + 16-bit logical counter (from snowflake-id.md)

**Suggested fix:** Either add a clocks/time section to storage-databases.md (since it sits alongside isolation levels) or accept that these are problem-local depth probes that don't need a pattern home.

---

### [low · conf:medium] Rate-limiting algorithms (token-bucket, GCRA, sliding-window, leaky-bucket) are the central pressure of stripe-rate-limiter.md but absent from both referenced pattern files

**Finding ID:** `infra-primitives-006` · **Category:** `pattern_gap`
**Archetype:** `infra-primitives`
**Files:** `docs/coach/problems/stripe-rate-limiter.md`, `docs/coach/patterns/storage-databases.md`, `docs/coach/patterns/architectural.md`

**Evidence:**  
> Names GCRA (Generic Cell Rate Algorithm) as Stripe's specific token-bucket variant ... single Theoretical Arrival Time (TAT) field per key (from stripe-rate-limiter.md)

**Suggested fix:** Consider referencing reliability-observability.md or load-balancing.md from this archetype's Patterns line (the rate-limiter problem fits more naturally with those pattern subjects).

---

### archetype: `ml-in-loop` — 4 findings (0 high, 2 medium, 2 low)

### [MEDIUM · conf:medium] Autonomous driving inference is embedded safety-critical inference infra, not a ranking funnel; design pressure (ASIL-D fail-operational, sensor fusion, on-vehicle dual-SoC) maps more naturally to ai-infrastructure than to the ml-in-loop candidate-gen → rank → re-rank archetype summary.

**Finding ID:** `ml-in-loop-001` · **Category:** `mis_categorization`
**Archetype:** `ml-in-loop`
**Files:** `docs/coach/problems/autonomous-driving-inference.md`

**Evidence:**  
> Articulates **safety-critical embedded inference** — architecturally distinct from cloud-served ranking. Cites **<100ms end-to-end** perception → planning → control

**Suggested fix:** Consider re-filing under ai-infrastructure (inference-serving infra) or splitting ml-in-loop into a 'serving funnels' vs 'embedded/realtime inference' sub-grouping. At minimum, acknowledge it as boundary case in archetypes.md.

---

### [MEDIUM · conf:high] Pattern file ml-specific.md does not cover safety-critical / embedded / low-power inference concerns invoked by autonomous-driving-inference and voice-assistant-routing (wake-word AOP, ASIL-D decomposition, fail-operational).

**Finding ID:** `ml-in-loop-003` · **Category:** `pattern_gap`
**Archetype:** `ml-in-loop`
**Files:** `docs/coach/patterns/ml-specific.md`, `docs/coach/problems/autonomous-driving-inference.md`, `docs/coach/problems/voice-assistant-routing.md`

**Evidence:**  
> ml-specific.md sections: Two-Tower, Multi-Stage Funnel, Feature Store, Model Registry/Shadow/Canary, Offline-vs-Online Metrics, Drift, Online Learning, Cold Start, LLM Serving. No section on embedded/realtime/safety-critical inference (ASIL-D, fail-operational, dual-SoC, sensor fusion, on-AOP low-power detectors).

**Suggested fix:** Add a 'Safety-critical / embedded inference' pattern section to ml-specific.md (or to ai-infra.md if those two problems migrate). Cover ASIL-D decomposition, dual-SoC cross-check, fail-operational redundancy, low-power 2-stage AOP detectors.

---

### [low · conf:medium] Voice-assistant routing is a cascade-of-ML-models (ASR/NLU/skill routing) with heavy on-device + low-power inference concerns; only partially overlaps with ml-in-loop's stated 'candidate-gen → ranking → re-rank funnel' pressure. Skill routing (Shortlister + HypRank) is the most ml-in-loop-shaped piece; the wake-word/ASR portions are embedded inference.

**Finding ID:** `ml-in-loop-002` · **Category:** `mis_categorization`
**Archetype:** `ml-in-loop`
**Files:** `docs/coach/problems/voice-assistant-routing.md`

**Evidence:**  
> Articulates **classical voice-assistant stack as cascade of ML models** in tight latency budgets, each with separate eval harnesses — NOT one ML model. Names **5-stage pipeline**: wake-word detection (on-device, sub-200ms, <100KB) → streaming ASR

**Suggested fix:** Either narrow the problem to the skill-routing slice (drop ASR/wake-word details) or treat as a cross-archetype boundary case with ai-infrastructure.

---

### [low · conf:medium] feature-store and model-rollout-shadow are ML-platform infra problems (not product ranking systems); the ml-in-loop archetype summary in archetypes.md emphasizes 'candidate-gen → ranking → re-rank funnel' which doesn't naturally describe them. They are still close enough that ml-in-loop is the best fit, but the archetype summary could be widened.

**Finding ID:** `ml-in-loop-007` · **Category:** `other`
**Archetype:** `ml-in-loop`
**Files:** `docs/coach/problems/feature-store.md`, `docs/coach/problems/model-rollout-shadow.md`

**Evidence:**  
> Real-time feature store — point-in-time-correct joins + offline-online consistency + dual-store + streaming aggregations. ML model rollout — shadow → canary → A/B + champion-challenger + three drift signals + auto-rollback + Thompson-sampling bandits.

**Suggested fix:** Consider broadening the ml-in-loop summary in archetypes.md to explicitly include ML-platform infra (feature stores, rollout, drift, registries) so these problems aren't conceptual outliers within the archetype.

---

### archetype: `realtime-messaging` — 12 findings (0 high, 6 medium, 6 low)

### [MEDIUM · conf:medium] telegram is a broadcast channel / fan-out problem framed against twitter-timeline; dominant pressure is fan-out strategy + push-notification fan-out, not connection model

**Finding ID:** `realtime-messaging-002` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/telegram.md`

**Evidence:**  
> 'Recognizes this as fan-out-on-read, not fan-out-on-write -- you do not write 200M inboxes' ... 'Differentiates from `twitter-timeline` by adding edit/delete semantics'

**Suggested fix:** Consider whether telegram fits better under fan-out (producer-to-many-consumer broadcast with celebrity-channel pressure)

---

### [MEDIUM · conf:medium] twitch-streaming's dominant design pressure is video transcoding ladder + CDN fan-out (ugc-pipeline archetype summary: 'chunking, dedup, transcoding ladders, CDN')

**Finding ID:** `realtime-messaging-003` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/twitch-streaming.md`

**Evidence:**  
> 'Treats live video as RTMP in, HLS out via CDN' ... 'Twitch's in-house hardware transcoders ... 10x capacity at 2x cost' ... 'bitrate ladder (source / 1080p60 / 720p60 ...)'

**Suggested fix:** Consider whether live-streaming fits ugc-pipeline (transcoding ladder + CDN delivery) versus realtime-messaging (connection model + presence)

---

### [MEDIUM · conf:medium] youtube-live is dominated by transcoding-ladder + multi-CDN aggregation + CDN delivery (ugc-pipeline pressures), not connection-model / presence pressures

**Finding ID:** `realtime-messaging-004` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/youtube-live.md`

**Evidence:**  
> 'DASH+QUIC delivery for low-latency tier; HLS for compatibility ... transcoding ladder ... Multi-language audio tracks ... CDN distribution: PoPs cache CMAF chunks'

**Suggested fix:** Consider whether live-streaming with chunked-CMAF + transcoding belongs under ugc-pipeline rather than realtime-messaging

---

### [MEDIUM · conf:medium] mqtt-broker is a 'design the messaging-broker primitive' problem (QoS semantics, persistent sessions, multi-tenant isolation) closer in spirit to infra-primitives (kafka/pulsar)

**Finding ID:** `realtime-messaging-005` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/mqtt-broker.md`

**Evidence:**  
> 'MQTT broker - IoT messaging at 1M+ devices with QoS 0/1/2 + persistent sessions' ... 'QoS levels - 0 (at-most-once...), 1 (at-least-once...), 2 (exactly-once via 4-step ... handshake)'

**Suggested fix:** Consider whether designing-the-broker-primitive belongs with kafka/pulsar under infra-primitives rather than realtime-messaging delivery problems

---

### [MEDIUM · conf:medium] Pattern does not cover MLS / Signal Protocol (E2E group key crypto), nor presence-fan-out economics (Manifold-style batched send), nor SFU layer-drop with encrypted payloads -- all dominant Staff+ topics in this archetype's problems

**Finding ID:** `realtime-messaging-009` · **Category:** `pattern_gap`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/patterns/networking-transport.md`

**Evidence:**  
> networking-transport.md covers DNS, TCP/UDP/QUIC, WebSocket/SSE/LongPoll, WebRTC SFU/MCU, HTTP versions, TLS, CDN, reverse-proxy/API-gateway

**Suggested fix:** Either add a 'secure-messaging-crypto' pattern (covering X3DH / Double Ratchet / MLS) or accept that signal-protocol/mls-group/audio-rooms invoke pressures outside the linked pattern

---

### [MEDIUM · conf:medium] Pattern's WebRTC subsection does not cover simulcast-vs-SVC, TWCC/GCC congestion control, NetEQ jitter buffer, DAVE/MLS E2E, or per-SFU capacity models -- all explicit Staff+ unlocks in discord-voice/zoom/webrtc-sfu

**Finding ID:** `realtime-messaging-010` · **Category:** `pattern_gap`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/patterns/networking-transport.md`

**Evidence:**  
> Pattern's WebRTC entry: 'Use an SFU for group video calls to avoid NxM peer connections ... Production systems. Zoom (proprietary SFU), Twilio (SFU-based), Google Meet (SFU)'

**Suggested fix:** Deepen the WebRTC subsection of networking-transport.md or add a companion pattern covering SFU operational concerns

---

### [low · conf:medium] discord-channels is primarily a storage/DB-migration problem (Cassandra->ScyllaDB, partitioning, hot-partition coalescing) rather than real-time delivery

**Finding ID:** `realtime-messaging-001` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/discord-channels.md`

**Evidence:**  
> # Discord channels - message storage at trillion-message scale (Cassandra->ScyllaDB) ... 'Store trillions of messages partitioned by channel ... 177 Cassandra nodes -> 72 ScyllaDB nodes (53% disk reduction)'

**Suggested fix:** Consider whether this problem fits better under infra-primitives (DB design / shard-per-core engine) or caching-read-heavy (request coalescing, hot-partition mitigation)

---

### [low · conf:medium] twilio's dominant pressure is carrier-routing + per-carrier throughput shaping + compliance, more akin to a messaging-gateway primitive than a real-time delivery system

**Finding ID:** `realtime-messaging-006` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/twilio.md`

**Evidence:**  
> 'Twilio - programmable messaging gateway + SIP voice termination' ... 'SMPP gateway architecture ... A2P 10DLC throughput tiers ... per-carrier shaping queues; trust-score gating'

**Suggested fix:** Consider whether twilio fits infra-primitives (gateway/primitive design with rate-limit/routing) better than realtime-messaging

---

### [low · conf:low] webrtc-sfu is explicitly framed as a primitive ('primitive: ICE/STUN/TURN ...') in the title; may fit infra-primitives, though it underpins many realtime-messaging problems

**Finding ID:** `realtime-messaging-007` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/webrtc-sfu.md`

**Evidence:**  
> '# WebRTC SFU - primitive: ICE/STUN/TURN, DTLS-SRTP, simulcast, TWCC, jitter buffer'

**Suggested fix:** Phase 2 should consider whether 'primitive' problems (webrtc-sfu, mls-group, signal-protocol) belong under infra-primitives or remain co-located with the systems that use them

---

### [low · conf:low] Both signal-protocol and mls-group are cryptographic-protocol designs (FS/PCS, TreeKEM, X3DH); dominant pressure is protocol mechanics, not delivery / connection-model / presence

**Finding ID:** `realtime-messaging-008` · **Category:** `mis_categorization`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/signal-protocol.md`, `docs/coach/problems/mls-group.md`

**Evidence:**  
> signal-protocol: 'Signal Protocol - X3DH + Double Ratchet + Sender Keys for E2E messaging'; mls-group: 'MLS group - RFC 9420 group E2E with TreeKEM at O(log N) update cost'

**Suggested fix:** Phase 2 should evaluate whether crypto-protocol-design problems form their own sub-cluster or are correctly co-located here as substrate

---

### [low · conf:high] Three problems (audio-rooms, twitch-streaming, youtube-live) share dominant pressure of HLS/CMAF + CDN fan-out for one-to-many broadcast -- possible internal sub-cluster worth noting for taxonomy

**Finding ID:** `realtime-messaging-012` · **Category:** `other`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/problems/audio-rooms.md`, `docs/coach/problems/twitch-streaming.md`, `docs/coach/problems/youtube-live.md`

**Evidence:**  
> audio-rooms uses HLS for listener fan-out ('listeners receive an HLS/LL-HLS mux'); twitch-streaming and youtube-live are live-video CDN fan-out via HLS/DASH

**Suggested fix:** Flag to Phase 2: cluster of CDN-broadcast-of-live-media problems may be evidence for a split or for moving them collectively

---

### [low · conf:medium] Three large sub-clusters of this archetype (push gateway, persistent-connection economics, IoT broker) have no pattern coverage at all

**Finding ID:** `realtime-messaging-011` · **Category:** `pattern_gap`
**Archetype:** `realtime-messaging`
**Files:** `docs/coach/patterns/networking-transport.md`

**Evidence:**  
> Pattern lacks any entry for push-notification gateway (APNs / FCM), persistent-connection memory economics (Erlang BEAM 1-2M/box), or IoT messaging semantics (MQTT QoS)

**Suggested fix:** Phase 2 should consider whether networking-transport.md needs expansion or whether these clusters warrant their own pattern files

---

### archetype: `search-indexing` — 2 findings (0 high, 1 medium, 1 low)

### [MEDIUM · conf:medium] Archetype references only data-structures.md, but the problems' core design pressures (LTR reranking, CDC->Kafka NRT update pipelines, doc-vs-term partitioning, two-phase retrieve-then-rerank, lock-free concurrent indexing) extend well beyond inverted-index/FST/HNSW data structures.

**Finding ID:** `search-indexing-002` · **Category:** `pattern_gap`
**Archetype:** `search-indexing`
**Files:** `docs/coach/patterns/data-structures.md`, `docs/coach/archetypes.md`

**Evidence:**  
> ## 7. Search and indexing
...
**Patterns.** See `docs/coach/patterns/data-structures.md`.

**Suggested fix:** Add references to additional pattern files (e.g. async-streaming.md for CDC/Kafka ingest paths in amazon-product-search/twitter-search/github-code-search; ml-specific.md for LTR rerank in geo-place-search/google-search; consistency-coordination.md for incremental-indexing's Percolator transactions) OR create a dedicated search/ranking pattern file.

---

### [low · conf:high] Two problems are self-declared as ~25-min deep-dive/follow-up problems rather than full 50-min solo slots. The archetype index does not mark this scope distinction, so a user picking from the catalog cannot tell which problems are full-slot vs paired follow-ups.

**Finding ID:** `search-indexing-003` · **Category:** `other`
**Archetype:** `search-indexing`
**Files:** `docs/coach/problems/incremental-indexing.md`, `docs/coach/problems/spell-correction.md`

**Evidence:**  
> *(Note: this is a 25-min follow-up problem, not a full solo slot — typically paired with `google-search` or `elasticsearch`.)*

**Suggested fix:** Surface the 'follow-up / deep-dive only' scope in `archetypes.md` next to those slugs (e.g. annotate `incremental-indexing†`, `spell-correction†`) so callers of the catalog don't pick a follow-up as a standalone mock.

---

### archetype: `ugc-pipeline` — 3 findings (0 high, 1 medium, 2 low)

### [MEDIUM · conf:high] Archetype 5 only references storage-databases.md, but UGC pipelines hinge on async/event-driven processing (Kafka, SQS, S3 events, Temporal, DLQ) not covered there; async-streaming.md is the obvious missing reference.

**Finding ID:** `ugc-pipeline-001` · **Category:** `pattern_gap`
**Archetype:** `ugc-pipeline`
**Files:** `docs/coach/archetypes.md`, `docs/coach/patterns/storage-databases.md`

**Evidence:**  
> **Patterns.** See `docs/coach/patterns/storage-databases.md`.

**Suggested fix:** Add `docs/coach/patterns/async-streaming.md` to the archetype's Patterns line (and consider `architectural.md` for the DAG/orchestrator framing); keep storage-databases.md for the object-store vs metadata-DB split.

---

### [low · conf:low] content-addressed-dedup self-describes as a 'primitive' shared by other ugc-pipeline problems; it reads more like an infra-primitives entry (CDC + fingerprint index + Merkle) than an upload→process→store→serve pipeline.

**Finding ID:** `ugc-pipeline-002` · **Category:** `mis_categorization`
**Archetype:** `ugc-pipeline`
**Files:** `docs/coach/problems/content-addressed-dedup.md`

**Evidence:**  
> `content-addressed-dedup` is the **dedup primitive** underlying `dropbox`, `google-photos`, and `backup-incremental`.

**Suggested fix:** Phase 2 should compare against infra-primitives archetype framing; if it stays here, tighten the delineation note to claim it as a UGC-pipeline building block.

---

### [low · conf:low] resumable-upload reads as a protocol/primitive (S3 multipart + tus mechanics, presigned URLs, integrity) shared across the other ugc problems rather than a full UGC pipeline; could fit infra-primitives.

**Finding ID:** `ugc-pipeline-003` · **Category:** `mis_categorization`
**Archetype:** `ugc-pipeline`
**Files:** `docs/coach/problems/resumable-upload.md`

**Evidence:**  
> `resumable-upload` is the **upload protocol** stage shared by `youtube-upload`, `instagram-upload`, `google-photos`, and `dropbox`.

**Suggested fix:** Phase 2 should weigh whether the catalog wants 'shared upload-protocol primitive' in ugc-pipeline or in infra-primitives; either is defensible.

---

## Cross-archetype duplicate candidates (epic: `interview-system-design-ng1`)

### [low · conf:high] Same domain but materially different prompts: autocomplete is backend FST/trie/sharding; autocomplete-typeahead is client async-hazard + ARIA. Intentional split, not a duplicate.

**Finding ID:** `xc-dup-001` · **Category:** `duplicate`
**Archetypes affected:** search-indexing, frontend
**Files:** `docs/coach/problems/autocomplete.md`, `docs/coach/problems/autocomplete-typeahead.md`

**Evidence:**  
> autocomplete (search-indexing) — 'Stores top-K completions precomputed per trie node ... Lucene FST suggester ... shards the trie by first 1-2 prefix chars'; autocomplete-typeahead (frontend) — 'AbortController ... debounce vs throttle ... ARIA combobox 1.2 ... aria-activedescendant'.

**Suggested fix:** No action. Confirmed clean cross-archetype split.

---

### [low · conf:high] Intentional backend (server-authoritative LWW design) + frontend (WASM/WebGL client) split. Not a duplicate.

**Finding ID:** `xc-dup-002` · **Category:** `duplicate`
**Archetypes affected:** conflict-resolution, frontend
**Files:** `docs/coach/problems/figma.md`, `docs/coach/problems/figma-canvas-client.md`

**Evidence:**  
> figma (conflict-resolution) — 'Map<ObjectID, Map<Property, Value>> ... last-writer-wins per (object, property) ... server defining order ... fractional indexing'; figma-canvas-client (frontend) — 'entire rendering layer canvas/WebGL ... WebAssembly C++ ... R-tree spatial index ... bindings layer'.

**Suggested fix:** No action.

---

### [low · conf:high] Intentional backend (OT/Jupiter) + frontend (cursor overlay + IME + offline IndexedDB) split.

**Finding ID:** `xc-dup-003` · **Category:** `duplicate`
**Archetypes affected:** conflict-resolution, frontend
**Files:** `docs/coach/problems/google-docs.md`, `docs/coach/problems/google-docs-client.md`

**Evidence:**  
> google-docs (conflict-resolution) — 'Jupiter central-server model ... TP1/TP2 ... transforms each incoming op only against that history'; google-docs-client (frontend) — 'optimistic typing with rollback ... presence cursors as absolutely-positioned div overlays ... IndexedDB TransactionQueue ... DOM is NOT source of truth'.

**Suggested fix:** No action.

---

### [low · conf:high] uber is dispatch (geo); uber-surge is ML pricing. Different prompts, explicitly delineated.

**Finding ID:** `xc-dup-004` · **Category:** `duplicate`
**Archetypes affected:** geo-proximity, ml-in-loop
**Files:** `docs/coach/problems/uber.md`, `docs/coach/problems/uber-surge.md`

**Evidence:**  
> uber (geo-proximity) — 'H3 hexagonal grid ... matching algorithm (nearest-K filter then ranking by ETA + acceptance probability) ... driver state machine'; uber-surge (ml-in-loop) — 'demand-forecast GBM ... price-elasticity controller ... active-active multi-region failover ... Michelangelo'.

**Suggested fix:** No action.

---

### [low · conf:high] Backend ranking (ml-in-loop) vs client map+grid sync (frontend). Different prompts. airbnb-search-map's bar-anchor leakage into backend-ranking territory was flagged separately (frontend-007).

**Finding ID:** `xc-dup-005` · **Category:** `duplicate`
**Archetypes affected:** ml-in-loop, frontend
**Files:** `docs/coach/problems/airbnb-search-ranking.md`, `docs/coach/problems/airbnb-search-map.md`

**Evidence:**  
> airbnb-search-ranking — 'DNN ranker architecture: 195 features ... 1.7B pairs ... listing2vec 32-d skip-gram ... IVF over HNSW'; airbnb-search-map — 'react-window FixedSizeList/Grid ... history.replaceState (not pushState) ... canvas/WebGL marker layer ... debounce viewport-bbox refetch'.

**Suggested fix:** No action; see frontend-007 for related Staff+ bar tightening.

---

### [low · conf:high] pinterest-home is the feed system using Pixie as a candidate source; pinterest-pixie is the graph-reco algorithm (PinSage/PinnerSage) deep dive. fan-out's own envelope (fan-out-007) flagged this for verification — confirmed distinct.

**Finding ID:** `xc-dup-006` · **Category:** `duplicate`
**Archetypes affected:** fan-out, ml-in-loop
**Files:** `docs/coach/problems/pinterest-home.md`, `docs/coach/problems/pinterest-pixie.md`

**Evidence:**  
> pinterest-home — 'SmartFeed Worker multi-source priority queue + dual HBase cluster ... Pixie graph as candidate generator: 60ms p99, 1K QPS/server'; pinterest-pixie — 'PinSage's importance-sampled neighborhoods ... ~100,000 random walks/query on 3B-node / 17B-edge graph ... PinSage hyperparameters: K=2 conv layers ... PinnerSage multi-vector user representations'.

**Suggested fix:** No action. Distinct prompts intentionally co-referenced.

---

### [MEDIUM · conf:medium] Two moderation problems explicitly delineate (UGC-pipeline integration vs AI-infra LLM-output moderation), but the line is thin and both reference classifier cascades + human review queues. Worth a Phase-3 cross-read to confirm the boundary holds in detail.

**Finding ID:** `xc-dup-007` · **Category:** `duplicate`
**Archetypes affected:** ugc-pipeline, ai-infrastructure
**Files:** `docs/coach/problems/content-moderation-pipeline.md`, `docs/coach/problems/safety-moderation-pipeline.md`

**Evidence:**  
> ugc-pipeline content-moderation-pipeline self-description: 'pipeline integration of moderation (gate placement, hash/fingerprint matching, confidence routing, human-review queue) — distinct from AI-infra safety-moderation-pipeline'.

**Suggested fix:** Phase 3: cross-read both files end-to-end and tighten delineation notes if any Staff+ anchor overlaps. Current state: intentional twin, low duplication risk.

---

## Orphan patterns (epic: `interview-system-design-ng1`)

These pattern files exist under `docs/coach/patterns/` but are not referenced by any archetype in `archetypes.md`. They may be intentional cross-cutting references, or they may be candidates for cleanup.

- `docs/coach/patterns/core-concepts.md`
- `docs/coach/patterns/load-balancing.md`
- `docs/coach/patterns/papers.md`
- `docs/coach/patterns/reliability-observability.md`
- `docs/coach/patterns/security-privacy.md`
- `docs/coach/patterns/tradeoffs.md`

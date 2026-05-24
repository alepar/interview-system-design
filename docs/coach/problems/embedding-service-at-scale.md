---
slug: embedding-service-at-scale
archetype: ai-infrastructure
sources:
  igotanoffer_openai: igotanoffer.com (OpenAI SWE prompt: "Design a vector database to store and search billions of embeddings efficiently")
  openai_text_embedding_3: openai.com/index/new-embedding-models-and-api-updates/
  meta_quickupdate_nsdi24: usenix.org/conference/nsdi24/presentation/matam
  cohere_embed_v3: cohere.com/embed
---

# Embedding service at scale (multi-tenant, online + offline workloads)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic embedding service: HTTP endpoint, GPU-backed model, batch internally for throughput. Doesn't distinguish online query embedding from offline corpus embedding workloads.
- **Senior (L5/E5):** Splits the two paths: low-latency online query embedding (10-50ms target) and high-throughput offline doc embedding (billions/day). Names dimension truncation as a cost lever (Matryoshka Representation Learning). Discusses embedding-model versioning as a real operational problem.
- **Staff+ (L6/E6+):** Drives proactively. Quantifies the two workloads: online ~10-50ms p99 per query embedding, offline ~50-80K tokens/sec on a single A100 with batched inference. Cites OpenAI text-embedding-3 specifics: 3072-dim large variant, MTEB 64.6%, Matryoshka truncation (256-d truncated still outperforms ada-002 at 1536-d). Cohere Embed v3: 96 texts per batch, 512-token chunking constraint. Cost math: $0.13/1M tokens (OpenAI large); self-hosted BGE-M3 on A100 ~$0.005/1M tokens at full utilization — flips build-vs-buy at >5-10% utilization. Names embedding-model migration as a multi-day GPU job for 1B-doc corpus; dual-write index for transition window. Meta QuickUpdate (NSDI 2024): 13× reduction in embedding-update bandwidth for production DLRM. Stretch (Sr Staff bar): semantic-hash cache for hot query templates; multi-modal embedding routing (text vs image vs audio service pools); streaming ingest (Kafka → Flink → embedding service → vector DB) with incremental partial updates.

## Canonical decomposition

### Requirements
**Functional:**
- Online query embedding at 100K+ QPS with sub-50ms p99
- Offline document embedding at 100M+ docs/day for indexing
- Multi-modal support (text, image, audio) with appropriate model per modality
- Embedding model versioning with dual-write migration support
- Per-tenant rate limiting and cost attribution

**Non-functional (with numbers):**
- Online p99 latency <50ms (embedding + network); typical 10-30ms
- Offline throughput: 50-80K tokens/sec on A100 (BGE-M3 with Flash Attention 2)
- Storage: 4 TB per 1B 1024-dim float32 vectors; truncatable to 256-d → 1 TB
- Cost ($0.13/1M tokens for OpenAI text-embedding-3-large; ~$0.005/1M tokens self-hosted at full utilization)
- Migration cost: re-embedding 1B docs on a single A100 ~5.8 days (NVIDIA L4 benchmark)

### Core entities
- **EmbeddingRequest:** request_id, tenant_id, model_version, input_type (query | document), texts (list, ≤batch_limit), dimensions (truncate target)
- **EmbeddingBatch:** batch_id, requests (list), submitted_ts, gpu_assigned
- **ModelVersion:** model_id, dim, max_input_tokens, supported_modalities, deployed_pods
- **CacheEntry:** semantic_hash, embedding, ttl, hit_count

### API
- `POST /v1/embeddings` body={input, model, dimensions?, encoding_format?} → {data: [{embedding, index}], usage}
- `POST /v1/embeddings/batch` async batch ingestion endpoint → {batch_id}
- `GET /v1/embeddings/batch/:id` → status + output URI

### HLD
Two distinct service pools share the embedding model fleet but operate at different operational profiles. The **online pool** is autoscaled aggressively (Knative-style scale-to-zero, fast cold-start via pre-warmed model containers), runs small batches (1-8 queries) to minimize per-request latency, exposes a synchronous REST endpoint. A **semantic-hash cache** sits in front: hash the input text (or template-normalized version for templated queries) and check for recent cached embedding; serve from cache on hit, skipping the GPU call entirely. The **offline pool** uses dedicated reserved capacity (no scale-to-zero — keep GPUs warm), large batches (96+ texts per Cohere; up to 512+ for BGE-M3), accepts async batch jobs via queue (Kafka or job-scheduler). The **embedding-model registry** maintains model versions with deployment state; supports dual-deployment for migrations (old version serves existing queries; new version warmed up; traffic shifts over days). The **streaming ingest pipeline** (Kafka → Flink → embedding service → vector DB) handles continuous doc ingestion with incremental updates (Meta QuickUpdate pattern: 13× reduction in embedding-update bandwidth via partial-update semantics rather than full re-embedding). **Multi-modal routing**: requests are routed by input type — text → BGE/E5/text-embedding-3 pool; image → CLIP/SigLIP pool; audio → embedding-via-Whisper-then-text-pool or dedicated audio model.

### Deep dives
1. **Online vs offline path separation with autoscaling.** Online needs fast cold-start + small batches + tight tail-latency budget. Offline needs steady-state high throughput + large batches + tolerant tail. Running them on the same pool is a compromise — small online batches starve large offline batches; large offline batches inflate online p99. Production answer: dedicated pools with shared model fleet (same model weights, different scheduler config). Online uses Knative or KServe with autoscale-to-zero for cost; offline uses Dataflow/Spark/Beam for throughput. Embedding cache for online path: semantic-hash for templated queries; LRU eviction; hit rate target >50% for query workloads with recurring patterns. Staff+ commit: pool sizing math, cache hit-rate measurement, autoscale signals (queue depth for online; backlog for offline).

2. **Embedding-model versioning and dual-index migration.** New embedding model = the entire vector index is now incompatible. For a 1B-doc corpus, re-embedding is multi-day work (NVIDIA L4: ~2K tokens/sec → 5.8 days on a single GPU; parallelize across N GPUs for proportional speedup). Production migration: dual-index for the transition — both indexes serve reads (old index during the migration; new index as it's built); writes go to both; once the new index is fully built, traffic shifts to new and old is decommissioned. Some retrieval architectures merge results from both indexes during transition (vote or interleave). Cost-aware: amortize re-embedding compute across cheap-tier GPUs (V100, A10G) rather than the precious H100s. Staff+ commit: dual-index strategy, traffic-shift schedule (days/weeks), rollback procedure if quality regresses.

3. **Streaming ingest with incremental updates (Meta QuickUpdate).** For continuously-changing corpora (news, user content, real-time events), re-embedding the full corpus periodically is too slow and too expensive. Meta QuickUpdate (NSDI 2024) for production DLRM achieves 13× reduction in embedding-update bandwidth by partial updates rather than full re-embedding. The streaming ingest pipeline: Kafka topic of doc updates → Flink job batches updates → embedding service (large batch for throughput) → vector DB writer (incremental upsert to nearest segment). Trade-off: more complex state management vs much lower steady-state cost. For news-style real-time freshness, this is non-negotiable; for static knowledge-base corpora, periodic batch is sufficient. Staff+ commit: streaming vs batch decision per workload, freshness SLO, partial-update semantics in the downstream vector index.

## Known failure modes
1. **Catastrophic re-embed when a new model ships.** Migration cost is non-trivial; if not staged, the cluster either runs the old + new in parallel (capacity doubled) or experiences a freeze period where new docs can't be indexed. Production answer: dual-index over a days-to-weeks transition window; new ingest goes to both; old reads decommission as the new index covers the corpus; per-tenant opt-in for premium tenants who want the new model immediately.

2. **Query-side cold cache spikes p99 latency.** First request for a templated query hits the GPU; subsequent requests in the same TTL window hit cache. Cold-cache requests look fine in average latency but spike p99. Production answer: precompute-on-write for known-template queries (e.g., common "what is X" templates pre-embedded at write time); per-template TTL extension for hot queries; semantic-hash cache warmup on deploy.

3. **Embedding drift causes silent retrieval regression.** A subtle model change (or training-data shift, or fine-tune drift) produces embeddings that look similar but rank differently. Downstream retrieval quality degrades silently. Production answer: canary queries with known-good rankings (e.g., 100 known query→top-K pairs); periodic verification; alert on rank-divergence beyond threshold.

## Notes for the coach
- **This is confirmed-asked at OpenAI** per IGotAnOffer ("Design a vector database to store and search billions of embeddings efficiently"). Anthropic likely asks variants paired with `billion-doc-rag`.
- **The build-vs-buy math at $0.13/1M (OpenAI) vs ~$0.005/1M (self-hosted at full utilization) is the cost-architecture anchor.** Flips at 5-10% sustained utilization — most companies don't justify self-hosting; frontier labs do.
- **Matryoshka truncation (3072-d → 256-d at acceptable recall) is a cheap cost lever.** Candidates who name MRL unprompted demonstrate 2024+ literacy; those still defaulting to "full embedding dimension" are behind.
- **Streaming ingest is the freshness-bar move.** Without it, the corpus is always stale by hours. The Meta QuickUpdate primary source is the academic anchor.

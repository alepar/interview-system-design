---
slug: image-search
archetype: search-indexing
sources:
  phash_dhash: ssojet.com/compare-hashing-algorithms/phash-vs-dhash
  two_stage_dedup: vecstore.app/blog/duplicate-image-detection
  pinterest_unified: arxiv.org/abs/1908.01707
  pinterest_acolyer: blog.acolyer.org/2019/10/11/learning-a-unified-embedding-for-visual-search-at-pinterest/
  tineye: en.wikipedia.org/wiki/TinEye
  clip_pinecone: pinecone.io/learn/clip-image-search/
---

# Reverse Image / Visual Search (pHash + ANN, two-stage)

## Bar anchors
- **Mid-level (L4/E4):** Proposes comparing images by storing them and checking similarity. May mention hashing or "use a neural network." Doesn't articulate the two-stage recall→precision pipeline, perceptual hashing vs embeddings, or ANN at billion scale unprompted.
- **Senior (L5/E5):** Knows images become **embeddings** (CNN/CLIP vectors) and similarity is nearest-neighbor in vector space, served via **ANN** (HNSW/FAISS). Mentions perceptual hashing for exact/near-duplicate detection. Proposes a pipeline: extract features → index → query. May not cleanly separate the cheap-hash-recall stage from the expensive-embedding-precision stage, or quantify the ANN/embedding tradeoffs, or know where this stops vs `billion-doc-rag`.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the **two-stage retrieval** that defines this problem: a **cheap perceptual-hash recall** (pHash/dHash, 64-bit via DCT low-frequency components; Hamming-distance filter, LSH-bucketed) catches resizes/recompressions; an **expensive embedding precision** stage (CLIP ~512-d → ANN) catches crops/rotations/filters/watermarks the hash misses. Names the ANN choice (HNSW high-recall vs IVF+PQ memory-constrained billion-scale vs ScaNN accelerator-batched, ~99% recall at sub-10ms). Quantifies: TinEye **77.6B+ images**; Pinterest unified visual embedding projected to **256-d, L2-normalized, binarized**, serving **~300K QPS at 3ms median** over billions; CLIP ViT-B/32 = 512-d cosine. Explicitly **delineates from AI-infra `billion-doc-rag`/`embedding-service-at-scale`** — keep the **hash-recall stage + two-stage architecture** here; reference (don't re-derive) the pure-vector serving. Adds object detection as query understanding (Pinterest Flashlight per-region) and adversarial robustness (pHash is attackable → ensembles).

## Canonical decomposition

### Requirements
**Functional:**
- Given a query image, return visually similar / near-duplicate images
- Catch exact-ish duplicates (resize, recompress, minor color shift) AND semantic similarity (crop, rotate, filter)
- Support region/object query (select part of an image)
- Scale ingest of new images (embedding generation is the bottleneck)

**Non-functional (with numbers):**
- Corpus up to tens of billions of images (TinEye 77.6B+)
- pHash/dHash 64-bit; Hamming ≤5 (pHash) ≈ near-duplicate
- Embedding 256–512-d (Pinterest 256-d binarized; CLIP ViT-B/32 512-d)
- Serving ~300K QPS at ~3ms median (Pinterest scoring) over billions
- ANN ~99% recall at sub-10ms latency

### Core entities
- **Image:** image_id, blob_oid, perceptual_hash (64-bit), embedding (256–512-d), metadata
- **HashBucket:** LSH bucket over perceptual hashes for fast near-duplicate recall
- **VectorIndex:** ANN structure (HNSW/IVF-PQ/ScaNN) over embeddings for semantic precision
- **Detection:** bounding box + per-object embedding (object-level / region query)

### API
- `POST /search/image` body={image | image_url, region?} → [{image_id, similarity}] top-K
- Internal: ingest pipeline → perceptual hash + embedding (GPU) → write hash bucket + ANN index
- Internal: `hash_recall(query_hash) → ~10K candidates`; `ann_rerank(query_embedding, candidates) → top-K`

### HLD
**Ingest.** Each image flows through a feature pipeline: compute a **perceptual hash** (pHash: resize/grayscale → DCT → keep low-frequency components → threshold to a 64-bit fingerprint) and a **deep embedding** (a CNN/CLIP model → a 256–512-d vector; Pinterest projects to 256-d, L2-normalizes, and binarizes by thresholding at zero with little accuracy loss, shrinking storage and speeding similarity). The embedding step is GPU-bound and is the ingest bottleneck, so it's bulk-batched and de-duplicated by blob OID (don't re-embed identical bytes). The hash goes into an LSH-bucketed store; the embedding goes into an **ANN index** (HNSW, or IVF+PQ for memory-constrained billion-scale, or ScaNN for accelerator-friendly batched search).

**Query (two stages).** Stage 1 — **cheap recall**: hash the query image and probe the LSH buckets to pull ~10K candidates that are exact-or-near duplicates by Hamming distance. This is fast and catches resizes/recompressions/minor color shifts, but misses crops, rotations, filters, watermarks. Stage 2 — **expensive precision**: run **ANN over embeddings** (optionally restricted to the candidate set, or as an independent retrieval whose results are fused with the hash hits) to find *semantically* similar images, then re-rank by exact cosine similarity to produce the final top-K. The two stages are complementary: hashing is cheap and precise-on-duplicates; embeddings are expensive and robust-to-transformation. For region/object queries, an **object detector** (Pinterest Flashlight, SSD at ~290×290px) produces per-object embeddings so "find this handbag in the photo" embeds the bag, not the whole scene; a **blender** fuses visual-similarity, object-search, and text-from-image annotation results.

### Deep dives
1. **The two-stage recall→precision pipeline** — The architectural spine, and the reason this is a search problem and not just "an embedding service." Perceptual hash recall is O(cheap) and excellent at the exact-duplicate cases that dominate dedup workloads (the same image reposted, resized, recompressed), returning a small candidate set with near-zero cost. But it's brittle: a crop, a 10° rotation, a watermark, or a filter changes the hash enough to miss. So the embedding stage adds transformation-robust semantic similarity, used either to re-rank the hash candidates or as a parallel retrieval leg fused with them. Staging cheap-then-expensive is exactly the recall→precision pattern of `google-search` and RAG retrieve→rerank — the candidate gives a Staff+ signal by naming that isomorphism rather than treating image search as sui generis.
2. **ANN index choice at billion scale** — Exact nearest-neighbor over billions of 512-d vectors is infeasible per query, so ANN trades a sliver of recall for orders-of-magnitude speed (~99% recall at sub-10ms). The choice is a memory/recall/throughput trade: **HNSW** (graph-based) gives high recall and low latency but high memory; **IVF+PQ** (inverted-file + product quantization) compresses vectors to fit billions in memory at some recall cost; **ScaNN** uses anisotropic quantization + a coarse-to-fine search well-suited to accelerators and 10B+ datasets. Pinterest's binarization (threshold embeddings at zero) is an aggressive form of this — 1-bit-per-dim cuts storage and makes similarity a Hamming op, with little accuracy loss for their classification-trained embeddings. The Staff+ point: name the constraint (memory vs recall vs QPS) before picking the index.
3. **Delineation from `billion-doc-rag` + adversarial robustness** — This problem deliberately stops where AI-infra begins. The **hash-recall stage and two-stage orchestration** are the search content here; the pure-vector serving internals (sharded ANN, KV-cache-aware routing, embedding-model serving) belong to `embedding-service-at-scale`/`billion-doc-rag` and should be *referenced*, not re-derived — a candidate who rebuilds the vector DB has misallocated the round. The genuinely image-specific depth is adversarial robustness: perceptual hashes are attackable (small perturbations flip bits, "it's not what it looks like" attacks), so production systems ensemble multiple hashes (pHash + dHash + a DNN-based perceptual fingerprint) and lean on the embedding stage for the final decision — relevant for trust-and-safety use cases (CSAM/known-bad-image matching) where evasion is adversarial by nature.

## Known failure modes
1. **pHash false positives on low-information images** — Near-blank, solid-color, or highly-uniform images hash to similar fingerprints and collide as "duplicates" even when unrelated. Mitigation: frequency-clipping / entropy thresholds to reject degenerate hashes, and always run the stage-2 embedding check before declaring a match — never return on hash alone for anything user-visible or safety-relevant.
2. **Embedding-generation ingest bottleneck** — At billion scale the GPU embedding step dominates ingest cost and can fall behind the image arrival rate. Mitigation: bulk-batch embeddings, de-duplicate by blob OID so identical bytes are embedded once, autoscale the GPU embedding fleet against queue depth, and decouple hash-indexing (cheap, immediate near-dup capability) from embedding-indexing (slower, semantic) so new images are at least dedup-searchable quickly.
3. **Adversarial evasion** — An adversary perturbs an image to evade a perceptual hash (defeating known-bad-image matching) or to be mis-matched. Mitigation: ensemble multiple independent hashes plus a learned perceptual fingerprint so a single-hash evasion doesn't slip through, weight the robust embedding stage in the final decision, and treat the matcher as an adversarial system (monitor for evasion patterns, rotate/augment the fingerprinting) rather than a static dedup.

## (Delineation note)
This problem owns the **perceptual-hash recall stage** and the **two-stage recall→precision architecture**. Pure-vector ANN serving at scale, embedding-model serving, and KV-cache-aware routing live in AI-infra `embedding-service-at-scale` and `billion-doc-rag` — reference them, don't rebuild them, in a mock.

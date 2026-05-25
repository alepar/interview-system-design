---
slug: hybrid-search
archetype: search-indexing
sources:
  rrf_paper: "Cormack, Clarke, Büttcher, Reciprocal Rank Fusion, SIGIR 2009, DOI 10.1145/1571941.1572114"
  colbert_paper: arxiv.org/abs/2004.12832
  colbertv2: arxiv.org/abs/2112.01488
  splade_v2: arxiv.org/abs/2107.05720
  beir: arxiv.org/abs/2104.08663
  es_hybrid: elastic.co/what-is/hybrid-search
---

# Hybrid Lexical + Dense Search (RRF fusion) — the AI bridge

## Bar anchors
- **Mid-level (L4/E4):** Knows you can search with keywords (BM25) or with embeddings (vector similarity). May propose "use vectors, they're better." Doesn't recognize the complementary failure modes or how to combine the two unprompted.
- **Senior (L5/E5):** Articulates that lexical (BM25) is strong on exact terms/IDs and dense (embeddings) is strong on semantics/paraphrase, and proposes running both and combining results. Knows ANN (HNSW) serves the dense leg. May reach for naive score-averaging (and not see the scale-incompatibility problem), may not name RRF, ColBERT, or SPLADE, and may not know where this stops vs the AI-infra vector-serving problem.
- **Staff+ (L6/E6+):** Drives proactively. Runs **BM25 + dense ANN in parallel**, each returning top-K, and fuses with **Reciprocal Rank Fusion** — `score(d)=Σ_r 1/(k+rank_r(d))`, **k=60** (Cormack SIGIR'09; k∈[40,80] comparable) — explaining **why rank-based fusion beats score-normalization** (BM25 scores and cosine similarities are on incompatible scales; RRF sidesteps normalization by operating on ranks). Knows when to upgrade: **ColBERT late-interaction** (MaxSim over per-token embeddings, used as a **reranker over the top-100**, not first stage; ColBERTv2 ~20–36 bytes/vec) and **SPLADE learned-sparse** (BERT-MLM term expansion into an inverted index). Cites **BEIR macro-averages** (BM25 ≈0.43 → ColBERTv2 ≈0.50 nDCG@10; DPR ≈0.35, *worse* than BM25 zero-shot). **Explicitly references AI-infra `billion-doc-rag` for embedding-service depth rather than re-deriving vector serving** — this is the bridge problem. Names production hybrid systems (Elasticsearch retrievers, Weaviate `alpha`, Qdrant named vectors).

## Canonical decomposition

### Requirements
**Functional:**
- Retrieve relevant documents for a query that may need exact-term match AND/OR semantic match
- Fuse a lexical ranked list and a dense ranked list into one ranking
- Optionally rerank the fused top-N with a higher-quality (more expensive) model
- Degrade gracefully when one leg is weak for a given query

**Non-functional (with numbers):**
- RRF k=60 (no per-dataset tuning needed); the default in ES/OpenSearch/Weaviate/Qdrant/Vespa/Azure/Mongo
- Latency: BM25 single-digit ms; +kNN(HNSW) 10–50ms; +reranker +50–200ms
- BEIR nDCG@10: BM25 ≈0.43, Contriever-ft ≈0.46, SPLADEv2 ≈0.47, ColBERTv2 ≈0.50
- Hybrid gain over best single leg: ~+5–15% nDCG (rule of thumb; per-dataset, e.g. ColBERT +5.8 TREC-COVID)
- ColBERTv2 storage 20–36 bytes/vector (vs original 256) via centroid+residual quantization

### Core entities
- **LexicalLeg:** BM25 over an inverted index → ranked list L_lex
- **DenseLeg:** dense embeddings over an ANN index (HNSW) → ranked list L_dense
- **Fusion:** RRF (rank-based) or weighted score combination → fused top-N
- **Reranker (optional):** ColBERT MaxSim / cross-encoder over the fused top-100
- **SparseLearned (alt):** SPLADE vector (term-expanded) living in the inverted index

### API
- `POST /search` body={query, k, alpha?} → fused ranked results
- Internal: `bm25(query, K) → L_lex`; `ann(embed(query), K) → L_dense` (parallel)
- Internal: `rrf(L_lex, L_dense, k=60) → fused`; optional `rerank(query, fused[:100])`

### HLD
A query runs down **two legs in parallel**. The **lexical leg** issues BM25 over the inverted index, returning its top-K by term-frequency/inverse-document-frequency scoring — strong on exact tokens, error codes, identifiers, abbreviations, and rare terms. The **dense leg** embeds the query (a bi-encoder) and runs **ANN (HNSW)** over the document-embedding index, returning its top-K by cosine similarity — strong on paraphrase, synonymy, and intent where the words don't overlap. Each leg returns, say, K=100.

The two ranked lists are fused with **Reciprocal Rank Fusion**: each document's fused score is the sum over the lists it appears in of `1/(k + rank)`, with **k=60**. RRF is preferred over score combination because BM25 scores (unbounded, corpus-dependent) and cosine similarities (bounded, model-dependent) are on **incompatible scales** — naively averaging them lets one leg dominate by scale accident. Operating on *ranks* sidesteps normalization entirely and needs no per-dataset tuning, which is why RRF is the default fusion in Elasticsearch, OpenSearch, Weaviate, Qdrant, Vespa, Azure AI Search, and Mongo Atlas. (When you *have* labeled relevance to tune against, weighted fusion — e.g. Weaviate's `alpha` — can beat plain RRF by tilting toward the more reliable leg.)

The fused **top-N** can optionally feed an expensive **reranker**: **ColBERT** computes late-interaction MaxSim (for each query token, the max cosine to any document token, summed) over **only the top-100** — near-cross-encoder quality at far lower cost than a full cross-encoder, but still too expensive for first-stage retrieval. An alternative to a separate dense index is **SPLADE** (learned sparse): a BERT MLM head expands each doc/query into a sparse, weighted term vector that drops into the *inverted index*, so "automobile" matches "car" with lexical-style serving (GPU cost only at indexing).

**Boundary:** the embedding model serving, sharded ANN at billion scale, and KV-cache-aware routing are the AI-infra `billion-doc-rag`/`embedding-service-at-scale` problems — referenced here, not rebuilt. This problem owns the **fusion boundary**: where lexical stops, where dense starts, and how to combine them.

### Deep dives
1. **Why RRF beats score normalization** — BM25 and cosine live on different scales (BM25 unbounded and corpus-statistics-dependent; cosine in [-1,1] and model-dependent), so combining raw or min-max-normalized scores makes the fusion fragile: a single high-BM25 outlier or a model whose cosines cluster tightly can swamp the other leg. RRF discards magnitudes and uses only **ranks**: `1/(k+rank)`. The constant k=60 (Cormack et al., TREC 2009; robust across k∈[40,80]) flattens the head — the contribution from rank 1 is only ~15% larger than rank 10 — so a document ranked decently by *both* legs beats one ranked #1 by a single leg, which is exactly the consensus behavior you want. No tuning, scale-agnostic, and empirically it beat Condorcet fusion and CombMNZ. Upgrade to weighted fusion only when you have labels to tune the leg weights.
2. **When to upgrade: ColBERT late-interaction and SPLADE learned-sparse** — Single-vector dense retrieval pools a document into one vector, losing token-level signal. **ColBERT** keeps per-token embeddings and scores via **MaxSim** (sum over query tokens of the max similarity to any doc token), recovering near-cross-encoder quality (MS MARCO MRR@10 ~34.9%, ~BERT-base) at ~170× lower cost than a full BERT reranker — but MaxSim is O(|q|·|d|·dim), so it belongs as a **reranker over the fused top-100**, never as first-stage retrieval; ColBERTv2's centroid+residual quantization cuts storage to 20–36 bytes/vector (from 256). **SPLADE** takes the opposite route: stay in the inverted index but make it semantic — a BERT MLM head produces a sparse term-expanded vector so lexical infrastructure gets synonym/paraphrase recall, with neural cost paid only at indexing. The Staff+ framing: dense bi-encoder for cheap first-stage recall, ColBERT for precise rerank, SPLADE when you want one inverted-index-served system — pick by latency budget and infra you already run.
3. **The bridge to AI-infra `billion-doc-rag` (what NOT to re-derive)** — This is explicitly the boundary problem, and the discipline is knowing where it stops. The *retrieval-quality* reasoning (lexical vs dense failure modes, RRF, ColBERT/SPLADE, BEIR numbers) is the content here. The *serving-infrastructure* reasoning — sharding a billion-vector ANN index, embedding-model inference serving, KV-cache-aware routing, GPU batching — is the AI-infra `billion-doc-rag`/`embedding-service-at-scale` content, and a candidate should *reference* it ("the dense leg's ANN index is served per billion-doc-rag") rather than rebuild it. BEIR is the calibration: pure dense (DPR ≈0.35) is *worse than BM25* (≈0.43) zero-shot out of domain, which is the empirical case for hybrid — neither leg dominates, and fusion (+5–15% nDCG, ColBERTv2 ≈0.50) wins. This is the exact framing being tested at Anthropic/OpenAI/DeepMind retrieval interviews in 2025–2026.

## Known failure modes
1. **RRF over-weights a common-but-wrong consensus** — When both legs agree on a popular-but-irrelevant document (e.g. a generic high-BM25, high-cosine doc), RRF's consensus bias ranks it too high. Mitigation: weighted RRF/`alpha` to tilt toward the higher-confidence leg for the query class, a reranker pass to break consensus ties on true relevance, and query-class routing (exact-ID queries weight lexical; natural-language questions weight dense).
2. **ColBERT (or cross-encoder) blows the latency budget** — Using a late-interaction or cross-encoder model as first-stage retrieval, or reranking too many candidates, pushes latency past budget (+50–200ms per the reranker, multiplied by candidate count). Mitigation: strictly reranker-only over a bounded top-100 (not top-10K), quantize (ColBERTv2 20–36 bytes/vec), and cache reranks for head queries; keep first-stage retrieval to cheap BM25 + ANN.
3. **Dense index drift on model retrain** — Re-training or swapping the embedding model invalidates the entire ANN index (old and new vectors aren't comparable), and a naive hot-swap silently degrades relevance. Mitigation: version the ANN index per embedding-model version, re-embed and rebuild offline, and A/B-shadow the new index against the old before promotion — never mix vectors from two model versions in one index. (Index build/serving mechanics: see AI-infra `embedding-service-at-scale`.)

## (Bridge note)
`hybrid-search` is the explicit bridge to AI-infra `billion-doc-rag`. Own the fusion boundary (lexical vs dense, RRF, rerank); defer embedding-model serving, billion-vector ANN sharding, and KV-cache routing to the AI-infra problems.

---
slug: ctr-prediction
archetype: ml-in-loop
sources:
  dlrm_paper: arxiv.org/abs/1906.00091 (Naumov et al. "DLRM" 2019)
  zionex_paper: arxiv.org/abs/2104.05158 (Mudigere et al. "Software-Hardware Co-design for Fast and Scalable Training of DLRM" ISCA 2022)
  he_2014: ADKDD'14 (He et al. "Practical Lessons from Predicting Clicks on Ads at Facebook")
  wide_deep_paper: arxiv.org/abs/1606.07792 (Cheng et al. "Wide & Deep Learning for Recommender Systems" 2016)
  meta_arm_2026: engineering.fb.com/2026/03/31/ml-applications/meta-adaptive-ranking-model
  meta_andromeda_2024: engineering.fb.com/2024/12/02/production-engineering/meta-andromeda-advantage-automation-next-gen-personalized-ads-retrieval-engine/
---

# CTR prediction — DLRM with TB-class embedding tables + 4D parallelism + memory hierarchy

## Bar anchors
- **Mid-level (L4/E4):** "Deep network predicts P(click)." No awareness of embedding-table dominance or sparse/dense compute split.
- **Senior (L5/E5):** Names DLRM, embedding tables, MLP top stack. May or may not address 4D parallelism, all-to-all bottleneck, HBM/DRAM/SSD memory tiering, or request-oriented optimization.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **embedding-table-dominated** model architecture — model is mostly memory, not compute. Per Naumov 2019: production DLRMs at Meta scale exceed hundreds of GB approaching TB. Names **hybrid parallelism**: model parallel embeddings + data parallel MLPs + all-to-all communication for interaction. Cites **ZionEX 12-trillion-parameter training** [Mudigere ISCA 2022]; 40× speedup over prior systems; 4D parallelism (table-wise + row-wise + column-wise + data). Cites **embedding tables >99% of params but <1% of FLOPs**; **all-to-all >60% of training time on 32-GPU clusters**. Names **mixed-tier storage** (HBM hot / DRAM warm / NVMe cold) with placement solved via MILP or RL (RecShard, DreamShard, EMBark) because access frequencies follow power law. Names **request-oriented optimization** (Meta ARM Mar 2026): shares user-request embeddings across thousands of candidate ads; 1T-param ranker at O(100ms) bounded inference, 35% MFU. Articulates **GBDT+LR → Wide&Deep → DLRM evolution**: He 2014 (GBDT-encoded leaf indices fed to LR; +3% over either alone; daily GBDT + online LR with per-coordinate FTRL); Cheng 2016 Wide&Deep (linear wide over crossed sparse + deep MLP; +1% on Google Play); Naumov 2019 DLRM (learned pairwise feature interactions). Stretch (Sr Staff bar): cites Meta Andromeda retrieval (Dec 2024): 10,000× model-capacity increase, +6% recall, +8% ad quality, 3×+ end-to-end QPS.

## Canonical decomposition

### Requirements
**Functional:**
- Predict P(click | user, ad, context) at planet scale
- Predict P(conversion | click, ad, lookback_window) with delayed-feedback handling (1-28 day windows)
- Calibration sufficient for downstream auction (eCPM = pCTR × bid; absolute calibration matters)
- Continuous retrain with online learning for fast drift adaptation

**Non-functional (with numbers):**
- ZionEX 12-trillion-parameter training; 1.7M queries/sec peak
- Per-node: 8× A100 40GB HBM (320 GB / 12.4 TB/s aggregate), 1.5 TB DDR, 200 Gbps RoCE/GPU
- Meta ARM 2026: 1T parameters, O(100ms) bounded inference latency, 35% MFU
- DLRMs at Meta: >50% training cycles, >80% inference cycles in AI fleet
- All-to-all: >60% of training time on 32-GPU clusters
- Wide & Deep trained on 500B examples (Google Play); DIN +10.0% CTR / +3.8% RPM
- Meta serves 3B+ DAU; per-impression ranking budget ~1 second

### Core entities
- **Dense features:** numerical (age, time-of-day, recency); fed to bottom MLP
- **Sparse features:** categorical (user_id, ad_id, page_id, hour); embedded via lookup tables
- **Embedding tables:** hundreds of tables × billions of rows × 64-256 dims = TBs total
- **Feature interactions:** pairwise dot-product (DLRM) or DCN-v2 / AutoInt
- **Top MLP:** consumes concatenated (dense + sparse + interactions) → P(click)

### API
- Internal: ranker.score(user_features, ad_candidates, context) → pCTR per candidate
- Internal: embedding_server.lookup(table_id, row_ids) → embeddings (cross-machine all-to-all)
- Inference: synchronous bid request → 1ms-class scoring (with feature lookups)

### HLD
**Sparse/dense compute split**: dense features → bottom MLP (small FC stack). Sparse features → embedding lookups across hundreds of tables totaling TBs. **Pairwise feature interactions** (dot products of all (dense, sparse) pairs). Concatenate → top MLP → P(click). **Embedding-table sharding** across machines via **4D parallelism**: table-wise (each table on one machine), row-wise (rows of one table split; each lookup hits multiple machines via all-to-all), column-wise (hidden dim split), data-parallelism (MLPs replicated, gradients all-reduced). TorchRec implements all strategies; sharding chosen per-table based on access pattern. **Memory hierarchy**: hot rows in GPU HBM (μs access), warm in CPU DRAM (ms), cold on NVMe SSD. Placement solved via MILP/RL (RecShard, DreamShard, EMBark) because access frequencies follow power law. **Request-oriented optimization** (Meta ARM): compute user-request embedding once per request, cross-attend with each candidate ad — collapses cost from `O(N_candidates × user_tower)` to `O(N_candidates × MLP_top + 1 × user_tower)`. **All-to-all is the bottleneck**: >60% of training time on 32-GPU clusters; sparse-dense communication via 200 Gbps RoCE NICs.

### Deep dives
1. **DLRM architecture + sparse/dense compute split.** Embeddings >99% of params but <1% of FLOPs; MLPs inverse. Drives heterogeneous CPU+GPU architecture: embeddings CPU-friendly (lookup-bound); MLPs GPU-bound (compute-bound). **Pairwise feature interactions** (DLRM) vs DCN-v2 (explicit cross + deep) vs AutoInt (multi-head self-attention over feature embeddings). **Calibration**: raw outputs aren't probabilities after negative downsampling; Platt scaling or isotonic regression post-train.

2. **4D parallelism + embedding-table sharding.** Single table at billion-row × 256-d × fp32 = 1 TB; aggregate TBs. Must shard. **Table-wise**: load imbalance if access frequencies differ. **Row-wise**: rows of one table split; each lookup hits multiple machines; aggregate via all-to-all. **Column-wise**: hidden dim split; rare; mainly for memory. **Data parallelism**: MLPs replicated, gradients all-reduced. **4D = combination** per ZionEX. TorchRec implements all. **All-to-all is the bottleneck**: >60% of training time on 32-GPU clusters [Wang arXiv:2407.04272]. Dual-Level Adaptive Lossy Compression reduces all-to-all volume.

3. **Memory hierarchy + request-oriented optimization.** **HBM/DRAM/SSD tiering**: hot rows on GPU HBM, warm on CPU DRAM, cold on NVMe. **Power-law access**: small fraction of rows account for most lookups; place those in HBM. MILP-based or RL-based placement (RecShard, DreamShard, EMBark). **AIBox / Distributed Hierarchical GPU Parameter Server**: SSD cache for industrial-scale recommendation models on single node. **Request-oriented optimization** (Meta ARM Mar 2026): compute user signals once per request rather than per ad candidate. Enabled scaling to 1T-param ARM at O(100ms) bounded inference, 35% MFU; deployed Q4 2025 with +3% conversions / +5% CTR. **Andromeda retrieval** (Meta Dec 2024): narrows tens of millions of active ads to a few thousand per impression via deep neural retrieval on NVIDIA Grace Hopper + MTIA; 10,000× model-capacity increase, +6% recall, +8% ad quality, 3×+ end-to-end QPS.

## Known failure modes
1. **Embedding table OOM under cardinality growth.** New advertiser explodes user_id × ad_id cardinality. Production answer: hash bucketing with collision-mitigation (DoubleHash, QR-trick, DHE, probabilistic-hash-embeddings PHE [arXiv:2511.20893]); INT4 post-training quantization (Pinterest reduced ad-model embedding tables 60% [arXiv:2505.05605]); long-tail row pruning.

2. **Training-serving skew at embedding level.** Different hashing in offline vs online stacks; library/version mismatches; numeric precision (fp32 train, int8 serve). Production answer: feature store enforces same transformation code both paths; regression tests on per-feature deltas; canary deploys with shadow scoring.

3. **Delayed-conversion bias in CVR.** Click today may convert in 1-28 days; naive training labels positives that haven't matured yet as negatives. Production answer: elapsed-time sampling (ES-DFM), label correction (ULC), influence functions, dual learning [Yasui 2020 arXiv:2002.02068].

4. **Position bias in training data.** Top slots get more clicks regardless of relevance. Production answer: position as feature at training, position=0 / dropout at serving (Huawei PAL); IPS reweighting; unbiased LambdaMART.

5. **Calibration drift** post-deployment destroys auction economics even though "model quality" unchanged. Production answer: continuous calibration monitoring; per-slice ECE; isotonic regression bins refreshed hourly.

## Notes for the coach
- **Asked-confirmed at Meta, Google, ByteDance, Snap, TikTok.** DLRM paper, ZionEX paper, Meta Engineering blogs on ARM and Andromeda are explicit interview-prep canon.
- **The embedding-table-dominated architecture is the canonical Staff+ unlock.** Candidates who treat this as "deep network on GPU" miss the entire architecture; candidates who articulate >99% of params in embeddings + <1% in FLOPs demonstrate the right framework.
- **4D parallelism is the depth probe.** Candidates who can articulate when to use table-wise vs row-wise vs column-wise sharding demonstrate DLRM operational expertise.
- **Adversarial probe: "why not use a transformer instead of DLRM?"** Strong answer: embedding-table compute is fundamentally sparse-lookup-dominated, not matmul-dominated; transformer architectures don't help with lookup latency; the bottleneck is all-to-all communication for embedding gather, not FLOPs. Weak answer: "transformers are better" without the architectural-fit argument.

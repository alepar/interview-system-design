# AI Infrastructure

Source: design spec §9 + `staff-engineer-study-guide.md` (Category 11).

## Continuous batching (vLLM-style)

**Definition.** Continuous batching processes each request as soon as it is ready rather than waiting to fill a fixed batch, so GPU utilization stays high even when request arrival times vary.

**Canonical use.** An inference service running an LLM applies continuous batching to avoid the throughput collapse that occurs when long-running sequences block shorter ones from entering a static batch.

**Production systems.** vLLM (open-source, used by many hosted providers), Anyscale Endpoints.

**Alternatives.** Static batching (simpler to implement, optimal only when request lengths are uniform); dynamic batching with fixed max-wait timeout (intermediate; adds a tunable latency floor).

## PagedAttention / KV-cache management

**Definition.** PagedAttention allocates KV-cache memory in fixed-size pages and maps logical token positions to physical pages, eliminating fragmentation that wastes GPU memory in naïve contiguous-buffer designs.

**Canonical use.** An LLM serving system uses PagedAttention to batch requests with highly variable sequence lengths without reserving worst-case memory for every slot, enabling 2–4× higher batch concurrency on the same hardware.

**Production systems.** vLLM (PagedAttention paper, Kwon et al. 2023), TensorRT-LLM (NVIDIA's production variant).

**Alternatives.** Contiguous KV-cache with pre-allocation (wastes memory for shorter sequences); streaming KV offload to CPU DRAM (reduces GPU pressure at the cost of bandwidth latency).

## Prefix caching

**Definition.** Prefix caching stores the computed KV state for a long shared prompt prefix so that subsequent requests reusing that prefix skip recomputation entirely.

**Canonical use.** A multi-turn chatbot with a large system prompt applies prefix caching so only the new turn tokens are processed on each call, not the entire context window.

**Production systems.** Anthropic API (publicly documents 90% cost reduction and up to 85% latency reduction; break-even at ~1.4 reads per cached prefix), OpenAI API (50% automatic discount on cached tokens above 1 024 tokens).

**Alternatives.** Context distillation / prompt compression (reduces token count rather than caching computation; no reuse benefit); speculative decoding (reduces latency differently; orthogonal).

## Speculative decoding

**Definition.** Speculative decoding uses a small, fast draft model to propose candidate tokens that a larger verifier model then accepts or rejects in parallel, trading draft-model cost for wall-clock latency reduction.

**Canonical use.** A latency-sensitive API serving a large model (e.g., 70 B parameters) pairs it with a 7 B draft model to achieve 2–3× wall-clock speedup on typical short-completion workloads without altering output distribution.

**Production systems.** Google DeepMind Gemini serving (reported), Hugging Face TGI speculative decoding support.

**Alternatives.** Continuous batching (improves throughput, not per-request latency); quantization (reduces compute cost; some quality trade-off); distilled smaller models (one model, lower quality ceiling).

## Model-router gateways

**Definition.** A model-router gateway classifies each incoming request by complexity, expected output length, or cost class and dispatches it to the cheapest model tier capable of satisfying the quality requirement.

**Canonical use.** A product with high query volume routes simple FAQ and short-generation requests to a smaller/cheaper model (e.g., Llama-3 8B) while reserving a frontier model (e.g., GPT-5 or Claude Sonnet) for complex multi-step reasoning tasks.

**Production systems.** LiteLLM proxy (open-source router), Martian (commercial model router).

**Alternatives.** Single-model serving (simpler ops; over-spends on easy queries); client-side model selection (moves routing logic to caller; harder to enforce centrally).

## Mixture-of-Experts (MoE)

**Definition.** MoE is a neural architecture in which each forward pass activates only a sparse subset of parameter blocks ("experts") selected by a learned router, keeping compute proportional to active parameters rather than total parameters.

**Canonical use.** A large-scale language model uses expert parallelism to distribute experts across GPUs so that routing different tokens to different sub-networks keeps each GPU's active compute manageable while the total parameter count scales.

**Production systems.** GPT-4 (reported MoE architecture), Mixtral 8×7B (open-weight MoE).

**Alternatives.** Dense transformer (all parameters active per token; simpler but compute-bound); sparse attention (different sparsity axis; orthogonal to MoE).

## Semantic caching

**Definition.** Semantic caching stores LLM responses keyed by embedding similarity rather than exact text, so queries that are semantically equivalent to a cached query are served from cache without re-inference.

**Canonical use.** A high-volume customer-support chatbot uses semantic caching to serve the ~31% of incoming queries that are semantically similar to prior queries without incurring inference cost or latency.

**Production systems.** GPTCache (open-source semantic cache library), Redis with vector search (production pattern).

**Alternatives.** Exact-match response cache (much lower hit rate; zero false-positive risk); prefix caching (KV-level; orthogonal; addresses long shared context, not query similarity).

## Eval pipelines as production systems

**Definition.** An eval pipeline is a continuous automated system that runs a model against a golden dataset, detects regressions using LLM-as-judge or reference metrics, and gates deployments — treated as first-class production infrastructure.

**Canonical use.** A model serving team runs an eval pipeline on every candidate model version before promotion, using LLM-as-judge with reference answers to cut false-positive grading from ~70% to ~15% (per Zheng et al. 2023 on reference-guided judging).

**Production systems.** Anthropic's internal eval harness (described in model-card methodology), OpenAI Evals framework (open-source).

**Alternatives.** Human evaluation panels (ground truth; high cost; slow); static benchmark suites only (fast; miss distribution shift and model-specific regressions).

## Parallel Safety Pipelines

**Definition.** A parallel Safety pipeline runs rule-based filters and ML classifiers concurrently with the main inference pass rather than serially, so safety latency does not add to user-facing response time.

**Canonical use.** An LLM API routes each request simultaneously to the model inference path and to a two-stage safety check (rule-based regex/blocklist at <1 ms, ML toxicity classifier at 10s of ms), returning the response only when both paths clear.

**Production systems.** Anthropic Constitutional AI serving stack (parallel safety described in alignment research); Meta Llama Guard (open-weight safety model designed for parallel deployment).

**Alternatives.** Serial pre-inference safety check (simpler; adds latency equal to classifier time); post-inference filtering only (lower latency; allows model to generate the unsafe token sequence before blocking).

## Distributed training

**Definition.** Distributed training partitions model parameters, gradients, or data across many accelerators and coordinates updates via collective operations (all-reduce being dominant), enabling training of models too large or slow to fit on a single device.

**Canonical use.** A team training a 70 B-parameter model uses FSDP (Fully Sharded Data Parallel) to shard optimizer state, gradients, and parameters across 512 GPUs, then runs an all-reduce over gradients each step.

**Production systems.** PyTorch FSDP (Meta, open-source), Megatron-LM (NVIDIA, tensor + pipeline parallelism), DeepSpeed (Microsoft, ZeRO optimizer).

**Alternatives.** Pipeline parallelism (partitions layers across devices; lower all-reduce bandwidth; introduces pipeline bubbles); tensor parallelism (shards individual weight matrices; high intra-layer bandwidth requirement); model-parallel inference (serving, not training; different trade-offs).

## Topology-aware GPU placement and training fault tolerance

**Definition.** Topology-aware placement matches a training job's parallelism plan (tensor-parallel groups, pipeline stages, data-parallel replicas) to the physical interconnect hierarchy — NVLink/NVSwitch domains within a node, PCIe locality, and multi-host RDMA fabrics (InfiniBand, RoCE) — so that the highest-bandwidth collectives land on the highest-bandwidth links. Training fault tolerance adds async checkpointing, collective-comm hang detection, and elastic membership so that a multi-week training run survives node failures without full restart.

**Canonical use.** A scheduler placing a 1024-GPU pretraining job pins each 8-way tensor-parallel group inside a single NVLink island, lays pipeline stages across nodes connected by the fattest InfiniBand rails, and reserves hot-spare nodes; async checkpoints write to a parallel filesystem every N minutes while NCCL Flight Recorder traces any all-reduce hang to the offending rank.

**Production systems.** PyTorch TorchElastic and DeepSpeed elastic training, Slurm with topology constraints, AWS HyperPod (auto-resume on hardware fault), TorchSnapshot for async checkpointing, NCCL Flight Recorder, internal schedulers at Anthropic and Meta.

**Alternatives.** Topology-blind bin-packing (simpler; degrades collective bandwidth dramatically); synchronous-only checkpointing (simpler; stalls training during writes and lengthens recovery); restart-from-zero on any fault (acceptable only at small scale).

## Long-context techniques: MLA, Ring Attention, chunked prefill

**Definition.** A family of techniques that extend PagedAttention to make very long contexts and very long prefills tractable: Multi-Head Latent Attention (MLA) compresses the KV cache via a low-rank latent projection; Ring Attention and sequence parallelism distribute attention computation across devices so context length scales with the number of devices; chunked prefill breaks the prefill phase into smaller chunks that interleave with decode steps; prefill/decode disaggregation runs the two phases on different hardware tiers tuned for their distinct compute profiles.

**Canonical use.** A serving system targeting million-token contexts uses MLA to shrink per-token KV footprint, Ring Attention to spread the attention matmul across a tensor-parallel group, and chunked prefill so a 200 K-token user prompt no longer blocks decode for thousands of in-flight requests; decode runs on memory-bandwidth-optimized GPUs while prefill runs on compute-dense ones.

**Production systems.** vLLM (chunked prefill and prefill/decode disaggregation), DeepSeek-V2 and DeepSeek-V3 (MLA), Ring Attention reference implementations (Liu et al. 2023), TensorRT-LLM long-context kernels.

**Alternatives.** Full-context-fits-in-memory (only viable for short contexts); sliding-window attention (cheap; loses long-range dependencies); retrieval augmentation instead of long context (different trade-off; loses in-context reasoning over the full document).

## Durable agent loops, MCP, and sandbox isolation

**Definition.** Long-running LLM-agent workflows need three things general request/response stacks do not: a durable execution substrate so multi-hour or multi-day runs survive node restarts, a standard protocol for exposing tools and resources to the model, and an isolation boundary for executing untrusted model-generated code. Durable execution is provided by workflow engines (Temporal, AWS Step Functions, Inngest) that persist every step. The Model Context Protocol (MCP) is Anthropic's open standard for tool, resource, and prompt exposure with capability negotiation. Sandboxing options trade isolation strength against cold-start latency: Firecracker microVMs (KVM-based, hundreds of ms cold start), gVisor (user-space kernel, lighter but weaker), and bubblewrap or raw Linux namespaces (kernel-shared, lightest, weakest).

**Canonical use.** An agent platform stores each agent run as a Temporal workflow whose steps are tool calls; tools are advertised to the model via MCP; every code-execution tool call lands in a Firecracker microVM with a fresh rootfs, network egress policy, and a wall-clock budget.

**Production systems.** ChatGPT Code Interpreter (gVisor), OpenAI Assistants and Responses API (Firecracker-backed sandboxes), E2B (Firecracker for agent sandboxes), Anthropic Claude with MCP, Temporal and Inngest for durable agent loops.

**Alternatives.** No isolation for tool execution (catastrophic risk for untrusted code); full VM per call (strong isolation; cold-start too slow for interactive agents); in-process exec with seccomp (fast; insufficient for adversarial workloads).

## Multi-tenant LoRA, embedding pools, and realtime multimodal serving

**Definition.** Three serving patterns that share one base infrastructure across many tenants or modalities. Multi-tenant LoRA serving keeps a single base model resident and pages in thousands of small LoRA adapters on demand, batching requests across tenants using Unified Paging (S-LoRA) or Segmented Gather Matrix-Vector multiplication (SGMV). Embedding service scaling combines Matryoshka representation learning — one model whose output dimensions are usable at multiple truncation lengths for different cost/quality tiers — with a tenant-sharded vector index. Realtime multimodal serving pipelines audio, vision, and text through a shared KV cache with WebRTC for low-latency audio I/O and framewise vision encoding overlapped with audio decoding.

**Canonical use.** A platform offering per-customer fine-tuned variants runs one 70 B base model with thousands of LoRA adapters batched via S-LoRA; an embedding endpoint serves the same Matryoshka model at 256, 768, and 1536 dimensions for different tiers; a realtime voice product streams audio in over WebRTC, encodes video frames in parallel, and emits audio out with sub-300 ms turn latency.

**Production systems.** vLLM with S-LoRA, Punica (SGMV kernels), OpenAI gpt-4o-realtime, Google Gemini Live, Cohere Embed (Matryoshka), OpenAI text-embedding-3 (Matryoshka).

**Alternatives.** Separate model deployment per tenant (no cross-tenant batching; cost-prohibitive at fleet scale); single-modality serving stitched together by a client (adds round trips; misses the cross-modal latency floor); fixed-dimension embeddings (forces one cost/quality point).

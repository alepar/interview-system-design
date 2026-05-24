---
slug: multimodal-realtime-serving
archetype: ai-infrastructure
sources:
  openai_realtime_api: developers.openai.com/api/docs/guides/realtime
  whisper_batched: mobiusml.github.io/batched_whisper_blog/
  vision_token_pricing: spoold.com/tools/vision-tokens
  comfyui_aws: aws.amazon.com/blogs/architecture/deploy-stable-diffusion-comfyui-on-aws-elastically-and-efficiently/
---

# Multi-modal real-time serving (voice + vision + image generation)

## Bar anchors
- **Mid-level (L4/E4):** Treats each modality as a separate service; doesn't address cross-modal session state or WebSocket vs SSE distinction. Doesn't size the vision-token cost differential.
- **Senior (L5/E5):** Knows WebSocket for voice (vs SSE for text streaming). Names CLIP-class vision encoders. Discusses Whisper for ASR. Knows diffusion serving is different (memory-bandwidth-bound, not compute-bound). May or may not address per-provider vision tokenization differences.
- **Staff+ (L6/E6+):** Drives proactively. Cites GPT-4o Realtime specifics: WebSocket persistent session, PCM16/24kHz/mono base64-encoded chunks, event-driven (input_audio_buffer.append, response.output_audio.delta), ~300ms voice-to-voice latency bypassing STT→LLM→TTS pipeline. Quantifies vision-token asymmetry: Claude area formula (W×H)/750 → ~1334 tokens per 1000×1000 image; Gemini ~258 tokens/image; GPT-4o tile-based (1280×720 → 4 tiles, 765 tokens); 1024×1024 ranges 2K-16K tokens depending on model; vision tokens cost 2-5× text tokens. Names Whisper batching: 30s segments, 2.8× throughput with batching, 12× with VAD pre-segmentation. Diffusion serving: memory-bandwidth-bound; ComfyUI node-graph for multi-step pipelines (inpaint → upscale → refine); Diffusers + Accelerate for multi-GPU batch. Stretch (Sr Staff bar): cross-modal session state coherence (voice + image upload + generated image in one conversation); per-session cost cap accounting for vision token multipliers; connection economics at 10M+ concurrent WebSocket sessions.

## Canonical decomposition

### Requirements
**Functional:**
- Voice-to-voice conversation with sub-300ms latency (GPT-4o Realtime parity)
- Vision understanding on user-uploaded images (multi-image conversations supported)
- Image generation on demand (Stable Diffusion / DALL-E class)
- Single product surface; cross-modal session state coherent
- Per-tenant token quotas that account for vision-token multipliers

**Non-functional (with numbers):**
- Voice e2e latency: ~300ms (GPT-4o Realtime; one persistent WebSocket session)
- Audio format: PCM16, 24kHz, mono, base64 over WebSocket
- ASR throughput with batching: 2.8× over single-stream Whisper; 12× with VAD pre-segmentation
- Vision tokens: 1024×1024 image = 2K-16K tokens depending on provider; 2-5× text token cost
- Diffusion: 5GB model size; cold-start seconds; ComfyUI multi-step pipelines
- Image moderation: <30ms per frame (quantized ViT classifier)
- Concurrent WebSocket sessions: 10M+ scale (ChatGPT-class)

### Core entities
- **Session:** session_id, tenant_id, modalities_active, ws_connection_state, cost_consumed
- **VoiceFrame:** session_id, ts, pcm_bytes, direction (in | out)
- **ImageInput:** image_id, session_id, bytes, resolution, vision_tokens_estimated
- **GenerationJob:** job_id, session_id, prompt, model, pipeline_steps, status

### API
- WebSocket `/v1/realtime` — persistent session for voice (PCM16 input, PCM16 output, event messages)
- `POST /v1/images/analyze` body={image, model} → vision tokens consumed + textual analysis
- `POST /v1/images/generate` body={prompt, model, pipeline_steps} → SSE progress + final image URL
- Cross-modal: session state persisted server-side across modality switches within one conversation

### HLD
The **WebSocket gateway** is the persistent session terminator for voice — connection-affined to a session pod that holds session state. Audio frames flow bidirectionally; VAD on input detects speech vs silence and only forwards speech frames to the **ASR pool** (Whisper, batched at 30s windows; VAD pre-segmentation gives 12× throughput speedup). Transcribed text goes to the **LLM grounding service** for response generation; LLM output goes to **TTS pool** which emits PCM16 frames back through the WebSocket. For GPT-4o Realtime parity, the entire pipeline collapses into a single end-to-end multi-modal model that hears + thinks + speaks in one forward pass (~300ms voice-to-voice; bypasses the STT→LLM→TTS chain). For **vision**: image uploads via `POST /v1/images/analyze` hit the **vision tokenization service** (different per-provider formula — Claude area-based, GPT-4o tile-based) which sizes the vision-token cost and decides on downsampling if the image exceeds the per-tenant limit; tokenized image goes to the multi-modal LLM for analysis. For **image generation**: requests enter a queue served by the **diffusion pool** (memory-bandwidth-bound — V100/A10G OK, H100 wasteful); ComfyUI-style node-graph for multi-step pipelines (inpaint → upscale → refine); SSE progress updates as steps complete; final image written to object storage with signed URL returned. **Cross-modal session state** is durably persisted: a conversation that starts in voice, switches to text with an uploaded image, then generates an image — all maintain coherent state across modality switches.

### Deep dives
1. **WebSocket session model for voice (300ms budget).** Stateful persistent session — bidirectional audio frames, server-side VAD, server-streaming output audio, half-duplex by default but interruptible (user can talk over the model). Connection economics at scale: per-connection memory cost (~50-100 KB per active WebSocket) drives gateway pod sizing — at 10M concurrent connections, that's 500GB-1TB across the gateway fleet, requiring connection-aware pod sizing (e.g., 100K connections per pod = 100 pods, each with 5-10 GB memory). Backpressure: device disconnects gracefully (TCP RST detected, session paused for grace period awaiting reconnect, after timeout session terminated and final state checkpointed). Reconnect with session resume: client presents session_id + last_event_id, server resumes from durable state. Staff+ commit: connection-count target, per-connection memory budget, reconnect protocol, what happens to in-flight audio on disconnect.

2. **Vision-token cost model and per-provider asymmetry.** Different providers compute vision tokens differently. Claude: area formula (W×H)/750 → ~1334 tokens per 1000×1000 image (scales linearly with area). Gemini: ~258 tokens per image regardless of resolution (within bounds). GPT-4o: tile-based, 512×512 blocks (1280×720 = 4 tiles = 765 tokens). A 1024×1024 image ranges 2K-16K tokens depending on provider. Vision tokens cost 2-5× text tokens. For a multi-image conversation (e.g., user uploads 10 photos), cost can spike unexpectedly. Production answer: per-tenant token quota that accounts for vision-token multipliers (not just text token count); downsampling policy for large images (resize to model's optimal resolution before tokenization); resolution-aware decision on whether to process or reject (1024×1024 OK, 8K×8K rejected with clear UX message). Staff+ commit: per-provider tokenization math, downsampling policy, per-tenant vision-token budget tier.

3. **Whisper batching + VAD pre-segmentation for ASR throughput.** Naive Whisper is too slow for 1K concurrent voice sessions on shared GPU pool. Batched Whisper at 2.8× throughput (multiple audio chunks processed in one forward pass on GPU); VAD pre-segmentation (cut silence regions before sending to Whisper) gives 12× speedup since most audio is silence. Whisper processes audio in 30-second segments; long-form uses Chunked (overlap+stitch) vs Sequential (slow but accurate) algorithms. Trade-off: batching adds latency (wait for batch to fill); for real-time voice, this latency is competing with the 300ms budget — small batches (4-8 audio chunks) or VAD-triggered batch flush. Staff+ commit: batch size, VAD threshold, chunked vs sequential per workload, GPU pool sizing for ASR.

## Known failure modes
1. **Connection storm on rolling deploy.** 10M WebSocket sessions disconnect and reconnect when gateway pods rotate; reconnect storm saturates the new pods. Production answer: staggered deploy with connection-drain timer (each pod accepts no new connections for N minutes before termination, existing connections continue); sticky-routing to keep sessions on pre-drain pods; client reconnect with exponential backoff to spread the storm; reconnect rate limit at gateway to bound the storm.

2. **Image moderation false-positive on benign content.** Aggressive NSFW filter rejects medical, artistic, or educational content; users get blocked without recourse. Production answer: tiered moderation (cheap NSFW classifier first → borderline cases to a heavier classifier → human review queue for ambiguous); per-tenant trust score (verified medical tenant gets higher threshold); user-feedback loop with appeal path; UX clearly explains "image rejected" with category and appeal link.

3. **Diffusion cold-start latency.** Loading a 5GB Stable Diffusion model from disk takes seconds; user perceives long delay for first generation in a session. Production answer: warm pool of pre-loaded model instances; model-server-side caching of common LoRAs/style adapters; explicit "generating" UX with progress (SSE updates per pipeline step); for premium tenants, dedicated always-warm pool for instant first generation.

## Notes for the coach
- **This is plausibly-asked.** GPT-4o Realtime, Claude vision, Gemini multi-modal are public products; the engineering challenges are well-documented in OpenAI Realtime docs and AWS ComfyUI deployment guide. No confirmed single interview question, but multi-modal serving is an obvious Staff+ probe at OpenAI, Google DeepMind, and Meta AI.
- **The 300ms voice-to-voice latency anchor is the GPT-4o-specific signal.** Candidates who name the "STT→LLM→TTS pipeline bypass" and the PCM16/24kHz protocol details demonstrate 2024+ literacy with the realtime API stack.
- **Vision-token asymmetry is the cost-architecture gap most candidates miss.** Treating "an image is just another token" misses the 1334-vs-258 tokens-per-image variation that affects cost modeling significantly.
- **Cross-modal session state is the integration-bar move.** Most candidates address each modality in isolation; the Staff+ candidate articulates how a single conversation can span all three with coherent state.

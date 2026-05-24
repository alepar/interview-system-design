---
slug: safety-moderation-pipeline
archetype: ai-infrastructure
sources:
  igotanoffer_openai: igotanoffer.com (OpenAI SWE prompt: "Design a system to detect NSFW content in real-time ChatGPT outputs. Address model selection, latency requirements, and the feedback loop.")
  anthropic_constitutional_classifiers: anthropic.com/research/constitutional-classifiers
  openai_instruction_hierarchy: openai.com/index/the-instruction-hierarchy/
  llama_guard_3: huggingface.co/meta-llama/Llama-Guard-3-8B
  scm_streaming_paper: arxiv.org/html/2506.09996v1
---

# Safety / moderation pipeline for LLM inference

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic pre/post filter: classify input, classify output, block if either flags. Picks "a moderation API" (OpenAI Moderation API or Perspective API). Treats safety as a single binary score. Doesn't address streaming, latency budget within LLM TTFT, or false-positive UX.
- **Senior (L5/E5):** Names input filter + output filter as separate paths with different SLOs. Articulates the latency tax of synchronous moderation (Llama Guard 3 ~200-400ms on each side) and proposes async-parallel with swap-on-flag. Knows per-category thresholds vs single score. Identifies streaming moderation as a special problem ("can't unsend tokens already flushed") and proposes chunk-buffered streaming. Names instruction hierarchy at category level. Discusses feedback loop (human review → labeled data → classifier retrain).
- **Staff+ (L6/E6+):** Drives the session proactively. Names the layered defense imperative: combining content filtering + hierarchical guardrails + response verification reduced attack success from 73.2% to 8.7% while preserving 94.3% of baseline task performance. Names OpenAI's Instruction Hierarchy explicitly (system > developer > user > tool output, +63% jailbreak robustness, baked into training). Names Anthropic's Constitutional Classifiers with the specific numbers: 86% → 4.4% jailbreak success, 23.7% compute overhead, 0.38% FPR (not statistically significant on n=5K), validated with 183 jailbreakers × 3000+ hours. Articulates streaming moderation via Streaming Content Monitor (classifies harmful content from first 18% of tokens for early-stop) and NeMo Guardrails chunk_size buffer (tokens flush + buffer; chunk_size is the safety/UX dial). Honest acknowledgement: 12 published prompt-injection defenses bypassed >90% in joint Anthropic/OpenAI/DeepMind testing — defense-in-depth + capability scoping + human approval for irreversible actions is the only durable answer. Stretch (Sr Staff bar): validation methodology (external red-team with measured adversary-hours, not held-out test sets); per-tenant policy override; legal-compliance retention for moderation decisions.

## Canonical decomposition

### Requirements
**Functional:**
- Screen user inputs for prompt-injection, harmful content, policy violations
- Screen model outputs for harmful content, PII leaks, IP violations
- Support streaming output: detect and interrupt harmful generation mid-stream
- Per-tenant policy override (medical research tenant can ask medical questions free-tier can't)
- Tamper-evident audit log for moderation decisions (compliance, incident response)
- Feedback loop to retrain classifiers on missed/false-positive cases

**Non-functional (with numbers):**
- Added p99 latency budget: <100ms total across input + output filtering
- Constitutional Classifiers compute overhead: 23.7% per Anthropic published numbers
- FPR on harmless queries: <0.5% (Anthropic: 0.38%, not statistically significant)
- Jailbreak block rate: >95% (Anthropic: 86% → 4.4% with classifiers)
- Streaming early-stop: SCM-class detection from ~18% of tokens
- Audit retention: years (regulatory), tamper-evident hash chain
- Coverage: 13+ content categories (omni-moderation-latest), per-category configurable thresholds

### Core entities
- **InputCheck:** check_id, request_id, classifier_version, per_category_scores, decision (allow | block | escalate), latency_ms
- **OutputCheck:** check_id, request_id, classifier_version, partial (bool), token_offset, scores, decision
- **PolicyOverride:** tenant_id, category, threshold_override, justification, approver, ts
- **AuditEvent:** event_id, request_id, action (input_blocked | output_blocked | streaming_interrupted | human_escalated), ts, signed_hash
- **RedTeamFinding:** finding_id, jailbreak_text, model_version, severity, status (open | mitigated)

### API
- `POST /v1/moderation` body={input | output, content, tenant_id, model_version} → {decision, per_category_scores, latency_ms}
- `POST /v1/moderation/stream` SSE — for streaming output moderation; emits `allow | block_now | continue` per chunk
- `POST /v1/feedback` body={request_id, human_label, justification} → {feedback_id}
- `GET /v1/audit/:request_id` → full chain of moderation decisions for forensic review
- `POST /v1/policies/:tenant_id/override` body={category, threshold} → policy update (requires approval)

### HLD
The moderation pipeline runs as a sidecar/middleware to the LLM serving stack. **Input path:** request hits gateway → input classifier (Llama Prompt Guard ~50ms — cheap first-pass for prompt-injection attempts) → if pass, parallel-dispatch to (a) LLM inference and (b) heavier input classifier (Llama Guard 3 ~200ms — full taxonomy classification). If the heavy classifier flags before LLM finishes prefill, cancel the LLM call and return policy-block. **Output path:** as tokens stream from LLM, they go through a **Streaming Content Monitor** (SCM-class) that classifies the partial response from a rolling prefix — early detection at ~18% of tokens triggers a `block_now` signal to the streaming layer. The streaming layer uses a **chunk_size buffer** (NeMo Guardrails pattern): tokens flush to the user in chunks; the chunk-buffer is the safety/UX dial (smaller chunk → faster user feedback but more frequent moderation passes; larger chunk → more efficient moderation but slower user feedback and less retraction room). **Instruction hierarchy** is enforced at the inference layer itself (trained into the model: system > developer > user > tool output) — the moderation pipeline assumes this is the first line of defense, not the last. **Policy engine** consumes per-tenant overrides and applies them to the classifier output before final decision. **Audit pipeline** consumes a Kafka stream of every moderation decision, writes tamper-evident hash-chained records to compliance storage. **Feedback loop** routes false-positives to a human review queue → labeled data → periodic classifier retrain (typically quarterly per Anthropic Constitutional Classifiers cadence).

### Deep dives
1. **Layered defense (cascade + ensemble).** Cheap classifier first (Llama Prompt Guard — small, fast, catches obvious attacks) → expensive classifier (Llama Guard 3 8B — taxonomic classification, 200-400ms) → instruction-hierarchy-trained model output (OpenAI's recipe: system > developer > user > tool output, baked into training, +63% jailbreak robustness) → output classifier (catches harmful generation that slipped through input + model defenses). Trade-off: more layers → more cost + latency, but compounding probability of catch (combining filtering + hierarchical guardrails + response verification reduced attack success 73.2% → 8.7% with 94.3% of baseline task performance retained). Anthropic Constitutional Classifiers specifically reported 86% → 4.4% jailbreak success at 23.7% compute overhead and 0.38% FPR. Staff+ commit: per-layer threshold tuning, cost-vs-coverage curve, false-positive budget (per-category), explicit acknowledgement that input filter alone is insufficient.

2. **Streaming moderation with early-stop.** Once a token is flushed to the user, it can't be unsent — chunk_size is the dial that bounds retraction room. NeMo Guardrails uses `stream_first=True` to flush + buffer in chunks; moderation runs on each chunk as it lands. Streaming Content Monitor (SCM, arXiv 2506.09996) classifies harmful content from a rolling prefix using hierarchical consistency-aware learning, achieving comparable F1 to full-output detection while seeing only the first 18% of tokens — enabling early-stop interception before significant harmful content emits. Trade-off: chunk_size small enough to retract effectively (e.g., 50 tokens) vs not so small that the moderation classifier overhead becomes dominant. Fallback for false-positive mid-stream: emit `[message removed by policy]` UX, log the false-positive for human review, refund the user the unused token budget. Staff+ commit: chunk_size, retraction protocol UX, what happens to in-flight cost when generation is interrupted.

3. **Instruction hierarchy + acknowledgement that prompt injection is unsolved.** OpenAI's Instruction Hierarchy bakes priority into training: system > developer > user > tool output. Trained via synthetic data with composite inputs at different hierarchy levels. The tool-output slot is the *most* untrusted input because it can carry attacker-controlled text (e.g., a web page with injected instructions). Anthropic's Constitutional Classifiers validate with 183 jailbreakers spending 3000+ hours; Feb 2025 public challenge: 339 participants, 300K+ interactions, 3700 collective hours, $55K paid out, only one universal jailbreak found across 8 questions. But: joint research from Anthropic + OpenAI + DeepMind tested 12 published defenses and bypassed all of them with >90% success for most. Honest answer: prompt injection is not solved at the defense-layer level; the durable mitigation is defense-in-depth + capability scoping + human approval for irreversible actions (an agent that can't autonomously transfer money or delete data can't be tricked into doing so). Staff+ commit: enumerate what the model *can't* do regardless of prompt content, not just what the input/output classifiers try to catch.

## Known failure modes
1. **False positive blocks legitimate users at scale.** Aggressive moderation rejects medical, legal, security-research, or artistic content that's policy-compliant but pattern-similar to harmful content. Production answer: per-category threshold tuning with tenant-specific overrides (medical research tenant gets higher threshold on health-related queries); tiered escalation (borderline cases go to human review rather than auto-block); user-feedback loop with measurable false-positive rate as a tracked SLI (Anthropic targets <0.5%, achieved 0.38%). UX matters: a transparent appeals process beats silent blocking.

2. **Adversarial prompt evolution outpaces classifier updates.** Jailbreaks invented in the wild faster than the classifier retrain cadence. Production answer: continuous external red-team budget (Anthropic's Feb 2025 challenge: $55K bounty paid out over a 3700-hour adversary-effort window); instrumentation to detect jailbreak patterns in live traffic (clustering of policy-flagged prompts, anomaly detection on response-pattern shifts); classifier retrain cadence aligned to threat-landscape change rate (quarterly minimum, faster on emerging-threat alerts). Held-out test sets are insufficient — they don't simulate the adversary-evolution dynamic.

3. **Streaming false positive mid-flush ruins UX.** SCM flags harmful content after partial output already sent to user. Production answer: chunk_size small enough to retract a meaningful portion (e.g., 50 tokens ≈ half a paragraph); explicit `[message removed by policy]` UX with reason and appeal path; post-incident audit trail capturing the partial-flushed content for human review (was the SCM right? if false-positive, retrain). Anti-pattern: silently truncating mid-sentence without UX feedback — users assume the LLM crashed.

## Notes for the coach
- **This is the confirmed OpenAI SWE prompt** per IGotAnOffer: "Design a system to detect NSFW content in real-time ChatGPT outputs. Address model selection, latency requirements, and the feedback loop." Anthropic asks this with safety framing as a first-class architectural concern — per the Exponent guide, "a 'highly available' system that serves toxic content is a failure." The Anthropic version emphasizes the layered defense + the honest acknowledgement of jailbreak risk; the OpenAI version emphasizes the model-selection trade-off + feedback-loop engineering.
- **The Constitutional Classifiers numbers (86% → 4.4%, 23.7% overhead, 0.38% FPR) are the Anthropic-specific Staff+ unlock.** Candidates who cite them demonstrate Anthropic-specific literacy.
- **The streaming-moderation problem is non-obvious.** Most candidates default to "moderate the full response after generation" and miss the "can't unsend" reality. Surface as a category-level gap flag if not addressed.
- **The Sr Staff bar is the honest acknowledgement that prompt injection is unsolved.** A candidate who claims their design "solves" prompt injection is missing the bar; the Sr Staff candidate names defense-in-depth + capability scoping as the production answer and bounds what the agent can autonomously do.

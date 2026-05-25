---
slug: voice-assistant-routing
archetype: ml-in-loop
sources:
  alexa_data_rep: amazon.science/blog/with-new-data-representation-scheme-alexa-can-better-match-skills-to-customer-requests
  alexa_hyprank: amazon.science/blog/hyprank-how-alexa-determines-what-skill-can-best-meet-a-customers-need
  apple_hey_siri: machinelearning.apple.com/research/hey-siri
  joint_intent_slot_bert: arxiv.org/abs/2202.13079
  amazon_skills_blog_2019: Amazon Developer Blog Sept 2019 (>100K Alexa skills)
  alexa_teacher_model: arxiv.org/abs/2206.07808 (FitzGerald et al. "Alexa Teacher Model")
---

# Voice-assistant intent routing (classical era) — 5-stage pipeline + Hey Siri 2-stage AOP + Alexa Shortlister+HypRank + JointBERT NLU

## Bar anchors
- **Mid-level (L4/E4):** "ASR + intent classifier." No latency budget per stage; no on-device specifics.
- **Senior (L5/E5):** Names wake-word + ASR + NLU + TTS. Discusses skill routing. May or may not address Hey Siri 2-stage architecture, JointBERT, Alexa Shortlister + HypRank, or P99 latency dominance.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **classical voice-assistant stack as cascade of ML models** in tight latency budgets, each with separate eval harnesses — NOT one ML model. Names **5-stage pipeline**: wake-word detection (on-device, sub-200ms, <100KB) → streaming ASR (RNN-T or Transformer-T, 100-500ms) → NLU (joint intent + slot via shared BERT encoder + 2 heads — CRF for slot tags + softmax for intent) → skill routing / dialog management → TTS (75-200ms time-to-first-audio). Names **Hey Siri 2-stage detector**: tiny always-on DNN on AOP/motion coprocessor (separate chip from main AP) processes 0.2s frames (20 frames) into phoneme-class probabilities → temporal integrator computes confidence → only if passes does main AP wake + run second-pass model. Two-stage minimizes always-on power. Cites **JointBERT and successors**: intent + slot done simultaneously with shared encoder + 2 heads; FitzGerald et al. *Alexa Teacher Model* (arXiv 2206.07808) distillation from 700M-9.3B teacher to 17M-170M production students yields +3.86% relative intent accuracy and +7.01% relative slot F1. Cites **>100,000 Alexa skills** (Amazon Sept 2019). Names **Alexa Shortlister + HypRank 2-stage arbitration**: Shortlister (scalable neural model finds k-best candidate skills — optimizes for high recall) + HypRank (re-ranks with high precision using contextual signals: dialog state, user account settings, prior skill usage). Names **confidence-thresholded clarification** (max intent prob <~0.7 triggers "Did you mean..." or skill-disambiguation handoff). Cites **end-to-end latency**: P90 ~3.5s / P99 ~5s; **P99 consistency dominates UX**, not P50. Stretch (Sr Staff bar): cites **on-device speculative endpointing** — Amazon Science: run 2 endpointers, speculative 200ms ahead of final, initiate downstream NLU early.

## Canonical decomposition

### Requirements
**Functional:**
- Wake-word detection on-device (always-on, low-power)
- Streaming ASR with speculative endpointing
- NLU: hierarchical domain → intent → slot classification
- Skill routing across 100K+ skills (catalog-scale retrieval + ranking problem)
- Dialog management with multi-turn state tracking
- TTS with low time-to-first-audio

**Non-functional (with numbers):**
- >100,000 Alexa skills [Amazon Developer Blog Sept 2019]
- 100M+ Alexa-enabled devices sold by 2019
- Wake-word: <200ms / <100KB on-device
- Hey Siri: 0.2s frames on AOP coprocessor
- ASR latency: 100-500ms streaming
- TTS time-to-first-audio: 75-200ms
- End-to-end: P90 ~3.5s / P99 ~5s
- JointBERT models ATIS: 88.6% / SNIPS: 92.8% sentence-level frame accuracy

### Core entities
- **Audio frame:** continuous mic input segmented into 0.2s frames
- **ASR hypothesis:** n-best transcriptions with confidence scores
- **Domain / intent / slot:** hierarchical NLU output (Music → PlaySong → {Artist=X, Song=Y})
- **Skill candidate:** (skill_id, recall_score) from Shortlister
- **Dialog state:** multi-turn context tracked across turns
- **Speech response:** TTS-synthesized audio streamed back to device

### API
- Device: stream(audio_frames) → wake_word_event → upload audio_buffer → ASR → NLU → Skill response → TTS → audio playback
- Internal: nlu.joint_intent_slot(text) → (intent, slots); skill_router.shortlist(intent, context) → k-best skills; skill_router.hyprank(candidates, dialog_state) → top skill

### HLD
**Wake-word detection** runs continuously on AOP/motion coprocessor (separate chip from main AP; <100KB model, sub-200ms latency, never streams audio to cloud — privacy + latency). **Hey Siri 2-stage**: stage 1 = tiny DNN on AOP processing 0.2s frames into phoneme-class probabilities; temporal integrator computes confidence; only if confidence > threshold does main AP wake + run second-pass heavier model (reduces false-accept rate). **Streaming ASR** (RNN-T or Transformer-T) transcribes audio incrementally; **speculative endpointing**: 2 endpointers — speculative 200ms ahead of final — initiates downstream NLU early. **NLU pipeline**: domain classifier (Music, Weather, Smart Home) → intent classifier within domain → slot tagger. **JointBERT** (shared encoder + 2 heads: CRF for slot BIO tags + softmax for intent) — mutually informative; production dominant. **Skill routing 2-stage**: **Shortlister** (scalable neural model finds k-best candidate skills — optimizes for high recall over 100K+ skills) + **HypRank** (re-ranks with high precision using contextual signals: dialog state, user account settings, prior skill usage). **Confidence thresholding**: if max intent prob <~0.7, trigger clarification turn ("Did you mean to play music or set a timer?") or skill-disambiguation handoff. **Alexa Conversations**: deep-learning dialog manager replacing rule-based flows; tracks state across turns via per-slot carryover decisions (encoder-decoder produces confidence per candidate slot). **TTS** streams audio back to device with 75-200ms time-to-first-audio.

### Deep dives
1. **5-stage pipeline + per-stage latency budget.** **Wake-word**: tiny on-device model continuously processing mic input; <200ms activation; <100KB; never streams audio to cloud (privacy + latency). **ASR**: streaming speech-to-text; 100-500ms depending on streaming config. **NLU hierarchical**: domain classifier (Music, Weather, Smart Home) → intent classifier (within domain — PlaySong, SkipSong, AdjustVolume) → slot tagger (Artist, Song, Volume). **Skill routing**: which skill (1st-party Spotify? Calendar? Smart-home?) handles this query — uses dialog state + user account links + prior skill usage. **TTS**: streaming text-to-speech; 75-200ms time-to-first-audio. **End-to-end**: P90 ~3.5s, P99 ~5s. **P99 dominates UX** (occasional very-slow responses break conversational feel).

2. **Hey Siri 2-stage detector + JointBERT NLU.** **Apple Hey Siri 2-stage**: stage 1 = tiny DNN on AOP/motion coprocessor — separate chip from main AP; processes 0.2s audio frames (20 frames) into phoneme-class probabilities; temporal integrator computes confidence score that uttered phrase was "Hey Siri." Only if confidence > threshold does the main AP wake + run a second-pass model (heavier; reduces false-accept rate). **Two-stage minimizes always-on power consumption**. **JointBERT** [arXiv:2202.13079]: intent classification + slot filling done **simultaneously** with shared encoder + two heads (one CRF/linear-chain for slot tags, one softmax for intent). Mutually informative: knowing the intent improves slot tagging accuracy and vice versa. Production deployment dominant pattern.

3. **Alexa Shortlister + HypRank + Conversations dialog manager.** **Shortlister**: scalable neural model finds k-best candidate skills per utterance — optimizes for high recall (don't miss a viable skill). **HypRank**: re-ranks the shortlist with high precision; uses contextual signals (dialog state, user account settings, prior skill usage, time-of-day). Two-stage arbitration handles 100K+ skills at Alexa scale. **Confidence thresholding**: if Shortlister's k-best max-prob < ~0.7, trigger clarification turn ("Did you mean to play music or set a timer?") or skill-disambiguation handoff. Always preferable to confident mis-routing. **Alexa Conversations**: deep-learning dialog manager replacing rule-based flows; tracks state across turns via per-slot carryover decisions (encoder-decoder produces confidence per candidate slot); enables scale across thousands of skills. **Alexa Teacher Model**: distillation from 700M-9.3B teacher to 17M-170M production students yields +3.86% relative intent accuracy and +7.01% relative slot F1.

## Known failure modes
1. **Wake-word false-accept/reject.** False-accept: noise mistakenly triggers wake (privacy concern; battery drain). False-reject: user said wake word but model missed (UX broken). Production answer: 2-stage detector (cheap on-AOP first, heavier on AP second); adaptive thresholds per-environment; per-user wake-word fine-tuning.

2. **ASR errors cascade into NLU mis-classification** (canonical voice-assistant failure mode). Production answer: n-best ASR hypotheses (top-K transcriptions) passed to NLU; joint ASR+NLU model; explicit error-recovery (clarification prompts) when confidence drops.

3. **Skill-routing under thousands of skills.** Many skills overlap functionally (multiple weather skills, multiple music skills). Production answer: Shortlister + HypRank 2-stage; explicit user-preference learning (which skill they prefer for ambiguous queries); contextual disambiguation.

4. **Cold-start skills** never route. Production answer: content-based bootstrap (skill descriptions, declared intents, example utterances); retrieval over skill catalog using semantic similarity.

5. **Privacy leakage** when on-device audio logged for retraining. Production answer: on-device-only wake-word; explicit opt-in for audio retention; federated learning for sensitive paths.

6. **Latency-tail under load** breaks "instant" perception. Production answer: P99 monitoring + capacity overprovisioning; degraded modes (skip TTS for speed; pre-cached responses for common queries).

## Notes for the coach
- **Asked-confirmed at Amazon (Alexa), Apple (Siri), Google (Assistant), Samsung (Bixby).** Amazon Science blog posts (data representation, HypRank, Conversations), Apple ML Hey Siri post, Alexa Teacher Model paper, JointBERT paper — all explicit interview-prep canon.
- **The 5-stage pipeline as cascade-of-ML-models is the canonical Staff+ unlock.** Candidates who treat this as "one ML model" miss the architectural reality entirely.
- **The Hey Siri AOP 2-stage detector is the deep-cut.** Mid-senior candidates default to "we run a small model on-device"; Staff+ candidates name the AOP/motion-coprocessor separation + temporal-integrator + main-AP wake-on-confidence as the canonical low-power always-on architecture.
- **The Shortlister + HypRank 2-stage arbitration is the depth probe for catalog-scale routing.** At 100K+ skills, single-stage scoring is infeasible; recall-vs-precision split is mandatory.
- **Adversarial probe: "your wake-word model has 1% false-accept rate. With 100M devices, what's the daily privacy/cost impact?"** Strong answer: 1M false-wakes per device per day across fleet; multiply by audio-upload cost + privacy exposure; mitigation = 2-stage detector + per-environment threshold tuning + on-device-only first stage. Weak answer: "we tune the threshold" without the fleet-scale math.

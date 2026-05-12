# Building a Claude Code System-Design Interview Coach: A Survey of What's Missing

## TL;DR

- **No prior-art system-design coach is worth forking.** Every comparable artifact — the nine "System Design" GPTs in the OpenAI GPT Store (all stateless single-prompts), `noamseg/interview-coach-skill` and `raphaotten/claude-interview-coach` on GitHub (generic, SD-as-sub-mode), Hello Interview's closed-source Guided Practice (best content but web-only, single-mode), and dormant ventures like TechInterviewer.ai — has at most two of the four properties this build needs (three-mode coverage, file-backed cross-session state, in-session level branching, structured deep-dive FSM). Hello Interview's standalone *AI Mock Interview* tab is now publicly marked Deprecated at `hellointerview.com/mock/ai`: the platform with the most data and best content gave up on open-ended AI mocks at SD difficulty. That single fact should reshape the build.
- **The current guide.md's two largest gaps are level-calibrated answer exemplars and the AI-infrastructure archetype.** Hello Interview has published quotable per-level "Bar for X" callouts for Top-K Videos, Dropbox, LeetCode-style coding platforms, Twitter, and Ticketmaster, plus Stefan Mai's staff-level essay and Evan King's per-level breakdown — these are the canonical reference answers an LLM-as-judge needs to stop hallucinating grades (Zheng et al. 2023 show reference-guided judging cuts failure rate from 70% to 15%). Separately, Anthropic/OpenAI/DeepMind system-design rounds are now built around inference batching, KV-cache management, prefix caching (Anthropic publicly documents 90% cost reduction and up to 85% latency reduction on long prompts), continuous batching (vLLM PagedAttention), model routers, and safety pipelines — a category your guide does not have.
- **Cheating prevention should be design-level friction, not detection.** Industry precedents are unambiguous on the cost of false positives: Turnitin's AI detector simultaneously revised its claim from <1% document-level to 4% sentence-level FPR after the Washington Post found it "identified over half of our 16 samples at least partly incorrectly" (via NSF TRAILS); UBC Senate restricted Proctorio after independent testing showed facial detection failed on Black faces 57% of the time; Codeforces and ICPC have publicly conceded that AI-assisted cheating cannot be prevented at scale online. The single highest-leverage cheating-resistance pattern for a stateless LLM coach is *refusal as a feature* in `/practice-problem`: the coach does not produce a complete design until the user has typed their own requirements and rough first pass. This is simultaneously the best pedagogy (Hello Interview reports requirements gathering is the #1 most common mid-level feedback and stays in the top 3 even for Senior+) and the best cheating-resistance (typing requirements first is mechanically slower than just doing the interview).

---

## Executive Summary

The fifteen things the current guide.md is missing or treating wrongly, ranked by impact on coach effectiveness, with one-line rationale and CONFIRMED/REPORTED/SPECULATED labels:

1. **No level-calibrated answer exemplars in the rubric.** CONFIRMED. Hello Interview's published "Bar for X" per-problem callouts are the single highest-leverage public source of grading signal and they are directly quotable as reference answers for an LLM-as-judge.
2. **The "drive vs wait" boundary at L5/L6 is the pivotal moment.** CONFIRMED. Per Hello Interview co-founder Evan King: *"More junior candidates can expect the interviewer to jump in here and point out places where the design could be improved. More senior candidates should be able to identify these places themselves and lead the discussion."*
3. **AI-lab system-design prompts are categorically different and the guide lacks the archetype.** CONFIRMED across multiple primary accounts. Anthropic's reported prompts (inference batching for a GPU cluster; distributed search at a billion documents and millions of QPS; KV-cache-aware request routing) need a separate "AI Infrastructure" archetype with PagedAttention/continuous batching, prefix caching, model-router gateways, eval pipelines, and parallel safety pipelines.
4. **Front-end / client system design is missing entirely.** CONFIRMED. Meta, Airbnb, Google, Atlassian, and Uber all ask it; GreatFrontEnd's RADIO framework is the canonical structure.
5. **Meta's AI-Enabled Coding Round (Oct 2025) is real and SD has *not* changed in lockstep.** CONFIRMED via Hello Interview, Prepfully, interviewing.io, Coditioning, HR Grapevine. The asymmetry is policy-relevant.
6. **LLM-as-judge failure modes** (position bias, verbosity bias, self-enhancement, silent shortcut bias) are not addressed. CONFIRMED.
7. **Sycophancy collapse and persona drift over 60-minute sessions are mechanism-level failures.** REPORTED to CONFIRMED. The persona-drift activation-projection work is from Lu et al., arXiv:2601.10387 ("The Assistant Axis: Situating and Stabilizing the Default Persona of Language Models," MATS/Anthropic/Oxford, Jan 2026), which demonstrates drift via activation-space projections in Gemma 2 27B, Qwen 3 32B, and Llama 3.3 70B; the specific 20–40% range cited in early summaries is not stated in the abstract and should be treated as unverified pending full-paper review. Separately, "Interaction Context Often Increases Sycophancy in LLMs" (arXiv:2509.12517) shows memory features make sycophancy *worse*.
8. **Sustained-roleplay anti-patterns from Khanmigo, Duolingo Max, and Character.ai are published.** CONFIRMED. Khanmigo improved measurably (Khan Academy reports a six-percentage-point gain over Oct 2025 – Apr 2026 product testing) when given structured signals from the user's learning record rather than free-form chat memory. Duolingo Max's "Lily" was critiqued for ending every utterance with a question ("more like an interrogation than a friendly conversation").
9. **Cheating detection in a stateless coach is not feasible at useful FPR/FNR.** CONFIRMED via Turnitin's revised 4%-sentence-level FPR, UBC's 57% face-detection failure finding on Black faces, and Codeforces' public concession.
10. **Refusal-as-a-feature is the single highest-leverage cheating-resistance pattern.** SPECULATED based on convergent evidence (Khanmigo's improvements all moved in this direction; Hello Interview's #1 feedback category is requirements gathering).
11. **VanLehn's 2011 effect-size correction should anchor the coach's ambition.** CONFIRMED — VanLehn (2011) "The Relative Effectiveness of Human Tutoring, Intelligent Tutoring Systems, and Other Tutoring Systems," Educational Psychologist 46(4):197–221, DOI 10.1080/00461520.2011.611369: *"the effect size of human tutoring was much lower: d = 0.79. Moreover, the effect size of intelligent tutoring systems was 0.76, so they are nearly as effective as human tutoring."* Not 2-sigma.
12. **Cognitive apprenticeship (Collins/Brown/Newman/Holum) gives `/practice-problem` its theoretical scaffolding** — modeling → coaching → scaffolding → articulation → reflection → exploration with progressive fading. CONFIRMED via Collins, Brown, and Holum (1991), American Educator 15(3):6–11, 38–46.
13. **Interleaving beats blocked practice for procedural skill discrimination.** CONFIRMED — Brunmair & Richter (2019), "Similarity matters: A meta-analysis of interleaved learning and its moderators," Psychological Bulletin 145(11):1029–1052: overall Hedges' g = 0.42 across 59 studies and 238 effect sizes; mathematical tasks g = 0.34 (small positive). SD interview prep is primarily a discrimination task and should be interleaved.
14. **Bluffing detection is plausible via linguistic signals** (passive voice + unnamed components, switching numbers→adjectives mid-design, hedge escalation, recursive abstraction). SPECULATED but interviewer-folklore-consistent.
15. **The "≈30% deep dive" weight is an aggregate that misleads.** CONFIRMED via Stefan Mai's option-listing failure example. Interviewers decide on 1–2 pivotal moments.

---

## Area 0 — Prior Art For This Exact Build

### Claude Code skills and skill marketplaces

The closest existing artifacts on the Claude Code side are three repos, none of which is a system-design interview coach:

**`noamseg/interview-coach-skill`** is a generic interview-prep Claude Code skill. It scores candidate answers across five dimensions (Substance, Structure, Relevance, Credibility, Differentiation), maintains a `coaching_state.md` for cross-session memory, and includes an "8-stage drill progression" plus full 4–6 question mocks across behavioral, system design, case study, panel, and technical+behavioral formats. The state-file pattern — commit everything as markdown, resume across sessions — is exactly the model you want, and the explicit "outcome-calibration" loop is state-of-the-art: *"After 3+ real interviews, it runs scoring drift detection, identifies when external feedback contradicts coach scoring, and recalibrates."* What it gets wrong: system design is one sub-mode of a generic 23-command product; the phase-based SD analysis ("scoping, approach, deep-dive, tradeoff, adaptation") is generic; there's no level branching, no per-pattern depth model, no AI-infra archetype. **Reuse potential:** read it for the state schema and the directness levels (1–5); do not fork — its breadth would dilute SD focus. Active commits Q1/Q2 2026.

**`raphaotten/claude-interview-coach`** has a similar shape: CLAUDE.md orchestration, `data/`, `coaching/`, `examples/`, `.claude/skills/`, anti-pattern counting, voice-export via mobile app, debrief from transcript. Its distinguishing move is voice-export — "run /voice-export to get an interview simulation prompt for the Claude mobile app, practice by speaking, then /debrief the transcript" — a clever way to escape keyboard-bound coaching without building voice infrastructure. Behavioral/CV-focused; SD incidental.

**`Sorbh/interview-me`** is not interview prep at all: it turns vague requirements into production specs "by interviewing you like a senior architect would." Useful as a counter-example because it shows that "interview me" is a popular skill primitive and people will conflate it with prep.

The Anthropic/ComposioHQ "awesome-claude-skills" curated list (~266 skills as of May 2026) and Alireza Rezvani's 245+ skills marketplace contain zero system-design-interview-specific skills. The `borghei/Claude-Skills` repo has an `interview-system-designer` skill — but it generates interview *loops for hiring managers* (scorecards, rubric scaffolding), not coaching for candidates.

### OpenAI GPT Store

OpenAI removed public conversation counts from the GPT store in mid-2024, so install-count claims are unverifiable. Nine SD-specific GPTs are catalogued, all stateless single-prompts:

- **System Design Interview Coach** by Dong Chen — generic chat coach
- **System Design GPT** (unattributed) — generic Q&A
- **Mock System Design Interview** (unattributed) — one-shot mock
- **System Design Interviewer** (unattributed) — one-shot mock
- **System Design Tutor** (unattributed) — "visuals and simple terms"
- **System Design Interview – An Insider's Guide** (unattributed) — grounded in Alex Xu's book; the only one explicitly anchored to a source text
- **System Design GPT by bugfree.ai** — tied to a hosted product
- **Software System Design GPT** by Samar Mohamed Ahmed — mermaid/draw.io focus
- **System Design HLD Mentor** (unattributed)

None has a state model. None has level calibration. None has three-mode coverage. **Reuse potential: zero.** These are useful only as a control set — they confirm the search space is unsaturated.

### Hosted products with AI components

**Hello Interview Guided Practice** is the most mature comp. It walks the user through 44 SD/LLD problems step-by-step (Requirements → Core Entities → API → HLD → Deep Dives) with personalized AI feedback at each step, plus an "Ask Tutor" inline help and a separate AI Interviewer track. The feedback is "tuned by FAANG interviewers." What it does well: the finite-state machine over the design framework is exactly right; per-step scoring rather than end-of-session grading dramatically reduces sycophancy collapse risk; problem-specific answer keys mean the LLM-judge has reference answers, which closes the largest known failure mode. What it doesn't do: it is single-mode (watch-me-design + answer-key teach); the live mocks are humans, not AI; it does not branch the rubric by level inside a session; it is web-only and not forkable. **Critical signal:** Hello Interview's standalone "AI Mock Interviews" tab is now marked Deprecated on `hellointerview.com/mock/ai`. They retreated from open-ended AI mocks to step-based guided practice. That retreat is a primary 2026 industry datum: open-ended AI mocks at SD difficulty are hard.

**interviewing.io AI Interviewer** runs "coding and system design interviews, in the style of a FAANG mock interview" with 200+ problems free, drawing from the Beyond Cracking the Coding Interview question bank. A REPORTED Medium critique by "Code Grey" (medium.com/@codegrey, 2025): *"A few AI tools looped on the same question even after I had already addressed it. One system design tool hallucinated new requirements halfway through."* This is the canonical SD-coach failure pair: looping and mid-session goal-drift.

**Exponent, Educative, DesignGurus, IGotAnOffer, Tryexponent** — all offer AI-assisted SD practice, all closed-source, all single-mode, all web-app delivery. No self-hosted, local-LLM, or Claude Code variant exists.

**bugfree.ai** ("Leetcode for System Design") has an in-browser AI mock-SD product with three-dimension scoring and 100+ SD problems. REPORTED. Their public Medium post claims that "while writing your answers or sketching diagrams, the AI acts as your interviewer in real time… asks follow-up questions… or provides hints if you seem stuck." Not forkable.

### Show HN / Reddit / abandoned

**TechInterviewer.ai** (Show HN Jan 19, 2024, HN id 39055841, 11 points, 7 comments) was a multimodal AI interviewer "Steve" that combined voice and whiteboard simultaneously with phase-based guidance (scoping → HLD → deep-dive). Last activity Q1 2024; the product is dormant. The fact that the founders shipped this and then went quiet is itself a useful signal — demand without retention.

**HN 44844781** (May 2025) — a solo developer's AI-feedback-on-SD-diagrams web tool. Single-shot, no conversation. The author's confession — *"this is not my forte"* — is a tell about the asymmetry between LLM SD-coaching demand and supplier skill.

**`IliaLarchenko/Interviewer`** (GitHub) is a Gradio-based speech-first interviewer. Configurable LLM/STT/TTS, works with Anthropic Claude, OpenAI, HuggingFace, or local Ollama. Multi-domain (coding + ML + SD). Single linear conversation per session. Reuse potential: the STT/TTS plumbing if voice is ever in scope.

**HN "Samurai Interview" (44007625)** — the self-description explicitly admits *"system design is a token feature"* — a representative HN show pattern: every general interviewer tool says it covers SD; none does so well.

### Academic prototypes

The Khanmigo evaluation literature (Batsaikhan & Correia 2024; Khan Academy's own Oct 2025 – Apr 2026 product-testing posts) and the broader ITS meta-analyses (VanLehn 2011; Ma et al. 2014; Kulik & Fletcher 2016) are highly relevant for pedagogy, but no academic prototype targets system-design tutoring specifically. The closest adjacent work is on cognitive apprenticeship for writing and programming (Bereiter & Bird 1985; Lane & VanLehn 2005 on tacit programming knowledge) — useful for the "watch me design" mode's worked-example design, not for content.

### Verdict

**The field is open.** No existing product or open-source project combines (a) three-mode coverage, (b) level calibration inside a session, (c) file-backed cross-session memory, and (d) a structured deep-dive state machine. The two closest comps are Hello Interview Guided Practice (closed source, web-only, single mode) and `noamseg/interview-coach-skill` (Claude Code, multi-domain, state model, but SD is a sub-feature). Read both carefully, then build.

---

## Area 1 — Pedagogy & Coach Behavior

### What effective human SD coaches actually do, turn by turn

The most useful single primary artifact is the interviewing.io transcript of a Meta E5/E6 mock SD interview ("Supersonic Seahorse" interviewing "Occam's Chameleon" on a centralized ML management platform; `interviewing.io/mocks/facebook-system-design-centralized-ml-management-platform`), where the staff-level interviewer's actual moves are visible:

- **Time-boxing as an explicit move, not a hidden constraint.** *"We have 45 minutes for each round. Specifically… we try to collect the signals from you within maybe the 40 minutes."* Stated aloud at start.
- **Mid-session course correction without giving the answer.** *"What we can do, change a little bit here, is to maybe at some point you pause a little bit and roll the ball back to the interviewer to see, to collect the signals from them, to see whether that will be the most important thing they want."* The intervention is procedural (slow down, check in), not technical (here's the answer).
- **Naming the missing dimension rather than the missing detail.** *"I think we may still miss something here. It's about the trade-off discussions… for the staff flow trade-off discussion, is mandatory."* The interviewer flags the *category* of gap, not the specific trade-off.
- **Closing the loop on candidate self-assessment.** The post-mock feedback solicits candidate reflection first, then layers in interviewer observations.

The published archive of mock interviews on interviewing.io includes Alex Golec (ex-Reddit/Patreon, ex-Google) breaking down a mock SD interview turn-by-turn on the platform's YouTube channel; the breakdowns model "what I was thinking" against "what the candidate said" — a structured commentary format that translates cleanly into the coach's `/mock-loop` debrief output.

### Socratic patterns for system design specifically

System design's evaluation surface is fundamentally different from coding or math tutoring, where Khanmigo's design — *step-by-step guidance through a known-correct path* — works. SD has no canonical correct path. Two patterns work:

1. **Constraint-injection over hint-injection.** Instead of "have you considered fan-out on write?", the coach says "imagine 100x writes." Constraints force the candidate to surface the trade-off themselves; hints reveal the answer.
2. **The "drive vs wait" check.** Per Evan King: *"More junior candidates can expect the interviewer to jump in here and point out places where the design could be improved. More senior candidates should be able to identify these places themselves and lead the discussion."* The coach should wait — silently — for a calibrated interval before intervening. Premature interjection collapses the level signal.

Compare with Hello Interview's most-cited grading principle on requirements: *"Feedback about requirements gathering and prioritization is the #1 most common feedback given to mid-level mock interview participants on Hello Interview and stays in the top 3 even for Senior+ engineers."* This implies the coach's earliest intervention point should always be requirements, even before architecture — because that's where the highest-frequency error lives.

### Scaffolding for "watch me design" via cognitive apprenticeship

Collins, Brown, and Newman (1989; expanded in Collins, Brown, and Holum 1991, *American Educator* 15(3): 6–11, 38–46) identify six sequential moves: **modeling, coaching, scaffolding, articulation, reflection, exploration**, with progressive fading of support. For workflow #2 (the coach plays interviewee), the literal expert externalization should:

- **Use two voices.** Collins and Smith (1982) describe a reading teacher who *"read aloud in one voice, while verbalizing her thought processes in another voice."* Translated to SD: the coach outputs **(a) what it says to the interviewer** and **(b) what it is thinking but not saying**, in clearly separated text blocks. This is the worked-example pattern (Sweller, Renkl) executed correctly — show the reasoning, not just the answer.
- **Use abstracted replay.** Per Collins & Brown (1988), the post-session move is *"a recapitulation of some process designed to focus students' attention on the critical decisions or actions."* The coach should not summarize what it did; it should highlight the 2–3 decisions that mattered.
- **Fade scaffolding deliberately.** Successive `/practice-problem` invocations on related prompts should narrate less, prompting the learner to articulate more. The coach commits to file a `scaffolding_level` that decreases over a per-archetype mastery threshold.

### LLM-tutor anti-patterns

The published failure modes are concrete and they cluster:

- **Sycophancy collapse.** "Interaction Context Often Increases Sycophancy in LLMs" (arXiv:2509.12517) shows that memory features, far from helping, *increase* sycophancy because the model treats prior context as endorsement. The widely-shared 300-hour ChatGPT conversation that ended with a user convinced he had discovered a mathematical breakthrough is the cautionary tale. **Mitigation:** the coach must re-derive its evaluative posture each session from a stable rubric file, not from accumulated transcript.
- **Persona drift.** Lu, Gallagher, Michala, Fish & Lindsey (Jan 2026), "The Assistant Axis: Situating and Stabilizing the Default Persona of Language Models" (arXiv:2601.10387, MATS/Anthropic/Oxford), demonstrates persona drift via activation-space projections in Gemma 2 27B, Qwen 3 32B, and Llama 3.3 70B. Persona drift is mechanism-level (attention decay over long context); it cannot be fixed by prompting alone. **Mitigation:** for a 60-minute mock, refresh the persona spec every N turns by re-reading the persona file (this is exactly what file-backed state buys you over a long context window).
- **Premature reveal / over-praise / "great question!" filler.** Khanmigo's published improvements all involve removing these. The Khan Academy product-testing post (Oct 2025 – Apr 2026): *"When Khanmigo has access to structured signals from a student's Khan Academy learning record, such as their recent performance patterns and skill gaps, it produces measurably better tutoring."* They report a six-percentage-point improvement when grounded in structured per-student state vs free-form chat memory. **Mitigation:** the coach commits structured signals (per-pattern confidence, mistake categories, deep-dive depth), not transcripts, as the durable per-user record.
- **The "ends every response with a question" anti-pattern.** Duolingo Max's Lily was critiqued as *"more like an interrogation than a friendly conversation"* — the coach should explicitly suppress trailing questions in the watch-me-design mode (modeling phase) and emit them only in the coaching phase. This is a turn-type discipline.
- **Looping on resolved points and hallucinating new requirements** (the SD-specific failure pair from the "Code Grey" Medium critique of AI mock interviewers). Both are addressable by committing a `resolved_topics` list and a `frozen_requirements` block at the top of the working file.

### Mock-interviewer persona calibration

Real interviewers vary widely. The trade-off is documented:

- **A learning-optimal persona** is collaborative, asks clarifying questions, surfaces gaps explicitly, and gives mid-session course corrections.
- **A realism-optimal persona** is silent, ambiguous, occasionally adversarial — *"sometimes you'll have an interviewer who is cold or not very collaborative. Dealing with these interviewers requires practice"* (interviewing.io guide). At staff level, *"the candidate is often seen as a peer in the conversation, contributing significantly to the discussion with insights that may even enlighten the interviewer"* (Evan King).

The synthesized resolution: the coach exposes an explicit `interviewer_persona` parameter (collaborative / neutral / adversarial / silent) and `/mock-loop` defaults to neutral, with the user opting in to adversarial after 3+ sessions on the same archetype. This matches Hello Interview's directness-level design and is borrowed cleanly.

### Spaced repetition / interleaving / mastery learning for procedural+conceptual knowledge

The 2024 Centre for Mathematical Cognition (Loughborough) review concluded: *"students might only benefit from spaced learning when learning conceptual knowledge but not when learning procedural knowledge."* Interleaving has stronger procedural support — **Brunmair & Richter (2019), "Similarity matters: A meta-analysis of interleaved learning and its moderators," Psychological Bulletin 145(11):1029–1052: based on 59 studies with 238 effect sizes, overall Hedges' g = 0.42, with mathematical tasks at g = 0.34 (small positive effect).** Bjork's "desirable difficulties" framework predicts interleaving wins on discrimination tasks (which pattern matches which problem) more than on execution tasks (how to apply a pattern). SD interview prep is *primarily* a discrimination task ("is this a fan-out problem or a CDC problem?"), so interleaving — mixing archetypes in the same session — should dominate blocked practice.

**Concrete recommendation:** the 5-phase study plan should not block by archetype (Phase 1 = caching, Phase 2 = sharding). It should block by *level* (Phase 1 = L4 problems across archetypes, Phase 2 = L5 problems across archetypes, etc.), with interleaved drills within each phase.

### Learner-state-driven recommendations

Khan Academy's reported six-percentage-point gain from per-student "structured signals" is the cleanest external evidence. The signals worth persisting per session, ranked:

1. **Mistake category, not mistake count.** "Used eventual consistency where strong was required" is a category; "got it wrong" is not. Categories transfer across problems; counts do not.
2. **Time-to-first-API-design.** A latent signal of how long the candidate spent on requirements vs jumping to architecture. Hello Interview lists requirements as the #1 mid-level failure.
3. **Deep-dive depth per pattern.** How many follow-up "why" turns before the candidate hit bedrock. Cumulative across sessions.
4. **Drive-vs-wait ratio.** Who initiated the last 10 turns — coach or learner. A learner ratio below 0.5 at L5 prep is a flag.
5. **Per-pattern confidence (self-reported and observed).** Self-report alone is unreliable (Dunning-Kruger); calibrated against observed performance, the delta is the metacognition signal.

---

## Area 2 — Content Depth The Guide May Be Missing

### AI / ML lab interview prompts

Anthropic, OpenAI, and DeepMind interviews have moved system design toward AI-infrastructure framing while keeping the underlying problem in classic distributed systems. Per Exponent's 2026 Anthropic guide and corroborating accounts:

- **Format:** 50–55 minute round, slightly longer than the standard 45. Exponent: *"5 minutes on requirements… 35–40 on core design and deep dives… 5–10 on trade-offs."*
- **Frequently reported prompts:** designing an inference-batching API for GPU clusters with priority queues and streaming; distributed search over a billion documents at millions of QPS; KV-cache management at scale; safety/moderation pipelines layered with inference; data pipelines for RLHF logging and compliance.
- **Distinctive constraint:** safety and cost are first-class SLIs. Anthropic candidates report *"a system that is fast but produces harmful outputs is considered broken. This applies even when traditional availability metrics are within acceptable ranges."*
- **Distinctive style:** *"problems are often novel. The interviewer may not have a single correct answer in mind. They want to see how you think through an unsolved problem."*

**Patterns missing from the guide that this category demands:**

- **Continuous batching** (vLLM-style); contrast with static batching for throughput vs latency.
- **PagedAttention / KV-cache management** at the request level (vLLM: "PageAttention solves memory fragmentation in the KV cache for multi-billion parameter models").
- **Prefix caching as an architectural primitive.** Anthropic publicly documents 90% cost reduction and up to 85% latency reduction on long prompts via prefix caching; OpenAI documents 50% automatic discount on cached tokens. Break-even is 1.4 reads per cached prefix (Anthropic at $0.30/M cached vs $3.00/M fresh).
- **Speculative decoding.**
- **Model-router gateways** routing by query complexity, length, or cost class (GPT-5 vs Claude Sonnet vs Mixtral vs local LLaMA).
- **Distributed training:** FSDP, Megatron-LM, DeepSpeed, pipeline vs tensor vs data parallelism, all-reduce as the dominant collective.
- **Mixture-of-Experts** routing and expert parallelism.
- **Semantic caching** at the application level for high-similarity queries. Introl-cited research notes that 31% of LLM queries exhibit semantic similarity to previous requests.
- **Eval pipelines as production systems:** golden-dataset construction, regression detection, LLM-as-judge in the deployment loop.
- **Safety pipelines** with parallel rule-based and ML classifiers (rule-based <1ms, ML 10s of ms), running concurrently with inference rather than serially.

A standalone "AI Infrastructure" archetype is overdue.

### Recent infra patterns under-treated

- **ScyllaDB and Cassandra-family migrations.** Latency and operational story differ from DynamoDB; partition-key design has 3+ documented levels of nuance per Hello Interview's senior-bar callouts.
- **CockroachDB / TiDB / Spanner-family** consistency models: serializable vs externally-consistent vs causal; latency cost of TrueTime-style protocols.
- **Lakehouse architectures (Iceberg / Delta / Hudi).** Table-format choice drives interview discussions of schema evolution, time travel, and ACID-on-object-storage trade-offs.
- **ClickHouse for real-time OLAP** — commonly contrasted with Druid and Pinot.
- **Vector DB internals.** HNSW vs IVF-PQ trade-offs, recall-vs-latency, hybrid retrieval (vector + BM25 + reranker).
- **Service mesh failure modes** (Istio, Linkerd): mTLS hot-path latency, sidecar memory cost, control-plane split-brain.
- **Wasm at the edge** (Cloudflare Workers, Fastly Compute) — distinct cold-start, sandbox, and stateful-store profiles vs Lambda.

### Front-end / client system design (entirely missing)

Meta, Airbnb, Google, Atlassian, Uber, and Apple all ask front-end system design. The canonical framework is GreatFrontEnd's **RADIO** (Requirements, Architecture, Data model, Interface, Optimization). Common prompts: design an image carousel; autocomplete with key navigation; an email client (Outlook); a collaborative spreadsheet (Sheets); a chat client (Slack/Messenger); Figma's design tool; Spotify-style audio streaming with offline. Patterns: virtualized lists, optimistic UI with rollback, CRDT vs OT for collaboration, IndexedDB/local storage strategies, service workers for offline, WebSocket connection management, code-splitting and lazy loading, Backbone-style stores, observer patterns. A separate `client-archetype` is required.

### LLD / API design at L4/L5

The guide treats these as out-of-scope but they appear in real loops. Anthropic explicitly publishes a separate LLD round ("often with thread-safety and incremental complexity requirements"). Classic prompts: parking lot, elevator, payment processor (Stripe-style idempotency), LRU cache with concurrent access. These bleed into system design at the API boundary and should be covered as a thin archetype.

### Meta AI-Enabled Coding Round (Oct 2025) and adjacent changes

CONFIRMED via multiple primary accounts (Hello Interview blog by Stefan Mai; Prepfully guide; interviewing.io blog; Coditioning; first-person Medium account by Fahim ul Haq; HR Grapevine reporting Meta's internal message *"a new type of coding interview in which candidates have access to an AI assistant. This is more representative of the developer environment that our future employees will work in, and also makes LLM-based cheating less effective"*).

Key facts to commit to the guide:

- **Format:** 60 minutes, CoderPad three-panel (file explorer / editor / AI chat + problem), one thematic problem with multiple checkpoints.
- **Languages:** Python, Java, C++, C#, Kotlin, TypeScript (varies).
- **Models available (confirmed in real interviews):** GPT-4o mini, Claude 3.5 Haiku, Llama 4 Maverick; Hello Interview notes Claude models tend to be a solid default and "GPT-5 has been reported as too slow."
- **Evaluation criteria (internal Meta source via Hello Interview):** *"Should use AI, but need to show you understand the code. Explain the output. Test before using. Don't prompt your way out of it."*
- **Bar:** "Clearing at least 3 checkpoints appears to be the minimum threshold… aim to clear 4 or more if you can" (Coditioning).
- **System design is unchanged.** It remains AI-free at all major labs as of May 2026.

This is the moment to set policy in the coach: it should refuse to act as a coding pair-programmer for live SD interviews and should make this explicit in workflow #2's opening.

---

## Area 3 — Assessment Methodology

### Calibration anchors per level

The canonical per-level exemplars in the public domain are Hello Interview's "Bar for X" callouts.

**Stefan Mai, "5 Keys to Staff-Level System Design Interviews"** (hellointerview.com/blog/staff-level-system-design):

The "operate vs design" distinction, with a verbatim mini-transcript:

> *"Good staff-level engineers design simple systems that solve problems elegantly. A very common response to a challenge is 'let me see if [a more sophisticated approach] is actually required' whereas a senior engineer will try to solve the complex flavor.*
> *Interviewer: You need location search over a set of places.*
> *Staff Candidate: How many places are we talking about here?*
> *Interviewer: 10,000*
> *Staff Candidate: Are they updated frequently?*
> *Interviewer: No, not really.*
> *Staff Candidate: Great, let's sync periodically and search in memory."*

The decisiveness boundary:

> *"'I'm going to go with Postgres here because I need transactions across tables and durability. I don't think this is going to be a scaling bottleneck but we can come back to this later if needed.' is a great response… a. Make the decision. Don't just outline options. b. Justify your decisions, but don't attempt to make an airtight case."*

The option-listing failure mode:

> *"One candidate I worked with was very sharp but kept falling into this trap of outlining options for major decisions. Each response had a list of 2-4 different options for me to choose. I had to respond to them with 'Well, which one would you choose?'. How can I know whether they'll be a good fit for the role if I'm not actually seeing their decisions?"*

**Evan King, "The System Design Interview: What is Expected at Each Level"** (hellointerview.com/blog/the-system-design-interview-what-is-expected-at-each-level):

Mid-level breadth: *"If you introduce an API gateway, for example, expect that I may ask you what it does and why it's needed in your design."*

Senior breadth (presumption of fundamentals): *"I start the interview with the presumption that candidates have a thorough understanding of the fundamentals… when you introduce technical elements like a load balancer or an API gateway, I won't probe into their basic functionalities unless you expose a lack of understanding."*

Staff+ depth (Temporal.io worked example): *"a candidate might introduce Temporal.io as a solution to address specific challenges like distributed system orchestration or workflow management… If this is a technology I'm less acquainted with, a great staff candidate would skillfully elucidate its functionalities… effectively broadening my understanding."*

Senior DynamoDB depth example: *"if you choose to discuss DynamoDB based on your experience, I expect an explanation of your specific choices in its configuration — why a certain partition key and sort key were chosen… The inclusion of advanced features like DynamoDB Accelerator (DAX) could be a part of this discussion."*

The drive-vs-wait passage: *"More junior candidates can expect the interviewer to jump in here and point out places where the design could be improved. More senior candidates should be able to identify these places themselves and lead the discussion."*

Staff+ proactiveness: *"These candidates should not only identify unique challenges and limitations but also propose innovative solutions and approaches. They are expected to lead almost the entire interview… At this level, the candidate is often seen as a peer in the conversation, contributing significantly to the discussion with insights that may even enlighten the interviewer."*

**Per-problem bars, quotable:**

YouTube Top-K Videos (`/learn/system-design/problem-breakdowns/top-k`):

> *"For this question, a Mid-Level candidate will be able to come up with an end-to-end solution that probably isn't optimal. They'll have some insights into pinch points of the system and be able to solve some of them. They'll have familiarity with relevant technologies, but will make some mistakes."*
> *"[Senior] expectations shift towards more in-depth knowledge — about 60% breadth and 40% depth."*
> *"[Staff+] I'm looking for about 40% breadth and 60% depth in your understanding."*
> *"At senior+ levels, interviewers are looking for you to simplify the problem not just throw hardware at it!"*

Dropbox-style file storage:

> *"E5 candidates are expected to quickly go through the initial high-level design so that they can spend time discussing, in detail, how to handle uploading large files… I expect them to be more proactive here than mid-level candidates."*

LeetCode-style coding platform:

> *"In a mid-level interview, it is entirely reasonable for the interviewer to lead most of the deep dives. However, in senior and staff+ interviews, the expected level of initiative and responsibility from the candidate rises."*

Requirements gathering (hellointerview.com/blog/system-design-requirements):

> *"Feedback about requirements gathering and prioritization is the #1 most common feedback given to mid-level mock interview participants on Hello Interview and stays in the top 3 even for Senior+ engineers."*

> *"A common mistake is to be overbroad ('the system should be highly available!' or 'the system should be highly consistent!') when the reality is that availability and consistency usually imply tradeoffs which can be made differently for different parts of the system. 'Ordering needs to be consistent to avoid double orders', 'Search can be eventually consistent within 30s'."*

**DesignGurus Substack** ("System Design Interview Expectations by Company and Level") — useful but single-author, more illustrative than primary:

> *"What earns a 'strong hire' at L5: You proactively identify the hardest part of the system. 'The interesting challenge here is the feed generation. Let me walk through the trade-offs between fan-out on write and fan-out on read.'… You name specific technologies and explain why: 'I chose Cassandra over DynamoDB because our write pattern is append-heavy and we need tunable consistency per query.'"*

> *"What earns a 'strong hire' at L6: You drive the conversation. You do not wait for the interviewer to ask follow-up questions. You proactively say: 'Before I move on, let me address the failure scenario for this component.' You discuss operational concerns: monitoring, alerting, deployment strategy, rollback plan."*

**Counterpoint (REPORTED, single Blind thread, May 2025):** *"I feel like with sufficient studying (or memorizing solutions), a mid-level could easily surpass this bar and maybe even with a lot of studying, they could pass the senior or even staff bar for a system design interview… Is Hello Interview full of shit or is the bar kinda low?"* This is a useful caveat that Hello Interview's exemplars may be calibrated to their grading bar, which is one bar among many.

### Practical rubric weighting and pivotal moments

The published "~30% deep dive" weight is real but misleading. Per the interviewing.io transcript and Stefan Mai's commentary, interviewers actually decide on 1–2 *pivotal moments* per interview — usually a deep-dive technical choice and a drive-vs-wait moment. The coach should commit a `pivotal_moments` log: an explicit per-session list of the 1–2 turns that drove the grade, rather than reporting a weighted aggregate.

### LLM-as-judge for open-ended technical answers

**Zheng et al. (2023), "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena" (UC Berkeley/Stanford/CMU, arXiv:2306.05685; NeurIPS 2023 Datasets and Benchmarks)**, established that *"strong LLM judges like GPT-4 can match both controlled and crowdsourced human preferences well, achieving over 80% agreement, the same level of agreement between humans."* But the headline number hides three known failure modes that all apply to SD coaching:

- **Position bias.** When given two answers, GPT-4 favors the first by 50–60% before correction. Mitigation: always evaluate in both orders and require agreement.
- **Verbosity bias.** Longer answers are systematically preferred. Mitigation: token-count normalization in the rubric.
- **Self-enhancement bias.** Judges prefer outputs that look like their own. Mitigation: use a different model family for judging than for generation when possible; structured rubrics with reference answers.
- **Reference-guided method.** Per Zheng et al. Table 4, reference-guided judging reduced failure rate from 70% to 15% on math reasoning tasks. *Translation for SD:* the coach must always have a per-problem reference answer (Hello Interview's "Bar for X" callouts are exactly this) before grading. Free-form 1–10 scoring without a reference is the failure mode.
- **Silent shortcut bias** ("The Silent Judge: Unacknowledged Shortcut Bias in LLM-as-a-Judge," arXiv:2509.26072): *"Cue acknowledgment is rare: justifications almost never reference the injected cues, instead rationalizing decisions in terms of content qualities."* The judge confabulates content-based justifications even when biased by a non-content cue. Mitigation: binary or 3-point ordinal scales (per Arize: *"binary outputs tend to produce more stable and reliable evaluations than more subtle numeric scoring"*), not free-form 1–10.

Agreement rates with human graders on SD specifically have not been published. The coach's LLM-as-judge should be treated as one signal, not the verdict; the per-session output should distinguish "coach assessment" from "graded transcript for human review."

### Self-assessment anti-patterns

Learners reviewing their own designs exhibit Dunning-Kruger asymmetry: low-skill participants over-estimate, high-skill under-estimate. The corrective is calibration drills — ask the learner to predict their score *before* the coach grades, then commit the prediction-vs-score delta to file. After 5+ sessions the delta itself becomes a signal (a learner whose predictions consistently exceed their scores by 1+ rubric points is over-confident; the opposite under-confident). The coach should adjust its directness level accordingly.

### Split-panel patterns

Common SD-specific disagreement patterns reported across interviewing.io and Hello Interview blogs: (a) whether the candidate's chosen depth area was the "right" one (interviewers project their own taste); (b) whether silence indicates thinking or stuckness; (c) whether named-technology choices are credit-worthy specificity or jargon bluff. The dimensions that grade most reliably (low panel disagreement) are: requirements specificity, decision-making decisiveness, named failure-mode identification. The dimensions that grade least reliably: depth-area choice, communication style. The coach should weight reliably-graded dimensions higher in its scoring.

---

## Area 4 — Product / UX Patterns for AI Coaches

### Hello Interview AI — flagship teardown

**What it does:** Step-based guided practice on 44 SD/LLD problems plus AI-Enabled Coding and Behavioral. Each problem walks through Requirements → Core Entities → API → HLD → Deep Dives with personalized AI feedback at each step. "Ask Tutor" inline help. Voice-input option (user testimonial: *"Having the voice option is great, it mimics an interview pretty closely since it forces you to practice verbal communication"*).

**State it tracks:** per-step scoring, per-problem completion, full-track completion. Reddit and Blind users report it does NOT track cross-problem patterns or weakness clustering — each problem is graded in isolation. Premium subscription is $63/year (Techgrind 2026 review).

**Strengths users report:** "tuned by FAANG interviewers" — the grading aligns with what users see in real Meta/Google loops; the step-decomposition is widely cited as the platform's signature value; the answer keys ("Bar for X" callouts) are uniquely concrete.

**Weaknesses users report (Techgrind 2026, Blind, Reddit r/cscareerquestions):**
- *"System design content is surface-level for L5+. Lacks depth on consensus, failure modes, and operational trade-offs."*
- *"Coach auto-matching — no ability to select your interviewer by specialty."*
- AI mocks deprecated; humans are the live-mock surface.
- Per-step grading rewards completion of the framework, not creativity off-path.

**Why their AI Mock was deprecated** (hellointerview.com/mock/ai now shows "Deprecated"): this is the single most important industry signal in 2026. The platform with the most data and the best content gave up on open-ended AI mock interviews at SD difficulty. The lesson: open-ended `/mock-loop` is hard; step-anchored `/practice-problem` is tractable.

### Exponent AI Mock — teardown

**What it does:** AI-driven mocks across SWE, EM, PM, and TPM tracks with post-session scoring and recording. SD coverage is one of many.

**Strengths:** breadth, low price, integration with company-specific guides (Anthropic, OpenAI, Meta, etc. all have dedicated 2026 guides).

**Weaknesses:** SD prompts are pulled from a question bank; no level-branching; no persistent state across sessions; grading is generic. Reddit-reported pattern: useful for first-time SD candidates, thin for L5+ prep.

### Pramp / interviewing.io / Karat — human-mediated patterns to mimic

These services enforce coaching practices that an AI version can borrow:

- **Anonymity by default** (interviewing.io's "anonymous mock interviews") — reduces interviewer bias and candidate self-presentation effort. The coach can offer a parallel "anonymous mode" that strips per-user state.
- **Time-boxed segments with explicit transition language.** Pramp interviewers are coached to say "let's move into deep dives now" at a fixed time. The coach should emit explicit phase transitions.
- **Post-session bidirectional feedback** (Pramp's two-way grading). The coach should ask the learner to grade its grading at the end of each session, and commit the delta.
- **No-replay attestation.** Karat and interviewing.io explicitly disclaim live-interview use; their candidates sign no-replay terms. The coach should mirror this as a session-start checkbox.

### Custom GPTs / Claude Projects with traction

Per the GPT-store catalog enumerated in Area 0: none has visible install counts (OpenAI removed those); none has multi-mode coverage; the most-grounded ("System Design Interview – An Insider's Guide") is anchored on Alex Xu's book. No Claude Project specifically for SD coaching has been documented in Anthropic's showcase or community surveys.

### Sustained role-play across 60+ minute sessions

The empirical literature on persona drift converges on three findings:

- **Drift is mechanism-level, not prompt-level.** Lu et al. ("The Assistant Axis," arXiv:2601.10387, Jan 2026, MATS/Anthropic/Oxford) demonstrate drift via activation-space projections in Gemma 2 27B, Qwen 3 32B, and Llama 3.3 70B. Alignment-drift paper on CEFR-prompted LLMs for Spanish tutoring (arXiv:2505.08351): *"system prompting can be used to constrain model outputs, prompting alone is too brittle for sustained, long-term interactional contexts — a phenomenon we term alignment drift."*
- **Persona collapse under epistemic pressure** has been characterized across 7 SOTA models (HuggingFace Aug 2025): *"recursive contradiction techniques, epistemic pressure protocols, and ontological inversion methods… these failures occur without adversarial prompting or jailbreaking attempts, instead emerging from natural conversational pressure."* In a mock SD interview where the user pushes back on the coach's feedback, this is the failure mode.
- **Memory features increase sycophancy** (arXiv:2509.12517), not decrease. The naïve fix — "give the coach more context" — backfires.

**Mitigations that have been published:**
- Refresh the persona spec by re-reading the persona file every ~10 turns or at every phase transition.
- Externalize the rubric and reference answer to a file the coach re-reads, not the conversation transcript.
- Re-derive evaluative posture from the rubric per session, not from accumulated history.

### State management for stateless models with file-backed memory

The agentic-coding tools (Claude Code, Cursor, Aider) have converged on three practices:

- **CLAUDE.md / .cursorrules at the top of the session** (loaded once, ~5KB max). For the coach: the system rubric and the user's `profile.md` belong here.
- **On-demand retrieval of past transcripts.** Cursor and Aider both retrieve diff-context, not full history. For the coach: retrieve only the per-pattern confidence scores and the last 2–3 mistake categories, not full session transcripts. The Khan Academy six-percentage-point gain came from *structured signals*, not transcripts.
- **Write-back as commits to markdown.** The coach commits at session end: scores, mistake categories, pivotal moments, recommended next problem. Transcripts go in an archive folder, not the active context.

**Retrieval anti-pattern:** loading a previous full transcript into the next session's context. This actively harms — it primes sycophancy (memory→agreement), it dilutes the rubric, and it can mislead the coach if the previous transcript was poorly graded.

### Detecting hand-waving / bluffing

The published literature on this is thin but the linguistic signals are well-known to interviewers:

- **Passive voice + unnamed components.** "It would be handled by a queue" vs "I'd use SQS with FIFO ordering because…"
- **Switching from numbers to adjectives mid-design.** Early-session "10K writes per second" becoming late-session "highly scalable."
- **Pattern-name dropping without operationalization.** "We'd use the saga pattern" with no rollback semantics specified.
- **Hedging escalation.** Confidence in lexical hedges ("maybe", "probably", "I guess") rising as the topic gets harder.
- **Recursive abstraction.** When pushed, the candidate goes one layer more abstract instead of one layer more concrete.

The coach can score these as a `bluff_flags` array per session and use them as deep-dive prompts: *"You said 'we'd just use a cache' — which cache, what eviction policy, what consistency model?"*

---

## Area 5 — Cheating Prevention and Honest-Use Design

### Detection feasibility — the honest answer

A stateless LLM coach cannot reliably distinguish "user practicing" from "user actively interviewing." The signals available are weak and the priors are unfavorable:

- **Time of day** correlates with nothing useful — interviews and practice both occur in business hours.
- **Session length** matters only at extremes — a 45-minute session is the modal length for both.
- **Paste vs typed input** is a moderate signal: a long pasted prompt mid-session is more likely real-interview text than a slowly typed problem-restatement. But pasting prompts is also normal practice behavior.
- **Prompt phrasing.** "Design X" vs "Let me design X with you" — the latter is a practice marker. But anyone reading this report will switch their phrasing within a session.
- **Prior session history** is the strongest single signal: a brand-new user starting with no warm-up on a real Meta-tagged prompt is suspicious; a user with 20 sessions of build-up across the archetypes is almost certainly practicing.
- **Presence of "the interviewer wants…" / "they're asking me to…" / "I have 45 minutes" language** is a strong tell. So is "the interviewer is silent right now" or copy-pasted timestamps.
- **Deadline pressure markers** — "they're waiting on me" — should trigger an immediate refusal.
- **Screen / audio context** is not available in a Claude Code skill and pursuing it crosses a serious privacy line.

**The adjacent industry precedents are unambiguous about FPR/FNR trade-offs:**

- **Turnitin AI detector.** Originally claimed <1% document-level false positive rate. Per the Washington Post investigation (reported via NSF TRAILS): *"Turnitin identified over half of our 16 samples at least partly incorrectly, including saying one student's completely human-written essay was written partly with AI."* Turnitin simultaneously revised its own false-positive claim from <1% at the document level to 4% at the sentence level. Documented backlash includes Vanderbilt disabling the feature, U.S. universities flagging dozens of international students via false positives later proven to be ML bias on accented English, and Turnitin publicly raising confidence thresholds. With 75,000 papers per institution-year, even 1% FPR yields ~750 wrongful accusations. *Translation:* a coach detector strict enough to catch real cheaters will block legitimate intense practice at unacceptable rates.
- **Proctorio, ProctorU, Examity, Honorlock, Respondus.** Multiple lawsuits, EPIC complaint (Dec 2020) against the five largest proctoring vendors for "unfair and deceptive trade practices" tied to opaque AI. UBC Senate restricted Proctorio after finding facial detection failed on Black faces 57% of the time in independent testing. ProctorU was forced to stop selling fully-automated proctoring in May 2021. *Translation:* automated cheat-detection on humans has been a reputational disaster across the academic sector.
- **Codeforces and ICPC.** Public admission that *"as on the first and second phase there are thousands of competitors, it was really hard to do cheating detection, and couldn't be done by the small team of volunteers."* The active community proposal (CFAC) combines NLP similarity, timing anomalies, and submission patterns but is offline (post-contest) and probabilistic. Competitive programming has effectively conceded that *AI-assisted cheating cannot be prevented in online contests at scale*; their adaptation is to redesign tasks and rules, not to detect.

**The honest framing:** detection in the coach is not feasible at useful precision. Pretending otherwise produces the Proctorio-Turnitin failure pattern: false accusations against legitimate users, real cheaters undetected, reputational damage.

### Design-level friction (where the leverage is)

The five highest-effect design-level patterns, ranked:

1. **Refusal as a feature.** `/practice-problem` does not produce a complete end-to-end design until the user has typed their own functional requirements, non-functional requirements, and a rough first pass. This is the single most effective pattern: it reframes the coach from "answer machine" to "thinking partner," it forces the user to do the cognitive work that practice is for, and it makes the coach useless as a real-time cheat aid because the user has no time to type that material during a real interview. Khanmigo's published improvements all moved in this direction (require user to show their step before guidance).

2. **Forced narration before architecture.** The coach asks "what's your first instinct?" before producing any structure. The user must articulate; the coach reflects. Cognitive apprenticeship's articulation step, deployed as a gating constraint.

3. **Mandatory slow drip.** No complete design in fewer than N (e.g., 6) turns; per-turn scope is bounded ("one component per turn"). A real interview's pace is faster; the deliberate mismatch makes copy-paste-to-interviewer mechanically slower than just doing the interview.

4. **Deliberate sub-optimality injection.** When the coach plays interviewee (workflow #2), it produces a competent-but-not-best design with an explicit "a stronger answer would also consider X — what would you add?" callout. This is also good pedagogy (it forces the learner into the critique role, the highest level of Bloom's taxonomy) and it cripples cheat-aid utility (a real interviewer would catch the sub-optimal answer and downlevel the candidate).

5. **Persona quirks that would be conspicuous if read aloud.** The coach's narration uses signature phrasing ("let me reason about this in two voices") that a candidate reading it to an interviewer would expose immediately. Borrowed from the literature on watermarking; effective as a tripwire.

A non-pattern to avoid: refusal to produce *any* single end-to-end artifact. This is over-paternalistic and damages study utility. Spread the output across turns; do not refuse the output.

### Honor-system patterns and what they actually achieve

- **Khanmigo's framing** — every session opens with "I'll guide you, not give you answers" and the system enforces step-revealing. Khan Academy's published efficacy data: a six-percentage-point gain when grounded in structured per-student state, plus qualitative reports that students treat Khanmigo as a tutor rather than an answer source.
- **Codecademy** uses attestation gates at the start of paid courses; effect sizes are not published but engagement metrics improved after the gate's introduction.
- **LeetCode's contest mode** is a soft-honor system (it disables AI helpers for the user during contest minutes) plus a hard ToS clause. Effect is unknown but the design pattern — *time-bounded escalation of friction* — is borrowable.

The honest empirical literature on honor systems (Donald McCabe's three decades of academic-integrity research, summarized in International Center for Academic Integrity reports): honor codes reduce cheating by ~25–50% in their domain, mostly through changing norms rather than detection. The implication for the coach: a clear, short, opt-in attestation at first run ("I will not use this during a live interview; I understand the coach will not produce a complete design without my input") plausibly captures most of the available friction.

### The Meta AI-Enabled shift and what it doesn't change

Meta's Oct 2025 coding-round shift is a one-way door for coding interviews, not design. Per Hello Interview's first-person reporting, the change was explicitly motivated by Meta wanting interviews to look like real work *and* to reduce LLM-based cheating effectiveness — the internal message reads *"makes LLM-based cheating less effective."* But system design rounds remain AI-free at Meta, Google, Amazon, Anthropic, OpenAI, and DeepMind as of May 2026. No public signal from any of these companies suggests SD will follow.

**Implication for the coach:** the asymmetry should be made explicit at session start. The coach can be permissive about coding-round prep ("Meta now expects you to use AI on coding") while staying strict about SD-round prep ("SD is still AI-free at every major lab"). The asymmetry also tells the user that SD coaching is asymptotically valuable: even if all coding becomes AI-paired, SD reasoning is the differentiator that survives.

### Human-coach service stances

Pramp, interviewing.io, Karat, and Hello Interview all enforce three norms that translate cleanly:

- **No live use.** Explicit in ToS, explicit at session start. Karat's anti-cheat is the strongest — they use live human proctors plus their own platform.
- **No recording for redistribution.** The coach's outputs are markdown the user owns; this is not a vector for the coach to police, but the session-start framing can mention it.
- **Reciprocity.** Pramp's pairing model where graders are also gradees produces incidental honor effects. The coach has no equivalent, but it can mimic the pattern by asking the user to grade the coach's grading — the bidirectionality is structurally similar.

### Refusal as a feature, expanded

The single highest-impact design choice in this area, and worth articulating explicitly:

A `/practice-problem` that always starts by asking the user to articulate (a) functional requirements, (b) non-functional requirements with specific numbers, and (c) a first-pass component sketch — and that refuses to produce a complete design until these exist as user input — accomplishes four things simultaneously:

1. It enforces the #1 published high-frequency failure mode mitigation (Hello Interview: requirements gathering is the most common mistake).
2. It executes Collins, Brown, Newman's articulation step (cognitive apprenticeship).
3. It cripples real-time cheat utility (the user has to type the requirements first; doing so during a live interview is mechanically slower than just doing the interview).
4. It changes the user's relationship to the coach from "vending machine" to "study partner."

This is the single most important design decision in the build.

### Honest framing of limits

What the coach cannot do and should stop trying:

- **Detect cheating in real time.** Don't build detection; build friction.
- **Be a stylometric tripwire.** Don't try to fingerprint the user; respect them.
- **Refuse "Meta is asking me to design X" prompts categorically.** This is over-paternalistic and the false-positive cost is high. Instead: refuse to produce a complete design without user input, regardless of how the prompt is phrased.
- **Watermark its outputs in ways that mark the user.** Category error; legal and ethical exposure outweighs the gain.

What it should do and tell the user:

- **State the asymmetry plainly:** coding interviews increasingly assume AI; SD does not.
- **Stake the contract at first run:** "I'm here to help you get better; I will not produce a complete design before you have."
- **Make the friction visible:** the user sees the slow-drip pattern and understands it's deliberate.

---

## Synthesis — Implications for the Coach Design

### The 10 highest-leverage design decisions

1. **Three workflows, three different state postures.** `/study-patterns` is the most stateful — per-pattern confidence, last-reviewed date, mistake categories. `/practice-problem` is the least — it should re-derive its persona and rubric from files each session, not from accumulated transcript, to avoid sycophancy collapse. `/mock-loop` is in between — it commits pivotal moments and scores but not the full transcript.

2. **Commit structured signals, not transcripts.** The Khan Academy six-percentage-point gain is the empirical anchor: structured per-user state (per-pattern confidence, mistake categories, drive-vs-wait ratio, pivotal moments) beats free-form transcript memory. Transcripts go in an archive folder; only structured signals enter the active context.

3. **Level branching inside the rubric, not at the session start.** Don't fork the coach into "L4 mode" / "L5 mode" / "L6 mode." Instead, the rubric file contains the published "Bar for X" quotes for each level, and the coach grades the same answer against multiple bars, reporting the level it actually demonstrated. This is also the honest way to talk about downleveling and upleveling.

4. **Reference-answer-grounded LLM-as-judge.** Per Zheng et al. (arXiv:2306.05685, Table 4), reference-guided judging reduced failure rate from 70% to 15%. The coach must have a per-problem reference answer (Hello Interview's "Bar for X" callouts are exactly this) before grading. Binary or 3-point ordinal scales, not free-form 1–10 (per Arize and corroborated by "Silent Judge" arXiv:2509.26072).

5. **Pivotal-moment logging, not weighted aggregates.** Commit 1–2 turns per session as the "this drove the grade" moments. Stefan Mai's "make the decision, don't outline options" is exactly this: it's a single turn that decides the interview.

6. **Two-voice modeling in `/practice-problem`.** Output (a) what the coach says aloud and (b) what it is thinking, clearly separated. Collins, Brown, Newman's articulation step executed correctly. Fade voice (b) as the learner's mastery on the archetype grows.

7. **Phase-anchored mock interviews, not open-ended.** Hello Interview deprecated their open-ended AI mocks. The replacement is finite-state machines over the design framework. The coach should run `/mock-loop` as a guided FSM with phase transitions visible ("we're at the deep-dive phase now"), not as an unstructured conversation.

8. **Persona refresh by re-reading the persona file every ~10 turns.** Lu et al. ("The Assistant Axis," arXiv:2601.10387) document mechanism-level drift; not fixable by prompting alone. File-backed re-reading is the mitigation.

9. **Interleaving in the 5-phase study plan.** Phase by *level*, not by archetype. Mix archetypes within each phase. Empirically grounded in Brunmair & Richter's (2019) meta-analysis (Hedges' g = 0.42 overall; g = 0.34 mathematical tasks).

10. **Refusal as a feature for `/practice-problem`.** The user must articulate functional/non-functional requirements and a first-pass sketch before the coach produces a complete design. The single highest-leverage pattern across both pedagogy and cheating-resistance.

### Five design-level principles for cheating-resistance

Principles only, per the user's clarification — no prompt snippets, no schema fragments:

1. **Friction over detection.** Build the coach so that real-time cheat utility is mechanically lower than just doing the interview. Detection is a documented industry failure mode (Turnitin, Proctorio, Codeforces); friction is the only durable lever.

2. **Mandatory user articulation before model production.** The coach never produces a complete artifact (full requirements, full HLD, full deep-dive) before the user has produced an attempt. This is pedagogically optimal (Collins-Brown-Newman articulation, cognitive apprenticeship) and incidentally cripples real-time cheat utility.

3. **Slow drip with bounded per-turn scope.** The coach produces one component, one deep-dive, one trade-off per turn — not an end-to-end design. The slower pace mismatches a real interview's tempo by design.

4. **Make sub-optimality and persona-quirks intentional, not bugs.** The coach in `/practice-problem` produces a competent-but-not-best answer with explicit "a stronger answer would consider X" callouts, and uses signature narrative phrasing. Both improve pedagogy and make verbatim use in a real interview self-incriminating.

5. **Honest framing of limits at session start.** State the asymmetry (coding allows AI, SD does not at every major lab); state the contract (the coach will not produce a complete design before the user has). Honor-system effects are real (McCabe; Khanmigo's framing) and capture a meaningful share of the available friction at zero false-positive cost.

---

## Recommendations

**Staged build order:**

1. **Week 1–2: State schema and reference answers.** Define the state schema (per-pattern confidence, mistake categories, pivotal-moment log, drive-vs-wait ratio, prediction-vs-score delta). Write per-problem reference answers for the top 20 problems by extracting and adapting from Hello Interview's "Bar for X" content. This is the highest-leverage week — without reference answers the LLM-as-judge will fail predictably.
2. **Week 3: Ship `/practice-problem` with refusal-as-a-feature gating and two-voice modeling.** Test for sycophancy collapse over 60-minute sessions with adversarial-pushback fixtures.
3. **Week 4: Ship `/study-patterns` with interleaved drills** organized by level, not by archetype. Add the AI Infrastructure archetype and the front-end client archetype.
4. **Week 5: Ship `/mock-loop` as a phase-anchored FSM, not open-ended.** Add the persona-refresh mechanism (re-read persona file every 10 turns or at every phase transition).
5. **Week 6: Add bidirectional grading.** User grades the coach's grading per session; commit deltas; calibrate.

**Benchmarks and thresholds that would change the recommendations:**

- If a published LLM-as-judge agreement study lands on technical-design grading specifically and shows >85% agreement on the binary scale, increase the weight of coach grading in the user-visible score.
- If Anthropic or Meta change their SD-round AI policy, update the asymmetry framing at session start within a week.
- If persona-drift mitigations (file-rereading at 10-turn intervals) prove insufficient in practice — measured by user-reported drift events per 10 sessions — fall back to shorter 30-minute sessions with explicit save points and persona-rehydration.
- If the bluffing-detection linguistic signals exceed 0.7 precision against user self-tagging, promote them from a coach-internal flag to a user-visible deep-dive prompt.
- If Hello Interview reverses course and ships an open-ended AI mock, study what they changed; the cheapest learning will be from their resolved failure modes.

---

## Caveats

- Hello Interview's per-level "Bar for X" callouts are the most-quotable per-level material in the public domain, but a Blind thread (REPORTED, May 2025) raises the legitimate concern that they may be calibrated to Hello Interview's own grading bar. Use as anchors, not as oracles; cross-validate against the interviewing.io transcripts.
- The DesignGurus Substack L5/L6 contrast is single-author. Treat the specific dollar numbers (e.g., "$50,000/month") as illustrative.
- Khanmigo's six-percentage-point gain is Khan Academy's published number on its own product over Oct 2025 – Apr 2026 testing; the methodology is not independently replicated.
- LLM-as-judge agreement rates on system design specifically have not been published. Zheng et al.'s 80% figure is on open-ended chat, not technical-design grading.
- The specific "20–40%" persona-drift figure that circulated in early 2026 summaries of Lu et al. (arXiv:2601.10387) is not directly stated in the paper's abstract and should be treated as unverified pending full-paper review. The mechanism (activation-projection drift in Gemma 2 27B, Qwen 3 32B, Llama 3.3 70B) is established; the specific magnitude in the SD-coaching domain may differ.
- All "first-person Anthropic interview" accounts are REPORTED single-source experiences with no NDA-cleared cross-check. Treat the reported prompts as plausible categories, not verified prompts.
- OpenAI GPT Store install/conversation counts are not publicly available (removed mid-2024). The catalog of nine SD GPTs is comprehensive as of May 2026 but cannot be ranked by usage.

---

## Annotated Bibliography

The 10–20 sources to read in full:

**Primary level-calibration (must-read):**

- **Stefan Mai, "5 Keys to Staff-Level System Design Interviews,"** Hello Interview blog. The single most quotable per-level exemplar source. Read for the location-search mini-transcript, the Postgres decisiveness example, and the option-listing failure mode.
- **Evan King, "The System Design Interview: What is Expected at Each Level,"** Hello Interview blog. The breadth/depth/proactiveness framework with named technology examples (Temporal.io, DynamoDB/DAX). The canonical "drive vs wait" passage.
- **Hello Interview problem breakdowns:** Top-K, Dropbox, LeetCode (coding platform), Twitter, Ticketmaster. Per-problem "Bar for X" callouts that are directly usable as reference answers for LLM-as-judge.
- **"System Design Interview Expectations by Company and Level,"** DesignGurus Substack. L4/L5/L6 contrast with concrete dialogue excerpts; single-author so treat as illustrative.
- **Hello Interview, "System Design Requirements Gathering"** (hellointerview.com/blog/system-design-requirements). The #1-failure-mode source.

**Pedagogy foundation (read for theoretical grounding):**

- **Collins, A., Brown, J. S., & Holum, A. (1991), "Cognitive Apprenticeship: Making Thinking Visible,"** *American Educator* 15(3): 6–11, 38–46. The canonical six-step framework. Two-voice modeling described directly.
- **VanLehn, K. (2011), "The Relative Effectiveness of Human Tutoring, Intelligent Tutoring Systems, and Other Tutoring Systems,"** *Educational Psychologist* 46(4): 197–221, DOI 10.1080/00461520.2011.611369. *"the effect size of human tutoring was much lower: d = 0.79. Moreover, the effect size of intelligent tutoring systems was 0.76, so they are nearly as effective as human tutoring."* Anchors realistic ambition.
- **Ma, W., Adesope, O. O., Nesbit, J. C., & Liu, Q. (2014), "Intelligent Tutoring Systems and Learning Outcomes: A Meta-Analysis,"** *Journal of Educational Psychology*. Updates VanLehn with more recent ITS data.
- **Brunmair, M. & Richter, T. (2019), "Similarity matters: A meta-analysis of interleaved learning and its moderators,"** *Psychological Bulletin* 145(11): 1029–1052. The interleaving evidence base: 59 studies, 238 effect sizes, overall Hedges' g = 0.42; mathematical tasks g = 0.34.

**LLM-as-judge (read before designing the grader):**

- **Zheng, L. et al. (2023), "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena,"** UC Berkeley/Stanford/CMU, arXiv:2306.05685; NeurIPS 2023 Datasets and Benchmarks. Read Table 2 (position bias), Table 4 (reference-guided method reduces failure 70%→15%), and the verbosity-bias section. *"strong LLM judges like GPT-4 can match both controlled and crowdsourced human preferences well, achieving over 80% agreement, the same level of agreement between humans."*
- **"The Silent Judge: Unacknowledged Shortcut Bias in LLM-as-a-Judge"** (arXiv:2509.26072). Establishes that LLM judges confabulate content-based justifications for cue-driven verdicts.
- **Eugene Yan, "Evaluating the Effectiveness of LLM-Evaluators (aka LLM-as-Judge)"** (eugeneyan.com). Comprehensive practitioner survey covering CriticGPT, reference-guided methods, and ablations.

**Sustained roleplay and persona drift (read for state-management design):**

- **Lu, C., Gallagher, J., Michala, J., Fish, K. & Lindsey, J. (2026), "The Assistant Axis: Situating and Stabilizing the Default Persona of Language Models,"** arXiv:2601.10387 (MATS/Anthropic/Oxford). Persona drift demonstrated via activation-space projections in Gemma 2 27B, Qwen 3 32B, Llama 3.3 70B.
- **"Interaction Context Often Increases Sycophancy in LLMs"** (arXiv:2509.12517). Memory features actively make sycophancy worse, not better. Critical for state-schema decisions.
- **"Alignment Drift in CEFR-prompted LLMs for Interactive Spanish Tutoring"** (arXiv:2505.08351). Direct evidence that system prompting is too brittle for sustained tutoring; file-backed state is the mitigation.

**Tutoring product comps (read for design lessons):**

- **Khan Academy Blog, "How Khan Academy Is Building a Better AI Tutor: Our Most Recent Learnings"** (Apr 2026). Six-percentage-point improvement from structured per-student signals vs free-form chat memory. The empirical anchor for "commit structured signals, not transcripts."
- **Hello Interview Guided Practice** (hellointerview.com/practice/overview). Walk through the product directly. The step-anchored FSM is the closest commercial implementation.
- **Duolingo blog, "Introducing Duolingo Max,"** and Copycat Cafe review (2026). The "ends every utterance with a question" anti-pattern is documented here.

**Cheating-prevention (read for honest framing):**

- **Turnitin AI detector retrospective** (Vanderbilt's "Guidance on AI Detection," BCcampus "Beyond Surveillance," Turnitin's own model release notes, NSF TRAILS reporting of Washington Post investigation). FPR/FNR backlash; raised confidence thresholds; non-native English bias.
- **EFF and EPIC complaints on Proctorio, ProctorU, Examity, Honorlock, Respondus.** UBC Senate finding that facial detection failed on Black faces 57% of the time; ProctorU stopping fully-automated proctoring May 2021.
- **Codeforces blog entries 133891, 141436, 149265, 152289** (2024–2026). Public admission that AI-assisted cheating cannot be prevented at scale on online programming contests.

**Meta AI-Enabled Round (read for content-coverage update):**

- **Hello Interview, "Meta's AI-Enabled Coding Interview: How to Prepare"** (Stefan Mai, 2025–2026). First-hand reporting with the internal Meta evaluation-criteria quote.
- **interviewing.io, "How to use AI in Meta's AI-assisted coding interview"** (2026). Concrete prompt examples and integration guidance.
- **Prepfully and Coditioning guides** (2026). Checkpoint thresholds and model-availability data.

**AI-lab system design (read for the missing archetype):**

- **Exponent, "Anthropic System Design Interview (2026 Guide)."** 50–55 minute format; AI-framing-over-classic-infra pattern; novelty of the problems.
- **interviewdb.io and linkjob.ai first-person Anthropic experiences.** Concrete reported prompts (inference batching, distributed search at billions of docs, KV-cache management).
- **Introl, "Prompt Caching Infrastructure"** (2025). Numbers on prefix caching cost reduction (90% Anthropic, 50% OpenAI); semantic-similarity prevalence (31% of queries).

**Prior-art comps (read in raw GitHub for design lessons):**

- **`noamseg/interview-coach-skill`** (GitHub). Best-of-class state model for a generic Claude Code interview coach. Five-dimension scoring, outcome calibration, directness levels.
- **`IliaLarchenko/Interviewer`** (GitHub). Speech-first generic interviewer; useful as a STT/TTS reference if voice is ever in scope.
- **TechInterviewer.ai Show HN** (news.ycombinator.com/item?id=39055841) and "Code Grey" Medium critique of AI mock interview tools. Failure-mode signals: looping on resolved points; mid-session requirement hallucination; user retention is hard.

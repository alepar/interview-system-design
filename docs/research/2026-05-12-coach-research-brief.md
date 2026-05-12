# Deep Research Brief: AI System-Design Interview Coach — Gaps & Foundations

*For Claude.ai Research, with `staff-engineer-study-guide.md` attached.*

---

## Context

I'm building a Claude Code–based AI coaching system for FAANG / AI-lab system-design interviews. Existing content is in the attached `staff-engineer-study-guide.md`, which already covers: a 100-question shortlist across 10 archetype categories; four universal evaluation competencies and level expectations from L3 through L7+; company-specific rubric mechanics for Meta, Google, Amazon as of October 2025; ~30 distributed-systems patterns; and a 5-phase study plan.

The coach will run as **Claude Code skills**, with three workflows / slash commands:

1. **`/study-patterns`** — user picks a pattern category (e.g., consistency / coordination); coach teaches interactively and checks understanding.
2. **`/practice-problem`** — user provides a system-design prompt; coach plays the *interviewee*, narrating their reasoning step by step.
3. **`/mock-loop`** — coach plays the *interviewer*, gives a problem, lets the user drive, intervenes only to keep things on track, then returns two bullet lists ("what was correct", "what was wrong") plus an overall summary.

**State model:** all artifacts — user self-profile, session transcripts, scores, study recommendations — are written as committed markdown in the repo. Sessions are model-stateless; persistent context comes from those files. The coach reads prior history to recommend what to study next.

## Goal of this research

Identify what I am currently missing or under-treating across the six areas below, so I can design the coach prompts and supporting state schema with full information. **Deliverable: a long-form survey report with citations** that I will mine myself. Lean toward concrete examples — transcripts, rubric anchors, specific products' features and failure modes, real prior-art repos — over generic principles. Where `staff-engineer-study-guide.md` is outdated, contradicted by recent reports, or wrong, **call it out explicitly**.

For each substantive claim, mark **CONFIRMED** (multiple recent primary sources) / **REPORTED** (single source or anecdote) / **SPECULATED** (your inference).

---

## Area 0 — Prior art for this exact build

Before anything else: **has someone already built this?** Specifically a Claude Code skill / Claude Project / custom GPT / open-source agent / local-LLM project that:

- Coaches *system-design* interviews specifically (not generic interview prep or LeetCode coding)
- Implements all three modes — teach-patterns, watch-me-design, mock-loop — or a meaningful subset
- Uses file-backed or otherwise persistent state to track learner progress across sessions

Where to look:

- **GitHub.** Search combinations of "system design interview" with "claude", "agent", "skill", "prompt", "tutor", "coach"; check Awesome-Claude-Code-Skills and similar curated lists; check claude-code-skills marketplace listings; check `dotfiles` repos and personal `~/.claude` shares.
- **Claude Projects** featured on Anthropic's showcase or shared on Reddit / Twitter / Hacker News.
- **Custom GPTs** on the OpenAI GPT store — search "system design interview coach" and adjacent terms; note install counts.
- **Hosted products.** Hello Interview, Exponent, interviewing.io, Educative, Tryexponent, ByteByteGo — do any have a *Claude Code, local skill, or self-hosted* offering beyond the hosted web app?
- **Community projects.** Hacker News Show HN, Reddit r/leetcode, r/cscareerquestions, r/ClaudeAI, r/LocalLLaMA; dev.to, Substack, personal blogs. **Include failed / abandoned attempts** — they're often more informative than successes.
- **Academic prototypes.** Papers from EDM, AIED, L@S, SIGCSE that built tutoring systems for software / systems design.

For each meaningful find, report:

- What it does well
- What it gets wrong
- What state / memory model it uses, if discernible
- Reuse potential — forkable code, transferable prompts or patterns
- Whether it's alive — commits / activity in the last 6 months

**If nothing comparable exists, say so explicitly.** That's also valuable.

---

## Area 1 — Pedagogy & coach behavior

What does great system-design interview coaching actually look like in practice?

- **Coach behavior in real sessions.** From published transcripts, recorded mock interviews (interviewing.io archives, YouTube mock-interview channels, Hello Interview's published critiques), what do effective human coaches *actually do* turn by turn? When do they interject vs let the candidate flounder? How do they hint without giving away the answer?
- **Socratic patterns specifically for system design.** System design has multiple valid solutions and no canonical correct path. What questioning patterns work? Contrast with Socratic patterns for math / coding tutoring, which assume convergent answers.
- **Scaffolding for the "watch me design" mode** (workflow #2): how should an expert externalize reasoning so a learner internalizes the *process*, not the answer? See think-aloud protocols, cognitive apprenticeship (Collins / Brown / Newman), and worked-example research (Sweller, Renkl).
- **AI-tutor anti-patterns.** Specifically for LLM-based tutors — over-praise, premature reveal, generic "great question!" filler, sycophancy collapse, losing the thread on long context, lecturing instead of dialog. What mitigations have been published or empirically shown?
- **Mock-interviewer persona calibration** (workflow #3): real human interviewers vary widely. What persona produces the best *learning* outcomes vs the most *realistic* experience, and how do those goals trade off?
- **Spaced repetition / interleaving / mastery learning applied to design patterns** (not flashcard facts). What's known about spacing for procedural + conceptual knowledge of the kind in `staff-engineer-study-guide.md` Section 3?
- **Learner-state-driven recommendations.** What signals from past sessions actually predict skill gaps? How do human coaches decide "drill X next"? What metadata is worth persisting (mistake categories, timing, deep-dive depth, per-pattern confidence)?

---

## Area 2 — Content depth the guide may be missing

Where is `staff-engineer-study-guide.md` thin, outdated, or behind 2025–2026 reality?

- **AI / ML lab interview prompts.** OpenAI, Anthropic, Mistral, xAI, DeepMind hire heavily and ask atypical prompts: agent loops, MCP-style tool servers, distributed inference (KV-cache sharding, speculative decoding, batched serving), RAG pipelines at scale, eval pipelines, prompt-caching infrastructure, model-routing layers. What's been reported, and what patterns are unique to this category?
- **Recent infra patterns missing or under-treated.** ScyllaDB migrations, CockroachDB / TiDB consistency models, lakehouse architectures (Iceberg / Delta / Hudi), ClickHouse for real-time OLAP, vector DB internals (HNSW vs IVF-PQ trade-offs), service-mesh failure modes, Wasm at the edge.
- **Front-end / client system design.** Increasingly asked at Meta, Airbnb, Google. Not in `staff-engineer-study-guide.md` at all.
- **LLD / API-design-flavored prompts at L4 / L5** — parking lot, payment processor, etc. — that aren't pure system design but show up in loops.
- **Meta's AI-assisted coding round (Oct 2025) and adjacent changes.** What's been reported since the guide was written? Any design-round changes too?

---

## Area 3 — Assessment methodology

How to grade open-ended designs reliably enough that the coach's feedback is signal, not noise?

- **Calibration anchors per level.** Ideally full transcripts of L4 vs L5 vs L6 answers to the same prompt; partial transcripts, summarized recaps, or rubric-anchored exemplars are also useful — anything that lets me build per-level exemplars. **Flag where you've extrapolated.**
- **Practical rubric weighting.** The "≈30% deep dive" weight is an aggregate; in practice interviewers often decide on one or two pivotal moments. What patterns describe those moments (e.g., the "drive vs wait" L5 / L6 boundary)?
- **LLM-as-judge for open-ended technical answers.** SOTA on using LLMs to grade open-ended design responses (Zheng et al. MT-Bench, G-Eval, more recent work). Failure modes — length bias, jargon bias, false positives on confident-sounding wrong answers. Agreement rates with human graders. Any published rubrics or eval harnesses I could borrow.
- **Self-assessment anti-patterns.** What biases do learners have when reviewing their own designs, and how does an external coach correct for them?
- **Common "split panel" patterns.** What disagreements between interviewers actually happen, and what does that tell us about which dimensions are reliably judged vs not?

---

## Area 4 — Product / UX patterns for AI coaches

What's been built (adjacent to but not necessarily the same as Area 0), what works, what doesn't?

- **Hello Interview AI** — flagship feature teardown: what does it do, what state does it track, what are users on Reddit / Blind saying about strengths and weaknesses?
- **Exponent's AI mock interview** — same teardown.
- **Pramp / interviewing.io / Karat** (human-mediated products) — what coaching practices do they enforce that an AI version should mimic?
- **Custom GPTs and Claude Projects** built by individuals for interview prep that have gained traction — what design patterns have emerged?
- **Sustained role-play with LLMs.** What's known from Character.ai, Inworld, AI Dungeon, and the academic literature about keeping a model in role across a 60+ minute session without persona drift?
- **State management for stateless models with file-backed memory.** Patterns from agentic-coding tools (Claude Code itself, Cursor, Aider) for what to put in system prompt vs retrieve on demand vs write back. Especially: when does retrieving past transcripts help vs hurt vs distract?
- **Detecting hand-waving / bluffing.** How do AI coaches (or could they) detect when a learner is bullshitting through a part they don't understand? What signals?

---

## Area 5 — Cheating prevention and honest-use design

The biggest abuse risk for this coach: a user pasting their *actual live interview prompt* into `/practice-problem` (workflow #2, where the coach plays the interviewee and narrates a complete design) and reading the output back to a real interviewer in real time. Workflow #2 is the highest-risk mode; #1 is medium; #3 is mostly self-incriminating to abuse.

I want a realistic, harm-reduction-oriented survey — **not** a generic "AI safety" treatment. Specifically:

- **Detection feasibility.** Can a stateless LLM coach plausibly distinguish "user practicing" from "user actively interviewing"? What signals are available and would actually correlate (time of day, session length, paste vs typed input, prompt phrasing — "design X" vs "let me design X with you", prior session history, presence of "the interviewer wants…" language, deadline-pressure markers, screen / audio context if available)? What detection approaches have been published or deployed in adjacent contexts — online-proctoring vendors (Proctorio, Honorlock, Examity), programming-contest cheat detection (Codeforces, ICPC), ChatGPT-essay-detection postmortems (Turnitin, GPTZero)?
- **False-positive cost.** Any detector strict enough to catch cheaters will also block legitimate intense practice. What FPR / FNR trade-offs have similar systems accepted, and how have those played out (Turnitin AI-detection backlash, Proctorio lawsuits)?
- **Design-level friction.** What product-design choices make the coach less useful as a real-time cheating aid *without* making it worse for study? Concrete patterns to evaluate: forced narration-before-architecture; mandatory slow drip (≥ N turns before a full design); deliberate sub-optimality injection ("here's one valid path; a stronger answer would consider X — what would you add?"); refusal to produce a single end-to-end answer artifact; persona quirks that would be conspicuous if read aloud to an interviewer.
- **Honor-system patterns that work.** Khanmigo, Codecademy, LeetCode have all faced versions of this. What attestation / pledge / context-priming patterns reduce abuse without paternalism? Any empirical data on effect sizes?
- **The Meta AI-assisted-round shift (Oct 2025).** Meta's coding round now explicitly assumes AI help is present. Does this change the conversation for system design (which is still AI-free for now)? What policies have OpenAI, Anthropic, Google publicly signaled for their own interview loops?
- **Human-coach service stances.** How do Pramp, Karat, interviewing.io frame and enforce no-cheating norms? What can a software-only coach borrow?
- **Refusal as a feature.** Is there a defensible design where `/practice-problem` *will not* produce a complete design until the user has first articulated (in their own words) requirements, constraints, and a rough first pass? This reframes the coach from "answer machine" to "thinking partner" and incidentally guts its real-time-cheat utility.
- **Honest framing of limits.** What should the report tell me to *stop trying* because it can't work? (Probably: server-side detection from chat content alone, beyond very obvious signals.)

The honest answer may be "you can't prevent it, only design around it." If so, surface that bluntly, with the strongest harm-reduction mechanisms ranked by realistic effect.

---

## Sources to prioritize

- Hello Interview, Exponent, interviewing.io, IGotAnOffer, Pramp engineering and content blogs
- Engineering blogs from Meta, Google, Amazon, Stripe, Uber, Anthropic, OpenAI, Discord, Cloudflare
- Academic literature on intelligent tutoring systems (Bloom's 2-sigma, VanLehn, Collins / Brown / Newman), worked examples (Sweller, Renkl), Socratic dialogue systems
- LLM-as-judge research (Zheng MT-Bench, G-Eval, etc.) and LLM-tutoring postmortems (Khanmigo, Duolingo Max, Codecademy AI)
- GitHub, Hugging Face Spaces, Anthropic / OpenAI showcase pages, Claude / GPT marketplaces — for Area 0 prior-art search
- Online-proctoring vendor disclosures and academic critiques (Proctorio, Honorlock, Examity)
- Programming-contest anti-cheat literature (Codeforces, ICPC, Kattis)
- AI-detection postmortems (Turnitin AI, GPTZero, OpenAI's own classifier withdrawal)

## Sources to skip

- Generic prep-course landing pages and marketing copy
- "Top 10 system design questions" listicles — already covered
- Pre-2024 advice that doesn't reflect current company practices
- Generic AI-tutor hype with no concrete mechanics

## Output format

Long-form report, ~8–14K words, structured as:

1. **Executive summary** (~1 page) — top 10–15 things I'm missing or treating wrongly, ranked by impact on the coach's effectiveness. **Lead with the Area 0 finding** — is there prior art worth forking, or is this a clear field?
2. **One section per Area 0–5**, each ~1500–2500 words, sub-headings matching the bullets above.
3. **Synthesis: implications for the coach design** — the 5–10 highest-leverage decisions I face when designing the three workflows and the state schema, **including 3–5 explicit design choices for cheating-resistance** (not vague "be careful" advice).
4. **Annotated bibliography** — every source cited inline, plus a curated reading list of the 10–20 sources to read in full.

Use concrete examples and short quoted excerpts wherever possible — one real transcript beats three paragraphs of meta-commentary.

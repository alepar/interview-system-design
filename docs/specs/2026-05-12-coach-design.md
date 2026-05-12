# AI System-Design Interview Coach — Design Spec

*Date: 2026-05-12*
*Status: v1 design, approved through brainstorming. Ready for implementation planning.*
*Companion docs: `docs/research/2026-05-12-coach-research-brief.md`, `docs/research/2026-05-12-coach-research-results.md`, `staff-engineer-study-guide.md`.*

---

## 1. Goals, non-goals, success criteria

### Goals

A local Claude Code coach that runs three reinforcing workflows for FAANG / AI-lab system-design interview prep:

- `/study-patterns` — coach teaches a chosen pattern subsection interactively and checks understanding.
- `/practice-problem` — coach plays the *interviewee* on a user-supplied or catalog problem, narrating reasoning step by step using two-voice modeling.
- `/mock-loop` — coach plays the *interviewer* under a phase-anchored FSM, intervenes only to keep things on track, and produces a structured assessment at the end.

Persistent across sessions via committed markdown — observable, audit-able, learner-owned. Honest about its limits: friction over detection, refusal as a feature, no over-praise.

### Non-goals (v1)

- Real-time cheating detection (industry precedent: doesn't work at useful FPR; Turnitin, Proctorio, Codeforces have publicly conceded this).
- Voice / multimodal interaction.
- Hosted multi-user platform.
- User-visible bluff scoring (bluff detection exists as a coach-internal flag and a deep-dive prompt only).
- Bidirectional grading (user grades coach's grading) — deferred to v2.

### Success criteria (testable)

1. `/practice-problem` refuses to produce a complete design before the user has typed functional requirements + at least one non-functional number + a first-pass component sketch.
2. `/mock-loop` runs as a 5-phase FSM with explicit phase transitions, not free chat.
3. Grading in `/mock-loop` uses reference answers and binary or 3-point ordinal scales (per Zheng et al., arXiv:2306.05685, Table 4 — reference-guided judging reduces failure rate from 70% to 15%).
4. After 5+ sessions, `/study-patterns` recommendations are driven by `state/observed.md`, not generic.
5. Persona stays stable across a 45-minute session — measured by user-reported drift events per 10 sessions; mitigation is mechanism-level (file-backed re-read schedule per Lu et al., arXiv:2601.10387).

---

## 2. Architectural shape

Three slash commands, one per workflow, sharing repo-root state files. Coach reference content (rubric, personas, patterns, problem answers) is read-only and lives under `docs/coach/`. User-mutable state lives under `state/`. The coach re-reads rubric + persona files at phase transitions to mitigate persona-drift / sycophancy-collapse failure modes; user state is *appended to* between sessions, never read back as transcript.

```
/
├── .claude/
│   └── commands/
│       ├── study-patterns.md       # slash command prompts
│       ├── practice-problem.md
│       └── mock-loop.md
├── docs/
│   ├── coach/
│   │   ├── rubric.md               # 4 dimensions × Bar-for-X anchors per level
│   │   ├── protocols.md            # refusal-gate, slow-drip, two-voice, phase rules, attestation, bluff list
│   │   ├── personas/
│   │   │   ├── coach.md            # base coach persona (collaborative tutor)
│   │   │   └── interviewer.md      # /mock-loop interviewer persona (neutral default)
│   │   ├── archetypes.md           # index of 10 + AI-Infra + Front-End; points to study guide
│   │   ├── patterns/               # one file per Section-3 subsection (3A-3O) + ai-infra.md + frontend.md
│   │   └── problems/               # v1: 5 reference answers (TinyURL, Twitter, Uber, Ticketmaster, Dropbox)
│   ├── research/                   # existing
│   └── specs/                      # this file
├── state/
│   ├── profile.md                  # user-declared (lazy creation on first run)
│   ├── observed.md                 # coach-maintained signals
│   ├── sessions/                   # per-session artifacts
│   │   └── YYYY-MM-DD-<workflow>-<slug>.md
│   └── archive/                    # full transcripts; write-only, never re-read
└── staff-engineer-study-guide.md   # canonical content; coach files are pointers
```

**Skill packaging.** Three slash commands in `.claude/commands/`, not skills with subagents. Lighter weight; sufficient for the conversational pattern.

---

## 3. Shared foundation

### `docs/coach/rubric.md`

The 4 universal dimensions from `staff-engineer-study-guide.md` — Problem Navigation, Solution Design, Technical Excellence, Communication — × per-level Bar anchors quoted directly from Hello Interview's per-problem "Bar for X" callouts (Top-K Videos, Dropbox, LeetCode-style platform, Twitter, Ticketmaster) plus Evan King's per-level passages and Stefan Mai's staff-level passages.

Scoring: binary (met / not met) or 3-point ordinal (clearly above bar / at bar / below bar) per dimension per level. Free-form 1–10 scoring is explicitly avoided (per Arize and "The Silent Judge," arXiv:2509.26072).

Used by `/practice-problem` (live narration grounding) and `/mock-loop` (post-session grading).

**Level handling.** The coach grades against *all* level bars on every session and reports the level demonstrated per dimension. The user's `target_level` (in profile) is used for *recommendation* (what to study next), not for *grading* (what bar to apply). This avoids letting the user game their level and surfaces honest uplevel/downlevel signal.

### `docs/coach/protocols.md`

Cross-cutting rules every workflow obeys:

- **Refusal-gate** for `/practice-problem`: explicit trigger conditions (no complete design until user has typed functional requirements + ≥1 NFR number + first-pass sketch).
- **Two-voice modeling format** for `/practice-problem`: `**Aloud:**` and `*Thinking:*` blocks, clearly delimited.
- **Slow drip**: one component / one trade-off / one deep-dive per coach turn; user must respond before coach continues.
- **Sub-optimality injection**: every full `/practice-problem` session ends with *"a stronger answer would consider X, Y, Z — what would you add?"*.
- **Phase-transition language** for `/mock-loop`: coach announces *"we're at the deep-dive phase now"* etc.
- **Re-read schedule**: persona + rubric files re-read at every phase transition or every 10 turns, whichever is sooner.
- **Bluff prompts**: 5 linguistic markers — passive voice + unnamed components; numbers→adjectives mid-design; pattern-name-dropping without operationalization; hedge escalation; recursive abstraction. Coach asks *"you said 'we'd just use a cache' — which cache, what eviction policy?"* rather than scoring out loud. Marker hit becomes a `bluff_flag` in the session artifact.
- **No trailing-question interrogation** (Duolingo Lily anti-pattern): coach does not end every turn with a question.
- **Honor attestation wording** (first-run only) and per-session reminder wording.
- **`observed.md` update rules** (see §4).

### `docs/coach/personas/coach.md`

Base coach persona for `/study-patterns` and `/practice-problem`: collaborative tutor, plain language, no over-praise, no "great question!" filler, no premature reveal of answers. Suppress questions in modeling-phase narration; emit only in coaching-phase prompts.

### `docs/coach/personas/interviewer.md`

`/mock-loop` interviewer persona: neutral by default. `adversarial` opt-in available after 3+ sessions on the chosen archetype. Time-boxing is announced aloud at session start. Mid-session course corrections name the *category* of gap, not the specific gap (per the interviewing.io Meta E5/E6 transcript pattern: *"I think we may still miss something here. It's about the trade-off discussions"*).

### `docs/coach/archetypes.md`

Index of the 10 archetypes from `staff-engineer-study-guide.md` Section 1, plus the two v1 additions: **AI-Infrastructure** (Category 11) and **Front-End** (Category 12). Each entry: 2–3 paragraph summary, top-3 prompts, links to canonical patterns. The file is a *pointer* into the study guide; the study guide is the single source of truth.

### `docs/coach/patterns/`

One file per `staff-engineer-study-guide.md` §3 subsection (3A through 3O) — coarse granularity, ~15 files total. Plus two new pattern files for the v1 archetype additions: `ai-infra.md` and `frontend.md`. Each file: pattern name, 1-paragraph definition, canonical use case, 1–2 named production systems, 1–2 alternatives.

### `docs/coach/problems/`

v1: 5 reference answers, one file per problem. Selection criteria: maximum archetype coverage with minimum count.

| Problem | Archetype | Source |
|---|---|---|
| `tinyurl.md` | Cat 1 (caching/read-heavy) | Hello Interview breakdown |
| `twitter-timeline.md` | Cat 2 (fan-out / feed) | Hello Interview breakdown |
| `uber.md` | Cat 6 (geo/proximity) | Hello Interview breakdown + interviewing.io transcripts |
| `ticketmaster.md` | Cat 4 (concurrent resource) | Hello Interview breakdown |
| `dropbox.md` | Cat 5 (UGC pipeline) | Hello Interview breakdown |

Each problem file follows a common template:

```markdown
---
slug: ticketmaster
archetype: concurrent-resource
sources:
  hello_interview: https://www.hellointerview.com/learn/system-design/problem-breakdowns/ticketmaster
  interviewing_io_transcript: <url if applicable>
---

# Bar anchors
- Mid-level: <quoted Hello Interview "Bar for Mid-Level">
- Senior:    <quoted "Bar for Senior">
- Staff+:    <quoted "Bar for Staff+">

# Canonical decomposition
## Requirements (functional + NFR with numbers)
## Core entities
## API
## HLD
## Deep dives (3–5 known areas)

# Known failure modes (2–3)
```

---

## 4. State schema

| File | Owner | Lifecycle |
|---|---|---|
| `state/profile.md` | user-declared, coach-prompted on first run | edited rarely; re-read at every session start |
| `state/observed.md` | coach-maintained | updated at session end; re-read at every session start |
| `state/sessions/YYYY-MM-DD-<workflow>-<slug>.md` | coach per-session | appended at session end; last 3 summaries re-read at session start |
| `state/archive/YYYY-MM-DD-<workflow>-<slug>.md` | coach per-session | append-only full transcripts; **never re-read into active context** |

### `state/profile.md`

Short freeform "about" paragraph at the top + extracted structured fields:

```yaml
target_level: L5
target_companies: [Anthropic, Meta]
timeline_weeks: 8
weekly_hours: 6
focus_areas: [ai-infrastructure, concurrent-resource]
```

User-editable by hand. Coach uses for recommendations only, not grading.

### `state/observed.md`

Coach-maintained signals:

```yaml
patterns:
  consistent-hashing: 2     # 0-3 ordinal
  lsm-vs-btree: 1
  ...
archetypes:
  ai-infrastructure: 1
  concurrent-resource: 2
mistake_categories_last_3:
  - "used eventual consistency where strong required"
  - "named technologies without justification"
  - "did not volunteer failure modes"
drive_wait_ratio_last_10: 0.4   # learner-initiated / total
prediction_score_delta_last_5: +0.6   # mean
scaffolding_level:
  ai-infrastructure: 3   # high scaffolding = early; decreases over sessions
```

**Update rules** (in `protocols.md`):

- Per-pattern confidence ← latest assessment, but **drops by ≤1 per session** (avoids noise from one bad session).
- Mistake categories: rolling last-3; older trimmed.
- Drive-vs-wait ratio: last 10 turn-initiators in `/mock-loop`.
- Prediction-vs-score delta: mean over last 5 `/mock-loop` sessions where calibration was captured.
- Scaffolding level: 0–3 per archetype; decreases by 1 after 3 sessions in archetype with ≥L-target performance.

### `state/sessions/*.md`

Per-session artifact, common YAML header:

```yaml
---
workflow: study-patterns | practice-problem | mock-loop
date: 2026-05-12
problem_or_topic: ticketmaster
duration_min: 45
level_demonstrated:
  problem_navigation: L5
  solution_design: L5
  technical_excellence: L4
  communication: L5
---
```

Workflow-specific structured body follows (see §5–§7).

### `state/archive/*.md`

Full session transcript. Write-only. Coach **never reads these back**. They exist so the learner can review their own history; the coach reads only `observed.md` and the last 3 `sessions/*.md` summaries at session start.

---

## 5. `/study-patterns`

### Invocation

- `/study-patterns` (no args) → coach reads `profile.md` + `observed.md` and recommends 3 next-up subsections **interleaved across archetypes** (per Brunmair & Richter 2019 meta-analysis, Hedges' g = 0.42; mathematical tasks g = 0.34). Each recommendation has a one-line rationale tied to weak signals. User picks one.
- `/study-patterns <topic>` → user picks a pattern subsection from `docs/coach/patterns/`. Accepted forms: a section code (`3A` through `3O`), the new archetype pattern files (`ai-infra`, `frontend`), or an archetype name (which resolves to the most-relevant subsection — e.g., `concurrent-resource` → `3G` consistency-coordination).

### Teaching loop

For each pattern in the chosen subsection (typically 5–8 patterns):

1. Coach gives a 1-paragraph intro: definition + canonical use case + one production system.
2. Coach poses a check question grounded in the rubric anchor (e.g., *"when would you pick LSM over B-tree?"*).
3. User answers.
4. Coach grades **3-point ordinal** (yes / partial / no):
   - **yes** → advance to next pattern.
   - **partial** → scaffold with the missing piece, re-ask a tighter question.
   - **no** → re-explain with a worked example, then re-ask.

Session pauses/resumes across user invocations via a `progress_index` field in the session artifact.

### Discipline

- No trailing-question interrogation; questions appear only at the check step, not at the end of every paragraph.
- Coach respects `profile.target_level` when picking the rubric anchor for grading the check answer.
- Honor reminder: none (lowest abuse risk among the three workflows).

### Session artifact

In addition to the common header:

```markdown
# Subsection
3G — Consistency / Coordination

# Per-pattern verdicts
- quorum-reads-writes: yes
- vector-clocks: partial — missing version-vector use case
- raft: yes
- crdt-vs-ot: no — re-explained with Google Docs example

# Recommended next
- 3D Storage (low confidence, related archetype)
- Practice problem: ticketmaster (deep dive in OCC will exercise this)
```

### Update to `observed.md`

Per-pattern confidence in `patterns:` map; new mistake categories appended; older trimmed.

---

## 6. `/practice-problem`

### Invocation

- `/practice-problem <problem-slug>` → catalog problem with reference answer in `docs/coach/problems/<slug>.md`.
- `/practice-problem` → freeform problem. Coach asks the user to state the problem, then proceeds *without* a reference answer; explicitly notes the absence and downgrades its confidence in feedback.
- **Fallback.** If `<problem-slug>` is supplied but no matching file exists in `docs/coach/problems/`, coach treats it as freeform: confirms the slug is unrecognized, asks the user to state the problem in their own words, and proceeds reference-less. Coach does not invent a reference answer.

### The refusal gate (the central pattern)

Coach refuses to produce a complete design until the user has typed (in chat or in a working file the user maintains):

1. Functional requirements (their interpretation, in their words)
2. Non-functional requirements with **at least one concrete number** (QPS, latency target, data size)
3. A rough first-pass component sketch (text bullets fine; no diagrams required)

Until those exist, coach asks **one** clarifying question per turn, gently pushing the user to articulate. Coach does **not** draft requirements *for* the user.

This is `protocols.md`'s gate executed strictly. It serves three purposes simultaneously:
- It enforces the #1 published high-frequency mistake mitigation (Hello Interview: requirements gathering is the most common feedback at mid-level, top-3 even at Senior+).
- It executes the Collins / Brown / Newman articulation step of cognitive apprenticeship.
- It cripples real-time cheat utility (typing this material first is mechanically slower than just doing the live interview).

### Two-voice modeling (once gate passes)

Coach narrates in two clearly-delimited voices per turn:

```
**Aloud:** "I'll use a write-through cache here, fronting Postgres
for the hot-path reads on the order table."

*Thinking:* "Considered write-back for throughput, but consistency
with the auth boundary makes write-through cleaner; the cost is
~20% lower write throughput, which is acceptable given the 5K
WPS target. Redis sorted set for the leaderboard query because
we need O(log N) range reads and TTL cleanup."
```

`*Thinking:*` block is the worked-example payload (Sweller, Renkl); `**Aloud:**` is what the coach would say to an imagined interviewer.

### Slow drip

One component / one trade-off / one deep-dive per coach turn. After each, coach pauses and asks the user one specific question — typically *"what would you add or change here?"* — and waits for the user's response before continuing. No end-to-end design dumps.

### Sub-optimality injection

Triggered when the user signals they're done — explicitly (e.g., *"I think that's it"*, *"let's wrap"*, `/done`) — or when the coach has narrated through all five canonical decomposition steps (Requirements → Core Entities → API → HLD → Deep Dives). Coach outputs a callout:

> *"A stronger answer would also consider: (a) idempotency tokens on the order endpoint to handle client retries; (b) shard-key choice for the orders table when traffic skews to a single artist; (c) graceful degradation when Redis is down. What would you add?"*

This is pedagogy (forces the learner into Bloom's critique level) and cheating-resistance (real interviewer catches the sub-optimal answer and downlevels).

### Scaffolding fade

Over successive sessions on the same archetype, the `*Thinking:*` voice shrinks and the user is prompted to articulate more. Tracked as `scaffolding_level` per archetype in `observed.md`. Implementation: protocol rule in `protocols.md` references the current scaffolding level when shaping the prompt.

### Honor reminder

1-line at top of every session output: *"Practice mode — not for live interview use."*

### Session artifact

Common header + workflow-specific body:

```markdown
# Problem
ticketmaster (catalog reference)

# User's stated requirements (verbatim from chat)
- Functional: book seats; concurrent bookings without double-allocation; ...
- NFR: 10K concurrent users on hot drops; <500ms p95 booking latency

# Pivotal moments
1. Turn 14: user proactively raised OCC vs Redis distributed lock without prompt → Senior signal.
2. Turn 22: user named "we'd use a queue" without specifying ordering or dedup → bluff flag → coach asked which queue / what semantics → user clarified Kafka with partition-key=event_id.

# Per-dimension levels demonstrated
- Problem Navigation: L5 (clear NFRs with numbers; named the hard part — concurrent booking)
- Solution Design: L5 (working OCC + queue architecture)
- Technical Excellence: L4 (named Kafka but did not discuss compaction or partition skew)
- Communication: L5 (responded to bluff prompt without defensiveness)

# Sub-optimality callouts shown
- Idempotency on POST /booking
- Shard-key skew handling
- Graceful Redis degradation

# Recommended next
- /study-patterns 3F (asynchronous / streaming — Kafka deep dive)
- /mock-loop ticketmaster (apply this design under interviewer pressure)
```

---

## 7. `/mock-loop`

### Invocation

- `/mock-loop` → coach picks a problem from `docs/coach/problems/`. Selection priority: (1) archetype overlap with `profile.focus_areas`; (2) lowest archetype mastery in `observed.md`; (3) interleaving (avoid same archetype as the user's last 2 sessions). Coach announces the selection and rationale before starting.
- `/mock-loop <problem-slug>` → user picks.
- `/mock-loop <problem-slug> adversarial` → adversarial persona; gated on 3+ prior sessions in that archetype (otherwise coach refuses and explains why).

### Opening

Coach announces aloud (i.e., as text the user sees):

- Time budget: *"We have 45 minutes. Let's collect signals in the first 40; we'll debrief in the last 5."*
- Persona: neutral / adversarial.
- Problem statement.
- Per-session honor reminder: included in the opening.

Persona + rubric files loaded into working context.

### Phase-anchored FSM

| Phase | Budget | Coach behavior |
|---|---|---|
| Requirements | ~5 min | Answers candidate's questions about scope; **does not volunteer constraints** unless asked. |
| Core Entities | ~3 min | Mostly silent; nods along. |
| API Design | ~5 min | Mostly silent; may ask *"what about X endpoint?"* once if obviously missing. |
| HLD | ~10 min | Silent unless candidate is visibly stuck >2 min. |
| Deep Dives | ~20 min | If candidate doesn't proactively pick depth areas, coach picks one and asks. **This is the pivotal drive-vs-wait moment**; logged as a pivotal turn in the session artifact. |

Budget interpretation: the coach has no wall clock. Budgets are conversational pacing targets — approximated by turn count and depth-per-turn, not real time. The user can supply elapsed-minutes hints (e.g., *"15 min in"*) which the coach respects; otherwise it paces by content density.

### Phase transitions

- Coach announces phase transitions aloud: *"we're at the deep-dive phase now."*
- Persona + rubric files re-read at every phase boundary (mechanism-level drift mitigation, Lu et al. arXiv:2601.10387; sycophancy mitigation, arXiv:2509.12517).

### Intervention rules

Coach interjects **only** when:

- Time is running out in the current phase (procedural intervention: *"we have 2 min left in this phase"*).
- Candidate is visibly stuck for >2 minutes (procedural intervention: *"want to think out loud about where you'd start?"*).
- A bluff marker is tripped (constraint-injection or specificity question; never hint-injection).

Coach **never** volunteers the answer. Constraint-injection (*"imagine 100× writes"*) is preferred over hint-injection (*"have you considered fan-out on write?"*).

### Adversarial mode (opt-in)

Persona pushes back occasionally on chosen approaches, asks *"why isn't this worse?"*, occasionally lets the candidate go down a wrong path before redirecting. Realism-optimal; less learning-optimal; gated behind 3+ prior sessions in the archetype.

### Closing assessment

1. **Calibration step.** Before showing the grade, coach asks: *"On a 1–3 scale per dimension, what's your prediction?"* User's prediction is committed; the delta from actual feeds `observed.md`'s `prediction_score_delta_last_5`.

2. **What was correct.** Bulleted list, dimensions × level-bars matched. Verbatim wording references the rubric anchors.

3. **What was wrong.** Bulleted list, dimensions × level-bars missed. Each item references the specific rubric anchor not met.

4. **Overall.** Short summary including:
   - Level demonstrated per-dimension (from the session header's `level_demonstrated`).
   - 1–2 **pivotal moments**, each with a one-sentence rationale.
   - Recommended next session.

Grading uses the reference answer (if catalog problem) + binary/3-pt ordinal per Zheng et al. Free-form 1–10 is explicitly avoided.

### Session artifact

Common header + the four assessment sections above, with the user's prediction captured before the actual grade.

---

## 8. Cross-cutting flows

### First-run flow

Trigger: any workflow invoked AND `state/profile.md` does not exist.

1. Coach defers the requested workflow.
2. Coach prompts: *"Looks like we haven't met. Tell me a few words about yourself, your goals for this practice, and any specific areas you want to focus on."*
3. User responds (typically 1–3 sentences).
4. Coach extracts `target_level`, `target_companies`, `timeline_weeks`, `weekly_hours`, `focus_areas` where stated; user's freeform text becomes the `about` paragraph at the top of `profile.md`.
5. Coach writes `state/profile.md`.
6. Coach presents the **honor attestation** (one-time):

   > *"Before we start: this coach is designed for practice. It won't produce a complete design before you've articulated requirements and a first-pass sketch, and it's not for use during a live interview. Reply 'agreed' to continue."*

7. On affirmative confirmation (`agreed`, `yes`, `sure`, `ok`, or equivalent), coach proceeds with the originally-requested workflow.
8. On refusal or non-confirmation, coach exits without further state writes.

### Persona / rubric refresh schedule

Re-read `docs/coach/personas/<workflow>.md` and `docs/coach/rubric.md` at:

- Session start (every workflow).
- Every phase transition in `/mock-loop`.
- Every 10 turns in `/practice-problem` (or at phase-equivalents — entering deep-dive after HLD).

File-backed re-read is the mitigation for mechanism-level persona drift. Prompt-only mitigations are documented as insufficient (Lu et al.; arXiv:2505.08351 on alignment drift in tutoring).

### Per-workflow honor reminder

- `/practice-problem`: 1-line at top of every session output — *"Practice mode — not for live interview use."*
- `/mock-loop`: included in the time-box opening announcement.
- `/study-patterns`: no reminder (lowest abuse risk).

### `observed.md` update protocol

Executed at session end by the coach:

1. Read the just-written `state/sessions/<file>.md`.
2. Update per-pattern confidence using the latest assessment, with the ≤1-step-down clamp.
3. Append new mistake categories; trim to last 3.
4. Update drive-vs-wait ratio (count of last 10 turn-initiators in the most recent `/mock-loop`).
5. Update prediction-vs-score delta (mean over last 5 `/mock-loop` sessions with calibration data).
6. Update scaffolding level if 3+ consecutive sessions in archetype demonstrated ≥ target level.

Exact rules documented in `docs/coach/protocols.md` so they're auditable by the user.

---

## 9. Content additions

### AI-Infrastructure archetype (new — Category 11)

Added to `staff-engineer-study-guide.md` Section 1 as Category 11. Indexed in `docs/coach/archetypes.md`. Companion `docs/coach/patterns/ai-infra.md`.

**Defining constraints.** Safety and cost are first-class SLIs. Format: 50–55 min at AI labs vs the standard 45. Problems are *often novel* — interviewer may not have a single correct answer in mind.

**Patterns (in `ai-infra.md`):** continuous batching (vLLM PagedAttention); prefix caching (Anthropic 90% cost / 85% latency reduction; break-even ~1.4 reads/prefix); KV-cache management and KV-aware request routing; speculative decoding; model-router gateways (route by complexity / length / cost class); MoE / expert parallelism; semantic caching (Introl: 31% of LLM queries semantically similar to prior); eval pipelines as production systems; parallel safety pipelines (rule-based <1ms + ML 10s ms, concurrent with inference); distributed training references (FSDP, Megatron-LM, DeepSpeed, all-reduce).

**Top-3 prompts.** (1) Inference-batching API for a GPU cluster with priority queues + streaming. (2) Distributed search over a billion documents at millions of QPS with KV-cache-aware routing. (3) Safety / moderation pipeline layered with inference.

### Front-End archetype (new — Category 12)

Added as Category 12 + index in `archetypes.md`. Companion `docs/coach/patterns/frontend.md`. Canonical framework: **RADIO** (Requirements, Architecture, Data model, Interface, Optimization). Companies asking: Meta, Airbnb, Google, Atlassian, Uber, Apple.

**Patterns (in `frontend.md`):** virtualized lists; optimistic UI with rollback; IndexedDB / local-storage strategies; service workers for offline; WebSocket connection management with reconnect/backoff; code-splitting and lazy loading; observer / store patterns; CRDT vs OT for collaboration; image lazy-load with intersection observer.

**Top-3 prompts.** Image carousel; autocomplete with keyboard navigation; collaborative spreadsheet (Sheets).

### v1 problem reference answer set

5 problems, maximum archetype coverage, minimum count: **TinyURL** (Cat 1), **Twitter timeline** (Cat 2), **Uber** (Cat 6), **Ticketmaster** (Cat 4), **Dropbox** (Cat 5). Each follows the common template (see §3 / `docs/coach/problems/`).

---

## 10. Open knobs deferred to v2

- **Bidirectional grading.** User grades the coach's grading at session end; commit deltas; calibrate. Week 6 of the research's recommended build order.
- **User-visible bluff scoring.** v1 surfaces bluff prompts as deep-dive questions only; v2 may surface a bluff_score as feedback if the linguistic-signal precision exceeds ~0.7 against user self-tagging.
- **Voice / multimodal.** STT/TTS reference (`IliaLarchenko/Interviewer` on GitHub) logged for future reuse if voice enters scope.
- **More reference answers.** v1 ships 5; expansion to ~20 (covering all 10 + 2 v1 archetypes) is a content task, not a design task.
- **Outcome calibration.** After the user has done 3+ real interviews, run scoring-drift detection against external feedback and recalibrate (pattern borrowed from `noamseg/interview-coach-skill`).

---

## 11. Build order (high-level — for the implementation plan)

The implementation plan (separate doc) will refine these into ordered tasks. High-level phases per the research's staged recommendation:

1. **Phase 1: Foundation + content.** State schema, `docs/coach/rubric.md`, `docs/coach/protocols.md`, `docs/coach/personas/*`, `docs/coach/archetypes.md`, the 15 `patterns/` files, the 5 `problems/` reference answers, and the two new archetype additions to `staff-engineer-study-guide.md`. Without these, every workflow fails predictably.
2. **Phase 2: `/practice-problem`.** Highest-leverage workflow (refusal-gate is the central pattern; pedagogy + cheating-resistance simultaneously). Test for sycophancy collapse with adversarial-pushback fixtures.
3. **Phase 3: `/study-patterns`.** Interleaved recommendation logic; teaching loop; per-pattern confidence updates.
4. **Phase 4: `/mock-loop`.** Phase-anchored FSM; persona refresh mechanism; closing assessment with calibration step.
5. **Phase 5: Polish + observations.** Mistake-category taxonomy refinement; scaffolding fade tuning; recommendation quality from real session data.

---

## 12. Sources

- `docs/research/2026-05-12-coach-research-results.md` — the synthesis this design draws from.
- `staff-engineer-study-guide.md` — the canonical study reference.
- Zheng et al. (2023), "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena," arXiv:2306.05685.
- Lu, Gallagher, Michala, Fish & Lindsey (2026), "The Assistant Axis," arXiv:2601.10387.
- "Interaction Context Often Increases Sycophancy in LLMs," arXiv:2509.12517.
- "The Silent Judge: Unacknowledged Shortcut Bias in LLM-as-a-Judge," arXiv:2509.26072.
- Brunmair & Richter (2019), "Similarity matters: A meta-analysis of interleaved learning and its moderators," *Psychological Bulletin* 145(11): 1029–1052.
- Collins, Brown & Holum (1991), "Cognitive Apprenticeship: Making Thinking Visible," *American Educator* 15(3): 6–11, 38–46.
- VanLehn (2011), "The Relative Effectiveness of Human Tutoring, Intelligent Tutoring Systems, and Other Tutoring Systems," *Educational Psychologist* 46(4): 197–221.
- Hello Interview problem breakdowns (Top-K, Dropbox, LeetCode-style, Twitter, Ticketmaster); Evan King's per-level breakdown; Stefan Mai's staff-level essay.
- `noamseg/interview-coach-skill` — state-model reference (read for patterns; not forked).

# Interview System Design — AI Coach

A local Claude Code coach for FAANG / AI-lab system-design interview prep. Three slash commands, persistent markdown state, designed around the way effective human coaches actually work — refusal-as-a-feature, slow drip, two-voice modeling, phase-anchored mocks, structured assessments.

---

## What this is

A coaching system you run inside Claude Code, in a repo you own. There is no hosted product, no account, no telemetry. Everything the coach knows about you lives in `state/` as committed markdown files; everything the coach teaches from lives in `docs/coach/` as committed reference content.

It's built for engineers preparing for system-design rounds at companies that still run them AI-free as of mid-2026 — Meta, Google, Amazon, Anthropic, OpenAI, DeepMind, Stripe, Uber, and similar. The content is calibrated to the L4 → L7+ progression and to per-company rubric mechanics documented in `staff-engineer-study-guide.md`.

It is **not** a replacement for a human mock interviewer. It's a tool for the long flat part of prep — pattern fluency, problem decomposition, deep-dive practice, calibrating where you actually grade out — between human mocks.

---

## Quickstart

1. **Clone the repo** and open it in [Claude Code](https://www.anthropic.com/claude-code).
2. **Run any slash command** — e.g. `/study-patterns` or `/practice-problem tinyurl`. On first run the coach will ask you a few words about yourself, your goals, and any focus areas. Reply briefly (1–3 sentences). The coach extracts target level, target companies, timeline, and focus areas, and writes them to `state/profile.md`.
3. **Confirm the honor attestation.** The coach is for practice — it will not produce a complete design before you have, and it is not for use during a live interview. Reply `agreed` (or `yes` / `sure` / `ok`) to continue.
4. **Work through the recommended next session.** After you finish, the coach commits a session artifact to `state/sessions/` and updates `state/observed.md` with what it learned about you.

That's it. From there, every session feeds the next: `/study-patterns` recommendations are driven by your weakest patterns; `/mock-loop` picks problems matched to your weak archetypes; per-pattern confidence accumulates across sessions.

---

## Commands

### `/study-patterns` — learn one pattern subsection at a time

The coach teaches you a chosen pattern subsection (e.g., consistency / coordination, caching, geo indexing) one pattern at a time, with check questions and 3-point grading.

**Invocation:**

- `/study-patterns` — coach reads your profile + observed signals, recommends 3 next-up subsections **interleaved across archetypes** (so you don't drill the same area three sessions in a row). Each recommendation includes a one-line rationale tied to your weak signals.
- `/study-patterns 3G` — pick a specific subsection by code (3A through 3O, plus `ai-infra` and `frontend`).
- `/study-patterns concurrent-resource` — pick by archetype name; resolves to the most-relevant subsection.

**What happens:** for each pattern in the chosen subsection, the coach gives a 1-paragraph intro (definition + canonical use + a named production system), then poses a check question grounded in the rubric. You answer; the coach grades **yes / partial / no**:

- **yes** → brief acknowledgment, advance
- **partial** → scaffolds with the missing piece, re-asks a tighter question
- **no** → re-explains with a worked example, then re-asks

You can stop mid-session; the coach saves your `progress_index` and resumes from that pattern next time.

**When to use:** building or refreshing pattern fluency. Use this heavily in weeks 1–3 of focused prep, then taper as you pivot to problems.

### `/practice-problem` — watch the coach solve a problem (and critique it)

The coach plays the *interviewee* on a problem you supply. It narrates reasoning step by step in two voices — what it would say aloud to an interviewer, and what it's thinking but not saying — and prompts you to critique each move.

**Invocation:**

- `/practice-problem tinyurl` — work through one of the catalog problems with a reference answer (currently: `tinyurl`, `twitter-timeline`, `uber`, `ticketmaster`, `dropbox`).
- `/practice-problem` — bring your own problem. The coach asks you to state it in your own words and proceeds without a reference answer.

**The refusal gate** is the central feature. The coach will not produce a complete design until *you* have typed:

1. Your interpretation of the **functional requirements**
2. **Non-functional requirements** with at least one concrete number (QPS, latency target, data scale)
3. A rough first-pass **component sketch** (text bullets fine; no diagrams required)

Until those exist, the coach asks one clarifying question per turn. It will not draft requirements for you. This is the core of what makes the practice useful: you're not consuming an answer, you're producing the start of one and getting feedback on it.

**Once the gate passes**, the coach narrates in two clearly-delimited voices:

```
**Aloud:** "I'll use a write-through cache here, fronting Postgres for the hot reads."

*Thinking:* "Considered write-back for throughput, but consistency with the auth
boundary makes write-through cleaner; the cost is ~20% lower write throughput,
which is acceptable given the 5K WPS target."
```

Then it slow-drips: one component / one trade-off / one deep-dive per turn, with a question to you at each stop. At the end, it injects deliberate sub-optimality — *"a stronger answer would also consider X, Y, Z; what would you add?"* — and waits for your critique.

**When to use:** when you want to see how a worked answer flows for an archetype you're weak in, OR when you want to drive your own design and have the coach critique it.

### `/mock-loop` — full mock interview

The coach plays the *interviewer* through a 5-phase finite-state-machine that mirrors how real Hello-Interview-style mocks run: Requirements → Core Entities → API → HLD → Deep Dives. You drive; the coach intervenes only to keep things on track. At the end, it produces a structured assessment.

**Invocation:**

- `/mock-loop` — coach picks a problem matched to your `focus_areas` and weakest archetype, and recommends a difficulty (see below).
- `/mock-loop ticketmaster` — you pick the problem; coach still recommends a difficulty.
- `/mock-loop ticketmaster medium` — pick a difficulty explicitly (`easy` / `medium` / `hard`).
- `/mock-loop ticketmaster hard adversarial` — difficulty and `adversarial` are orthogonal axes; any combination is valid.
- `/mock-loop ticketmaster adversarial` — adversarial persona (pushes back, occasionally lets you go down a wrong path); recommended after 3+ prior sessions in the same archetype. If you ask for it earlier, the coach runs it anyway and notes once why it isn't the default (it's a soft gate).

**Difficulty.** Three named levels control how proactively the coach drives the conversation:

- **Easy** — the coach suggests rough FR/NFR areas during Requirements, offers a one-sentence focus prompt at the start of HLD, and announces the deep-dive topics up-front. Use when you're early in prep or learning an unfamiliar archetype.
- **Medium** — the coach is silent through Requirements / Entities / API / HLD, then picks **one** deep-dive topic to ensure a named bottleneck area is covered. Use when you can drive the breadth and want pressure on depth.
- **Hard** — the coach is silent across all five phases, intervening only on the four existing rules (time warnings, stuck-prompts, bluff markers, category-level gap flags). Closest approximation of a real interview.

If you omit the difficulty, the coach recommends one based on your last three `/mock-loop` sessions — ≥2 demonstrating Solution Design **and** Technical Excellence at your target level → `hard`; 1 → `medium`; 0 → `easy`. Fewer than three prior sessions falls back to `medium`. If you pass an explicit difficulty that differs from what the coach would recommend, it runs your choice and notes the divergence in one line. You can override mid-session by typing `easy`, `medium`, or `hard` after the opening.

Per-session contributions to `observed.md` mastery trajectories are **weighted by difficulty** (hard 1.0, medium 0.6, easy 0.3), so demonstrated signals at easy don't masquerade as the same evidence as hard. The drive-vs-wait pivotal moment is logged fully at hard, partially at medium (only on signals the coach didn't drive), and not at easy.

**Opening:** the coach announces the time budget aloud (45 min: 40 collect signals, 5 debrief), the persona mode, the difficulty level (recommendation or explicit choice), the problem, and a one-line honor reminder.

**During the session:** the coach announces each phase transition (*"we're at the deep-dive phase now"*) and is mostly silent within phases. It interjects **only** when (a) time is running out in the current phase, (b) you're visibly stuck for 2+ turns, or (c) one of the bluff markers from `protocols.md` trips. Interventions are procedural (*"we have 2 min left"*) or constraint-injection (*"imagine 100× writes"*) — never hint-injection (*"have you considered fan-out on write?"*).

**Closing assessment** (in this order):

1. **Calibration step** — the coach asks you to predict your score on a 1–3 scale per dimension *before* showing the grade. The delta is committed and feeds your prediction-vs-actual signal over time.
2. **What was correct** — bulleted list, dimensions × level-bars matched.
3. **What was wrong** — bulleted list, dimensions × level-bars missed.
4. **Overall** — level demonstrated per dimension, 1–2 pivotal moments quoted with rationale, and a recommended next session.

The coach grades against **all** level bars on every session and reports the level you actually demonstrated per dimension — not just hire/no-hire at a target level. That gives you honest signal on which dimensions are uplevelable and which are downlevel risk.

**When to use:** weeks 4+ of focused prep, when you've built pattern fluency and want signal on whether you can drive an interview end-to-end at your target level.

---

## What gets saved

Everything is markdown in `state/`, committed to git so your progress survives across sessions and machines:

- **`state/profile.md`** — your declared identity (target level, companies, timeline, focus areas) plus a short freeform "about" paragraph. Created on first run; you can edit it by hand.
- **`state/observed.md`** — what the coach has learned about you: per-pattern confidence (0–3 ordinal), per-archetype mastery, last 3 mistake categories, drive-vs-wait ratio, prediction-vs-score delta, scaffolding level per archetype. Updated at the end of every session.
- **`state/sessions/YYYY-MM-DD-<workflow>-<slug>.md`** — per-session artifact: pivotal moments, per-dimension levels demonstrated, the two bullet lists for `/mock-loop` (what was correct / what was wrong), recommended next.
- **`state/archive/YYYY-MM-DD-<workflow>-<slug>.md`** — full session transcript. Append-only; the coach **never reads these back into context** (writing them is for your review, not the coach's memory).

The coach reads only `profile.md`, `observed.md`, and the last 3 session summaries at the start of each session. The structured signals matter more than the conversation history — that design choice is grounded in published evidence that LLM tutors *get worse* when fed accumulated context (sycophancy collapse and persona drift; see `docs/research/2026-05-12-coach-research-results.md` for the citations).

---

## Tips for getting the most out of it

- **Be honest in `/study-patterns` check answers.** If you don't know, say so. The coach's grading is calibrated to surface gaps, not to make you feel good.
- **Use `/practice-problem` to *prepare* for `/mock-loop`.** Working through a problem with the coach narrating is much cheaper than burning a mock on it.
- **Take the calibration step in `/mock-loop` seriously.** Predicting your score before you see the grade builds metacognition. After 5+ sessions, the prediction-vs-actual delta is itself a signal — if you consistently over-predict by 1 rubric point, you're over-confident; the opposite means you're under-selling and probably leaving signal on the table in real interviews.
- **Run multiple problems in the same archetype before declaring it solved.** Pattern fluency transfers, but problem-shape fluency doesn't always.
- **Re-run `/mock-loop` on the same problem after a week.** Your delta on the second pass shows what stuck.
- **Bring your own problems too.** The catalog has 5 problems with reference answers; the coach handles freeform problems too (it just downgrades its grading confidence and tells you).

---

## Limits — what this isn't

- **Not a cheat aid.** The refusal gate, slow drip, two-voice modeling, sub-optimality injection, and signature persona quirks are designed to make the coach mechanically slower than just doing the live interview. The coach will not produce an end-to-end design before you have. If you try to use it during an actual interview, you will be conspicuous — and you will fail to internalize the practice anyway.
- **Not a substitute for human mocks.** The coach can't read your tone, can't hear hesitation, can't push back on you the way a real interviewer will. Use it for the long flat part of prep; book human mocks for calibration before the real loop.
- **Sometimes wrong.** LLM-as-judge has documented failure modes (length bias, verbosity bias, self-enhancement) — the coach uses 3-point ordinal scales and reference answers per problem to mitigate, but the grading is one signal, not the verdict.
- **Calibrated to mid-2026.** Company practices change. Meta added an AI-assisted coding round in October 2025; system-design rounds remain AI-free at every major lab as of May 2026, but that may change. Confirm the format with your recruiter.

---

## Repository layout

For the curious, or for engineers who want to extend or fork:

| Path | What's there |
|---|---|
| `.claude/commands/` | The three slash command prompts. Read these to see exactly what the coach is told to do. |
| `docs/coach/` | The coach's knowledge base — `rubric.md`, `protocols.md`, `personas/`, `archetypes.md`, `patterns/` (one file per `staff-engineer-study-guide.md` §3 subsection plus `ai-infra.md` and `frontend.md`), `problems/` (5 reference answers). |
| `docs/specs/` | Design docs (`2026-05-12-coach-design.md` is the canonical v1 spec). |
| `docs/research/` | Research synthesis the design draws from, plus your dogfood notes if you commit them. |
| `docs/plans/` | Implementation plans. |
| `staff-engineer-study-guide.md` | The canonical study reference. The pattern files in `docs/coach/patterns/` are summaries pointing into this. |
| `state/` | Your session state. Committed across sessions. |
| `tests/` | Bash validation harness — file existence, frontmatter keys, required content markers in slash command prompts. Run with `bash tests/all.sh`. |

---

## How it works in one paragraph

The coach is governed by file-backed rules (`docs/coach/protocols.md`), not by accumulated chat history. State is structured markdown — observable, auditable, learner-owned. Grading uses reference answers per problem and 3-point ordinal scales (no free-form 1–10) per the LLM-as-judge research (Zheng et al. arXiv:2306.05685). Coach re-reads persona and rubric files at phase transitions and every ~10 turns to mitigate mechanism-level persona drift (Lu et al. arXiv:2601.10387) and sycophancy collapse from accumulated context (arXiv:2509.12517). The detailed design rationale is in `docs/specs/2026-05-12-coach-design.md`; the research that informed it is in `docs/research/2026-05-12-coach-research-results.md`.

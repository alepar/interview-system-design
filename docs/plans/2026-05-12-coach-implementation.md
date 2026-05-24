# AI System-Design Interview Coach — v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement v1 of the local Claude Code AI coach defined in `docs/specs/2026-05-12-coach-design.md` — three slash commands (`/study-patterns`, `/practice-problem`, `/mock-loop`) backed by a `docs/coach/` reference-content library and a `state/` user-mutable directory, with a bash-based validation harness.

**Architecture:** Three slash command prompts in `.claude/commands/` consume read-only reference content under `docs/coach/` (rubric, protocols, personas, archetypes, patterns, problems) and read/write structured state under `state/` (profile, observed signals, per-session artifacts, transcript archive). All persistence is markdown + YAML frontmatter. Coach behavior is governed by file-backed rules (refusal gate, slow drip, two-voice modeling, phase-anchored FSM, persona refresh) documented in `docs/coach/protocols.md` and enforced via the slash command prompts.

**Tech Stack:** Claude Code (slash commands, conversational LLM); Markdown + YAML frontmatter for all content; Bash (with `grep`, `sed`, `[[` test expressions) for the validation harness; no other runtime.

**Source references (the engineer should have these open while implementing):**
- `docs/specs/2026-05-12-coach-design.md` — the canonical design
- `docs/research/2026-05-12-coach-research-results.md` — research synthesis the design draws from
- `staff-engineer-study-guide.md` — canonical study content; pattern files at `docs/coach/patterns/3X-*.md` summarize its §3 subsections

**Testing approach.** Two layers:
1. **Static checks** (`tests/*.sh`, bash + grep): file existence, frontmatter keys, required content markers in prompts.
2. **Dogfood checks** (manual): each workflow phase ends with a documented fixture conversation the engineer runs by hand.

Each task follows the cycle: write failing test → run, verify FAIL → write content → run, verify PASS → commit. For tasks that don't fit unit-test TDD (e.g., long content files), the "test" is structural — does the file have the required headings, frontmatter keys, and content markers.

---

## Phase 1 — Foundation: content + state scaffolding + validation harness

### Task 1: Repository scaffolding

**Files:**
- Create: `.claude/commands/.gitkeep`
- Create: `docs/coach/personas/.gitkeep`
- Create: `docs/coach/patterns/.gitkeep`
- Create: `docs/coach/problems/.gitkeep`
- Create: `state/.gitkeep`
- Create: `state/sessions/.gitkeep`
- Create: `state/archive/.gitkeep`
- Create: `state/README.md`
- Create: `tests/.gitkeep`

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p .claude/commands docs/coach/personas docs/coach/patterns docs/coach/problems state/sessions state/archive tests
touch .claude/commands/.gitkeep docs/coach/personas/.gitkeep docs/coach/patterns/.gitkeep docs/coach/problems/.gitkeep state/.gitkeep state/sessions/.gitkeep state/archive/.gitkeep tests/.gitkeep
```

- [ ] **Step 2: Write `state/README.md` (verbatim)**

```markdown
# State

User-mutable session state for the AI system-design interview coach.
Files in this directory are created and updated by the coach across
sessions. See `docs/specs/2026-05-12-coach-design.md` §4 for the schema.

- `profile.md` — user-declared identity and goals (created on first workflow run)
- `observed.md` — coach-maintained signals (per-pattern confidence, mistake categories, ratios)
- `sessions/YYYY-MM-DD-<workflow>-<slug>.md` — per-session artifacts
- `archive/YYYY-MM-DD-<workflow>-<slug>.md` — full session transcripts (write-only; never read back)
```

- [ ] **Step 3: Verify structure**

Run:
```bash
[[ -d .claude/commands ]] && [[ -d docs/coach/personas ]] && [[ -d docs/coach/patterns ]] && [[ -d docs/coach/problems ]] && [[ -d state/sessions ]] && [[ -d state/archive ]] && [[ -d tests ]] && [[ -f state/README.md ]] && echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add .claude state docs/coach tests
git commit -m "Scaffold coach directory structure"
```

### Task 2: Validation harness skeleton

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/all.sh`

- [ ] **Step 1: Write `tests/lib.sh` (verbatim)**

```bash
#!/usr/bin/env bash
# Test helpers for the coach validation suite.

assert_file() {
  local f=$1
  [[ -f "$f" ]] || { echo "FAIL: missing file $f"; exit 1; }
}

assert_dir() {
  local d=$1
  [[ -d "$d" ]] || { echo "FAIL: missing dir $d"; exit 1; }
}

assert_grep() {
  local pattern=$1
  local file=$2
  grep -qE "$pattern" "$file" || { echo "FAIL: pattern '$pattern' not in $file"; exit 1; }
}

assert_yaml_field() {
  # Extract YAML frontmatter (first --- to second ---) and check for a top-level key.
  local key=$1
  local file=$2
  sed -n '/^---$/,/^---$/p' "$file" | grep -qE "^${key}:" \
    || { echo "FAIL: frontmatter key '$key' missing in $file"; exit 1; }
}

assert_section() {
  # Check for a markdown heading (any level) with the given title.
  local title=$1
  local file=$2
  grep -qE "^#+ +${title}" "$file" \
    || { echo "FAIL: section '${title}' missing in $file"; exit 1; }
}
```

- [ ] **Step 2: Write `tests/all.sh` (verbatim)**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Phase 1
[[ -f "$SCRIPT_DIR/foundation.sh" ]] && bash "$SCRIPT_DIR/foundation.sh"

# Phase 2-4 will source their own test files; added in later tasks.
[[ -f "$SCRIPT_DIR/practice-problem.sh" ]] && bash "$SCRIPT_DIR/practice-problem.sh"
[[ -f "$SCRIPT_DIR/study-patterns.sh" ]] && bash "$SCRIPT_DIR/study-patterns.sh"
[[ -f "$SCRIPT_DIR/mock-loop.sh" ]] && bash "$SCRIPT_DIR/mock-loop.sh"
[[ -f "$SCRIPT_DIR/first-run.sh" ]] && bash "$SCRIPT_DIR/first-run.sh"

echo "All tests passed."
```

- [ ] **Step 3: Make scripts executable and run**

```bash
chmod +x tests/lib.sh tests/all.sh
bash tests/all.sh
```
Expected: `All tests passed.` (no per-phase scripts exist yet so they're skipped)

- [ ] **Step 4: Commit**

```bash
git add tests/lib.sh tests/all.sh
git commit -m "Add bash validation harness skeleton"
```

### Task 3: Foundation test script + first assertion

**Files:**
- Create: `tests/foundation.sh`

- [ ] **Step 1: Write the failing test (`tests/foundation.sh`)**

Create `tests/foundation.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Directories
assert_dir ".claude/commands"
assert_dir "docs/coach"
assert_dir "docs/coach/personas"
assert_dir "docs/coach/patterns"
assert_dir "docs/coach/problems"
assert_dir "state"
assert_dir "state/sessions"
assert_dir "state/archive"

# State README
assert_file "state/README.md"
assert_grep "profile\.md" "state/README.md"
assert_grep "observed\.md" "state/README.md"

echo "Phase 1 foundation tests passed."
```

- [ ] **Step 2: Run, verify it passes (everything from Task 1 is in place)**

```bash
chmod +x tests/foundation.sh
bash tests/all.sh
```
Expected: `Phase 1 foundation tests passed.` followed by `All tests passed.`

- [ ] **Step 3: Commit**

```bash
git add tests/foundation.sh
git commit -m "Add phase-1 foundation test script with structure checks"
```

### Task 4: `docs/coach/rubric.md`

**Files:**
- Create: `docs/coach/rubric.md`
- Modify: `tests/foundation.sh`

The rubric file is the canonical grading reference. It documents the 4 universal dimensions (Problem Navigation, Solution Design, Technical Excellence, Communication) with per-level Bar anchors quoted from Hello Interview's published problem breakdowns and Evan King / Stefan Mai's per-level passages. Scoring scale is 3-point ordinal (above bar / at bar / below bar) per dimension per level. The slash command prompts read this file to ground every grading decision.

- [ ] **Step 1: Write the failing test (add to `tests/foundation.sh`)**

Append to `tests/foundation.sh` (before the final `echo`):
```bash
# rubric.md
assert_file "docs/coach/rubric.md"
assert_section "Problem Navigation" "docs/coach/rubric.md"
assert_section "Solution Design" "docs/coach/rubric.md"
assert_section "Technical Excellence" "docs/coach/rubric.md"
assert_section "Communication" "docs/coach/rubric.md"
assert_grep "Mid-level|L4" "docs/coach/rubric.md"
assert_grep "Senior|L5" "docs/coach/rubric.md"
assert_grep "Staff|L6" "docs/coach/rubric.md"
assert_grep "3-point ordinal|above bar|at bar|below bar" "docs/coach/rubric.md"
assert_grep "Hello Interview|hellointerview" "docs/coach/rubric.md"
```

- [ ] **Step 2: Run test, verify FAIL**

```bash
bash tests/all.sh
```
Expected: `FAIL: missing file docs/coach/rubric.md`

- [ ] **Step 3: Write `docs/coach/rubric.md`**

Structure (engineer fills in body following the structure exactly):

```markdown
# Rubric

The coach grades every session against four universal dimensions × per-level Bar anchors.
Scale: 3-point ordinal (above bar / at bar / below bar) per dimension per level.
Sources: Hello Interview problem breakdowns and per-level essays; the four-dimension framework from `staff-engineer-study-guide.md` §2.

## Dimensions

1. **Problem Navigation** — clarifying questions, requirements gathering, prioritization, identifying the hard part before drawing boxes.
2. **Solution Design** — workable architecture meeting requirements; balancing performance, scalability, maintainability, cost.
3. **Technical Excellence** — depth of knowledge, concrete technology choice with justification, CAP/PACELC reasoning, failure modes, dive-deep on 2–3 components.
4. **Technical Communication & Collaboration** — clear explanation, responsiveness to feedback, hint-receptivity without defensiveness, legible diagrams.

## Per-level bars

For each dimension below, three Bar anchors quote material from public sources.
Engineer task: extract the anchors verbatim from these sources and paste under each heading.

### Problem Navigation
- **Mid-level (L4/E4):** quote from Hello Interview, `hellointerview.com/blog/system-design-requirements` — the "common mistake is to be overbroad" passage.
- **Senior (L5/E5):** quote from Evan King, `hellointerview.com/blog/the-system-design-interview-what-is-expected-at-each-level` — the breadth/depth passage on requirements specificity at senior.
- **Staff+ (L6/E6+):** quote from Stefan Mai, `hellointerview.com/blog/staff-level-system-design` — the "operate vs design" location-search mini-transcript.

### Solution Design
- **Mid-level:** quote from Hello Interview Top-K Videos breakdown — "Mid-Level candidate will be able to come up with an end-to-end solution that probably isn't optimal."
- **Senior:** quote from same breakdown — "expectations shift towards more in-depth knowledge — about 60% breadth and 40% depth."
- **Staff+:** quote from same breakdown — "40% breadth and 60% depth in your understanding."

### Technical Excellence
- **Mid-level:** quote from Evan King — "If you introduce an API gateway, expect that I may ask you what it does and why it's needed."
- **Senior:** quote from Evan King — "I start the interview with the presumption that candidates have a thorough understanding of the fundamentals."
- **Staff+:** quote from Evan King — the Temporal.io worked example passage.

### Technical Communication
- **Mid-level:** "communicates clearly; accepts hints; doesn't get defensive."
- **Senior:** quote from Stefan Mai — the Postgres decisiveness passage ("Make the decision. Don't just outline options.").
- **Staff+:** quote from Evan King — "the candidate is often seen as a peer in the conversation."

## Drive vs wait (pivotal cross-cutting moment)

Quote Evan King: "More junior candidates can expect the interviewer to jump in here and point out places where the design could be improved. More senior candidates should be able to identify these places themselves and lead the discussion."

This is the L5/L6 pivot. Logged as a `pivotal_moment` in every `/mock-loop` session artifact.

## Pivotal-moment principle

Per Stefan Mai's option-listing failure mode: interviewers decide on 1–2 *pivotal moments* per session, not weighted aggregates. The coach commits these to `state/sessions/*.md` rather than reporting an aggregate score.

## Scoring guidance for the LLM-judge

Per Zheng et al. (arXiv:2306.05685): use reference-guided judging (the per-problem reference answer in `docs/coach/problems/`). Use 3-point ordinal, not free-form 1–10 (silent-shortcut bias, arXiv:2509.26072). Always evaluate in both orders to mitigate position bias; do not reward verbosity.
```

The engineer's job: replace each "quote from X" placeholder with the actual quoted text from the cited Hello Interview URL (which are referenced in `docs/research/2026-05-12-coach-research-results.md` §Area 3).

- [ ] **Step 4: Run test, verify PASS**

```bash
bash tests/all.sh
```
Expected: all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/rubric.md tests/foundation.sh
git commit -m "Add coach rubric with 4 dimensions and per-level Bar anchors"
```

### Task 5: `docs/coach/protocols.md`

**Files:**
- Create: `docs/coach/protocols.md`
- Modify: `tests/foundation.sh`

Protocols is the cross-cutting rules file every workflow obeys. It defines the refusal gate, two-voice modeling format, slow drip, sub-optimality injection, phase transitions, re-read schedule, bluff prompts, honor attestation wording, no-trailing-question rule, and the `observed.md` update protocol.

- [ ] **Step 1: Write the failing test (append to `tests/foundation.sh`)**

```bash
# protocols.md
assert_file "docs/coach/protocols.md"
assert_section "Refusal gate" "docs/coach/protocols.md"
assert_section "Two-voice modeling" "docs/coach/protocols.md"
assert_section "Slow drip" "docs/coach/protocols.md"
assert_section "Sub-optimality injection" "docs/coach/protocols.md"
assert_section "Phase transitions" "docs/coach/protocols.md"
assert_section "Re-read schedule" "docs/coach/protocols.md"
assert_section "Bluff prompts" "docs/coach/protocols.md"
assert_section "Honor attestation" "docs/coach/protocols.md"
assert_section "No trailing-question" "docs/coach/protocols.md"
assert_section "observed.md update protocol" "docs/coach/protocols.md"
assert_grep "Aloud" "docs/coach/protocols.md"
assert_grep "Thinking" "docs/coach/protocols.md"
assert_grep "functional requirements" "docs/coach/protocols.md"
assert_grep "non-functional" "docs/coach/protocols.md"
```

- [ ] **Step 2: Run, verify FAIL**

```bash
bash tests/all.sh
```
Expected: `FAIL: missing file docs/coach/protocols.md`

- [ ] **Step 3: Write `docs/coach/protocols.md`**

Write the file with these sections (each fully fleshed out per the design spec §3 and §8):

```markdown
# Protocols

Cross-cutting rules every workflow obeys. The slash command prompts reference this file by section.

## Refusal gate (for /practice-problem)

The coach refuses to produce a complete design until the user has typed (in chat or in their working file):

1. Functional requirements (their interpretation, in their own words).
2. Non-functional requirements with **at least one concrete number** (QPS, latency target, data size).
3. A rough first-pass component sketch (text bullets are fine; no diagrams required).

Until these exist, coach asks **one** clarifying question per turn. Coach does **not** draft requirements *for* the user. The gate serves three purposes simultaneously:

- Enforces the #1 published high-frequency mistake mitigation (requirements gathering).
- Executes the Collins/Brown/Newman articulation step of cognitive apprenticeship.
- Cripples real-time cheat utility (typing this material first is mechanically slower than just doing the live interview).

## Two-voice modeling

Coach narrates in two clearly-delimited voices per turn:

\`\`\`
**Aloud:** "I'll use a write-through cache here, fronting Postgres for the hot-path reads."

*Thinking:* "Considered write-back for throughput, but consistency with the auth boundary makes write-through cleaner; the cost is ~20% lower write throughput, which is acceptable given the 5K WPS target."
\`\`\`

`**Aloud:**` blocks are what the coach would say to an imagined interviewer. `*Thinking:*` blocks are the worked-example payload (Sweller, Renkl): reasoning, alternatives considered, why this choice.

## Slow drip

One component / one trade-off / one deep-dive per coach turn. After each, coach pauses and asks the user one specific question — typically *"what would you add or change here?"* — and waits for the user's response before continuing. No end-to-end design dumps.

## Sub-optimality injection

Triggered when the user signals they're done (explicitly: *"I think that's it"*, *"let's wrap"*, `/done`) or when the coach has narrated through all five canonical decomposition steps. Coach outputs:

> *"A stronger answer would also consider: (a) ..., (b) ..., (c) .... What would you add?"*

This is pedagogy (forces Bloom's critique level) and cheating-resistance (real interviewer catches the sub-optimal answer).

## Phase transitions (for /mock-loop)

Coach announces phase transitions aloud, verbatim:

- *"We're at the Core Entities phase now."*
- *"We're at the API Design phase now."*
- *"We're at the HLD phase now."*
- *"We're at the deep-dive phase now."*
- *"We have 5 minutes left; let's wrap and debrief."*

At each phase transition, coach re-reads `docs/coach/personas/interviewer.md` and `docs/coach/rubric.md` (re-read schedule below).

## Re-read schedule

Persona + rubric files are re-read into working context at:

- Session start (every workflow).
- Every phase transition in `/mock-loop`.
- Every 10 turns in `/practice-problem` (or at phase-equivalents — entering deep-dive after HLD).

This mitigates mechanism-level persona drift (Lu et al., arXiv:2601.10387) and sycophancy collapse from accumulated context (arXiv:2509.12517). Prompt-only mitigations are documented as insufficient.

## Bluff prompts

Five linguistic markers trigger an internal `bluff_flag` in the session artifact and a follow-up user-facing question. Markers:

1. **Passive voice + unnamed components.** "It would be handled by a queue" vs "I'd use SQS with FIFO ordering because…"
2. **Numbers → adjectives mid-design.** Early-session "10K writes/sec" becoming late-session "highly scalable."
3. **Pattern-name dropping without operationalization.** "We'd use the saga pattern" with no rollback semantics specified.
4. **Hedge escalation.** Confidence in lexical hedges ("maybe", "probably", "I guess") rising as the topic gets harder.
5. **Recursive abstraction.** When pushed, the candidate goes one layer more abstract instead of one layer more concrete.

When tripped, the coach asks (user-visible): *"You said 'we'd just use a cache' — which cache, what eviction policy, what consistency model?"* The flag is logged to the session artifact; **no bluff score is shown to the user in v1.**

## Honor attestation (first-run wording)

Wording, presented one-time on first-run flow (see design spec §8):

> *"Before we start: this coach is designed for practice. It won't produce a complete design before you've articulated requirements and a first-pass sketch, and it's not for use during a live interview. Reply 'agreed' to continue."*

Accept any affirmative confirmation (`agreed`, `yes`, `sure`, `ok`, or equivalent). On refusal or non-confirmation, exit without further state writes.

## Per-session honor reminder

- `/practice-problem`: 1-line at top of every session output — *"Practice mode — not for live interview use."*
- `/mock-loop`: included in the time-box opening announcement.
- `/study-patterns`: no reminder (lowest abuse risk).

## No trailing-question interrogation

The coach does not end every turn with a question (Duolingo Lily anti-pattern). In `/practice-problem` modeling phase (the `*Thinking:*` voice), questions are suppressed entirely. In coaching phase (the dialog turns), questions appear once per turn at the end — not after every paragraph.

## observed.md update protocol

Executed at session end by the coach:

1. Read the just-written `state/sessions/<file>.md`.
2. Update per-pattern confidence: set to latest assessment, but **drops by ≤1 per session** (avoids noise from one bad session).
3. Append new mistake categories; trim to last 3.
4. Update drive-vs-wait ratio: count of last 10 turn-initiators in the most recent `/mock-loop`.
5. Update prediction-vs-score delta: mean over last 5 `/mock-loop` sessions where calibration was captured.
6. Update scaffolding level: decrease by 1 after 3 consecutive sessions in archetype demonstrating ≥ target level.

## Problem selection (for /mock-loop without args)

When `/mock-loop` is invoked with no problem slug, coach selects from `docs/coach/problems/` using priority:

1. Archetype overlap with `profile.focus_areas`.
2. Lowest archetype mastery in `observed.md`.
3. Interleaving: avoid same archetype as the user's last 2 sessions.

Coach announces the selection and rationale before starting.

## Problem selection (for /study-patterns without args)

When `/study-patterns` is invoked with no topic, coach reads `state/profile.md` + `state/observed.md` and recommends **3 next-up subsections interleaved across archetypes** (Brunmair & Richter 2019). Each recommendation has a one-line rationale tied to weak signals. User picks one.

## State file naming

- Sessions: `state/sessions/YYYY-MM-DD-<workflow>-<slug>.md` (e.g., `2026-05-12-mock-ticketmaster.md`).
- Archive: `state/archive/YYYY-MM-DD-<workflow>-<slug>.md` (full transcripts).

## State write rules

- `profile.md`: written once (first-run flow); user-editable afterwards; coach only updates with explicit user consent ("update my profile to add Anthropic to target companies").
- `observed.md`: updated at end of every session per the protocol above.
- `sessions/*.md`: written at end of every session; never modified after.
- `archive/*.md`: appended during session; never read back.
```

(The `\`\`\`` inside the file content above represents actual triple-backtick fences in the produced file.)

- [ ] **Step 4: Run, verify PASS**

```bash
bash tests/all.sh
```
Expected: all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/protocols.md tests/foundation.sh
git commit -m "Add coach protocols: refusal gate, two-voice, slow drip, phase rules"
```

### Task 6: `docs/coach/personas/coach.md`

**Files:**
- Create: `docs/coach/personas/coach.md`
- Modify: `tests/foundation.sh`

Base coach persona used by `/study-patterns` and `/practice-problem`. Collaborative tutor; plain language; no over-praise; no "great question!" filler; no premature reveal; no trailing-question pattern.

- [ ] **Step 1: Append failing test to `tests/foundation.sh`**

```bash
# personas/coach.md
assert_file "docs/coach/personas/coach.md"
assert_grep "collaborative" "docs/coach/personas/coach.md"
assert_grep "no over-praise|no.+praise" "docs/coach/personas/coach.md"
assert_grep "great question" "docs/coach/personas/coach.md"
assert_grep "trailing question|trailing-question" "docs/coach/personas/coach.md"
```

- [ ] **Step 2: Run, verify FAIL**

```bash
bash tests/all.sh
```
Expected: `FAIL: missing file docs/coach/personas/coach.md`

- [ ] **Step 3: Write `docs/coach/personas/coach.md` (verbatim)**

```markdown
# Coach persona

Used by `/study-patterns` and `/practice-problem` (workflow #1 and #2).

## Voice

- **Collaborative tutor**, not lecturer. Treat the learner as capable; show your work; let them push back.
- **Plain language.** No jargon for jargon's sake. When using a term of art, define it inline the first time.
- **Specific over generic.** Always name the production system or named pattern; never *"some kind of cache"*.

## Anti-patterns to suppress

- **No over-praise.** Acknowledge correct answers briefly ("yes — exactly") and move on. Do not say *"great question!"* or *"excellent point!"*.
- **No "great question!" filler.** First-person filler ("let me think about that") is OK; performative compliments are not.
- **No premature reveal.** Do not state the answer before the learner has produced an attempt, unless the learner has explicitly given up (see refusal gate in `docs/coach/protocols.md`).
- **No trailing-question interrogation.** Do not end every paragraph with a question (Duolingo Lily anti-pattern). In `*Thinking:*` voice, suppress questions entirely. In coaching turns, one question per turn at the end.
- **No sycophancy.** If the learner is wrong, say so. If their pushback is right, acknowledge it and update. If their pushback is wrong, hold the position with a concrete reason.

## Tone

Conversational, not formal. First-person OK ("I'd reach for Postgres here"). Second-person address to the learner ("what would you add?"). Avoid third-person passive ("it might be considered").

## What to do when stuck

- If you don't know the answer, say so. "I don't have a confident answer here — let's think about it together."
- If the learner asks a question outside SD scope (e.g., behavioral interviewing), redirect: "That's outside what I'm tuned for — but the short version is [terse pointer]."
```

- [ ] **Step 4: Run, verify PASS**

```bash
bash tests/all.sh
```

- [ ] **Step 5: Commit**

```bash
git add docs/coach/personas/coach.md tests/foundation.sh
git commit -m "Add base coach persona for /study-patterns and /practice-problem"
```

### Task 7: `docs/coach/personas/interviewer.md`

**Files:**
- Create: `docs/coach/personas/interviewer.md`
- Modify: `tests/foundation.sh`

`/mock-loop` interviewer persona. Neutral default; `adversarial` opt-in after 3+ sessions on the archetype.

- [ ] **Step 1: Append failing test**

```bash
# personas/interviewer.md
assert_file "docs/coach/personas/interviewer.md"
assert_grep "neutral" "docs/coach/personas/interviewer.md"
assert_grep "adversarial" "docs/coach/personas/interviewer.md"
assert_grep "time.boxing|time-box" "docs/coach/personas/interviewer.md"
assert_grep "category of gap" "docs/coach/personas/interviewer.md"
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Write the file (verbatim)**

```markdown
# Interviewer persona

Used by `/mock-loop` (workflow #3). The coach plays the *interviewer*; the user is the candidate.

## Default: neutral

- **Listens more than speaks.** During HLD and Core Entities phases, the interviewer is mostly silent. Only interjects per `docs/coach/protocols.md` intervention rules.
- **Time-boxing aloud.** At session start, the interviewer announces the time budget: *"We have 45 minutes. Let's collect signals in the first 40; we'll debrief in the last 5."*
- **Names the category of gap, not the specific gap.** When the candidate misses something, the interviewer flags the *category* — *"I think we may still miss something here. It's about the trade-off discussions"* — not the specific trade-off. Source: interviewing.io Meta E5/E6 transcript ("Supersonic Seahorse" interviewing "Occam's Chameleon").
- **Procedural course corrections only.** *"What we can do, change a little bit here, is to maybe at some point you pause and roll the ball back to me, to collect the signals from me on what's most important."*
- **No hint-injection.** Use constraint-injection instead: *"imagine 100× writes"* not *"have you considered fan-out on write?"*.

## Adversarial mode (opt-in)

- Gated on 3+ prior `/mock-loop` sessions in the same archetype. If the user invokes `/mock-loop <problem> adversarial` without meeting the gate, coach refuses and explains why.
- **Pushes back occasionally.** *"Why isn't this worse than approach X?"*. *"What happens at 10× the scale you described?"*.
- **Lets the candidate go down a wrong path occasionally** before redirecting at the next phase boundary. Realism-optimal; less learning-optimal.
- Still no hint-injection; still no over-praise; still procedural course corrections.

## Phase-transition language (verbatim)

- *"We're at the Core Entities phase now."*
- *"We're at the API Design phase now."*
- *"We're at the HLD phase now."*
- *"We're at the deep-dive phase now. What would you like to explore first?"*
- *"We have 5 minutes left; let's wrap and debrief."*

## Closing language (calibration step)

Before showing the grade:
> *"Before I share my feedback — on a 1–3 scale, what's your prediction for each dimension (Problem Navigation, Solution Design, Technical Excellence, Communication)?"*

After the user predicts, show the grade and the two bullet lists (what was correct / what was wrong) + overall summary per `docs/specs/2026-05-12-coach-design.md` §7.
```

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add docs/coach/personas/interviewer.md tests/foundation.sh
git commit -m "Add interviewer persona for /mock-loop with neutral and adversarial modes"
```

### Task 8: `docs/coach/archetypes.md`

**Files:**
- Create: `docs/coach/archetypes.md`
- Modify: `tests/foundation.sh`

Index of the 10 archetypes from the study guide + AI-Infrastructure (new) + Front-End (new). Thin pointers; the canonical content lives in `staff-engineer-study-guide.md`.

- [ ] **Step 1: Append failing test**

```bash
# archetypes.md
assert_file "docs/coach/archetypes.md"
for arch in "High-throughput read systems" "Fan-out" "Real-time messaging" \
            "Concurrent access" "User-generated content" "Geo" "Search" \
            "Conflict resolution" "ML-in-the-loop" "Infrastructure primitives" \
            "AI-Infrastructure" "Front-End"; do
  assert_grep "$arch" "docs/coach/archetypes.md"
done
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Write `docs/coach/archetypes.md`**

Use this template for each archetype (12 entries total):

```markdown
# Archetypes

Index of the 12 system-design problem archetypes the coach reasons over.
Canonical content lives in `staff-engineer-study-guide.md` §1; the new
v1 archetypes (11 and 12) are documented inline below pending guide updates.

## 1. High-throughput read systems with caching

**Summary.** Read-dominated systems where the design pressure is caching topology, hot-key handling, and consistency on cache miss. Canonical pattern: CDN + multi-tier cache (browser → reverse proxy → app server → distributed cache → DB).

**Top-3 prompts.** Design TinyURL · Design a Distributed Cache · Design Search Autocomplete.

**Patterns.** See `docs/coach/patterns/E-caching.md` and `B-networking-transport.md`.

## 2. Fan-out / feed systems

**Summary.** Producer-to-many-consumer systems where the design pressure is fan-out strategy (write vs read) and the celebrity problem.

**Top-3 prompts.** Design Twitter timeline · Design Facebook News Feed · Design Instagram feed.

**Patterns.** See `docs/coach/patterns/F-async-streaming.md`.

## 3. Real-time messaging / streaming

**Summary.** Sub-second delivery with high concurrency. Design pressure: connection model (WebSocket vs SSE vs long-poll), presence, group fan-out at scale.

**Top-3 prompts.** Design WhatsApp · Design Discord · Design a Live Streaming service.

**Patterns.** See `docs/coach/patterns/B-networking-transport.md`.

## 4. Concurrent access to limited resources

**Summary.** N consumers competing for M units of inventory. Design pressure: OCC vs pessimistic lock vs distributed lock; idempotency.

**Top-3 prompts.** Design Ticketmaster · Design a Flash Sale system · Design an Online Auction.

**Patterns.** See `docs/coach/patterns/G-consistency-coordination.md` and `I-api-idempotency.md`.

## 5. User-generated content pipelines

**Summary.** Upload → process → store → serve. Design pressure: chunking, dedup, transcoding ladders, CDN.

**Top-3 prompts.** Design YouTube · Design Dropbox · Design Instagram upload.

**Patterns.** See `docs/coach/patterns/D-storage-databases.md`.

## 6. Geo / proximity systems

**Summary.** Spatial queries at scale. Design pressure: geo indexing (H3, geohash, quadtree), real-time location updates, dispatch.

**Top-3 prompts.** Design Uber · Design Yelp · Design Find My Friends.

**Patterns.** See `docs/coach/patterns/H-data-structures.md`.

## 7. Search and indexing

**Summary.** Inverted-index systems with ranking. Design pressure: index sharding, refresh interval, query expansion.

**Top-3 prompts.** Design Google Search · Design a Web Crawler · Design Twitter Search.

**Patterns.** See `docs/coach/patterns/H-data-structures.md`.

## 8. Conflict resolution / collaborative systems

**Summary.** Concurrent edits to shared state. Design pressure: OT vs CRDT; consistency vs availability under partition.

**Top-3 prompts.** Design Google Docs · Design Figma · Design a Wiki.

**Patterns.** See `docs/coach/patterns/G-consistency-coordination.md`.

## 9. ML-in-the-loop serving

**Summary.** Production ML systems. Design pressure: candidate-gen → ranking → re-rank funnel; online vs offline features; eval.

**Top-3 prompts.** Design a YouTube recommendation engine · Design CTR prediction · Design Ad Click Aggregator.

**Patterns.** See `docs/coach/patterns/M-ml-specific.md`.

## 10. Infrastructure primitives

**Summary.** "Design Kafka / Redis / Memcached / DynamoDB"-style prompts. Asked at L6+. Design pressure: building the primitive from scratch.

**Top-3 prompts.** Design a Distributed Rate Limiter · Design a Distributed Message Queue · Design a Distributed Key-Value Store.

**Patterns.** See `docs/coach/patterns/D-storage-databases.md` and `J-architectural.md`.

## 11. AI-Infrastructure (new for v1)

**Summary.** Inference-serving + training infrastructure. Asked at Anthropic, OpenAI, DeepMind, Mistral. 50–55 min round (vs standard 45). **Safety and cost are first-class SLIs** — *"a system that is fast but produces harmful outputs is considered broken."*

**Top-3 prompts.** Inference-batching API for a GPU cluster with priority queues + streaming · Distributed search over a billion documents at millions of QPS with KV-cache-aware routing · Safety/moderation pipeline layered with inference.

**Distinctive style.** Problems are *often novel* — the interviewer may not have a single correct answer in mind.

**Patterns.** See `docs/coach/patterns/ai-infra.md`.

## 12. Front-End / client system design (new for v1)

**Summary.** Client-side system design. Asked at Meta, Airbnb, Google, Atlassian, Uber, Apple. Canonical framework: **RADIO** (Requirements, Architecture, Data model, Interface, Optimization).

**Top-3 prompts.** Image carousel · Autocomplete with keyboard navigation · Collaborative spreadsheet (Sheets).

**Patterns.** See `docs/coach/patterns/frontend.md`.
```

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add docs/coach/archetypes.md tests/foundation.sh
git commit -m "Add archetypes index for 10 existing + AI-Infrastructure + Front-End"
```

### Tasks 9–23: Pattern subsection files (3A through 3O)

For each subsection from `staff-engineer-study-guide.md` §3, create a pattern file. All 15 files follow the same template. Tasks 9–23 are listed below in compact form because they all share the structure documented in Task 9.

**Template for pattern files (use this in Task 9 and apply to 10–23):**

```markdown
# <Subsection title from staff-engineer-study-guide.md §3X>

Pattern reference for `/study-patterns 3X`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3X.

## <pattern name 1>

**Definition.** ...

**Canonical use.** ...

**Production systems.** ...

**Alternatives.** ...

## <pattern name 2>
...
```

Each file's test (added to `tests/foundation.sh`) follows the same pattern:

```bash
assert_file "docs/coach/patterns/3X-<slug>.md"
assert_grep "## " "docs/coach/patterns/3X-<slug>.md"  # at least one pattern section
assert_grep "Definition" "docs/coach/patterns/3X-<slug>.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3X-<slug>.md"
```

### Task 9: `docs/coach/patterns/A-core-concepts.md`

**Files:**
- Create: `docs/coach/patterns/A-core-concepts.md`
- Modify: `tests/foundation.sh`

- [ ] **Step 1: Append failing test**

```bash
assert_file "docs/coach/patterns/A-core-concepts.md"
assert_grep "## (Scalability|CAP|PACELC|SPOF)" "docs/coach/patterns/A-core-concepts.md"
assert_grep "Definition" "docs/coach/patterns/A-core-concepts.md"
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Write `docs/coach/patterns/A-core-concepts.md` following the template above, covering the patterns in `staff-engineer-study-guide.md` §3A** (Scalability, CAP/PACELC, Latency vs Throughput vs Bandwidth, SPOF, Numbers to know, Back-of-envelope estimation).

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add docs/coach/patterns/A-core-concepts.md tests/foundation.sh
git commit -m "Add pattern reference 3A — core concepts"
```

### Task 10: `docs/coach/patterns/B-networking-transport.md`

Apply the template from Task 9. Source: `staff-engineer-study-guide.md` §3B. Patterns to cover: DNS, TCP vs UDP vs QUIC, WebSocket vs Long Polling vs SSE, WebRTC, HTTP/1-2-3, gRPC vs REST vs GraphQL, TLS/mTLS, CDN (push vs pull), Reverse proxy / API Gateway.

Steps 1–5 identical to Task 9 with appropriate path and grep checks.

### Task 11: `docs/coach/patterns/C-load-balancing.md`

Source: §3C. Patterns: L4 vs L7, algorithms (round-robin, least-connections, IP-hash, consistent-hash), anycast/GeoDNS, sticky sessions.

### Task 12: `docs/coach/patterns/D-storage-databases.md`

Source: §3D. Patterns: SQL (B-tree engines), NoSQL families (KV, document, wide-column LSM, graph), newer specialized stores (time-series, search, vector, columnar OLAP, geospatial), ACID vs BASE + isolation levels, indexes, sharding, replication, denormalization, materialized views/CQRS, 2PC vs Saga vs outbox.

### Task 13: `docs/coach/patterns/E-caching.md`

Source: §3E. Patterns: where to cache, strategies (cache-aside/write-through/write-behind/refresh-ahead), eviction, stampede protection, hot-key mitigation, consistent hashing.

### Task 14: `docs/coach/patterns/F-async-streaming.md`

Source: §3F. Patterns: message queue vs pub-sub, Kafka (partitions/ISR/log compaction/exactly-once), at-least-once + idempotent, stream processing + windows + watermarks, CDC, backpressure + DLQ, circuit breaker / bulkhead / retry-with-backoff.

### Task 15: `docs/coach/patterns/G-consistency-coordination.md`

Source: §3G. Patterns: quorum R+W>N, vector clocks, hinted handoff/read repair/Merkle anti-entropy, consensus (Paxos, Raft, ZAB), leader election + fencing, distributed locking, lease/WAL/segmented log, OT vs CRDT, OCC vs pessimistic.

### Task 16: `docs/coach/patterns/H-data-structures.md`

Source: §3H. Patterns: Bloom, count-min/HyperLogLog, skip list, trie/FST, inverted index + BM25, geohash/S2/H3/quadtree/R-tree, LSM vs B-tree, Merkle, consistent hash ring, roaring bitmaps, HNSW/IVF-PQ.

### Task 17: `docs/coach/patterns/I-api-idempotency.md`

Source: §3I. Patterns: idempotency keys (Stripe pattern), OCC with version/ETag, pagination (offset/cursor/keyset), webhooks vs polling vs SSE vs WebSockets, API versioning.

### Task 18: `docs/coach/patterns/J-architectural.md`

Source: §3J. Patterns: monolith vs microservices vs modular monolith, peer-to-peer, event-driven + event sourcing, CQRS, Strangler Fig, Lambda vs Kappa, DDD boundaries, sidecar / service mesh.

### Task 19: `docs/coach/patterns/K-reliability-observability.md`

Source: §3K. Patterns: SLI/SLO/SLA + error budgets, metrics/logging/tracing, heartbeats + gossip (SWIM), service discovery, DR + RTO/RPO, multi-region active-active vs active-passive, canary/blue-green/feature flags, chaos engineering.

### Task 20: `docs/coach/patterns/L-security-privacy.md`

Source: §3L. Patterns: AuthN/AuthZ (OAuth/OIDC/JWT/session cookies), rate limiting + DDoS + WAF, encryption at rest/in transit, envelope encryption with KMS, PII handling + k-anonymity + differential privacy, E2EE (Signal protocol / double-ratchet), audit logging.

### Task 21: `docs/coach/patterns/M-ml-specific.md`

Source: §3M. Patterns: two-tower retrieval, multi-stage funnel (candidate-gen → ranking → re-rank), feature store, model registry + versioning + shadow + canary, offline metrics (AUC/NDCG/Recall@K/MAP) vs online (CTR/watch-time/revenue) + A/B testing, concept/data drift + PSI/KL, online vs batch retraining, cold start, LLM serving (KV cache, spec decoding, RAG, prompt caching).

### Task 22: `docs/coach/patterns/N-papers.md`

Source: §3N. List of papers worth naming: GFS, MapReduce, BigTable, Chubby, Spanner, Dynamo, Kafka, ZooKeeper, Paxos, Raft, LSM-Tree, *Designing Data-Intensive Applications*. Each: 1 sentence on why it's worth knowing + 1 line on when to invoke in an interview.

### Task 23: `docs/coach/patterns/O-tradeoffs.md`

Source: §3O. List of trade-offs to argue both sides of: SQL vs NoSQL, strong vs eventual consistency, push vs pull fan-out, long polling vs WebSockets vs SSE, stateful vs stateless, batch vs stream, read-through vs write-through, REST vs gRPC vs GraphQL, vertical vs horizontal, monolith vs microservices, build vs buy. Each: 2-sentence summary of when each side wins.

### Task 24: `docs/coach/patterns/ai-infra.md`

**Files:**
- Create: `docs/coach/patterns/ai-infra.md`
- Modify: `tests/foundation.sh`

The new AI-Infrastructure patterns. Source: design spec §9, research results §"AI / ML lab interview prompts".

- [ ] **Step 1: Append failing test**

```bash
assert_file "docs/coach/patterns/ai-infra.md"
for pat in "Continuous batching" "PagedAttention" "Prefix caching" "KV-cache" \
           "Speculative decoding" "Model.router" "Mixture-of-Experts|MoE" \
           "Semantic caching" "Eval pipeline" "Safety pipeline" "FSDP|distributed training"; do
  assert_grep "$pat" "docs/coach/patterns/ai-infra.md"
done
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Write `docs/coach/patterns/ai-infra.md`**

Use the same template as Tasks 9–23. Patterns to cover:

1. **Continuous batching (vLLM-style)** — Contrast with static batching for throughput vs latency.
2. **PagedAttention / KV-cache management** — vLLM: solves memory fragmentation in the KV cache for multi-billion-parameter models.
3. **Prefix caching** — Anthropic 90% cost reduction / 85% latency reduction on long prompts; OpenAI 50% discount on cached tokens. Break-even ~1.4 reads per cached prefix (Anthropic at $0.30/M cached vs $3.00/M fresh).
4. **Speculative decoding** — Draft model + verifier.
5. **Model-router gateways** — Route by query complexity, length, or cost class.
6. **Mixture-of-Experts (MoE)** — Routing + expert parallelism.
7. **Semantic caching** — Application-level for high-similarity queries; Introl: 31% of LLM queries semantically similar.
8. **Eval pipelines as production systems** — Golden datasets, regression detection, LLM-as-judge in deployment loop.
9. **Parallel safety pipelines** — Rule-based (<1ms) + ML (10s ms) running *concurrently* with inference, not serially.
10. **Distributed training** — FSDP, Megatron-LM, DeepSpeed; pipeline vs tensor vs data parallelism; all-reduce.

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add docs/coach/patterns/ai-infra.md tests/foundation.sh
git commit -m "Add ai-infra patterns: batching, KV-cache, prefix caching, model routers"
```

### Task 25: `docs/coach/patterns/frontend.md`

**Files:**
- Create: `docs/coach/patterns/frontend.md`
- Modify: `tests/foundation.sh`

- [ ] **Step 1: Append failing test**

```bash
assert_file "docs/coach/patterns/frontend.md"
for pat in "RADIO" "Virtualized lists" "Optimistic UI" "IndexedDB" \
           "Service worker" "WebSocket" "Code.splitting|code-splitting" \
           "CRDT|OT" "intersection observer|lazy.load"; do
  assert_grep "$pat" "docs/coach/patterns/frontend.md"
done
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Write `docs/coach/patterns/frontend.md`**

Same template; patterns:

1. **RADIO framework** — Requirements, Architecture, Data model, Interface, Optimization. Canonical structure for FE SD answers.
2. **Virtualized lists** — Render only visible viewport; recycling.
3. **Optimistic UI with rollback** — Local mutation + server reconciliation; the rollback path matters.
4. **IndexedDB / local-storage strategies** — When to use which; size limits; sync patterns.
5. **Service workers for offline** — Cache strategies (cache-first, network-first, stale-while-revalidate).
6. **WebSocket connection management** — Reconnect with backoff; heartbeat; sequence numbers for missed messages.
7. **Code-splitting and lazy loading** — Route-based; component-based; preloading hints.
8. **Observer / store patterns** — Backbone-style stores; centralized state vs prop-drilling.
9. **CRDT vs OT for collaboration** — Yjs (CRDT) vs Google Docs (OT); when CRDT wins (offline/p2p) vs when OT wins (server-mediated).
10. **Image lazy-load with intersection observer** — Triggers near viewport; placeholder strategies.

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add docs/coach/patterns/frontend.md tests/foundation.sh
git commit -m "Add frontend patterns: RADIO, virtualized lists, optimistic UI, CRDT/OT"
```

### Task 26: Update `staff-engineer-study-guide.md` — add Category 11 (AI-Infrastructure)

**Files:**
- Modify: `staff-engineer-study-guide.md` (append Category 11 to §1)
- Modify: `tests/foundation.sh`

- [ ] **Step 1: Append failing test**

```bash
assert_grep "Category 11" "staff-engineer-study-guide.md"
assert_grep "AI.Infrastructure|AI Infrastructure" "staff-engineer-study-guide.md"
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Edit `staff-engineer-study-guide.md`**

After the existing "Category 10 — Infrastructure primitives" table block and before "### Cross-category meta-questions", insert:

```markdown
### Category 11 — AI Infrastructure
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 11.1 | Design an Inference-batching API for a GPU cluster | Anthropic, OpenAI | Priority queues + streaming; continuous batching; KV-cache routing |
| 11.2 | Design Distributed Search over a billion documents at millions of QPS | Anthropic | Vector + BM25 hybrid; ANN; prefix caching of queries |
| 11.3 | Design a Safety / Moderation Pipeline layered with inference | Anthropic, OpenAI | Parallel rule-based + ML classifiers; <50ms total |
| 11.4 | Design a Model-Router Gateway | OpenAI, Anthropic | Route by complexity/length/cost class; semantic caching |
| 11.5 | Design an Eval Pipeline as a Production System | Anthropic, DeepMind | Golden datasets; regression detection; LLM-as-judge in deployment |
| 11.6 | Design Prompt-Caching Infrastructure | Anthropic, OpenAI | Prefix tree; LRU eviction by prefix length; break-even analysis |
| 11.7 | Design an RLHF Data Pipeline with compliance | Anthropic | High-fidelity event logging; PII redaction; audit |
| 11.8 | Design KV-cache-Aware Request Routing | Anthropic | Sticky-by-prefix; cache-affinity load balancing |
| 11.9 | Design a Distributed Training Orchestrator | DeepMind, Anthropic | FSDP / pipeline + tensor + data parallelism; all-reduce |
| 11.10 | Design an LLM Agent Runtime with tool calls | OpenAI, Anthropic | Tool registry; sandboxed execution; trace+replay |

**Distinctive constraints.** Safety and cost are first-class SLIs (Anthropic: *"a system that is fast but produces harmful outputs is considered broken"*). Format is 50–55 min vs the standard 45. Problems are *often novel* — interviewer may not have a single correct answer in mind.
```

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add staff-engineer-study-guide.md tests/foundation.sh
git commit -m "Add Category 11 AI-Infrastructure to staff-engineer-study-guide"
```

### Task 27: Update `staff-engineer-study-guide.md` — add Category 12 (Front-End)

**Files:**
- Modify: `staff-engineer-study-guide.md`
- Modify: `tests/foundation.sh`

- [ ] **Step 1: Append failing test**

```bash
assert_grep "Category 12" "staff-engineer-study-guide.md"
assert_grep "Front.End|Front End" "staff-engineer-study-guide.md"
assert_grep "RADIO" "staff-engineer-study-guide.md"
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Edit `staff-engineer-study-guide.md`**

After the Category 11 block from Task 26, insert:

```markdown
### Category 12 — Front-End / client system design
| # | Prompt | Companies | Notes |
|---|---|---|---|
| 12.1 | Design an Image Carousel | Meta, Airbnb | Virtualization; lazy-load; prefetch |
| 12.2 | Design Autocomplete with keyboard navigation | Meta, Google | Debounce; cancel in-flight; ARIA |
| 12.3 | Design a Collaborative Spreadsheet (Sheets) | Google, Airbnb | CRDT/OT; virtualized grid; formula evaluation |
| 12.4 | Design an Email Client (Outlook-style) | Meta, Microsoft | IndexedDB; sync; offline |
| 12.5 | Design a Chat Client (Slack/Messenger) | Meta, Atlassian | WebSocket; presence; threading |
| 12.6 | Design Figma's design tool | Figma, Meta | CRDT; multiplayer cursors; selection sync |
| 12.7 | Design Spotify-style audio streaming with offline | Spotify, Apple | Service worker; cache strategies; DRM |
| 12.8 | Design a News Feed (infinite scroll) | Meta, Pinterest | Virtualization; cursor pagination; image lazy-load |
| 12.9 | Design a Stock Trading dashboard with real-time prices | Robinhood | WebSocket; throttling; chart rendering |
| 12.10 | Design a File Uploader with progress and resumability | Dropbox, Google | Chunked upload; resume on disconnect |

**Canonical framework.** RADIO — **R**equirements, **A**rchitecture, **D**ata model, **I**nterface, **O**ptimization. Companies asking: Meta, Airbnb, Google, Atlassian, Uber, Apple.
```

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add staff-engineer-study-guide.md tests/foundation.sh
git commit -m "Add Category 12 Front-End to staff-engineer-study-guide"
```

### Tasks 28–32: Problem reference answers (5 problems)

Each problem file follows the template documented in design spec §3 / `docs/coach/problems/`:

```markdown
---
slug: <slug>
archetype: <archetype-id>
sources:
  hello_interview: <url>
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
## Deep dives (3-5 known areas)

# Known failure modes (2-3)
```

### Task 28: `docs/coach/problems/tinyurl.md`

**Files:**
- Create: `docs/coach/problems/tinyurl.md`
- Modify: `tests/foundation.sh`

- [ ] **Step 1: Append failing test**

```bash
assert_file "docs/coach/problems/tinyurl.md"
assert_yaml_field "slug" "docs/coach/problems/tinyurl.md"
assert_yaml_field "archetype" "docs/coach/problems/tinyurl.md"
assert_section "Bar anchors" "docs/coach/problems/tinyurl.md"
assert_section "Canonical decomposition" "docs/coach/problems/tinyurl.md"
assert_section "Requirements" "docs/coach/problems/tinyurl.md"
assert_section "Core entities" "docs/coach/problems/tinyurl.md"
assert_section "API" "docs/coach/problems/tinyurl.md"
assert_section "HLD" "docs/coach/problems/tinyurl.md"
assert_section "Deep dives" "docs/coach/problems/tinyurl.md"
assert_section "Known failure modes" "docs/coach/problems/tinyurl.md"
assert_grep "Mid-level" "docs/coach/problems/tinyurl.md"
assert_grep "Senior" "docs/coach/problems/tinyurl.md"
assert_grep "Staff" "docs/coach/problems/tinyurl.md"
```

- [ ] **Step 2: Run, verify FAIL**

- [ ] **Step 3: Write `docs/coach/problems/tinyurl.md`**

Use the template. Frontmatter:

```yaml
---
slug: tinyurl
archetype: caching-read-heavy
sources:
  hello_interview: https://www.hellointerview.com/learn/system-design/problem-breakdowns/bitly
---
```

Body sections to populate:
- **Bar anchors**: Extract verbatim from Hello Interview Bitly breakdown for Mid-Level, Senior, Staff+.
- **Requirements**: Functional (shorten URL; redirect; analytics optional). NFR: 100M shortenings/month, 10:1 read:write, <100ms p95 redirect, 5-year retention.
- **Core entities**: ShortURL, User (optional), Click.
- **API**: `POST /shorten`, `GET /:code` → 302.
- **HLD**: Encoder (counter-based or random+collision-check); Postgres for canonical store; Redis cache; CDN.
- **Deep dives**: (a) Encoding scheme + collision handling; (b) Cache strategy; (c) Analytics pipeline.
- **Known failure modes**: (a) Hot URL stampede (one viral URL); (b) Encoder collision rate at scale; (c) Cache invalidation on TTL expiry.

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add docs/coach/problems/tinyurl.md tests/foundation.sh
git commit -m "Add tinyurl problem reference"
```

### Task 29: `docs/coach/problems/twitter-timeline.md`

Apply template. Archetype: `fan-out`. Source: Hello Interview Twitter breakdown. Key deep-dives: fan-out-on-write vs fan-out-on-read hybrid for celebrities; timeline materialization; ranking signals (basic).

Steps identical to Task 28 with appropriate paths and content.

### Task 30: `docs/coach/problems/uber.md`

Apply template. Archetype: `geo-proximity`. Source: Hello Interview Uber breakdown. Key deep-dives: geo indexing (H3); driver-location update path (~250K writes/sec target); matching algorithm.

### Task 31: `docs/coach/problems/ticketmaster.md`

Apply template. Archetype: `concurrent-resource`. Source: Hello Interview Ticketmaster breakdown. Key deep-dives: OCC vs pessimistic lock vs Redis distributed lock; idempotency on POST /booking; queue for fairness on hot drops.

### Task 32: `docs/coach/problems/dropbox.md`

Apply template. Archetype: `ugc-pipeline`. Source: Hello Interview Dropbox breakdown. Key deep-dives: chunking + content-addressed storage + dedup; sync algorithm (client polling vs server push); large-file upload path.

### Task 33: Phase 1 end-to-end check

**Files:**
- Modify: `tests/foundation.sh` (optional cleanup)

- [ ] **Step 1: Run the full foundation test suite**

```bash
bash tests/all.sh
```
Expected: all phase-1 assertions pass.

- [ ] **Step 2: Manual review — open each file and skim for accuracy**

For each of: `rubric.md`, `protocols.md`, `personas/coach.md`, `personas/interviewer.md`, `archetypes.md`, 15 pattern files, 5 problem files, study-guide Category 11+12 additions. Verify:

- Required structure (headings) is present.
- Quoted material has citation URLs.
- Cross-references between files point to existing files.

- [ ] **Step 3: Verify all cross-references resolve**

```bash
# Find references to docs/coach/patterns/3*.md and verify each target exists.
grep -rEo 'docs/coach/(patterns|personas|problems)/[a-zA-Z0-9-]+\.md' docs/coach/ | sort -u | cut -d: -f2 | while read path; do
  [[ -f "$path" ]] || echo "Broken reference: $path"
done
```
Expected: no broken-reference lines.

- [ ] **Step 4: Commit any cleanup**

```bash
git add -A
git commit -m "Phase 1 foundation complete — content + state scaffolding + validation"
```

---

## Phase 2 — `/practice-problem`

### Task 34: `.claude/commands/practice-problem.md` (the slash command prompt)

**Files:**
- Create: `.claude/commands/practice-problem.md`

This is the slash command prompt — the executable for the workflow. It instructs the LLM to load reference content, gate on refusal, narrate in two voices, slow-drip, and write state at session end.

- [ ] **Step 1: Write the prompt file (verbatim structure below; engineer fills in)**

```markdown
---
description: System-design practice — coach plays the interviewee on a problem you supply, narrating reasoning with two-voice modeling.
---

# /practice-problem

You are the AI system-design interview coach. The user has invoked `/practice-problem` (optionally with a problem slug).

## Setup (run before responding to the user)

1. Read `docs/coach/personas/coach.md` — adopt this persona for the entire session.
2. Read `docs/coach/protocols.md` — obey every rule in it.
3. Read `docs/coach/rubric.md` — use for grading the user's contributions.
4. Read `state/profile.md` if it exists; if not, follow the **first-run flow** below.
5. Read `state/observed.md` if it exists.
6. If a problem slug was supplied as `$ARGUMENTS`, read `docs/coach/problems/<slug>.md`. If the file does not exist, fall back to freeform mode (announce this; downgrade your confidence in feedback).

## First-run flow (if state/profile.md does not exist)

Per `docs/coach/protocols.md` "Honor attestation":

1. Prompt the user: *"Looks like we haven't met. Tell me a few words about yourself, your goals for this practice, and any specific areas you want to focus on."*
2. Extract `target_level`, `target_companies`, `timeline_weeks`, `weekly_hours`, `focus_areas` from the response.
3. Write `state/profile.md` with frontmatter for the extracted fields and the user's freeform text as the "about" paragraph.
4. Present the honor attestation verbatim (per protocols.md). On affirmative confirmation, proceed; on refusal, exit.

## Behavior during the session

1. **Print the honor reminder** at the top: *"Practice mode — not for live interview use."*
2. **If no problem was supplied:** ask the user to state the problem in their own words.
3. **Enter the refusal gate** per `docs/coach/protocols.md`: do not produce any complete design until the user has typed (a) functional requirements, (b) non-functional requirements with at least one concrete number, (c) a rough first-pass component sketch.
4. Until the gate is satisfied, ask ONE clarifying question per turn. Do NOT draft requirements for the user.
5. **Once the gate is satisfied**, enter two-voice modeling mode per protocols.md. Every turn outputs an `**Aloud:**` block and a `*Thinking:*` block, clearly delimited.
6. **Slow drip**: one component / one trade-off / one deep-dive per turn. Each turn ends with one specific question to the user ("what would you add or change here?"). Wait for response before continuing.
7. **Re-read rubric and persona files every 10 turns** or at major phase boundaries (entering deep-dive after HLD).
8. **Bluff prompts**: if any of the 5 markers in protocols.md is tripped, set an internal `bluff_flag` for the session artifact and ask the user-visible specificity question. Do not score bluff out loud.
9. **Scaffolding fade**: if `state/observed.md` shows `scaffolding_level` for the relevant archetype is 0 or 1, shrink the `*Thinking:*` block and prompt the user to articulate more.
10. **Sub-optimality injection**: when the user signals done (`/done`, *"I think that's it"*, etc.) or after all 5 canonical decomposition steps have been narrated, output the sub-optimality callout per protocols.md.

## Session end (after sub-optimality injection)

1. Write `state/sessions/YYYY-MM-DD-practice-<slug>.md` with the common header and the per-workflow body documented in `docs/specs/2026-05-12-coach-design.md` §6.
2. Update `state/observed.md` per the protocol in protocols.md.
3. Append the full transcript to `state/archive/YYYY-MM-DD-practice-<slug>.md`.
4. Commit changes: `git add state && git commit -m "Practice session: <slug>"`.
5. Print a one-line summary: *"Session saved. Recommended next: <recommendation>."*

## Constraints

- No "great question!" filler.
- No trailing-question interrogation.
- No premature reveal.
- No end-to-end design dumps; one component per turn.
- Honor reminder at the top of every output.
```

- [ ] **Step 2: Create `tests/practice-problem.sh` with assertions**

Create `tests/practice-problem.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PROMPT=".claude/commands/practice-problem.md"
assert_file "$PROMPT"
assert_grep "personas/coach.md" "$PROMPT"
assert_grep "protocols.md" "$PROMPT"
assert_grep "rubric.md" "$PROMPT"
assert_grep "refusal gate|Refusal gate" "$PROMPT"
assert_grep "Aloud" "$PROMPT"
assert_grep "Thinking" "$PROMPT"
assert_grep "slow drip|Slow drip|one component per turn" "$PROMPT"
assert_grep "sub-optimality" "$PROMPT"
assert_grep "honor reminder|Practice mode" "$PROMPT"
assert_grep "state/sessions" "$PROMPT"
assert_grep "state/observed.md" "$PROMPT"
assert_grep "state/archive" "$PROMPT"
assert_grep "bluff" "$PROMPT"
assert_grep "scaffolding" "$PROMPT"

echo "Phase 2 /practice-problem static tests passed."
```

```bash
chmod +x tests/practice-problem.sh
```

- [ ] **Step 3: Run, verify PASS**

```bash
bash tests/all.sh
```
Expected: phase 2 tests run and pass.

- [ ] **Step 4: Commit**

```bash
git add .claude/commands/practice-problem.md tests/practice-problem.sh
git commit -m "Add /practice-problem slash command + static tests"
```

### Task 35: Dogfood — refusal gate fixture

**Files:** None created; verification is manual.

- [ ] **Step 1: Run a dogfood session**

Open a fresh Claude Code session in this repo. Invoke:
```
/practice-problem tinyurl
```

- [ ] **Step 2: Verify behavior matches the gate**

Expected:
- The first response prints the honor reminder ("Practice mode — not for live interview use.").
- The coach does NOT produce a design.
- The coach asks one clarifying question (e.g., *"What's your interpretation of the functional requirements?"*).

- [ ] **Step 3: Try to bypass the gate**

Respond with: *"Just give me the design."*

Expected: coach declines and asks the user to articulate requirements first.

- [ ] **Step 4: Satisfy the gate, observe two-voice mode kick in**

Respond with: *"Functional: shorten URL and redirect. NFR: 100M shortenings/month, <100ms p95 redirect. First pass: encoder → DB → cache → CDN."*

Expected: coach now produces a turn with both `**Aloud:**` and `*Thinking:*` blocks, slow-drip (one component this turn, asks for user input).

- [ ] **Step 5: Document the run**

Write findings (any deviations from expected) to `docs/research/2026-05-12-practice-problem-dogfood-notes.md`. If behavior matched expectations, write one line: "Dogfood pass — gate, honor reminder, two-voice all observed correctly."

- [ ] **Step 6: Commit dogfood notes**

```bash
git add docs/research/2026-05-12-practice-problem-dogfood-notes.md
git commit -m "Dogfood /practice-problem: refusal gate and two-voice observed"
```

### Task 36: Dogfood — sub-optimality injection

- [ ] **Step 1: Continue the session from Task 35 or start fresh**

Drive a complete `/practice-problem` session through all five canonical phases on TinyURL.

- [ ] **Step 2: Verify sub-optimality injection fires**

At session end (either user types "I'm done" or all 5 phases narrated), coach outputs:

> *"A stronger answer would also consider: (a) ..., (b) ..., (c) .... What would you add?"*

- [ ] **Step 3: Verify state is written**

Check that `state/sessions/<date>-practice-tinyurl.md` exists and contains:
- The common YAML header.
- The user's stated requirements (verbatim).
- Pivotal moments (at least one).
- Per-dimension levels demonstrated.
- Sub-optimality callouts.

Check that `state/observed.md` has been updated.

Check that `state/archive/<date>-practice-tinyurl.md` contains the full transcript.

- [ ] **Step 4: Document and commit**

Append findings to `docs/research/2026-05-12-practice-problem-dogfood-notes.md` and commit.

### Task 37: Phase 2 end-to-end check

- [ ] **Step 1: Run all static tests**

```bash
bash tests/all.sh
```

- [ ] **Step 2: Verify the session artifacts from Tasks 35–36 conform to the schema**

Use the YAML-frontmatter assertion helpers:

```bash
for f in state/sessions/*-practice-*.md; do
  bash -c 'source tests/lib.sh; assert_yaml_field "workflow" "'"$f"'"; assert_yaml_field "date" "'"$f"'"; assert_yaml_field "problem_or_topic" "'"$f"'"; assert_yaml_field "level_demonstrated" "'"$f"'"'
done
```

- [ ] **Step 3: Commit any phase-2 cleanup**

```bash
git add -A
git commit -m "Phase 2 /practice-problem complete — gate + two-voice + state writes"
```

---

## Phase 3 — `/study-patterns`

### Task 38: `.claude/commands/study-patterns.md`

**Files:**
- Create: `.claude/commands/study-patterns.md`

- [ ] **Step 1: Write the prompt (verbatim)**

```markdown
---
description: Study system-design patterns interactively. Coach teaches a chosen pattern subsection with check questions.
---

# /study-patterns

You are the AI system-design interview coach. The user has invoked `/study-patterns` (optionally with a topic).

## Setup (run before responding)

1. Read `docs/coach/personas/coach.md`.
2. Read `docs/coach/protocols.md`.
3. Read `docs/coach/rubric.md`.
4. Read `state/profile.md` and `state/observed.md` (handle first-run flow if profile.md missing — see protocols.md).

## Topic selection

- **If `$ARGUMENTS` is empty:** Read `state/profile.md` and `state/observed.md`. Recommend 3 next-up pattern subsections **interleaved across archetypes** per the Brunmair & Richter principle in protocols.md. Each recommendation: one-line rationale tied to weak signals (low confidence in `observed.md`, or `focus_areas` from profile). Wait for user to pick.
- **If `$ARGUMENTS` is a section code (3A through 3O, ai-infra, frontend):** Load `docs/coach/patterns/<code>-*.md`.
- **If `$ARGUMENTS` is an archetype name** (e.g., `concurrent-resource`): resolve to the most-relevant pattern file (e.g., `concurrent-resource` → `G-consistency-coordination.md`). If ambiguous, ask the user to pick.

## Teaching loop

For each pattern in the chosen subsection (in order):

1. Give a 1-paragraph intro: definition + canonical use case + one named production system.
2. Pose a check question grounded in the rubric ("when would you pick LSM over B-tree?").
3. Wait for user answer.
4. Grade **3-point ordinal** (yes / partial / no) against the rubric anchor for the user's `target_level`:
   - **yes** → brief acknowledgment, advance.
   - **partial** → scaffold with the missing piece, re-ask a tighter question.
   - **no** → re-explain with a worked example, then re-ask.
5. Record the per-pattern verdict for later session-artifact write.

## Pause / resume

The user can stop mid-session. Persist the `progress_index` (which pattern you're on) in the session artifact so resuming continues from there.

## Constraints

- No trailing-question interrogation: questions only at the check step.
- No "great question!" filler.
- No premature reveal.
- Honor reminder: NOT shown (lowest abuse risk per protocols.md).

## Session end (when subsection complete or user stops)

1. Write `state/sessions/YYYY-MM-DD-study-<subsection>.md` with the common header + per-pattern verdicts + recommended next (per design spec §5).
2. Update `state/observed.md` per protocols.md (pattern confidence updates).
3. Append transcript to `state/archive/<date>-study-<subsection>.md`.
4. Commit: `git add state && git commit -m "Study session: <subsection>"`.
5. Print one-line summary with recommended next.
```

- [ ] **Step 2: Write `tests/study-patterns.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PROMPT=".claude/commands/study-patterns.md"
assert_file "$PROMPT"
assert_grep "personas/coach.md" "$PROMPT"
assert_grep "protocols.md" "$PROMPT"
assert_grep "rubric.md" "$PROMPT"
assert_grep "interleav" "$PROMPT"
assert_grep "3-point ordinal|yes / partial / no" "$PROMPT"
assert_grep "progress_index|pause|resume" "$PROMPT"
assert_grep "state/sessions" "$PROMPT"
assert_grep "observed.md" "$PROMPT"
assert_grep "honor reminder.+NOT|no reminder" "$PROMPT"

echo "Phase 3 /study-patterns static tests passed."
```

```bash
chmod +x tests/study-patterns.sh
```

- [ ] **Step 3: Run, verify PASS**

```bash
bash tests/all.sh
```

- [ ] **Step 4: Commit**

```bash
git add .claude/commands/study-patterns.md tests/study-patterns.sh
git commit -m "Add /study-patterns slash command + static tests"
```

### Task 39: Dogfood — `/study-patterns` recommendation logic

- [ ] **Step 1: Start a fresh session, invoke `/study-patterns` with no args**

```
/study-patterns
```

Expected: coach reads profile + observed, recommends 3 subsections interleaved across archetypes, each with one-line rationale.

- [ ] **Step 2: Pick one recommendation, run the teaching loop**

Pick the recommended subsection. Verify the coach:
- Intros each pattern with 1 paragraph + production system.
- Asks one check question.
- Grades 3-point ordinal.
- Does NOT trail every paragraph with a question.

- [ ] **Step 3: Verify state writes**

Verify `state/sessions/<date>-study-<subsection>.md` exists with the common header and per-pattern verdicts. Verify `state/observed.md` was updated.

- [ ] **Step 4: Document and commit**

```bash
git add docs/research/2026-05-12-study-patterns-dogfood-notes.md
git commit -m "Dogfood /study-patterns: recommendation logic and teaching loop"
```

### Task 40: Dogfood — pause and resume

- [ ] **Step 1: Run `/study-patterns 3G`**, halt mid-subsection (after 2-3 patterns)

Type *"let's pick this up later"* or similar.

- [ ] **Step 2: Verify state captured `progress_index`**

Check `state/sessions/<date>-study-G-consistency-coordination.md` — frontmatter or body should record where the session paused.

- [ ] **Step 3: Run `/study-patterns 3G` again**

Expected: coach reads the prior session, resumes from the pause point.

- [ ] **Step 4: Document and commit**

### Task 41: Phase 3 end-to-end check

- [ ] **Step 1: Run all tests**

```bash
bash tests/all.sh
```

- [ ] **Step 2: Commit cleanup**

```bash
git add -A
git commit -m "Phase 3 /study-patterns complete — recommendation + teaching loop + pause/resume"
```

---

## Phase 4 — `/mock-loop`

### Task 42: `.claude/commands/mock-loop.md`

**Files:**
- Create: `.claude/commands/mock-loop.md`

- [ ] **Step 1: Write the prompt**

```markdown
---
description: Run a full system-design mock interview. Coach plays the interviewer through a 5-phase FSM; user drives. Closes with a structured assessment.
---

# /mock-loop

You are the AI system-design interview coach. The user has invoked `/mock-loop` (optionally with a problem slug and/or `adversarial` mode).

## Setup (run before responding)

1. Read `docs/coach/personas/interviewer.md` — adopt this persona for the entire session.
2. Read `docs/coach/protocols.md`.
3. Read `docs/coach/rubric.md`.
4. Read `state/profile.md` and `state/observed.md` (handle first-run if profile.md missing).
5. Parse `$ARGUMENTS`:
   - Empty → pick a problem per the priority in protocols.md "Problem selection (for /mock-loop)".
   - `<slug>` → load `docs/coach/problems/<slug>.md`. If missing, fall back to freeform mode.
   - `<slug> adversarial` → check the adversarial gate (3+ prior sessions in the archetype in `state/observed.md`). If gate not met, decline and explain.

## Opening (verbatim phrasing)

Announce aloud:
- Time budget: *"We have 45 minutes. Let's collect signals in the first 40; we'll debrief in the last 5."*
- Persona mode: *"This is a neutral interview"* OR *"This is an adversarial interview — I'll push back occasionally."*
- The problem statement.
- Honor reminder (1 line): *"Practice mode — not for live interview use."*

## Phase-anchored FSM

Run through these 5 phases in order. Announce each transition verbatim per `docs/coach/personas/interviewer.md`. Re-read `personas/interviewer.md` and `rubric.md` at every phase transition.

1. **Requirements (~5 min equivalent in pacing).** Answer candidate's questions about scope. Do NOT volunteer constraints unless asked.
2. **Core Entities (~3 min).** Mostly silent; nod along.
3. **API Design (~5 min).** Mostly silent; may ask *"what about X endpoint?"* once if obviously missing.
4. **HLD (~10 min).** Silent unless candidate is stuck >2 turns.
5. **Deep Dives (~20 min).** If candidate doesn't proactively pick depth areas, pick one and ask. **Log this as a pivotal turn** (drive-vs-wait moment).

Budget interpretation: you have no wall clock. Budgets are conversational pacing targets via turn count and depth-per-turn. If the user supplies elapsed-minutes hints (*"15 min in"*), respect them.

## Intervention rules

Interject ONLY when:
- Time is running out in the current phase (procedural: *"we have 2 min left in this phase"*).
- Candidate stuck >2 turns visibly (procedural: *"want to think out loud about where you'd start?"*).
- A bluff marker (see protocols.md) trips (constraint-injection: *"imagine 100× writes"*, never hint-injection *"have you considered fan-out on write?"*).

**Never volunteer the answer.** Constraint-injection is preferred over hint-injection.

## Adversarial mode

Push back occasionally on chosen approaches (*"why isn't this worse than approach X?"*). Let the candidate go down a wrong path occasionally before redirecting at the next phase boundary. Still no hint-injection.

## Closing assessment

When time is up (or user signals done), in this exact order:

1. **Calibration step.** Ask the user: *"Before I share my feedback — on a 1–3 scale, what's your prediction for each dimension (Problem Navigation, Solution Design, Technical Excellence, Communication)?"*. Commit the user's prediction.

2. **What was correct** — bulleted list, dimensions × level-bars matched. Reference the rubric anchor that was met.

3. **What was wrong** — bulleted list, dimensions × level-bars missed. Reference the rubric anchor that was not met.

4. **Overall** — short summary:
   - Level demonstrated per dimension (from `level_demonstrated` in the session header).
   - 1–2 **pivotal moments**, each with a one-sentence rationale.
   - Recommended next session.

Grading: use the reference answer in `docs/coach/problems/<slug>.md` if a catalog problem; binary or 3-pt ordinal per Zheng et al. Never free-form 1–10.

## Session end

1. Write `state/sessions/YYYY-MM-DD-mock-<slug>.md` with the common header + the closing assessment sections + the user's calibration prediction + any bluff_flags + pivotal moments.
2. Update `state/observed.md` per protocols.md.
3. Append transcript to `state/archive/<date>-mock-<slug>.md`.
4. Commit: `git add state && git commit -m "Mock interview: <slug>"`.
5. Print one-line summary with recommended next.
```

- [ ] **Step 2: Write `tests/mock-loop.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PROMPT=".claude/commands/mock-loop.md"
assert_file "$PROMPT"
assert_grep "personas/interviewer.md" "$PROMPT"
assert_grep "protocols.md" "$PROMPT"
assert_grep "rubric.md" "$PROMPT"
assert_grep "Requirements" "$PROMPT"
assert_grep "Core Entities" "$PROMPT"
assert_grep "API Design" "$PROMPT"
assert_grep "HLD" "$PROMPT"
assert_grep "Deep Dives" "$PROMPT"
assert_grep "constraint-injection" "$PROMPT"
assert_grep "hint-injection" "$PROMPT"
assert_grep "adversarial" "$PROMPT"
assert_grep "calibration" "$PROMPT"
assert_grep "pivotal moment" "$PROMPT"
assert_grep "What was correct" "$PROMPT"
assert_grep "What was wrong" "$PROMPT"
assert_grep "state/sessions" "$PROMPT"
assert_grep "Practice mode" "$PROMPT"

echo "Phase 4 /mock-loop static tests passed."
```

```bash
chmod +x tests/mock-loop.sh
```

- [ ] **Step 3: Run, verify PASS**

- [ ] **Step 4: Commit**

```bash
git add .claude/commands/mock-loop.md tests/mock-loop.sh
git commit -m "Add /mock-loop slash command + static tests"
```

### Task 43: Dogfood — `/mock-loop` 5-phase FSM

- [ ] **Step 1: Invoke `/mock-loop ticketmaster`**

Expected opening: time budget announcement, persona declaration (neutral), problem statement, honor reminder.

- [ ] **Step 2: Drive through each phase**

Verify:
- Coach announces each phase transition verbatim ("We're at the Core Entities phase now." etc.).
- During Requirements, coach answers your questions but does not volunteer constraints.
- During Core Entities and HLD, coach is mostly silent.
- During Deep Dives, if you don't proactively pick, coach picks for you and logs the moment.

- [ ] **Step 3: Trigger a bluff marker intentionally**

Say something hand-wavy like *"we'd just use a cache here"*. Verify coach asks the specificity question (which cache, what eviction, etc.).

- [ ] **Step 4: Verify intervention rules**

Don't progress for several turns. Verify coach only interjects with procedural language, not hint-injection.

- [ ] **Step 5: Run to closing assessment**

Signal done. Verify:
- Coach asks for calibration prediction FIRST.
- Then presents "What was correct" bulleted list.
- Then "What was wrong" bulleted list.
- Then "Overall" with level demonstrated, pivotal moments, recommended next.

- [ ] **Step 6: Verify state writes**

Check `state/sessions/<date>-mock-ticketmaster.md` for the structured assessment + calibration delta. Check `state/observed.md` was updated.

- [ ] **Step 7: Document and commit**

```bash
git add docs/research/2026-05-12-mock-loop-dogfood-notes.md
git commit -m "Dogfood /mock-loop: 5-phase FSM, intervention rules, closing assessment"
```

### Task 44: Dogfood — adversarial mode gating

- [ ] **Step 1: Attempt `/mock-loop ticketmaster adversarial` early**

If `state/observed.md` shows fewer than 3 prior sessions in the `concurrent-resource` archetype, coach should refuse and explain.

- [ ] **Step 2: Document and commit**

### Task 45: Phase 4 end-to-end check

- [ ] **Step 1: Run all tests**

```bash
bash tests/all.sh
```

- [ ] **Step 2: Verify session-artifact schema for `/mock-loop`**

```bash
for f in state/sessions/*-mock-*.md; do
  bash -c 'source tests/lib.sh; assert_section "What was correct" "'"$f"'"; assert_section "What was wrong" "'"$f"'"; assert_section "Overall" "'"$f"'"'
done
```

- [ ] **Step 3: Commit cleanup**

```bash
git add -A
git commit -m "Phase 4 /mock-loop complete — FSM + intervention + closing assessment"
```

---

## Phase 5 — Polish: first-run flow + README

### Task 46: First-run flow validation

**Files:**
- Create: `tests/first-run.sh`

The first-run flow is implemented in each slash command's prompt (Tasks 34, 38, 42). This task tests it cross-cutting.

- [ ] **Step 1: Write `tests/first-run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# All three commands must handle first-run when state/profile.md is missing.
for cmd in practice-problem study-patterns mock-loop; do
  PROMPT=".claude/commands/$cmd.md"
  assert_grep "first-run|first run" "$PROMPT"
  assert_grep "state/profile.md|profile\.md does not exist" "$PROMPT"
  assert_grep "tell me a few words|tell me a few words about yourself" "$PROMPT"
  assert_grep "honor attestation|honor_attestation|Honor attestation" "$PROMPT"
done

echo "First-run flow static tests passed."
```

```bash
chmod +x tests/first-run.sh
```

- [ ] **Step 2: Run, verify PASS**

```bash
bash tests/all.sh
```
Expected: all tests including first-run pass.

- [ ] **Step 3: Dogfood — fresh repo first run**

In a separate branch, delete `state/profile.md` (if it exists from earlier dogfooding) and invoke `/practice-problem tinyurl`. Verify:
- Coach detects no profile.md.
- Coach prompts for "a few words about yourself, your goals, and any specific areas to focus on".
- Coach extracts fields and writes profile.md.
- Coach presents honor attestation verbatim.
- On "agreed", coach proceeds with the workflow.

- [ ] **Step 4: Restore state and commit**

```bash
git checkout state/profile.md   # restore
git add tests/first-run.sh
git commit -m "Add first-run flow validation across all three workflows"
```

### Task 47: Root `README.md` for users

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# Interview System Design — AI Coach

A local Claude Code coach for FAANG / AI-lab system-design interview prep.

## Quick start

1. Open this repo in Claude Code.
2. On first run, the coach will ask you a few words about yourself, your goals, and any focus areas. Reply briefly (1–3 sentences).
3. Confirm the honor attestation. The coach is for **practice only** — it will not produce a complete design before you've articulated your own first pass, and is not for use during a live interview.
4. Pick a workflow:

| Command | What it does |
|---|---|
| `/study-patterns` | Coach teaches you a pattern subsection (consistency, caching, geo, etc.). Asks check questions; grades 3-point ordinal. |
| `/practice-problem <slug>` | Coach plays the *interviewee*, narrating reasoning with two-voice modeling. Refuses to produce a complete design until you've typed requirements and a first-pass sketch. |
| `/mock-loop <slug>` | Coach plays the *interviewer* through a 5-phase FSM (Requirements → Core Entities → API → HLD → Deep Dives). Closes with a structured assessment. |

## What's where

- `docs/coach/` — read-only coach reference content (rubric, protocols, personas, patterns, problem answers).
- `docs/specs/` — design and architecture docs.
- `docs/research/` — research synthesis and dogfood notes.
- `docs/plans/` — implementation plans.
- `staff-engineer-study-guide.md` — canonical study guide.
- `state/` — your session state (profile, observed signals, per-session artifacts, transcript archive). Committed across sessions.

## How it works

See `docs/specs/2026-05-12-coach-design.md`. The summary:

- Coach is governed by file-backed rules (`docs/coach/protocols.md`), not by accumulated chat history.
- State is structured markdown — observable, auditable, learner-owned.
- Grading uses reference answers (per problem) and 3-point ordinal scales — no free-form 1–10.
- Coach re-reads persona and rubric files at phase transitions to mitigate persona drift.

## Honest limits

- The coach cannot detect cheating, and it doesn't try. It builds *friction* instead: refusal-as-feature, slow drip, sub-optimality injection.
- It will sometimes be wrong. Grade its grading; the coach's feedback is one signal, not the verdict.

## Tests

```bash
bash tests/all.sh
```

Static checks: file existence, frontmatter keys, required content markers. Behavior validation is via documented dogfood sessions (`docs/research/*-dogfood-notes.md`).
```

- [ ] **Step 2: Verify static structure**

```bash
[[ -f README.md ]] && grep -q "Quick start" README.md && grep -q "study-patterns" README.md && grep -q "practice-problem" README.md && grep -q "mock-loop" README.md && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Add root README with quick start and workflow overview"
```

### Task 48: Final end-to-end verification

- [ ] **Step 1: Run the complete test suite**

```bash
bash tests/all.sh
```
Expected: all phase-1, phase-2, phase-3, phase-4, first-run tests pass.

- [ ] **Step 2: Verify all cross-references resolve**

```bash
grep -rEo 'docs/coach/(patterns|personas|problems)/[a-zA-Z0-9_-]+\.md' .claude docs/coach 2>/dev/null | cut -d: -f2 | sort -u | while read path; do
  [[ -f "$path" ]] || echo "Broken reference: $path"
done
```
Expected: no broken-reference lines.

- [ ] **Step 3: Run one complete session of each workflow as a final dogfood**

Repeat:
- `/study-patterns` (let coach recommend; pick one; run to completion)
- `/practice-problem twitter-timeline`
- `/mock-loop dropbox`

Verify all state writes work and observed.md updates accumulate correctly across sessions.

- [ ] **Step 4: Commit final verification**

```bash
git add -A
git commit -m "v1 implementation complete — all workflows operational"
```

---

## Self-review notes

After all tasks complete:

1. **Spec coverage check.** Open `docs/specs/2026-05-12-coach-design.md` and verify every section has at least one task implementing it. Known mappings:
   - Spec §3 rubric → Task 4.
   - Spec §3 protocols → Task 5.
   - Spec §3 personas → Tasks 6–7.
   - Spec §3 archetypes → Task 8.
   - Spec §3 patterns → Tasks 9–25.
   - Spec §3 problems → Tasks 28–32.
   - Spec §4 state schema → Task 1 + protocols (Task 5).
   - Spec §5 /study-patterns → Tasks 38–41.
   - Spec §6 /practice-problem → Tasks 34–37.
   - Spec §7 /mock-loop → Tasks 42–45.
   - Spec §8 first-run + persona refresh + honor reminder + observed.md → Tasks 5, 34, 38, 42, 46.
   - Spec §9 content additions → Tasks 24, 25, 26, 27.

2. **Deferred (per spec §10):** bidirectional grading, user-visible bluff scoring, voice/multimodal, expanded reference-answer corpus, outcome calibration. Not in this plan.

3. **Phase verification.** Each phase ends with an end-to-end check task (33, 37, 41, 45, 48). These are the merge points if the plan is staged into multiple PRs.

---

## Execution options

After this plan is approved, two execution paths:

1. **Subagent-Driven (recommended).** Dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution.** Execute tasks in this session using executing-plans, batch execution with checkpoints.

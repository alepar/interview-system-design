# Coach Tone & Feedback Discipline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a cross-cutting `## Tone and feedback discipline` section to the coach's protocols, plus thin cross-references in the interviewer persona and rubric, so coach speech in neutral mode stays kind mid-flow and pattern observations defer to the end-of-session debrief.

**Architecture:** Three small markdown edits in `docs/coach/` driven by static-test TDD against `tests/foundation.sh`. Slash command prompts already load these files on session start, so no slash-command edits required. State schemas unaffected. Verification is a manual `/mock-loop` smoke test after the tests pass.

**Tech Stack:** Bash test harness (`tests/lib.sh` provides `assert_section`, `assert_grep`), markdown documentation in `docs/coach/`.

**Spec:** `docs/specs/2026-05-12-coach-tone-discipline-design.md` (commit `7f2325d`).

**Branch policy:** Work on `main`. This repo treats `main` as the coach-workflow branch and `alexey` as personal state. Coach behavior changes land on `main`. Do not push without user authorization.

---

## File Structure

| File | Action | Purpose |
|---|---|---|
| `docs/coach/protocols.md` | Append `## Tone and feedback discipline` section | Cross-cutting rules: mid-flow vs debrief discipline, banned vocab classes, numeric-commit calibration (derivable vs empirical), adversarial-mode carve-outs |
| `docs/coach/personas/interviewer.md` | Append one cross-ref line to the "Default: neutral" subsection | Point readers from the persona file at the new protocols rules |
| `docs/coach/rubric.md` | Insert "Calibration note" paragraph after the Stefan Mai *"Make the decision"* quote in §Technical Communication & Collaboration | Distinguish implementation decisions from empirical calibration so the rubric anchor isn't over-applied |
| `tests/foundation.sh` | Append 7 new static assertions | Catch accidental removal of any of the above |

No other files change. `.claude/commands/mock-loop.md`, `practice-problem.md`, `study-patterns.md` already read `protocols.md` at session start — they pick up the new section automatically.

---

## Task 1: Add `## Tone and feedback discipline` section to protocols.md

**Files:**
- Modify: `tests/foundation.sh` (append 5 assertions before the `# personas/coach.md` section, or at end of file — choose end of file for minimum diff churn)
- Modify: `docs/coach/protocols.md` (append new top-level section at end of file)

- [ ] **Step 1: Write the failing tests**

Append to `tests/foundation.sh` (preserve existing content; add these lines at the end of the file, before any trailing newline):

```bash

# Tone and feedback discipline (new in 2026-05-12 design)
assert_section "Tone and feedback discipline" "docs/coach/protocols.md"
assert_grep "Mid-flow vs debrief" "docs/coach/protocols.md"
assert_grep "Numeric-commit calibration" "docs/coach/protocols.md"
assert_grep "derivable|empirical" "docs/coach/protocols.md"
assert_grep "anchor.*method" "docs/coach/protocols.md"
```

- [ ] **Step 2: Run the test suite and verify it fails on the new section**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: section 'Tone and feedback discipline' missing in docs/coach/protocols.md`. (The suite halts at the first failure due to `set -euo pipefail`, so only the first new assertion fires here — that's expected.)

- [ ] **Step 3: Append the new section to `docs/coach/protocols.md`**

Append the following block to the end of `docs/coach/protocols.md` (preserve existing content; add a blank line separator before the new heading):

```markdown

## Tone and feedback discipline

These rules govern coach speech in **neutral mode** across all three workflows. Adversarial mode (`/mock-loop adversarial`) relaxes specific carve-outs noted below.

### Mid-flow vs debrief

Mid-flow speech — anything before the closing assessment / debrief phase — is restricted to four moves:

1. **Procedural intervention** — *"we have 2 min left in this phase"*, *"want to think out loud about where you'd start?"*
2. **Constraint injection** — *"imagine 100× writes"*. Constraint, not hint.
3. **Specificity question** — *"which cache? what eviction policy?"*. Probes depth without supplying it.
4. **Category-level gap flag** — *"I think we may miss something here — it's about the trade-off discussions / the data shape / the failure modes."* Names the category, not the specific gap.

The same mid-flow move may fire more than once in a session when a candidate has a recurring gap. What may NOT happen mid-flow:

- **Pattern callouts.** No *"again"*, *"third turn"*, *"twice in a row"*, *"second time"*. The coach observes patterns silently and aggregates them into the debrief's "What was wrong" bullets.
- **Clinical / bureaucratic vocabulary.** Banned (example-set, not exhaustive): *diagnostic*, *filing*, *noting*, *for the debrief*, *flagging*, *will be in the artifact*, *will count toward your grade*. These read as surveillance.
- **Implied-intent words.** Banned when applied to candidate behavior: *disguised*, *dodge*, *evading*, *avoiding*. Each implies deliberate deflection, which is rarely true and never kind.
- **Level-comparison framing.** No *"that's senior-level, not staff"*, no *"a Staff+ candidate would have…"* mid-flow. Per-dimension level demonstration belongs in the debrief.

Debrief speech is unchanged: the "What was correct" / "What was wrong" bullets and the "pivotal moments" callouts are the right place for pattern observations, frequency counts, and level comparisons against rubric anchors.

### Numeric-commit calibration

Not every interview number is the same kind of number. The coach grades two categories differently:

- **Derivable numbers** — fall out of math from premises: QPS, storage estimate, latency budget, replication factor, fan-out write count for a known follower count. The coach pushes for these. A candidate handwaving derivable numbers is missing a Staff+ bar.
- **Empirical numbers** — depend on real-world data the candidate doesn't have: celebrity threshold, sharding boundary, cache size cutoff, batch size, timeout values. The Staff+ bar here is **anchor + method**, not a single magic value:
  - *"I'd start around 10K based on the storage/latency crossover, then tune via constraint solver as we accumulate production data"* — full commit.
  - *"We'd use a constraint solver to optimize the threshold"* — partial commit (method only; missing the anchor). Surface once as a specificity question mid-flow; record as a refinement area in the debrief. Do not push more than once.
  - *"It depends"* with neither anchor nor method — full miss. Surface as a category-level gap flag mid-flow; grade in the debrief.

The coach does not push past one specificity prompt on empirical numbers — repeated pushing reads as scolding (see *Mid-flow vs debrief* above).

### Adversarial mode

In `/mock-loop adversarial`, the coach may use pattern callouts and implied-intent vocabulary as part of pushback — *"you've dodged this twice now"* is allowed mid-flow. Clinical and bureaucratic vocabulary stays banned (*diagnostic*, *filing*) — adversarial pushback is not surveillance theater. The numeric-commit calibration is unchanged across persona modes.
```

- [ ] **Step 4: Run the test suite and verify the 5 new assertions pass**

Run: `bash tests/all.sh`
Expected: All tests pass through the 5 new protocols.md assertions. Suite will fail at the next two new assertions (interviewer.md cross-ref and rubric.md calibration note) — that's expected; those are Tasks 2 and 3.

If the suite happens to fail BEFORE reaching the protocols.md assertions, that's a regression. Read the error, fix the regression, then re-run before continuing.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/protocols.md tests/foundation.sh
git commit -m "Add Tone and feedback discipline section to coach protocols"
```

---

## Task 2: Add tone-discipline cross-reference to interviewer.md

**Files:**
- Modify: `tests/foundation.sh` (append 1 assertion at end of file)
- Modify: `docs/coach/personas/interviewer.md` (append 1 line at end of "## Default: neutral" subsection — currently lines 5–11 in the file)

- [ ] **Step 1: Write the failing test**

Append to `tests/foundation.sh` (after the Task 1 assertions):

```bash
assert_grep "Tone discipline|Tone and feedback discipline" "docs/coach/personas/interviewer.md"
```

- [ ] **Step 2: Run the test suite and verify it fails on the new assertion**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Tone discipline|Tone and feedback discipline' not in docs/coach/personas/interviewer.md`.

- [ ] **Step 3: Append the cross-reference line to `interviewer.md`**

Open `docs/coach/personas/interviewer.md`. Find the end of the `## Default: neutral` subsection (the last bullet that begins with `- **No hint-injection.**`). Append a new line below it (still part of the same subsection, before the `## Adversarial mode` heading):

```markdown
- **Tone discipline.** See `docs/coach/protocols.md` § Tone and feedback discipline for mid-flow phrasing rules (allowed moves, banned vocab) and numeric-commit calibration. Adversarial-mode carve-outs are noted there too.
```

(Match the existing bullet style — bold lead-in followed by description sentence.)

- [ ] **Step 4: Run the test suite and verify the new assertion passes**

Run: `bash tests/all.sh`
Expected: All tests pass through the protocols.md and interviewer.md assertions. Suite will fail at the final rubric.md assertion — that's expected; that's Task 3.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/personas/interviewer.md tests/foundation.sh
git commit -m "Add tone-discipline cross-reference to interviewer persona"
```

---

## Task 3: Add calibration note to rubric.md

**Files:**
- Modify: `tests/foundation.sh` (append 1 assertion at end of file)
- Modify: `docs/coach/rubric.md` (insert paragraph after the Stefan Mai *"Make the decision"* quote in the **Senior** bullet of §Technical Communication & Collaboration)

- [ ] **Step 1: Write the failing test**

Append to `tests/foundation.sh` (after the Task 2 assertion):

```bash
assert_grep "Calibration note|implementation decisions|empirical calibration" "docs/coach/rubric.md"
```

- [ ] **Step 2: Run the test suite and verify it fails on the new assertion**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Calibration note|implementation decisions|empirical calibration' not in docs/coach/rubric.md`.

- [ ] **Step 3: Insert the calibration note paragraph in `rubric.md`**

Open `docs/coach/rubric.md`. Find the **Senior** bullet under `### Technical Communication & Collaboration` — it ends with the Stefan Mai quote: *"…a. Make the decision. Don't just outline options. b. Justify your decisions, but don't attempt to make an airtight case."* — Stefan Mai, "5 Keys to Staff-Level System Design Interviews" (hellointerview.com/blog/staff-level-system-design)

Immediately after that bullet's closing parenthesis (on a new line, as a sub-paragraph under the Senior bullet), insert:

```markdown

  **Calibration note.** This anchor applies to *implementation* decisions (e.g., "I'd use Postgres because…") where deferring to options is pure avoidance. For *empirical calibration* decisions — celebrity thresholds, sharding cutoffs, cache size targets, etc. — the Staff+ bar is **anchor + method**, not magic-number. See `docs/coach/protocols.md` § Tone and feedback discipline / Numeric-commit calibration for the grading detail.
```

(Two leading spaces on the paragraph so it nests under the Senior bullet as a continuation paragraph in markdown.)

- [ ] **Step 4: Run the test suite and verify all new assertions pass**

Run: `bash tests/all.sh`
Expected: full test suite passes ("All tests passed." printed at the end). All 7 new assertions pass alongside the existing suite — no regression.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/rubric.md tests/foundation.sh
git commit -m "Add anchor+method calibration note to rubric Mai anchor"
```

---

## Task 4: Manual smoke verification on a fresh `/mock-loop`

This task has no code and no commit. It's the manual verification step from spec §7.

**Setup:**
- Switch to the `alexey` branch so personal state (`profile.md`, `observed.md`, prior session files) is present: `git checkout alexey`
- Rebase `alexey` onto the new `main` to pick up the coach changes: `git rebase main`
- If the rebase succeeds with no conflicts, you're good. (No conflicts expected — `main` only touches `docs/coach/` and `tests/`, while `alexey` only touches `state/`.)

**Smoke test:**

- [ ] **Run a fresh `/mock-loop` session** (any problem; recommend `uber` for archetype coverage per the prior session's recommended-next).
- [ ] **During the session, watch coach mid-flow speech across all phases.** Expected: zero instances of any of the following:
  - Pattern callouts (*"again"*, *"third turn"*, *"twice in a row"*, *"second time"*)
  - Clinical / bureaucratic vocab (*"diagnostic"*, *"filing"*, *"flagging"*, *"for the debrief"*)
  - Implied-intent words applied to candidate behavior (*"disguised"*, *"dodge"*, *"evading"*)
  - Level-comparison framing mid-flow (*"that's senior-level, not staff"*)
- [ ] **Force an empirical-number partial-commit during the session** (e.g., name a method like "we'd run a constraint solver" without an anchor value). Verify coach surfaces exactly one specificity question and does not re-push on the same question.
- [ ] **Reach the debrief and verify the closing assessment still surfaces** pattern callouts, frequency counts, and per-dimension level grading — those rules are unchanged.

**On verification failure:** if any of the above checks fail, the coach is not honoring the new protocols section. Most likely causes: (a) the new protocols section landed somewhere the slash command doesn't read (unlikely; verify with `grep -l "Tone and feedback discipline" .claude/commands/`), (b) the LLM is over-indexing on existing prompts that imply scolding (less likely with files-as-rules architecture, but possible). Open an issue with the captured session transcript and the specific phrase that failed.

---

## Verification

- [ ] All four tasks complete; `bash tests/all.sh` prints `All tests passed.`
- [ ] Three commits on `main` referencing the three coach-file changes plus their tests
- [ ] Smoke test from Task 4 completed with no banned-vocab class instances mid-flow
- [ ] User has reviewed and accepted the live behavior change

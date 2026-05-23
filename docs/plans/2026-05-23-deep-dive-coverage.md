# Deep-dive Coverage Loop + Topic-Sequencing Carve-out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make medium `/mock-loop` deep-dives a sequential coverage loop over all critical bottlenecks, and stop the coach mis-grading deep-dive topic-sequencing as the "non-committing" option-listing failure.

**Architecture:** Pure documentation/prompt edits to the coach's canonical files. Difficulty behavior lives in `docs/coach/personas/interviewer.md` (cited by `mock-loop.md`); grading principles live in `docs/coach/rubric.md`; mid-flow speech rules live in `docs/coach/protocols.md`. Backed by a bash content-marker test harness — the only real "tests" are `assert_*` greps.

**Tech Stack:** Markdown + bash harness (`tests/*.sh`; `tests/lib.sh`: `assert_section "title" "file"` greps `^#+ +title`, `assert_grep "pattern" "file"` is `grep -qE`). Run `bash tests/all.sh`.

**Spec:** `docs/specs/2026-05-23-deep-dive-coverage-design.md`

---

### Task 1: Medium deep-dive coverage loop (spec §3)

**Files:**
- Modify: `tests/foundation.sh` (interviewer.md block, after the `[Ss]oft gate` assertion)
- Modify: `tests/mock-loop.sh` (after the `[Ss]oft gate` assertion)
- Modify: `docs/coach/personas/interviewer.md` (Deep Dives row Medium cell ~line 31; drive-vs-wait Medium row ~line 42)
- Modify: `.claude/commands/mock-loop.md` (Phase 5 Deep Dives ~line 65)
- Modify: `README.md` (Medium description ~line 96)

- [ ] **Step 1: Write the failing tests**

In `tests/foundation.sh`, find this line:

```bash
assert_grep "[Ss]oft gate" "docs/coach/personas/interviewer.md"
```

Add immediately after it:

```bash
assert_grep "all critical bottlenecks" "docs/coach/personas/interviewer.md"
```

In `tests/mock-loop.sh`, find this line:

```bash
assert_grep "[Ss]oft gate" ".claude/commands/mock-loop.md"
```

Add immediately after it:

```bash
assert_grep "coverage loop" ".claude/commands/mock-loop.md"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/foundation.sh`
Expected: FAIL with `FAIL: pattern 'all critical bottlenecks' not in docs/coach/personas/interviewer.md`

Run: `bash tests/mock-loop.sh`
Expected: FAIL with `FAIL: pattern 'coverage loop' not in .claude/commands/mock-loop.md`

- [ ] **Step 3: Rewrite the interviewer.md Deep Dives Medium cell**

In `docs/coach/personas/interviewer.md`, find this exact substring (the middle/Medium cell of the Deep Dives table row):

```
Coach picks **one** deep-dive topic and asks (*"let's dig into the write path"*), ensuring at least one named bottleneck area is covered before time ends. Candidate may also propose topics.
```

Replace it with:

```
Coverage loop: coach opens with **one** bottleneck (*"let's start with the write path"*), the candidate drives the depth, and the coach asks follow-up questions only to fill gaps. When that area is covered, the coach picks the **next** bottleneck — repeating until all critical bottlenecks are covered. No proactive pushing or constraint-injection; neutral hole-filling only. Candidate may also propose topics.
```

- [ ] **Step 4: Update the interviewer.md drive-vs-wait Medium row**

Find this exact line:

```
| Medium | Deep-dive topic selection (coach picks one) | Requirements, HLD focus, depth within deep-dive topics — partial signal logged |
```

Replace it with:

```
| Medium | All deep-dive topic selection (coach sequences through every bottleneck) | Requirements, HLD focus, depth within each deep-dive topic — partial signal logged |
```

- [ ] **Step 5: Rewrite the mock-loop.md Phase 5 medium + pivotal clauses**

In `.claude/commands/mock-loop.md`, find this exact substring (the tail of the Deep Dives phase line):

```
At medium: pick **one** deep-dive topic and ask, ensuring at least one named bottleneck area is covered. At hard: fully candidate-driven; coach does **not** pick a topic — silence is a signal, not a prompt. **Log a pivotal turn** (drive-vs-wait moment) only at hard if the candidate failed to drive, or at medium if the candidate failed to drive HLD-focus or within-topic depth.
```

Replace it with:

```
At medium: run a coverage loop — open with **one** bottleneck, let the candidate drive depth, ask follow-up questions only to fill gaps, then pick the **next** bottleneck, repeating until all critical bottlenecks are covered (the critical set comes from `docs/coach/problems/<slug>.md` Deep dives / Known failure modes for catalog problems; coach judgment for freeform). No proactive pushing or constraint-injection at medium — neutral hole-filling only. At hard: fully candidate-driven; coach does **not** pick a topic unless the candidate enumerates the critical areas and explicitly asks the coach to sequence — silence is a signal, not a prompt. **Log a pivotal turn** (drive-vs-wait moment) only at hard if the candidate stayed silent or passively waited (enumerating the areas and asking the coach to sequence is **not** a failure — see `docs/coach/rubric.md` § Drive vs wait), or at medium if the candidate failed to drive HLD-focus or within-topic depth.
```

- [ ] **Step 6: Rewrite the README.md Medium difficulty bullet**

In `README.md`, find this exact line:

```
- **Medium** — the coach is silent through Requirements / Entities / API / HLD, then picks **one** deep-dive topic to ensure a named bottleneck area is covered. Use when you can drive the breadth and want pressure on depth.
```

Replace it with:

```
- **Medium** — the coach is silent through Requirements / Entities / API / HLD, then runs a deep-dive **coverage loop**: it opens with one bottleneck, lets you drive the depth and asks follow-up questions to fill gaps, then moves to the next bottleneck until all the critical ones are covered. Use when you can drive the breadth and want every bottleneck aired.
```

- [ ] **Step 7: Run the full suite to verify it passes**

Run: `bash tests/all.sh`
Expected: PASS, ending with `All tests passed.`

- [ ] **Step 8: Verify README edit landed**

Run: `grep -n "coverage loop" README.md`
Expected: one match on the Medium bullet.

- [ ] **Step 9: Commit**

```bash
git add tests/foundation.sh tests/mock-loop.sh docs/coach/personas/interviewer.md .claude/commands/mock-loop.md README.md
git commit -m "Make medium deep-dives a coverage loop over all bottlenecks"
```

---

### Task 2: Codify reactive-vs-proactive constraint-injection (spec §4)

**Files:**
- Modify: `tests/foundation.sh` (interviewer.md block, after the `all critical bottlenecks` assertion)
- Modify: `docs/coach/personas/interviewer.md` (the intervention-rules note ~line 33)

- [ ] **Step 1: Write the failing test**

In `tests/foundation.sh`, find this line (added in Task 1):

```bash
assert_grep "all critical bottlenecks" "docs/coach/personas/interviewer.md"
```

Add immediately after it:

```bash
assert_grep "untriggered" "docs/coach/personas/interviewer.md"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/foundation.sh`
Expected: FAIL with `FAIL: pattern 'untriggered' not in docs/coach/personas/interviewer.md`

- [ ] **Step 3: Extend the intervention-rules note**

In `docs/coach/personas/interviewer.md`, find this exact line:

```
Hard preserves the four existing intervention rules from `.claude/commands/mock-loop.md` § Intervention rules (procedural time-warnings, stuck-prompts, bluff-marker constraint injection, category-level gap flag). Easy and medium add *proactive* moves on top of those, but do not remove them.
```

Replace it with:

```
Hard preserves the four existing intervention rules from `.claude/commands/mock-loop.md` § Intervention rules (procedural time-warnings, stuck-prompts, bluff-marker constraint injection, category-level gap flag). Easy and medium add *proactive* moves on top of those, but do not remove them. The reactive interventions — including constraint-injection — fire on a bluff-marker trip or stall at **all three levels**; only **easy** volunteers constraint-injection *proactively*, without a trigger. Medium and hard never volunteer it untriggered.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/foundation.sh`
Expected: PASS, ending with `Phase 1 foundation tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tests/foundation.sh docs/coach/personas/interviewer.md
git commit -m "Codify reactive-vs-proactive constraint-injection by difficulty"
```

---

### Task 3: Topic-sequencing carve-out + positive breadth signal (spec §5, §6)

**Files:**
- Modify: `tests/foundation.sh` (rubric.md block after the `Hello Interview` assertion; protocols.md block after the `Soft gates` assertion)
- Modify: `docs/coach/rubric.md` (Method sub-bar ~line 28; Drive vs wait ~lines 59 and 63; Pivotal-moment principle ~line 69)
- Modify: `docs/coach/protocols.md` (Mid-flow vs debrief bullet list, after `Level-comparison framing`)

- [ ] **Step 1: Write the failing tests**

In `tests/foundation.sh`, find this line:

```bash
assert_grep "Hello Interview|hellointerview" "docs/coach/rubric.md"
```

Add immediately after it:

```bash
assert_grep "topic sequenc" "docs/coach/rubric.md"
```

Then find this line:

```bash
assert_section "Soft gates" "docs/coach/protocols.md"
```

Add immediately after it:

```bash
assert_grep "Topic-sequencing|topic sequenc" "docs/coach/protocols.md"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/foundation.sh`
Expected: FAIL with `FAIL: pattern 'topic sequenc' not in docs/coach/rubric.md` (the rubric assertion runs first).

- [ ] **Step 3: Add the carve-out to the rubric Method sub-bar**

In `docs/coach/rubric.md`, find this exact substring (the end of the Method sub-bar paragraph):

```
never kick the decision back to the interviewer.
```

Replace it with:

```
never kick the decision back to the interviewer. This applies to **technical/design decisions** (which datastore, which concurrency strategy) — not to deep-dive **topic sequencing**: enumerating the critical bottleneck areas and asking the interviewer which to explore next is legitimate scoping, never the option-listing failure (see § Drive vs wait).
```

- [ ] **Step 4: Refine the Drive-vs-wait canonical failure**

Find this exact line:

```
- **Hard:** logged normally — the canonical instance is failing to pick a deep-dive topic when the coach was silent.
```

Replace it with:

```
- **Hard:** logged normally — the canonical *failure* instance is the candidate going **silent / passively waiting** for the coach to drive. Enumerating the critical bottleneck areas and asking the coach which to explore next is **not** a failure (the drive was demonstrated by the enumeration); the coach may pick the next area in response.
```

- [ ] **Step 5: Add the positive instance to Drive-vs-wait**

Find this exact line:

```
The session artifact's `difficulty.drive_vs_wait_logged` flag (per `.claude/commands/mock-loop.md` § Closing assessment step 6) records the per-session outcome.
```

Replace it with:

```
The session artifact's `difficulty.drive_vs_wait_logged` flag (per `.claude/commands/mock-loop.md` § Closing assessment step 6) records the per-session outcome.

**Positive instance (any level).** Enumerating the full critical set of deep-dive bottleneck areas — even when the candidate then asks the interviewer to pick the order — demonstrates Problem Navigation (identifying the hard parts). Log it as an above-bar Problem-Navigation signal in "What was correct", not as a non-committing pattern.
```

- [ ] **Step 6: Scope the Pivotal-moment option-listing failure**

Find this exact substring (the tail of the Stefan Mai quote in § Pivotal-moment principle):

```
How can I know whether they'll be a good fit for the role if I'm not actually seeing their decisions?"* — Stefan Mai, "5 Keys to Staff-Level System Design Interviews" (hellointerview.com/blog/staff-level-system-design)
```

Replace it with:

```
How can I know whether they'll be a good fit for the role if I'm not actually seeing their decisions?"* — Stefan Mai, "5 Keys to Staff-Level System Design Interviews" (hellointerview.com/blog/staff-level-system-design)

**Scope of this failure mode.** It is about *decisions* — a list of technologies or approaches handed to the interviewer to choose. It does **not** cover deep-dive **topic sequencing**: offering the interviewer a menu of *areas* to explore next is collaboration, not decision-avoidance (see § Solution Design Method sub-bar and § Drive vs wait).
```

- [ ] **Step 7: Add the mid-flow tone-discipline bullet**

In `docs/coach/protocols.md`, find this exact line:

```
- **Level-comparison framing.** No *"that's senior-level, not staff"*, no *"a Staff+ candidate would have…"* mid-flow. Per-dimension level demonstration belongs in the debrief.
```

Replace it with:

```
- **Level-comparison framing.** No *"that's senior-level, not staff"*, no *"a Staff+ candidate would have…"* mid-flow. Per-dimension level demonstration belongs in the debrief.
- **Topic-sequencing as non-committing.** Offering the interviewer a menu of deep-dive *areas* to explore next is collaboration, not the option-listing failure. Do not call it out (*"pick one, drive"*) — that pattern is about technical *decisions* (see `docs/coach/rubric.md` § Pivotal-moment principle).
```

- [ ] **Step 8: Run the full suite to verify it passes**

Run: `bash tests/all.sh`
Expected: PASS, ending with `All tests passed.`

- [ ] **Step 9: Commit**

```bash
git add tests/foundation.sh docs/coach/rubric.md docs/coach/protocols.md
git commit -m "Carve topic-sequencing out of the option-listing failure; credit as Problem-Nav positive"
```

---

## Notes for the implementer

- **Edit by exact text match, not line number.** Line numbers above are approximate (the soft-gates change shifted `protocols.md`). Use the quoted substrings as match targets. The substrings chosen are unique within their files.
- **Preserve `<slug>` and other template tokens verbatim** — do not substitute real values.
- **Touch only the files listed per task.** Do not alter the Refusal gate, honor attestation, the reactive intervention rules themselves, or any state-artifact schema.
- **DRY:** the positive-signal *definition* lives only in `rubric.md` (Drive vs wait); `mock-loop.md` references `§ Drive vs wait` rather than restating it. The coach re-reads `rubric.md` at phase transitions, so the rubric carve-out governs live behavior.
- **Self-review after each task:** `git diff HEAD~1 HEAD` — confirm only the listed files changed, edits landed verbatim, and the old phrasing ("picks **one** deep-dive topic", "failing to pick a deep-dive topic when the coach was silent") is gone where replaced.

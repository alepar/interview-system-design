# Coach Staff-Method Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a staff-method sub-bar to the `docs/coach/rubric.md` Solution Design Staff+ anchor — a level-conditioned check that grades whether the candidate progresses top-down (simple → bottleneck → criteria → commit), with an optional breadth-menu bonus. Wire it into `/mock-loop`'s closing assessment via a structured `staff_method` artifact field, plus an `observed.md` trajectory rule.

**Architecture:** Four markdown edits (rubric, protocols, mock-loop command) driven by static-test TDD against `tests/mock-loop.sh` and `tests/foundation.sh`. The check is debrief-only — no new mid-flow intervention rule — so the closing-assessment step is the only logic change in the slash command. State schemas are documented in the command prompt; the LLM writes the field at session end. Verification is a manual `/mock-loop` smoke test after the static tests pass.

**Tech Stack:** Bash test harness (`tests/lib.sh` provides `assert_section`, `assert_grep`), markdown documentation in `docs/coach/` and `.claude/commands/`.

**Spec:** `docs/specs/2026-05-20-coach-staff-method-check-design.md` (commit `4dbaec9`).

**Branch policy:** Work on `alexey` (current working branch). Do not push without user authorization.

---

## File Structure

| File | Action | Purpose |
|---|---|---|
| `docs/coach/rubric.md` | Insert Method sub-bar paragraph + level-conditioned table after the Solution Design Staff+ Hello Interview quote | Anchor the new check in the rubric; document L4/L5/L6+ grading rules |
| `docs/coach/protocols.md` | Append one cross-ref line to § Tone and feedback discipline / Mid-flow vs debrief; append step 7 to § observed.md update protocol | Surface the silent-mid-flow rule; add trajectory tracking |
| `.claude/commands/mock-loop.md` | Add Closing assessment step 5 (Fill staff_method); update Session end step 1 with artifact schema | Tell the coach when and how to classify and record the field |
| `tests/mock-loop.sh` | Append 8 static assertions | Catch accidental removal of rubric sub-bar, table, command sub-step, schema |
| `tests/foundation.sh` | Append 2 cross-ref assertions | Catch accidental removal of protocols.md additions |

No other files change. `state/*` files are written at runtime by the coach when running `/mock-loop`; the schema documentation lives in the command prompt only.

---

## Task 1: Add Method sub-bar paragraph and level table to rubric.md

**Files:**
- Modify: `tests/mock-loop.sh` (append 4 assertions at the end of the file, before the final `echo` line)
- Modify: `docs/coach/rubric.md` (insert after line 26, the Solution Design Staff+ Hello Interview quote)

- [ ] **Step 1: Write the failing tests**

Open `tests/mock-loop.sh`. Insert these lines immediately before the final `echo "Phase 4 /mock-loop static tests passed."` line:

```bash

# Staff-method sub-bar (new in 2026-05-20 design)
assert_grep "Method sub-bar.*Staff" "docs/coach/rubric.md"
assert_grep "simplest workable baseline.*bottleneck" "docs/coach/rubric.md"
assert_grep "commit to one choice" "docs/coach/rubric.md"
assert_grep "Target level.*Simple.*bottleneck arc.*Commit-with-criteria.*Breadth menu" "docs/coach/rubric.md"
```

- [ ] **Step 2: Run the test suite and verify it fails on the new section**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Method sub-bar.*Staff' not in docs/coach/rubric.md`. (Suite halts at first failure due to `set -euo pipefail`; only the first new assertion fires.)

- [ ] **Step 3: Insert the Method sub-bar block into `docs/coach/rubric.md`**

Locate the Solution Design Staff+ anchor in `docs/coach/rubric.md` — it currently reads:

```markdown
- **Staff+:** *"[Staff+] I'm looking for about 40% breadth and 60% depth in your understanding."* — Hello Interview, YouTube Top-K Videos problem breakdown (hellointerview.com/learn/system-design/problem-breakdowns/top-k)
```

Append the following block immediately after that bullet, preserving the blank line that follows before the next `###` heading:

```markdown

  **Method sub-bar (Staff+).** A Staff+ design progresses top-down: simplest workable baseline → name the bottleneck → describe ways to resolve → state criteria guiding the tech selection → commit to one choice. Optionally enumerate 2–3 candidate technologies with one-line pro/con before committing (breadth bonus, not required). The anti-pattern is naming a specific technology (*"I'd use DynamoDB"*) without surfacing the criteria that led there. Per Stefan Mai's option-listing principle (see Communication anchor), the commit is required even when the menu is shown — never kick the decision back to the interviewer.

  | Target level | Simple→bottleneck arc | Commit-with-criteria | Breadth menu (optional) |
  |---|---|---|---|
  | L4 (Mid) | not graded | not graded | demonstrated → above-bar signal |
  | L5 (Senior) | demonstrated → above-bar; missed → neutral | at-bar expectation | demonstrated → above-bar signal |
  | L6+ (Staff+) | required (missed → below-bar) | required (missed → below-bar) | demonstrated → above-bar bonus |

  This check is observed silently mid-flow per `docs/coach/protocols.md` § Tone and feedback discipline / Mid-flow vs debrief; it surfaces only in the closing assessment.
```

Two-space indentation on the inner paragraph and table is deliberate — it nests under the `- **Staff+:**` bullet so the existing list structure is preserved.

- [ ] **Step 4: Run the test suite and verify all four new assertions pass**

Run: `bash tests/all.sh`
Expected: PASS (full test suite runs to completion; "Phase 4 /mock-loop static tests passed." prints).

- [ ] **Step 5: Commit**

```bash
git add docs/coach/rubric.md tests/mock-loop.sh
git commit -m "$(cat <<'EOF'
Add Staff+ method sub-bar to Solution Design rubric anchor

Grades top-down design progression (simple workable baseline → name the
bottleneck → criteria → commit) with an optional breadth-menu bonus.
Level-conditioned: L4 not graded, L5 reach signal, L6+ required. The
check is debrief-only — observed silently mid-flow per the tone
discipline rules.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add cross-reference line to protocols.md § Tone and feedback discipline

**Files:**
- Modify: `tests/foundation.sh` (append 1 assertion at end of file, before the final `echo` line)
- Modify: `docs/coach/protocols.md` (insert one line at the end of the "Mid-flow vs debrief" subsection)

- [ ] **Step 1: Write the failing test**

Open `tests/foundation.sh`. Insert this line immediately before the final `echo "Phase 1 foundation tests passed."` line:

```bash

# Staff-method check cross-reference (new in 2026-05-20 design)
assert_grep "staff-method sub-bar" "docs/coach/protocols.md"
```

- [ ] **Step 2: Run the test suite and verify it fails on the new assertion**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'staff-method sub-bar' not in docs/coach/protocols.md`.

- [ ] **Step 3: Insert the cross-reference line into `docs/coach/protocols.md`**

Locate the "Mid-flow vs debrief" subsection in `docs/coach/protocols.md`. Find the paragraph that currently ends:

```markdown
Debrief speech is unchanged: the "What was correct" / "What was wrong" bullets and the "pivotal moments" callouts are the right place for pattern observations, frequency counts, and level comparisons against rubric anchors.
```

Insert a new paragraph immediately after that line (with a blank line separator), before the `### Numeric-commit calibration` subsection:

```markdown

The staff-method sub-bar in `docs/coach/rubric.md` § Solution Design Staff+ is observed silently mid-flow under the same rule — debrief-only.
```

- [ ] **Step 4: Run the test suite and verify the new assertion passes**

Run: `bash tests/all.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/protocols.md tests/foundation.sh
git commit -m "$(cat <<'EOF'
Cross-reference staff-method sub-bar from tone discipline rules

Adds a one-line pointer from § Tone and feedback discipline / Mid-flow
vs debrief to the new Solution Design Staff+ method sub-bar, making
the silent-mid-flow rule discoverable from both sides.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add step 7 to protocols.md § observed.md update protocol

**Files:**
- Modify: `tests/foundation.sh` (append 1 assertion at end of file, before the final `echo` line)
- Modify: `docs/coach/protocols.md` (append a new step 7 to the observed.md update protocol list)

- [ ] **Step 1: Write the failing test**

Open `tests/foundation.sh`. Insert this line immediately before the final `echo "Phase 1 foundation tests passed."` line (which already has the Task 2 assertion above it after that task completes):

```bash
assert_grep "staff_method_trajectory|staff_method trajectory" "docs/coach/protocols.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'staff_method_trajectory|staff_method trajectory' not in docs/coach/protocols.md`.

- [ ] **Step 3: Append step 7 to the observed.md update protocol in `docs/coach/protocols.md`**

Locate the `## observed.md update protocol` section in `docs/coach/protocols.md`. The list currently ends at step 6:

```markdown
6. Update scaffolding level: decrease by 1 after 3 consecutive sessions in archetype demonstrating ≥ target level.
```

Append a new step 7 immediately after that line (preserve list numbering and indentation):

```markdown
7. Update staff_method trajectory: count `demonstrated` / `missed` for `simple_to_bottleneck_arc` and `commit_with_criteria` across the last 5 `/mock-loop` sessions where each slot was graded (sessions with `not_graded` excluded from the denominator). Record `breadth_menu_count` as count-of-demonstrated over the same window. The "Recommended next session" line may bias toward archetypes where `commit_with_criteria` is recurring `missed`. Field shape in `observed.md`:

   ```yaml
   staff_method_trajectory:
     window_sessions: 5
     simple_to_bottleneck_arc: "3/4 demonstrated"
     commit_with_criteria: "2/4 demonstrated"
     breadth_menu_count: 1
   ```
```

- [ ] **Step 4: Run the test suite and verify the new assertion passes**

Run: `bash tests/all.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/protocols.md tests/foundation.sh
git commit -m "$(cat <<'EOF'
Add staff_method_trajectory to observed.md update protocol

Adds step 7 to the session-end observed.md write rule: count
demonstrated/missed for the staff-method slots across the last 5
/mock-loop sessions (excluding not_graded sessions from the
denominator), with a breadth-menu demonstration count. Used to bias
"Recommended next session" toward recurring commit_with_criteria misses.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add Closing assessment sub-step and artifact schema to mock-loop.md

**Files:**
- Modify: `tests/mock-loop.sh` (append 4 assertions at the end of the file, before the final `echo` line)
- Modify: `.claude/commands/mock-loop.md` (insert step 5 in Closing assessment; update Session end step 1)

- [ ] **Step 1: Write the failing tests**

Open `tests/mock-loop.sh`. Insert these lines immediately before the final `echo "Phase 4 /mock-loop static tests passed."` line (which will already have Task 1's assertions inserted above it):

```bash

# Staff-method closing-assessment sub-step and schema (new in 2026-05-20 design)
assert_grep "Fill staff_method" ".claude/commands/mock-loop.md"
assert_grep "simple_to_bottleneck_arc.*demonstrated.*missed.*not_graded" ".claude/commands/mock-loop.md"
assert_grep "commit_with_criteria" ".claude/commands/mock-loop.md"
assert_grep "breadth_menu.*demonstrated.*absent" ".claude/commands/mock-loop.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Fill staff_method' not in .claude/commands/mock-loop.md`.

- [ ] **Step 3: Insert step 5 into the Closing assessment section of `.claude/commands/mock-loop.md`**

Locate the `## Closing assessment` section. The numbered list currently has steps 1–4. Insert a new step 5 immediately after step 4 and before the prose line that starts "Grading: use the reference answer…":

```markdown

5. **Fill staff_method.** Before writing the session artifact, classify each slot from the transcript:

   - `simple_to_bottleneck_arc`: `demonstrated` if HLD or Deep-Dive showed simple-baseline → named-bottleneck → resolution arc; `missed` if depth dives happened with no baseline-bottleneck framing; `not_graded` if target_level is L4 and the marker was absent.
   - `commit_with_criteria`: `demonstrated` if at least one tech choice stated criteria and committed to one option; `missed` if a tech was named without surfacing criteria; `not_graded` if target_level is L4 and the marker was absent.
   - `breadth_menu`: `demonstrated` if the candidate enumerated 2–3 candidates with one-line pro/con before committing on any decision; `absent` otherwise (never penalized — only the positive case is recorded).

   Cite the Staff+ method sub-bar anchor in any "What was correct" / "What was wrong" bullet derived from these slots.
```

- [ ] **Step 4: Update Session end step 1 in `.claude/commands/mock-loop.md`**

Locate the `## Session end` section, step 1, which currently reads:

```markdown
1. Write `state/sessions/YYYY-MM-DD-mock-<slug>.md` with the common header + the closing assessment sections + the user's calibration prediction + any bluff_flags + pivotal moments.
```

Replace it with:

```markdown
1. Write `state/sessions/YYYY-MM-DD-mock-<slug>.md` with the common header + the closing assessment sections + the user's calibration prediction + any bluff_flags + pivotal moments + the `staff_method` field with shape:

   ```yaml
   staff_method:
     simple_to_bottleneck_arc: demonstrated | missed | not_graded
     commit_with_criteria: demonstrated | missed | not_graded
     breadth_menu: demonstrated | absent
     notes: "one-line free text — what triggered the call, or which depth-area decision"
   ```
```

- [ ] **Step 5: Run the test suite and verify all four new assertions pass**

Run: `bash tests/all.sh`
Expected: PASS (full test suite runs to completion; both phase messages print).

- [ ] **Step 6: Commit**

```bash
git add .claude/commands/mock-loop.md tests/mock-loop.sh
git commit -m "$(cat <<'EOF'
Wire staff_method into /mock-loop closing assessment

Adds Closing assessment step 5 (Fill staff_method) telling the coach
how to classify the three slots from the transcript, and updates the
Session end artifact write to include the staff_method field with its
yaml shape inline.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Manual smoke test

This task is verification, not code. No commits expected unless a regression is found.

- [ ] **Step 1: Confirm full test suite passes**

Run: `bash tests/all.sh`
Expected: Both `Phase 1 foundation tests passed.` and `Phase 4 /mock-loop static tests passed.` print, plus any other phase outputs the suite emits.

- [ ] **Step 2: Smoke test — commit-with-criteria missed**

In an interactive Claude session at the repo root, run:

```
/mock-loop tinyurl
```

(or any catalog problem). As the candidate, during HLD or Deep-Dive, deliberately name a specific technology (e.g., *"I'd use DynamoDB for the URL store"*) without stating the criteria that led there. Continue to debrief.

Expected debrief behavior:
- Mid-flow: coach does NOT prompt *"why DynamoDB?"* triggered by this check alone. (Other existing moves — bluff prompts, specificity questions for unrelated reasons — may fire; those are fine.)
- Closing assessment includes a "What was wrong" bullet under Solution Design citing the **Staff+ method sub-bar** anchor, with `commit_with_criteria: missed` reflected in the session artifact `state/sessions/<date>-mock-tinyurl.md`.
- The artifact contains the `staff_method:` block with the four documented fields populated.

- [ ] **Step 3: Smoke test — breadth menu demonstrated**

Run another `/mock-loop` session. During at least one tech decision, enumerate 2–3 candidate technologies with one-line pro/con before committing (e.g., *"For the leaderboard store I'd consider Redis sorted sets, Postgres with a covering index, or DynamoDB with a GSI; given low write QPS and need for sorted reads, I'd go with Redis."*).

Expected debrief behavior:
- Session artifact contains `breadth_menu: demonstrated`.
- Closing assessment includes an "above bar" callout for the breadth menu (separate from or embedded in the Solution Design bullets).

- [ ] **Step 4: Smoke test — observed.md trajectory updated**

After both smoke sessions above complete, open `state/observed.md`. Verify it contains a `staff_method_trajectory:` block with non-zero counts (e.g., `commit_with_criteria: "0/1 demonstrated"` after the missed session, `1/2 demonstrated` after the breadth-menu session if a commit was made there).

- [ ] **Step 5: Smoke test — L4 target gets not_graded**

Edit `state/profile.md` (or run a session with a profile where `target_level: L4`). Run a `/mock-loop` session deliberately omitting the simple-to-bottleneck arc. Verify:
- Session artifact records `simple_to_bottleneck_arc: not_graded` (NOT `missed`).
- No negative "What was wrong" bullet appears for the staff-method check in the debrief.
- `observed.md` trajectory denominator excludes this session.

If any smoke test fails, file the regression as a bug; do not amend the prior commits.

---

## Notes for the implementer

- **TDD order matters.** Each task writes the test first and runs it to confirm a real failure before making the code change. Do not skip the failing-run step — it's the only thing that catches a copy-paste error in the assertion regex.
- **No state file edits in this plan.** `state/observed.md` and `state/sessions/*.md` are written at runtime by the coach. The schema documentation in `mock-loop.md` (Task 4) is the spec the coach reads at session start; the LLM populates the field at session end.
- **No mid-flow prompt changes.** The check is debrief-only by design. If you find yourself editing the intervention rules or persona files mid-flow guidance, stop — that contradicts the spec.
- **Existing assertions must keep passing.** All foundation, mock-loop, practice-problem, study-patterns, first-run, and tone-discipline assertions stay green throughout. If any go red, you've introduced a regression — don't paper over it by editing the existing assertion.
- **Branch policy reminder.** Work on `alexey`. Do not push without explicit user authorization.

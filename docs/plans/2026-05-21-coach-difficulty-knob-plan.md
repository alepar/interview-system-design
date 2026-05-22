# Coach Difficulty Knob Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three named difficulty levels (`easy`, `medium`, `hard`) to `/mock-loop`, orthogonal to the existing `neutral`/`adversarial` switch, with CLI selection + coach recommendation, per-phase behavior tables, weighted observed.md trajectory contributions, and a difficulty-conditioned drive-vs-wait pivotal moment.

**Architecture:** Six markdown edits across `interviewer.md`, `mock-loop.md`, `protocols.md`, and `rubric.md`, driven by static-test TDD against `tests/foundation.sh` and `tests/mock-loop.sh`. No state-schema files are touched directly — schema lives inline in `mock-loop.md` as the LLM-readable spec. Verification is manual `/mock-loop` smoke testing after the 12 new static assertions pass.

**Tech Stack:** Bash test harness (`tests/lib.sh` provides `assert_section`, `assert_grep`), markdown documentation in `docs/coach/` and `.claude/commands/`.

**Spec:** `docs/specs/2026-05-21-coach-difficulty-knob-design.md` (commit `7d7d02e`).

**Branch policy:** Work on `main`. The repo convention is that coach-behavior changes land on `main`; `alexey` is personal state. Do not push without user authorization.

---

## File Structure

| File | Action | Purpose |
|---|---|---|
| `docs/coach/personas/interviewer.md` | Insert new `## Difficulty levels` section between Adversarial mode and Phase-transition language | 3×5 behavior table + drive-vs-wait sub-table; sole source of truth for per-phase rules |
| `.claude/commands/mock-loop.md` | Rewrite argument parsing; add `## Difficulty recommendation`; add Opening bullet; per-phase clauses in FSM; Closing assessment step 6 (Fill difficulty record); update Session end step 1 with artifact field | CLI grammar, recommendation logic, opening announcement, FSM phase-level dispatch, artifact schema |
| `docs/coach/protocols.md` | Append step 8 to § observed.md update protocol; update step 7 example yaml to fractional form | Difficulty modifier on trajectory aggregates |
| `docs/coach/rubric.md` | Append "Difficulty-conditioned logging" paragraph to § Drive vs wait | Document how the pivotal moment grades per difficulty |
| `tests/foundation.sh` | Append 6 new structural assertions | Catch removal of difficulty levels section, drive-vs-wait note, trajectory modifier |
| `tests/mock-loop.sh` | Append 6 new structural assertions | Catch removal of CLI grammar, recommendation, opening, artifact field |

No other files change. State files (`state/observed.md`, `state/sessions/*.md`) are written at runtime by the coach; schema documentation lives in the command prompt.

---

## Task 1: Add Difficulty levels section to interviewer.md

**Files:**
- Modify: `tests/foundation.sh` (append 3 assertions before the final `echo` line)
- Modify: `docs/coach/personas/interviewer.md` (insert new section between Adversarial mode and Phase-transition language)

- [ ] **Step 1: Write the failing tests**

Open `tests/foundation.sh`. Insert these lines immediately before the final `echo "Phase 1 foundation tests passed."` line:

```bash

# Difficulty levels section in interviewer.md (new in 2026-05-21 design)
assert_section "Difficulty levels" "docs/coach/personas/interviewer.md"
assert_grep "easy.*medium.*hard|Easy.*Medium.*Hard" "docs/coach/personas/interviewer.md"
assert_grep "Drive-vs-wait logging by difficulty|Drive vs wait at non-hard" "docs/coach/personas/interviewer.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: section 'Difficulty levels' missing in docs/coach/personas/interviewer.md`.

- [ ] **Step 3: Insert the Difficulty levels section into `docs/coach/personas/interviewer.md`**

Locate the "Adversarial mode (opt-in)" subsection and its closing line about adversarial pushback. The next heading after it is `## Phase-transition language (verbatim)`. Insert a new section between them, preserving blank-line separators:

```markdown

## Difficulty levels

Three named levels control how proactively the coach drives the conversation. Orthogonal to the neutral/adversarial push axis: any combination is valid (e.g., `easy adversarial`, `hard neutral`). Selection rules and the recommendation logic live in `.claude/commands/mock-loop.md`.

| Phase | Easy | Medium | Hard |
|---|---|---|---|
| Requirements | Suggest rough FR/NFR **areas** to consider (*"think about read vs write paths, scale targets, and consistency model"*). Never list specific FRs/NFRs — the candidate fills in the content. | Silent. Answer scope questions only when asked. | Silent. Answer scope questions only when asked. |
| Core Entities | Silent. | Silent. | Silent. |
| API Design | Silent. May ask *"what about X endpoint?"* once if an obvious endpoint is missing (existing rule). | Same as easy. | Same as easy. |
| HLD | Offer a helping focus prompt at the start (*"let's start with the write path"* or *"focus on the read fan-out first"*). One sentence, no architecture detail. | Silent unless candidate stuck >2 turns. | Silent unless candidate stuck >2 turns. |
| Deep Dives | Announce the topics to cover up-front (*"we'll cover sharding, hot-key handling, and propagation lag"*). Then candidate drives within each topic. | Coach picks **one** deep-dive topic and asks (*"let's dig into the write path"*), ensuring at least one named bottleneck area is covered before time ends. Candidate may also propose topics. | Fully candidate-driven. Coach does **not** pick a topic even if candidate is silent — silence at hard is a signal, not a prompt for the coach to fill. |

Hard preserves the four existing intervention rules from `.claude/commands/mock-loop.md` § Intervention rules (procedural time-warnings, stuck-prompts, bluff-marker constraint injection, category-level gap flag). Easy and medium add *proactive* moves on top of those, but do not remove them.

### Drive-vs-wait logging by difficulty

The drive-vs-wait pivotal moment (`docs/coach/rubric.md` § Drive vs wait) is logged conditionally:

| Mode | Where coach drives by protocol | Where candidate could still demonstrate drive |
|---|---|---|
| Hard | Nowhere (coach only steps in for stuck/bluff) | Everywhere — full signal logged |
| Medium | Deep-dive topic selection (coach picks one) | Requirements, HLD focus, depth within deep-dive topics — partial signal logged |
| Easy | Requirements areas, HLD focus, deep-dive topics | Almost nowhere — signal not logged |

At easy, drive-vs-wait is not logged because the coach drove the meaningful inflection points by protocol; logging it would punish the candidate for the protocol's choice to drive.
```

- [ ] **Step 4: Run the test suite and verify all three new assertions pass**

Run: `bash tests/all.sh`
Expected: PASS with all phases completing.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/personas/interviewer.md tests/foundation.sh
git commit -m "$(cat <<'EOF'
Add Difficulty levels section to interviewer persona

3x5 behavior table covering Requirements/Entities/API/HLD/Deep-Dives
across easy/medium/hard. Drive-vs-wait pivotal-moment logging is
conditioned on difficulty in a sub-table. Orthogonal to the existing
neutral/adversarial axis.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Update mock-loop.md argument parsing + Difficulty recommendation

**Files:**
- Modify: `tests/mock-loop.sh` (append 2 assertions before the final `echo` line)
- Modify: `.claude/commands/mock-loop.md` (rewrite Problem selection step 5; insert new § Difficulty recommendation)

- [ ] **Step 1: Write the failing tests**

Open `tests/mock-loop.sh`. Insert these lines immediately before the final `echo "Phase 4 /mock-loop static tests passed."` line:

```bash

# Difficulty knob — CLI grammar + recommendation (new in 2026-05-21 design)
assert_grep "Difficulty recommendation" ".claude/commands/mock-loop.md"
assert_grep "easy\|medium\|hard" ".claude/commands/mock-loop.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Difficulty recommendation' not in .claude/commands/mock-loop.md`.

- [ ] **Step 3: Rewrite the Problem selection step 5 to accept the difficulty token**

Locate `## Problem selection and FSM setup` and its step 5 in `.claude/commands/mock-loop.md`. The current text reads:

```markdown
5. Parse `$ARGUMENTS`:
   - Empty → pick a problem per the priority in protocols.md "Problem selection (for /mock-loop)".
   - `<slug>` → load `docs/coach/problems/<slug>.md`. If missing, fall back to freeform mode.
   - `<slug> adversarial` → check the adversarial gate (3+ prior sessions in the archetype in `state/observed.md`). If gate not met, decline and explain.
```

Replace it with:

```markdown
5. Parse `$ARGUMENTS` (positional, order-insensitive after slug):
   - Tokens: `<slug>`, one of `easy|medium|hard`, optional `adversarial`.
   - Empty / no slug → pick a problem per the priority in protocols.md "Problem selection (for /mock-loop)".
   - No difficulty token → compute recommendation per § Difficulty recommendation below.
   - Difficulty token present → use it directly; skip the recommendation.
   - `adversarial` → check the adversarial gate (3+ prior sessions in the archetype in `state/observed.md`). If gate not met, decline and explain.
```

- [ ] **Step 4: Insert the new § Difficulty recommendation subsection**

Insert a new top-level section after the `## Problem selection and FSM setup` section and before `## Opening (verbatim phrasing)`:

```markdown
## Difficulty recommendation

Run only if `$ARGUMENTS` did not include a difficulty token.

1. Read `state/observed.md` and count `/mock-loop` sessions in the trajectory window.
2. If fewer than 3 prior `/mock-loop` sessions exist: recommend `medium`.
3. Otherwise, for the last 3 sessions, count **passes** — a session passes if both `level_demonstrated.solution_design` and `level_demonstrated.technical_excellence` are `≥ profile.target_level`.
4. Map pass count → recommendation:
   - 2 or 3 passes → `hard`
   - 1 pass → `medium`
   - 0 passes → `easy`

The recommendation is used as the session's difficulty. Surface it in the Opening announcement so the user can override mid-session by typing `easy`, `medium`, or `hard`.
```

- [ ] **Step 5: Run the test suite and verify both new assertions pass**

Run: `bash tests/all.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add .claude/commands/mock-loop.md tests/mock-loop.sh
git commit -m "$(cat <<'EOF'
Add /mock-loop difficulty CLI grammar and recommendation logic

Rewrites Problem selection step 5 to accept easy|medium|hard as an
optional positional token (order-insensitive after slug). Adds the
Difficulty recommendation subsection: read last 3 /mock-loop sessions
from observed.md; map pass count to recommendation; fall back to
medium when fewer than 3 prior sessions exist.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add Opening announcement bullet and per-phase FSM clauses

**Files:**
- Modify: `tests/mock-loop.sh` (append 1 assertion before the final `echo` line)
- Modify: `.claude/commands/mock-loop.md` (add Difficulty bullet to Opening; per-phase clauses in FSM)

- [ ] **Step 1: Write the failing test**

Open `tests/mock-loop.sh`. Insert this line immediately before the final `echo "Phase 4 /mock-loop static tests passed."` line:

```bash
assert_grep "Running as.*level|Say.*easy.*medium.*hard" ".claude/commands/mock-loop.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Running as.*level|Say.*easy.*medium.*hard' not in .claude/commands/mock-loop.md`.

- [ ] **Step 3: Add the Difficulty bullet to § Opening (verbatim phrasing)**

Locate `## Opening (verbatim phrasing)`. The current list reads:

```markdown
- Time budget: *"We have 45 minutes. Let's collect signals in the first 40; we'll debrief in the last 5."*
- Persona mode: *"This is a neutral interview"* OR *"This is an adversarial interview — I'll push back occasionally."*
- The problem statement.
- Honor reminder (1 line): *"Practice mode — not for live interview use."*
```

Insert a new bullet between "Persona mode" and "The problem statement":

```markdown
- Difficulty: *"Running as <level>. <one-line behavior summary>. Say 'easy', 'medium', or 'hard' to switch."* Per-level summaries: easy → *"I'll guide requirements, HLD focus, and deep-dive topics."*; medium → *"I'll pick deep-dive topics; the rest is yours to drive."*; hard → *"You drive everything; I only step in for stuck-prompts or bluff markers."* When the level came from a recommendation, prepend *"Based on your last 3 sessions, recommending <level>."*
```

- [ ] **Step 4: Update Phase-anchored FSM — append "At <level>:" clause to Requirements**

Locate `## Phase-anchored FSM`. Step 1 currently reads:

```markdown
1. **Requirements (~5 min equivalent in pacing).** Answer candidate's questions about scope. Do NOT volunteer constraints unless asked.
```

Replace with:

```markdown
1. **Requirements (~5 min equivalent in pacing).** Answer candidate's questions about scope. Do NOT volunteer constraints unless asked. At easy: open the phase by suggesting rough FR/NFR areas to consider (per `personas/interviewer.md` § Difficulty levels). At medium/hard: no proactive guidance.
```

- [ ] **Step 5: Update Phase-anchored FSM — append "At <level>:" clause to HLD**

Step 4 (HLD) currently reads:

```markdown
4. **HLD (~10 min).** Silent unless candidate is stuck >2 turns.
```

Replace with:

```markdown
4. **HLD (~10 min).** Silent unless candidate is stuck >2 turns. At easy: open the phase with a one-sentence helping prompt for the focus area (per `personas/interviewer.md` § Difficulty levels). At medium/hard: no proactive guidance.
```

- [ ] **Step 6: Rewrite Phase-anchored FSM step 5 (Deep Dives)**

Step 5 currently reads:

```markdown
5. **Deep Dives (~20 min).** If candidate doesn't proactively pick depth areas, pick one and ask. **Log this as a pivotal turn** (drive-vs-wait moment).
```

Replace with:

```markdown
5. **Deep Dives (~20 min).** At easy: announce the topics to cover up-front (3–5 named bottleneck areas), then candidate drives within each. At medium: pick **one** deep-dive topic and ask, ensuring at least one named bottleneck area is covered. At hard: fully candidate-driven; coach does **not** pick a topic — silence is a signal, not a prompt. **Log a pivotal turn** (drive-vs-wait moment) only at hard if the candidate failed to drive, or at medium if the candidate failed to drive HLD-focus or within-topic depth.
```

- [ ] **Step 7: Run the test suite and verify the new assertion passes**

Run: `bash tests/all.sh`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add .claude/commands/mock-loop.md tests/mock-loop.sh
git commit -m "$(cat <<'EOF'
Wire difficulty knob into /mock-loop Opening and FSM phases

Adds the Difficulty bullet to the Opening announcement with verbatim
per-level behavior summaries and the recommendation-prepend. Updates
the Requirements, HLD, and Deep-Dives FSM phases with "At <level>:"
clauses. Removes the hard-mode auto-pick fallback on Deep Dives —
silence at hard is now a signal, not a prompt for the coach to fill.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Closing assessment Fill difficulty record + artifact schema

**Files:**
- Modify: `tests/mock-loop.sh` (append 3 assertions before the final `echo` line)
- Modify: `.claude/commands/mock-loop.md` (insert Closing assessment step 6; update Session end step 1; add Overall one-liner)

- [ ] **Step 1: Write the failing tests**

Open `tests/mock-loop.sh`. Insert these lines immediately before the final `echo "Phase 4 /mock-loop static tests passed."` line:

```bash
assert_grep "Fill difficulty record" ".claude/commands/mock-loop.md"
assert_grep "difficulty\.source|difficulty_source" ".claude/commands/mock-loop.md"
assert_grep "drive_vs_wait_logged" ".claude/commands/mock-loop.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Fill difficulty record' not in .claude/commands/mock-loop.md`.

- [ ] **Step 3: Insert Closing assessment step 6**

Locate `## Closing assessment`. The current list has steps 1–5 (5 being Fill staff_method, added last task series), followed by the prose `Grading: use the reference answer...` line.

Insert a new step 6 between step 5 and the Grading line:

```markdown

6. **Fill difficulty record.** Before writing the session artifact, populate:

   - `difficulty.level`: `easy | medium | hard` — the level actually run (after any mid-session overrides via the user typing `easy`/`medium`/`hard`).
   - `difficulty.source`: `cli | recommended | overridden_mid_session` — how this level was chosen. `cli` if it came from `$ARGUMENTS`; `recommended` if from § Difficulty recommendation and accepted; `overridden_mid_session` if the user switched after the opening.
   - `difficulty.drive_vs_wait_logged`: `true | false` — `true` at hard (always), `true` at medium (only if HLD-focus or within-topic-depth signals fired), `false` at easy.
```

- [ ] **Step 4: Update Session end step 1 with the new artifact field**

Locate `## Session end`. Step 1 currently reads (after the staff_method addition):

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

Replace with:

```markdown
1. Write `state/sessions/YYYY-MM-DD-mock-<slug>.md` with the common header + the closing assessment sections + the user's calibration prediction + any bluff_flags + pivotal moments + the `staff_method` field + the `difficulty` block. Shapes:

   ```yaml
   staff_method:
     simple_to_bottleneck_arc: demonstrated | missed | not_graded
     commit_with_criteria: demonstrated | missed | not_graded
     breadth_menu: demonstrated | absent
     notes: "one-line free text — what triggered the call, or which depth-area decision"

   difficulty:
     level: easy | medium | hard
     source: cli | recommended | overridden_mid_session
     drive_vs_wait_logged: true | false
   ```
```

- [ ] **Step 5: Add Overall summary one-liner for difficulty**

Locate the Closing assessment step 4 (Overall summary). It currently reads:

```markdown
4. **Overall** — short summary:
   - Level demonstrated per dimension (from `level_demonstrated` in the session header).
   - 1–2 **pivotal moments**, each with a one-sentence rationale.
   - Recommended next session.
```

Replace with:

```markdown
4. **Overall** — short summary:
   - Level demonstrated per dimension (from `level_demonstrated` in the session header).
   - 1–2 **pivotal moments**, each with a one-sentence rationale.
   - *"Difficulty: <level> (<source>)."* — one line stating the level and how it was chosen.
   - Recommended next session.
```

- [ ] **Step 6: Run the test suite and verify all three new assertions pass**

Run: `bash tests/all.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add .claude/commands/mock-loop.md tests/mock-loop.sh
git commit -m "$(cat <<'EOF'
Record difficulty in /mock-loop session artifact

Adds Closing assessment step 6 (Fill difficulty record) covering
level/source/drive_vs_wait_logged. Updates Session end step 1 with the
difficulty yaml block alongside staff_method. Adds a one-line
difficulty mention to the Overall debrief summary.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add observed.md trajectory modifier in protocols.md

**Files:**
- Modify: `tests/foundation.sh` (append 2 assertions before the final `echo` line)
- Modify: `docs/coach/protocols.md` (append step 8 to observed.md update protocol; update step 7 example yaml)

- [ ] **Step 1: Write the failing tests**

Open `tests/foundation.sh`. Insert these lines immediately before the final `echo "Phase 1 foundation tests passed."` line:

```bash

# Difficulty modifier in observed.md update protocol (new in 2026-05-21 design)
assert_grep "difficulty modifier|trajectory weight" "docs/coach/protocols.md"
assert_grep "weight 1.0|weight 0.6|weight 0.3" "docs/coach/protocols.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'difficulty modifier|trajectory weight' not in docs/coach/protocols.md`.

- [ ] **Step 3: Append step 8 to the observed.md update protocol**

Locate `## observed.md update protocol` in `docs/coach/protocols.md`. The list ends at step 7 (staff_method trajectory, including the yaml block). Append step 8 after the closing ```` ``` ```` of step 7's yaml block:

```markdown
8. Apply the difficulty modifier to per-session contributions. For each session in the trajectory windows used by steps 2, 5, 6, 7:
   - Hard sessions count at weight 1.0.
   - Medium sessions count at weight 0.6.
   - Easy sessions count at weight 0.3.

   Numerators stay fractional. Denominators stay integer (count of graded sessions in the window). Round displayed values to one decimal place. Example: 2 demonstrated at hard + 1 at medium + 0 at easy across 4 sessions → numerator = 2·1.0 + 1·0.6 + 0·0.3 = 2.6, displayed as `2.6/4 demonstrated`.

   Sessions written before this design landed (no `difficulty` block) are treated as `hard` (weight 1.0). This preserves trajectory continuity.
```

- [ ] **Step 4: Update step 7's example yaml to fractional form**

Locate the yaml block under step 7 of the observed.md update protocol:

```yaml
staff_method_trajectory:
  window_sessions: 5
  simple_to_bottleneck_arc: "3/4 demonstrated"
  commit_with_criteria: "2/4 demonstrated"
  breadth_menu_count: 1
```

Replace it with:

```yaml
staff_method_trajectory:
  window_sessions: 5
  simple_to_bottleneck_arc: "2.9/4 demonstrated"
  commit_with_criteria: "1.6/4 demonstrated"
  breadth_menu_count_weighted: 0.6
```

- [ ] **Step 5: Run the test suite and verify the new assertions pass**

Run: `bash tests/all.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add docs/coach/protocols.md tests/foundation.sh
git commit -m "$(cat <<'EOF'
Apply difficulty modifier to observed.md trajectory aggregates

Adds step 8 to the observed.md update protocol: per-session
contributions are weighted by difficulty (hard=1.0, medium=0.6,
easy=0.3). Numerators become fractional. Pre-difficulty sessions
default to hard for trajectory continuity. Updates the
staff_method_trajectory yaml example to the weighted form.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add difficulty-conditioned drive-vs-wait note to rubric.md

**Files:**
- Modify: `tests/foundation.sh` (append 1 assertion before the final `echo` line)
- Modify: `docs/coach/rubric.md` (append paragraph to § Drive vs wait)

- [ ] **Step 1: Write the failing test**

Open `tests/foundation.sh`. Insert this line immediately before the final `echo "Phase 1 foundation tests passed."` line:

```bash
assert_grep "Difficulty-conditioned logging" "docs/coach/rubric.md"
```

- [ ] **Step 2: Run the test suite and verify it fails**

Run: `bash tests/all.sh`
Expected: FAIL with `FAIL: pattern 'Difficulty-conditioned logging' not in docs/coach/rubric.md`.

- [ ] **Step 3: Append the Difficulty-conditioned logging paragraph to § Drive vs wait**

Locate `## Drive vs wait (pivotal cross-cutting moment)` in `docs/coach/rubric.md`. The section currently ends with:

```markdown
This is the L5/L6 pivot. Logged as a `pivotal_moment` in every `/mock-loop` session artifact.
```

Append the following block immediately after that line (preserving the blank line before the next `## Pivotal-moment principle` heading):

```markdown

**Difficulty-conditioned logging.** This pivotal moment is logged in the session artifact based on the session's `difficulty.level`:

- **Hard:** logged normally — the canonical instance is failing to pick a deep-dive topic when the coach was silent.
- **Medium:** logged only on signals where the coach was silent (HLD-focus selection, within-topic depth). The deep-dive-selection sub-signal is N/A because protocol made the coach drive it.
- **Easy:** not logged. The coach drove the meaningful inflection points by protocol; insufficient candidate-driven moments remain to produce a meaningful signal.

The session artifact's `difficulty.drive_vs_wait_logged` flag (per `.claude/commands/mock-loop.md` § Closing assessment step 6) records the per-session outcome.
```

- [ ] **Step 4: Run the test suite and verify the new assertion passes**

Run: `bash tests/all.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/coach/rubric.md tests/foundation.sh
git commit -m "$(cat <<'EOF'
Document difficulty-conditioned drive-vs-wait logging

Appends a paragraph to rubric.md § Drive vs wait stating that the
pivotal moment is logged fully at hard, partially at medium
(non-coach-driven signals only), and not at all at easy. References
the difficulty.drive_vs_wait_logged artifact field as the per-session
record.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Final test suite confirmation

This task is a verification gate, not a code change. No commit expected.

- [ ] **Step 1: Run the full test suite**

Run: `bash tests/all.sh`
Expected: ALL phases pass.

- [ ] **Step 2: Spot-check the 12 new assertions count**

Run: `grep -c "2026-05-21" tests/foundation.sh tests/mock-loop.sh`
Expected: `tests/foundation.sh:1` and `tests/mock-loop.sh:1` (each file has one "new in 2026-05-21 design" comment marker). Total of 6 new assertion lines in foundation.sh and 6 in mock-loop.sh.

If counts don't match, investigate before declaring done.

---

## Task 8: Manual smoke verification (deferred to user)

This task is verification, not code. No commits expected unless a regression is found.

- [ ] **Step 1: `/mock-loop tinyurl easy`**

Run an interactive `/mock-loop tinyurl easy` session. Verify:
- Requirements phase begins with the coach naming rough FR/NFR areas (*"think about read vs write paths, scale targets, and consistency model"*).
- HLD phase begins with a one-sentence focus prompt.
- Deep Dives begins with 3–5 named topics announced up-front.
- Closing artifact has `difficulty: { level: easy, source: cli, drive_vs_wait_logged: false }`.

- [ ] **Step 2: `/mock-loop tinyurl medium`**

Verify:
- Coach is silent through Requirements, Entities, API, HLD.
- In Deep Dives, coach picks one topic and asks.
- Closing artifact has `level: medium, drive_vs_wait_logged: true` only if HLD-focus or within-topic-depth signals fired.

- [ ] **Step 3: `/mock-loop tinyurl hard`**

Verify:
- Coach silent across all 5 phases except for the four existing intervention rules.
- Deep Dives does NOT auto-pick a topic when the candidate is silent (this is a behavior change from pre-2026-05-21).
- Closing artifact has `level: hard, drive_vs_wait_logged: true`.

- [ ] **Step 4: `/mock-loop tinyurl hard adversarial`**

Verify both hard behaviors AND adversarial pushback are active.

- [ ] **Step 5: Recommendation with ≥3 prior sessions**

With ≥3 prior `/mock-loop` sessions in `observed.md`, run `/mock-loop tinyurl` (no difficulty arg). Verify the coach announces *"Based on your last 3 sessions, recommending <level>"* and the level matches the pass-count logic.

- [ ] **Step 6: Recommendation fallback with <3 prior sessions**

With fewer than 3 prior sessions, verify the fallback recommends medium.

- [ ] **Step 7: Mid-session override**

After a `/mock-loop tinyurl medium` opening, type `hard`. Verify the coach honors the override mid-session and the closing artifact records `source: overridden_mid_session, level: hard`.

- [ ] **Step 8: Weighted observed.md trajectory**

After running a mix of difficulties across ≥3 sessions, open `state/observed.md`. Verify:
- `staff_method_trajectory` numerators are fractional (e.g., `2.6/4 demonstrated`).
- `breadth_menu_count_weighted` is a float.

If any smoke test fails, file the regression as a bug; do not amend the prior commits.

---

## Notes for the implementer

- **TDD order matters.** Each task writes the failing test first and runs it to confirm a real failure before making the doc change. The failing-run step is the only thing that catches a copy-paste error in the assertion regex.
- **Behavior change at hard.** Today's `mock-loop.md` Deep-Dives step auto-picks a topic when the candidate is silent. The plan REMOVES this fallback at hard (it stays at medium). Make sure step 6 of Task 3 fully replaces the old sentence — don't leave the auto-pick instruction.
- **Cross-task file ordering.** Tasks 2, 3, and 4 all edit `.claude/commands/mock-loop.md` and `tests/mock-loop.sh`. Execute them in order — each task assumes the prior task's edits are present.
- **State file rule unchanged.** No `state/*` files are edited in this plan. The LLM populates `state/observed.md` and `state/sessions/*.md` at session-end per the rules documented in `protocols.md` and `mock-loop.md`. Static tests verify the *spec* (the command prompt and protocol docs); runtime correctness is the smoke-test job.
- **Existing assertions must keep passing.** All foundation, mock-loop, practice-problem, study-patterns, first-run, tone-discipline, and staff-method assertions stay green throughout. If any go red, you've introduced a regression — don't paper over it by editing the existing assertion.
- **Branch policy reminder.** Work on `main`. Do not push without explicit user authorization.

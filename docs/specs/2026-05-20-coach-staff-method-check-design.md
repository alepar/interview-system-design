# Coach Staff-Method Check — Design

*Date: 2026-05-20*
*Status: v1 design, approved through brainstorming. Ready for implementation planning.*
*Companion docs: `docs/specs/2026-05-12-coach-design.md` (v1 coach spec), `docs/specs/2026-05-12-coach-tone-discipline-design.md` (tone rules this check honors).*

---

## 1. Context

The `/mock-loop` workflow grades candidate performance against the four-dimension rubric in `docs/coach/rubric.md`. The Solution Design Staff+ bar currently anchors on the Hello Interview *"40% breadth and 60% depth"* quote, and Problem Navigation Staff+ anchors on Stefan Mai's *"good staff-level engineers design simple systems"* quote — but neither explicitly grades the *method* by which a Staff+ candidate arrives at a design: starting from a simple workable baseline, identifying the bottleneck, naming ways to resolve, stating criteria guiding tech selection, and committing to one choice.

A specific failure mode this misses: a candidate names a concrete technology (*"I'd use DynamoDB"*) without surfacing the criteria — write QPS shape, key cardinality, consistency model — that should have led there. At Staff+, the *commit* is required (per Stefan Mai's option-listing principle in §Communication), but so is the *reasoning trace* that justifies the commit. Without the trace, the interviewer cannot distinguish a calibrated choice from name-dropping.

This design adds a **staff-method sub-bar** under Solution Design Staff+, observed silently mid-flow and graded at debrief. Optionally, the candidate may enumerate 2–3 candidate technologies with one-line pro/con before committing — this earns a breadth bonus but is not required (the commit itself is required, per Stefan Mai). The check is level-conditioned: not graded at L4, treated as a reach signal at L5, required at L6+.

---

## 2. Goals, non-goals, success criteria

### Goals

1. The Solution Design Staff+ anchor in `rubric.md` explicitly documents the top-down method sub-bar: simple → bottleneck → resolution → criteria → commit.
2. The session artifact written by `/mock-loop` carries a structured `staff_method` field with three slots, so the signal persists session-over-session.
3. Mid-flow coach speech remains silent on this check, honoring the existing tone discipline rules (`protocols.md` § Tone and feedback discipline / Mid-flow vs debrief). The check surfaces only in the closing assessment.
4. Level-conditioned grading: L4 not graded, L5 reach signal (above-bar when demonstrated, neutral when missed), L6+ required (below-bar when missed). Implemented via a small table beneath the new sub-bar.
5. The breadth-menu bonus (2–3 candidates with pro/con) is recorded as an above-bar callout when present, never penalized when absent.
6. The `observed.md` update protocol gains a `staff_method_trajectory` field tracking demonstrated/missed counts over the last 5 `/mock-loop` sessions, so the coach can bias the "Recommended next session" line.

### Non-goals

- New mid-flow intervention rules. The check is debrief-only by design — adding a new mid-flow prompt would conflict with the four-moves restriction in `protocols.md` § Mid-flow vs debrief.
- Retroactive editing of existing session artifacts (`state/sessions/*.md` predating this change are historical record; no `staff_method` backfill).
- Changes to `/practice-problem` or `/study-patterns`. The check only fires in `/mock-loop` because the FSM provides the HLD → Deep-Dive arc the check observes.
- LLM-output runtime tests of staff_method classification (too brittle for the static-test layer; manual smoke is the verification path, same shape as the tone discipline spec).

### Success criteria (testable)

1. `bash tests/all.sh` passes with new assertions checking: rubric sub-bar text presence, level-conditioned table presence, protocols.md cross-reference, mock-loop.md closing-assessment sub-step, artifact schema documented.
2. Manual smoke test of `/mock-loop`: a session ending with `commit_with_criteria: missed` produces a "What was wrong" bullet citing the Staff+ method sub-bar anchor.
3. Manual smoke test: a session with `breadth_menu: demonstrated` produces an above-bar callout in the debrief and increments the breadth_menu_count in `observed.md`.
4. Manual smoke test: mid-flow coach speech contains zero references to the staff-method check (no *"start simpler"*, no *"what criteria led to that?"* triggered by this check alone — though existing specificity questions for unrelated reasons may still fire).
5. All existing foundation / mock-loop / practice-problem / study-patterns / first-run / tone-discipline assertions still pass.

---

## 3. Architectural shape

The change spans the rubric, protocols, mock-loop command, and tests. The session artifact gets a new structured field; `observed.md` gets a trajectory section.

| File | Change | Approx. size |
|---|---|---|
| `docs/coach/rubric.md` | Append method sub-bar paragraph + level-conditioned table to Solution Design Staff+ anchor | ~18 lines |
| `docs/coach/protocols.md` | Add one-liner in § Tone and feedback discipline pointing to the silent-mid-flow nature; extend observed.md update protocol with trajectory rule | ~8 lines |
| `.claude/commands/mock-loop.md` | Add "fill staff_method" sub-step to Closing assessment; document artifact field shape | ~12 lines |
| `tests/mock-loop.sh` | New static assertions for rubric text, table, artifact schema, anchor citation | ~8 lines |
| `tests/foundation.sh` | One cross-reference assertion for protocols.md | ~2 lines |
| `state/observed.md` | Updated at session end (no edit to the template; the update protocol writes it) | n/a |
| `docs/coach/personas/interviewer.md` | No edit — existing "Tone discipline" cross-ref already pulls in protocols.md | 0 |

**Why Solution Design and not Technical Excellence.** The check is fundamentally about *how the candidate builds the design top-down* — that is a Solution Design behavior. Technical Excellence (Temporal.io anchor) grades depth on individual components after the architecture is in place. The two are complementary; the staff-method check belongs under the dimension that grades architectural progression.

**Why debrief-only.** The existing tone discipline rules restrict mid-flow speech to four kind moves (procedural / constraint injection / specificity question / category-level gap flag). Adding a fifth move for staff-method would create a fifth class of mid-flow speech, against the spirit of the tone-discipline spec. Silent observation + debrief surfacing fits the established `bluff_flag` pattern.

**Why structured artifact field, not free-text.** A three-slot enum lets `observed.md` track trajectory mechanically (count of `demonstrated` / `missed` over a window). A free-text note would require LLM re-parsing at every session-end. The structured shape is also testable via static assertions.

---

## 4. Content: rubric sub-bar and level-conditioned table

Append to `docs/coach/rubric.md` § Solution Design → Staff+ bar, after the existing Hello Interview 40/60 breadth/depth quote (line 26 area):

```markdown
**Method sub-bar (Staff+).** A Staff+ design progresses top-down: simplest workable baseline → name the bottleneck → describe ways to resolve → state criteria guiding the tech selection → commit to one choice. Optionally enumerate 2–3 candidate technologies with one-line pro/con before committing (breadth bonus, not required). The anti-pattern is naming a specific technology (*"I'd use DynamoDB"*) without surfacing the criteria that led there. Per Stefan Mai's option-listing principle (see Communication anchor), the commit is required even when the menu is shown — never kick the decision back to the interviewer.

| Target level | Simple→bottleneck arc | Commit-with-criteria | Breadth menu (optional) |
|---|---|---|---|
| L4 (Mid) | not graded | not graded | demonstrated → above-bar signal |
| L5 (Senior) | demonstrated → above-bar; missed → neutral | at-bar expectation | demonstrated → above-bar signal |
| L6+ (Staff+) | required (missed → below-bar) | required (missed → below-bar) | demonstrated → above-bar bonus |

This check is observed silently mid-flow per `docs/coach/protocols.md` § Tone and feedback discipline / Mid-flow vs debrief; it surfaces only in the closing assessment.
```

---

## 5. Content: protocols.md cross-reference and observed.md update rule

### Cross-reference in § Tone and feedback discipline

Append one line at the end of the existing "Mid-flow vs debrief" subsection (before the "Numeric-commit calibration" subsection):

```markdown
The staff-method sub-bar in `docs/coach/rubric.md` § Solution Design Staff+ is observed silently mid-flow under the same rule — debrief-only.
```

### Extension to observed.md update protocol

Append step 7 to § observed.md update protocol (after the existing step 6 "Update scaffolding level"):

```markdown
7. Update staff_method trajectory: count `demonstrated` / `missed` for `simple_to_bottleneck_arc` and `commit_with_criteria` across the last 5 `/mock-loop` sessions where each slot was graded (sessions with `not_graded` excluded from the denominator). Record `breadth_menu_count` as count-of-demonstrated over the same window. The "Recommended next session" line may bias toward archetypes where `commit_with_criteria` is recurring `missed`.
```

The matching field shape in `observed.md`:

```yaml
staff_method_trajectory:
  window_sessions: 5
  simple_to_bottleneck_arc: "3/4 demonstrated"
  commit_with_criteria: "2/4 demonstrated"
  breadth_menu_count: 1
```

---

## 6. Content: mock-loop.md closing-assessment sub-step and artifact schema

### Closing-assessment sub-step

In `.claude/commands/mock-loop.md` § Closing assessment, add a new step 5 after the existing step 4 ("Overall") and before the "Grading" prose line:

```markdown
5. **Fill staff_method.** Before writing the session artifact, classify each slot from the transcript:

   - `simple_to_bottleneck_arc`: `demonstrated` if HLD or Deep-Dive showed simple-baseline → named-bottleneck → resolution arc; `missed` if depth dives happened with no baseline-bottleneck framing; `not_graded` if target_level is L4 and the marker was absent.
   - `commit_with_criteria`: `demonstrated` if at least one tech choice stated criteria and committed to one option; `missed` if a tech was named without surfacing criteria; `not_graded` if target_level is L4 and the marker was absent.
   - `breadth_menu`: `demonstrated` if the candidate enumerated 2–3 candidates with one-line pro/con before committing on any decision; `absent` otherwise (never penalized — only the positive case is recorded).

   Cite the Staff+ method sub-bar anchor in any "What was correct" / "What was wrong" bullet derived from these slots.
```

### Artifact schema documentation

Update `.claude/commands/mock-loop.md` § Session end step 1 to include the new field in the inline field listing. Change:

```markdown
1. Write `state/sessions/YYYY-MM-DD-mock-<slug>.md` with the common header + the closing assessment sections + the user's calibration prediction + any bluff_flags + pivotal moments.
```

to:

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

---

## 7. Tests

Append to `tests/mock-loop.sh`:

```bash
# Staff-method sub-bar
assert_grep "Method sub-bar.*Staff" "docs/coach/rubric.md"
assert_grep "simple.*workable baseline.*bottleneck" "docs/coach/rubric.md"
assert_grep "commit to one choice" "docs/coach/rubric.md"
assert_grep "Target level.*Simple.*bottleneck arc.*Commit-with-criteria.*Breadth menu" "docs/coach/rubric.md"

# mock-loop.md closing-assessment sub-step + schema documentation
assert_grep "Fill staff_method" ".claude/commands/mock-loop.md"
assert_grep "simple_to_bottleneck_arc.*demonstrated.*missed.*not_graded" ".claude/commands/mock-loop.md"
assert_grep "commit_with_criteria" ".claude/commands/mock-loop.md"
assert_grep "breadth_menu.*demonstrated.*absent" ".claude/commands/mock-loop.md"
```

Append to `tests/foundation.sh`:

```bash
# Protocols.md cross-references for staff-method check
assert_grep "staff-method sub-bar" "docs/coach/protocols.md"
assert_grep "staff_method_trajectory|staff_method trajectory" "docs/coach/protocols.md"
```

Ten new assertions. All are structural-marker checks — they verify that the rubric text, command sub-step, and protocols cross-reference exist, not that the LLM correctly classifies any specific transcript.

---

## 8. Verification

**Automated (cheap):**

- `bash tests/all.sh` passes with the ten new assertions.
- All existing foundation / mock-loop / practice-problem / study-patterns / first-run / tone-discipline assertions still pass.

**Manual smoke test (the real verification):**

- Run a `/mock-loop` session for a known-archetype problem. During HLD/Deep-Dive, deliberately name a tech choice (e.g., "DynamoDB") without stating criteria. Verify:
  - Mid-flow: coach does NOT say *"why DynamoDB?"* triggered by this check (other reasons may fire a specificity question; that's fine).
  - Debrief: session artifact contains `staff_method.commit_with_criteria: missed` and a "What was wrong" bullet citing the Staff+ method sub-bar.
- Run a second session where the candidate enumerates 2–3 options with pro/con before committing. Verify:
  - Artifact contains `breadth_menu: demonstrated`.
  - Debrief contains an "above bar" callout for the breadth menu.
- After two sessions, verify `state/observed.md` has a `staff_method_trajectory` block with non-zero counts.
- Run a third session where `profile.target_level` is L4. Deliberately omit the arc. Verify artifact records `not_graded` (not `missed`) and no negative bullet appears in the debrief.

---

## 9. Rationale notes

**Why level-conditioned interpretation instead of Staff+-only.** A Senior candidate (L5) targeting Staff often demonstrates the method without being held to it; logging `demonstrated` as above-bar gives the coach a positive growth signal for "Recommended next session" pacing. An L4 candidate hitting the marker is an even stronger signal but shouldn't be penalized for missing it. The "always observed, level-conditioned interpretation" branch from brainstorming captures all three cases cleanly with one observation rule.

**Why breadth menu is optional but the commit is required.** Per Stefan Mai's option-listing principle (`rubric.md:51`), enumerating 2–4 options and kicking the decision back to the interviewer is the named anti-pattern. The reconciliation: think the menu, but commit out loud — surface the menu briefly as justification for the commit, never as a question. This design encodes that exactly: `breadth_menu: demonstrated` is the brief menu *plus* the commit; the menu alone (without commit) would still trip `commit_with_criteria: missed`.

**Why structured `not_graded` instead of omitting the field.** Omitting fields for L4 sessions would make trajectory counting fragile (does absent mean "not graded" or "graded as missed"?). Explicit `not_graded` makes the denominator computation unambiguous in step 7 of the observed.md update protocol.

**Why no Solution Design L4/L5 anchor changes.** The existing L4/L5 anchors (mid-level "end-to-end solution that probably isn't optimal", senior "60% breadth / 40% depth") are about output shape, not method. The staff-method check is a Staff+ behavior; the table beneath it documents the L4/L5 grading rules, but the L4/L5 anchors themselves don't need to change.

**Why `tests/mock-loop.sh` for most assertions, `tests/foundation.sh` for protocols cross-refs.** The rubric text and command sub-step are mock-loop-specific (they govern that workflow). The protocols cross-refs apply across workflows in principle (debrief-only observation is a tone rule) and live with the other foundational assertions.

---

## 10. Open questions

None. All discussion points were resolved during brainstorming:

- Mid-flow manifestation: **debrief-only signal** (resolved).
- Granularity: **one combined staff-method check** (resolved).
- Rubric anchor: **Solution Design Staff+** (resolved).
- Trigger recipe: **3-step arc + commit-with-criteria, with optional breadth menu bonus** (resolved).
- Level scope: **all levels, level-conditioned interpretation** (resolved).
- Implementation approach: **Approach A — sub-bar + structured artifact field** (resolved).

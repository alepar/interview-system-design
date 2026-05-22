# Coach Difficulty Knob for /mock-loop — Design

*Date: 2026-05-21*
*Status: v1 design, approved through brainstorming. Ready for implementation planning.*
*Companion docs: `docs/specs/2026-05-12-coach-design.md` (v1 coach spec), `docs/specs/2026-05-12-coach-tone-discipline-design.md` (tone rules), `docs/specs/2026-05-20-coach-staff-method-check-design.md` (staff-method check this design extends).*

---

## 1. Context

The `/mock-loop` workflow currently runs a single FSM where the coach is silent during HLD and earlier phases and auto-picks a deep-dive topic only when the candidate is visibly stuck. This is roughly a "medium" experience for an unprepared candidate (some coach drive on deep-dives) and a "hard" experience for an experienced one (coach mostly silent). The workflow exposes one orthogonal switch — `adversarial` — that controls *push* (pushback intensity) but not *drive* (how much the coach proactively structures the conversation).

For self-paced practice, users at different readiness levels benefit from different amounts of coach guidance. A user three months from their interview wants the coach to surface FR/NFR areas and announce deep-dive topics up-front; a user one week out wants the coach silent unless they bluff. The current FSM only serves the second case well.

This design adds a `difficulty` knob with three named levels — `easy`, `medium`, `hard` — that's **orthogonal** to the existing `neutral`/`adversarial` switch (so 6 valid combinations). Difficulty controls *what the coach proactively does* per phase; the push axis controls *how the coach reacts* to candidate moves. The CLI accepts an explicit difficulty; otherwise the coach recommends one based on the last 3 sessions' performance. Grading is unaffected mechanically, but session-level observed.md trajectories weight contributions by difficulty (easy=0.3, medium=0.6, hard=1.0) so demonstrated signals at easy don't masquerade as the same evidence as hard.

---

## 2. Goals, non-goals, success criteria

### Goals

1. Add a `difficulty` knob to `/mock-loop` with three levels (`easy`, `medium`, `hard`), orthogonal to the existing `adversarial` switch.
2. CLI grammar accepts the difficulty as an optional positional argument (`/mock-loop <slug> easy adversarial`). When omitted, the coach recommends a level based on the last 3 sessions' performance.
3. Per-phase coach behavior is explicitly documented in a 3×5 table in `docs/coach/personas/interviewer.md`. Each FSM phase in `.claude/commands/mock-loop.md` references the table with a short "At <level>:" clause.
4. The session artifact records `difficulty.level`, `difficulty.source` (cli / recommended / overridden_mid_session), and `difficulty.drive_vs_wait_logged` so trajectories can be reconstructed and grading reasoning is auditable.
5. `state/observed.md` trajectory updates apply a difficulty weight (`{easy: 0.3, medium: 0.6, hard: 1.0}`) to per-session contributions so easy sessions don't get full credit toward mastery counts.
6. `rubric.md` § Drive vs wait documents that the pivotal moment is logged at hard fully, at medium only for non-coach-driven phases, and not at all at easy.

### Non-goals

- Difficulty extension to `/practice-problem` or `/study-patterns`. Those workflows don't have the FSM the difficulty knob modulates. If the concept generalizes later, it migrates to `protocols.md` then.
- Adversarial-mode changes. Adversarial keeps its existing semantics (gated on 3+ archetype sessions; pushback allowed) and the existing carve-outs in `protocols.md` § Tone and feedback discipline / Adversarial mode.
- Auto-promotion across difficulties. The recommendation logic in this design is read-only; it does not auto-update profile defaults or auto-graduate the user. The user is in control via CLI override.
- Retroactive backfill of `difficulty` on pre-existing session artifacts. Sessions in `state/sessions/` before this lands have no `difficulty` block; the observed.md trajectory step 8 treats absent `difficulty.level` as `hard` (current default behavior) when re-aggregating.
- LLM-output runtime tests of the FSM behavior at each level. Same rationale as prior specs — static-test layer verifies structure; manual smoke is the verification path.

### Success criteria (testable)

1. `bash tests/all.sh` passes with 12 new assertions: 6 foundation (rubric, protocols, interviewer.md additions) and 6 mock-loop (CLI parsing, recommendation step, opening phrasing, artifact field).
2. Manual smoke: `/mock-loop tinyurl easy` produces a Requirements-phase coach prompt suggesting FR/NFR areas, an HLD focus prompt, and a deep-dive topic announcement up-front.
3. Manual smoke: `/mock-loop tinyurl medium` is silent through Requirements/Entities/API/HLD; picks one deep-dive topic in the deep-dive phase.
4. Manual smoke: `/mock-loop tinyurl hard` is silent across all 5 phases except for the existing four intervention rules (time warnings, stuck-prompts, bluff markers, category-level gap flags). No deep-dive auto-pick.
5. Manual smoke: `/mock-loop tinyurl` (no difficulty arg) with ≥3 prior sessions produces a recommendation announcement based on pass count.
6. Manual smoke: typing `easy` / `medium` / `hard` mid-session after the opening produces a mid-session override; the closing artifact records `difficulty.source: overridden_mid_session`.
7. All existing foundation / mock-loop / practice-problem / study-patterns / first-run / tone-discipline / staff-method assertions still pass (no regression).

---

## 3. Architectural shape

The design fits the existing pattern set by adversarial mode: a persona-level knob documented in `interviewer.md`, plumbed through `mock-loop.md` via argument parsing and per-phase clauses, with trajectory effects in `protocols.md` and a pivotal-moment carve-out in `rubric.md`.

| File | Change | Approx. size |
|---|---|---|
| `docs/coach/personas/interviewer.md` | Add `## Difficulty levels` section with 3×5 behavior table and drive-vs-wait table | ~40 lines |
| `.claude/commands/mock-loop.md` | Rewrite argument parsing (step 5); add `## Difficulty recommendation` subsection; insert one-line "At <level>:" clauses in 3 FSM phases (Requirements, HLD, Deep Dives — rewrite the Deep Dives sentence); add Difficulty bullet to Opening; add Closing assessment step 6 (Fill difficulty record); update Session end step 1 with new artifact field | ~50 lines |
| `docs/coach/protocols.md` | Append step 8 to § observed.md update protocol (difficulty modifier); update the existing `staff_method_trajectory` example yaml in step 7 to reflect fractional numerators | ~12 lines |
| `docs/coach/rubric.md` | Append "Difficulty-conditioned logging" paragraph to § Drive vs wait | ~8 lines |
| `tests/foundation.sh` | 6 new assertions | ~8 lines |
| `tests/mock-loop.sh` | 6 new assertions | ~8 lines |

No new files. No state-schema changes outside what `mock-loop.md` documents inline (artifact field shape). The slash command prompt is the schema.

**Why orthogonal axes instead of a single 5-level dial.** Difficulty (drive) and push (neutral/adversarial) measure different things. A candidate practicing under-prepared still benefits from coach pushback if their plan is wrong; a candidate practicing while well-prepared benefits from silence on guidance but pushback on tech choices. Collapsing onto one dial loses this — for example, "hard + neutral" (the current default behavior) and "hard + adversarial" (the current `/mock-loop <slug> adversarial`) would both have to be the same mode under collapse. Six combinations is the minimum that preserves both signals.

**Why a fixed weight table instead of per-user calibration.** The weights `{0.3, 0.6, 1.0}` are deliberately simple. Per-user calibration (e.g., "for this user, easy contributes 0.5 because they're a fast learner") would require new state and a re-aggregation mechanism. The simpler scheme works for the trajectory window (5 sessions) and can be revised later if needed.

**Why the recommendation is unweighted.** The recommendation is a *binary* signal — did this session demonstrate target_level on the two core skill dimensions? The difficulty modifier is for aggregated mastery counts (where a fractional contribution makes sense), not for a per-session classifier (where it doesn't).

---

## 4. CLI grammar, recommendation logic, opening announcement

### Argument grammar

```
/mock-loop [<slug>] [easy|medium|hard] [adversarial]
```

All three positional tokens optional. Slug must come first if present; difficulty and adversarial can appear in either order after.

Examples:
- `/mock-loop` — coach picks problem; coach recommends difficulty.
- `/mock-loop tinyurl` — load problem; coach recommends difficulty.
- `/mock-loop tinyurl medium` — explicit difficulty.
- `/mock-loop tinyurl hard adversarial` — fully explicit.
- `/mock-loop tinyurl adversarial` — backwards-compat: adversarial keeps working without difficulty; coach recommends.

### Recommendation logic

Runs only when no difficulty token was given.

1. Read `state/observed.md`. Look at the last 3 `/mock-loop` sessions in the trajectory window.
2. A session **passes** if both `level_demonstrated.solution_design` and `level_demonstrated.technical_excellence` are `≥ profile.target_level`.
3. Map pass count → recommendation:
   - 2 or 3 passes → `hard`
   - 1 pass → `medium`
   - 0 passes → `easy`
4. **Fallback** when fewer than 3 prior `/mock-loop` sessions exist (including zero): recommend `medium`.

The recommendation is used directly as the session's difficulty; the user can override mid-session by typing `easy` / `medium` / `hard` after the Opening.

### Opening announcement

Append a new bullet between "Persona mode" and "The problem statement" in `.claude/commands/mock-loop.md` § Opening:

```markdown
- Difficulty: *"Running as <level>. <one-line behavior summary>. Say 'easy', 'medium', or 'hard' to switch."*
```

Per-level one-line behavior summaries (verbatim):

- Easy: *"I'll guide requirements, HLD focus, and deep-dive topics."*
- Medium: *"I'll pick deep-dive topics; the rest is yours to drive."*
- Hard: *"You drive everything; I only step in for stuck-prompts or bluff markers."*

When the level came from a recommendation rather than from the CLI, prepend the one-line:

> *"Based on your last 3 sessions, recommending <level>."*

---

## 5. Difficulty levels section in `interviewer.md`

Insert a new `## Difficulty levels` section in `docs/coach/personas/interviewer.md` after the "Adversarial mode (opt-in)" subsection and before "Phase-transition language (verbatim)".

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

---

## 6. FSM updates in `.claude/commands/mock-loop.md`

### Argument parsing — rewrite § Problem selection and FSM setup, step 5

Replace the current 3-bullet parse with:

```markdown
5. Parse `$ARGUMENTS` (positional, order-insensitive after slug):
   - Tokens: `<slug>`, one of `easy|medium|hard`, optional `adversarial`.
   - Empty / no slug → pick a problem per the priority in protocols.md "Problem selection (for /mock-loop)".
   - No difficulty token → compute recommendation per § Difficulty recommendation below.
   - Difficulty token present → use it directly; skip the recommendation.
   - `adversarial` → check the adversarial gate (3+ prior sessions in the archetype in `state/observed.md`). If gate not met, decline and explain.
```

### New § Difficulty recommendation subsection

Insert between § Problem selection and § Opening:

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

The recommendation is used as the session's difficulty. Surface it in the Opening announcement so the user can override mid-session.
```

### Per-phase guidance — update § Phase-anchored FSM

- **Requirements:** append *"At easy: open the phase by suggesting rough FR/NFR areas to consider (per `personas/interviewer.md` § Difficulty levels). At medium/hard: no proactive guidance."*
- **Core Entities:** no change.
- **API Design:** no change.
- **HLD:** append *"At easy: open the phase with a one-sentence helping prompt for the focus area (per `personas/interviewer.md` § Difficulty levels). At medium/hard: no proactive guidance."*
- **Deep Dives:** rewrite the existing sentence `"If candidate doesn't proactively pick depth areas, pick one and ask. Log this as a pivotal turn (drive-vs-wait moment)."` to:

  > *"At easy: announce the topics to cover up-front (3–5 named bottleneck areas), then candidate drives within each. At medium: pick **one** deep-dive topic and ask, ensuring at least one named bottleneck area is covered. At hard: fully candidate-driven; coach does **not** pick a topic — silence is a signal, not a prompt. Log a pivotal turn (drive-vs-wait moment) only at hard if the candidate failed to drive, or at medium if the candidate failed to drive HLD-focus or within-topic depth."*

### Opening announcement bullet

Already specified in §4 above (CLI grammar / opening). Add it between "Persona mode" and "The problem statement" in the existing Opening verbatim list.

### Closing assessment step 6

Add a new step 6 after the existing step 5 (Fill staff_method) and before the "Grading" prose line:

```markdown
6. **Fill difficulty record.** Before writing the session artifact, populate:

   - `difficulty.level`: `easy | medium | hard` — the level actually run (after any mid-session overrides via the user typing `easy`/`medium`/`hard`).
   - `difficulty.source`: `cli | recommended | overridden_mid_session` — how this level was chosen. `cli` if it came from `$ARGUMENTS`; `recommended` if from § Difficulty recommendation and accepted; `overridden_mid_session` if the user switched after the opening.
   - `difficulty.drive_vs_wait_logged`: `true | false` — `true` at hard (always), `true` at medium (only if HLD-focus or within-topic-depth signals fired), `false` at easy.
```

### Session end step 1

Update step 1 to include the new artifact block in the inline field listing:

```markdown
1. Write `state/sessions/YYYY-MM-DD-mock-<slug>.md` with the common header + the closing assessment sections + the user's calibration prediction + any bluff_flags + pivotal moments + the `staff_method` field + the `difficulty` block with shape:

   ```yaml
   difficulty:
     level: easy | medium | hard
     source: cli | recommended | overridden_mid_session
     drive_vs_wait_logged: true | false
   ```
```

### Debrief surfacing

The Overall summary in step 4 of Closing assessment gets one additional one-liner: *"Difficulty: <level> (<source>). Next session recommendation: <next>."* No structural change to "What was correct" / "What was wrong" bullets.

---

## 7. observed.md trajectory modifier in `protocols.md`

### New step 8 in § observed.md update protocol

Append after the existing step 7 (`staff_method_trajectory`):

```markdown
8. Apply the difficulty modifier to per-session contributions. For each session in the trajectory windows used by steps 2, 5, 6, 7:
   - Hard sessions count at weight 1.0.
   - Medium sessions count at weight 0.6.
   - Easy sessions count at weight 0.3.

   Numerators stay fractional. Denominators stay integer (count of graded sessions in the window). Round displayed values to one decimal place. Example: 2 demonstrated at hard + 1 at medium + 1 at easy across 4 sessions → numerator = 2·1.0 + 1·0.6 + 0·0.3 = 2.6, displayed as `2.6/4 demonstrated`.

   Sessions written before this design landed (no `difficulty` block) are treated as `hard` (weight 1.0). This preserves trajectory continuity.
```

### Update `staff_method_trajectory` example yaml in step 7

Replace the existing example with the weighted form:

```yaml
staff_method_trajectory:
  window_sessions: 5
  simple_to_bottleneck_arc: "2.9/4 demonstrated"
  commit_with_criteria: "1.6/4 demonstrated"
  breadth_menu_count_weighted: 0.6
```

The `breadth_menu_count_weighted` field replaces `breadth_menu_count` since aggregated count is now fractional.

---

## 8. rubric.md drive-vs-wait note

Append to `docs/coach/rubric.md` § Drive vs wait, after the existing block:

```markdown
**Difficulty-conditioned logging.** This pivotal moment is logged in the session artifact based on the session's `difficulty.level`:

- **Hard:** logged normally — the canonical instance is failing to pick a deep-dive topic when the coach was silent.
- **Medium:** logged only on signals where the coach was silent (HLD-focus selection, within-topic depth). The deep-dive-selection sub-signal is N/A because protocol made the coach drive it.
- **Easy:** not logged. The coach drove the meaningful inflection points by protocol; insufficient candidate-driven moments remain to produce a meaningful signal.

The session artifact's `difficulty.drive_vs_wait_logged` flag (per `.claude/commands/mock-loop.md` § Closing assessment step 6) records the per-session outcome.
```

---

## 9. Tests

### Append to `tests/foundation.sh`

```bash
# Difficulty levels (new in 2026-05-21 design)
assert_section "Difficulty levels" "docs/coach/personas/interviewer.md"
assert_grep "easy.*medium.*hard|Easy.*Medium.*Hard" "docs/coach/personas/interviewer.md"
assert_grep "Drive-vs-wait logging by difficulty|Drive vs wait at non-hard" "docs/coach/personas/interviewer.md"
assert_grep "difficulty modifier|trajectory weight" "docs/coach/protocols.md"
assert_grep "weight 1.0|weight 0.6|weight 0.3" "docs/coach/protocols.md"
assert_grep "Difficulty-conditioned logging" "docs/coach/rubric.md"
```

### Append to `tests/mock-loop.sh`

```bash
# Difficulty knob (new in 2026-05-21 design)
assert_grep "Difficulty recommendation" ".claude/commands/mock-loop.md"
assert_grep "easy\\|medium\\|hard" ".claude/commands/mock-loop.md"
assert_grep "Fill difficulty record" ".claude/commands/mock-loop.md"
assert_grep "difficulty\\.source|difficulty_source" ".claude/commands/mock-loop.md"
assert_grep "drive_vs_wait_logged" ".claude/commands/mock-loop.md"
assert_grep "Running as.*level|Say.*easy.*medium.*hard" ".claude/commands/mock-loop.md"
```

12 new assertions. All structural — verify section presence, key phrases, modifier weights, artifact field names. The LLM is trusted to interpret the per-phase behavior tables; only structural markers are asserted.

---

## 10. Verification

**Automated (cheap):**

- `bash tests/all.sh` passes with all 12 new assertions.
- All existing foundation / mock-loop / practice-problem / study-patterns / first-run / tone-discipline / staff-method assertions still pass.

**Manual smoke tests (the real verification):**

1. Run `/mock-loop tinyurl easy`. Verify: Requirements phase begins with the coach naming rough FR/NFR areas; HLD phase begins with a one-sentence focus prompt; Deep Dives begins with 3–5 named topics announced up-front; closing artifact has `difficulty: easy, source: cli, drive_vs_wait_logged: false`.
2. Run `/mock-loop tinyurl medium`. Verify: coach is silent in Requirements/Entities/API/HLD; in Deep Dives, coach picks one topic to dig into; closing artifact has `difficulty: medium, drive_vs_wait_logged: true` only if HLD-focus or within-topic-depth signal fired.
3. Run `/mock-loop tinyurl hard`. Verify: coach silent across all 5 phases except for the existing four intervention rules; Deep Dives does NOT auto-pick a topic when the candidate is silent; closing artifact has `difficulty: hard, drive_vs_wait_logged: true`.
4. Run `/mock-loop tinyurl hard adversarial`. Verify: all hard behaviors AND adversarial pushback is allowed mid-flow; closing artifact reflects both.
5. With ≥3 prior `/mock-loop` sessions in `observed.md`, run `/mock-loop tinyurl` (no difficulty). Verify: coach announces *"Based on your last 3 sessions, recommending <level>"* with the level matching pass-count logic.
6. With <3 prior sessions, run `/mock-loop tinyurl`. Verify: recommendation defaults to medium with the same announcement pattern.
7. After a `/mock-loop tinyurl medium` opening, type `hard`. Verify: coach honors the override mid-session; closing artifact records `source: overridden_mid_session, level: hard`.
8. After running a mix of difficulties across ≥3 sessions, open `state/observed.md`. Verify: `staff_method_trajectory` numerators are fractional (e.g., `2.6/4 demonstrated`); `breadth_menu_count_weighted` is a float.

---

## 11. Rationale notes

**Why orthogonal axes instead of merging into the adversarial switch.** Drive (difficulty) and push (adversarial) are independent signals. Merging would force a single named mode to be both "easy + adversarial" and "hard + adversarial" simultaneously, which is incoherent — pushback only makes sense when the candidate is being pushed *on something they did*, but in easy the coach surfaces what to do. Orthogonality also leaves room for future per-axis evolution without re-shuffling named modes.

**Why a fixed weight table and not per-archetype.** The trajectory window is small (5 sessions); per-archetype weights would multiply the surface area by ~12. The simpler scheme is more legible to a reader of `observed.md`. Per-archetype calibration can be revisited if mastery signals get noisy.

**Why the recommendation uses Solution Design + Technical Excellence and not all four dimensions.** Problem Navigation at easy is partially coach-driven (FR/NFR areas suggested); Communication is hard to discount cleanly. Solution Design and Technical Excellence are the two dimensions where the candidate's actual technical chops surface regardless of difficulty. Using these two for the pass classifier matches what we'd want a recommendation to track.

**Why "passes" is `≥ profile.target_level` and not `at target_level` exactly.** Above-target-level (e.g., a Senior candidate hitting Staff bars) is a stronger pass than at-bar; treating both as a pass means a candidate growing into their target level isn't bounced down to easier difficulty unnecessarily.

**Why mid-session override is allowed.** The user might mis-estimate their readiness and want to switch (typically up — *"this is too hand-holdy, let me drive"*). Forcing them to abandon and restart loses transcript continuity. The `overridden_mid_session` source value preserves auditability of why the trajectory weight applied.

**Why pre-difficulty session artifacts default to hard in trajectory aggregation.** Pre-difficulty sessions ran what's now closest to hard (coach mostly silent except for deep-dive auto-pick fallback). Treating absent-difficulty as hard preserves the trajectory's continuity and doesn't artificially discount prior demonstrated signals.

**Why the auto-pick fallback at hard is removed.** Today's `mock-loop.md` step 5 says *"If candidate doesn't proactively pick depth areas, pick one and ask."* That behavior is now medium-mode. At hard, silence is a signal we want to capture in drive-vs-wait, not paper over with an auto-pick. This is a behavior change for users running `/mock-loop` today — flagged explicitly so verification catches it.

---

## 12. Open questions

None. All discussion points were resolved during brainstorming:

- Mode shape: **orthogonal (6 modes)** (resolved).
- Selection: **CLI arg + coach recommendation; fallback medium** (resolved).
- Per-phase behavior: **easy = R/HLD/DD guidance; medium = DD only; hard = none** (resolved).
- Grading impact: **grade everything, apply difficulty modifier to observed.md trajectory counts** (resolved).
- Recommendation source: **last 3 sessions, passes = SolDesign + TechEx ≥ target_level** (resolved).
- Drive-vs-wait: **logged at hard fully, at medium partially, not at easy** (resolved).
- Modifier weights: **{easy: 0.3, medium: 0.6, hard: 1.0}** (resolved).
- File layout: **interviewer.md (persona table) + mock-loop.md (FSM) + protocols.md (trajectory) + rubric.md (drive-vs-wait note)** (resolved).
- Pre-difficulty sessions in trajectory: **treated as hard** (resolved).

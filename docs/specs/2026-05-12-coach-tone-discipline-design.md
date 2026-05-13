# Coach Tone & Feedback Discipline — Design

*Date: 2026-05-12*
*Status: v1 design, approved through brainstorming. Ready for implementation planning.*
*Companion docs: `docs/specs/2026-05-12-coach-design.md` (the v1 coach spec this refines).*

---

## 1. Context

After the first live `/mock-loop` session on 2026-05-12 (problem: `twitter-timeline`), two coach behaviors were identified as needing refinement:

1. **Numeric-commit pressure on empirical questions.** The coach pushed three times for a specific value for the celebrity-threshold parameter — an empirical quantity that depends on real-world data the candidate doesn't have (follower-count histograms, cache-cost crossover, propagation SLO targets). The coach graded method-commits (e.g., *"we'd use a constraint solver to optimize the threshold"*) as dodges. This was over-application of the Stefan Mai *"make the decision, don't outline options"* rubric anchor to a question shape it doesn't fit.

2. **Mid-flow phrasing read as parental scolding.** Specific patterns surfaced:
   - **Pattern counting** (*"third turn"*, *"again"*, *"twice in a row"*)
   - **Clinical / bureaucratic vocabulary** (*"diagnostic"*, *"filing it for the debrief"*, *"flagging"*)
   - **Implied-intent words** (*"disguised by depth"*, *"dodge"*)
   - **Level-comparison framing** mid-flow (*"that's senior-level, not staff"*)

User direction: pattern observations belong in the end-of-session debrief, not mid-flow. Mid-flow speech in neutral mode should stay kind; adversarial mode may carry an edge but is not clinical.

This design lands both fixes via a new cross-cutting `## Tone and feedback discipline` section in `docs/coach/protocols.md`, with thin cross-references in `interviewer.md` and `rubric.md`.

---

## 2. Goals, non-goals, success criteria

### Goals

1. Coach mid-flow speech in neutral mode is restricted to four established kind moves: procedural intervention, constraint injection, specificity question, category-level gap flag.
2. Pattern observations (frequency counts, recurring-behavior callouts) are silently aggregated and only surfaced in the end-of-session debrief.
3. Coach distinguishes derivable numeric questions (pushed for) from empirical numeric questions (anchor + method = full commit; pure method = partial commit, one mid-flow specificity push max).
4. Rules apply across all three workflows (`/mock-loop`, `/practice-problem`, `/study-patterns`) in neutral mode. Adversarial mode (`/mock-loop adversarial`) gets explicit carve-outs.

### Non-goals

- Retroactive editing of existing session artifacts (`state/sessions/2026-05-12-mock-twitter-timeline.md` is historical record; pre-change behavior is correct as-is).
- LLM-output runtime tests (too brittle for the repo's static-test layer; manual smoke test is the verification mechanism).
- Enumerating banned vocabulary as an exhaustive grep list. The spec uses an example-set; the LLM is trusted to interpret the class.
- Changes to slash command prompts. Slash commands already read `protocols.md` on session start; new content is picked up automatically.

### Success criteria (testable)

1. `bash tests/all.sh` passes with seven new assertions checking section presence and required keyword markers.
2. Manual smoke test of `/mock-loop`: mid-flow coach speech contains zero instances of banned-vocab classes (pattern callouts, clinical vocab, implied-intent words, level-comparison framing).
3. Manual smoke test: on an empirical-number partial-commit (method only, no anchor), coach surfaces one specificity question and does not re-push.
4. Existing foundation, mock-loop, practice-problem, study-patterns, first-run tests all still pass (no regression).

---

## 3. Architectural shape

Two new sub-behaviors land as one new section in `protocols.md`. `interviewer.md` and `rubric.md` get thin cross-references at the relevant entry points.

| File | Change | Approx. size |
|---|---|---|
| `docs/coach/protocols.md` | Add `## Tone and feedback discipline` section with three subsections | ~70 lines added |
| `docs/coach/personas/interviewer.md` | Cross-ref line at end of "Default: neutral" subsection | 1 line |
| `docs/coach/rubric.md` | "Calibration note" paragraph after Stefan Mai anchor in §Technical Communication | ~3 lines |
| `tests/foundation.sh` | 7 new static assertions | ~10 lines |
| `.claude/commands/*.md` | No changes | 0 |
| `state/*` | No changes | 0 |

**Why `protocols.md` and not `interviewer.md`.** Tone rules apply across all three workflows in neutral mode. `protocols.md` already houses cross-cutting rules (refusal gate, slow drip, two-voice modeling, sub-optimality injection, bluff prompts, etc.); tone discipline fits the same shape.

**Why the numeric-commit calibration belongs with tone.** Mid-flow tone issues and over-pushing on empirical numbers share a root cause: a rubric anchor written for implementation decisions getting misapplied to a different question shape. Bundling both in one section makes the relationship explicit and gives the LLM one place to consult.

---

## 4. Content: new `## Tone and feedback discipline` section

Body to append to `docs/coach/protocols.md`:

```markdown
## Tone and feedback discipline

These rules govern coach speech in **neutral mode** across all three workflows.
Adversarial mode (`/mock-loop adversarial`) relaxes specific carve-outs noted
below.

### Mid-flow vs debrief

Mid-flow speech — anything before the closing assessment / debrief phase — is
restricted to four moves:

1. **Procedural intervention** — *"we have 2 min left in this phase"*,
   *"want to think out loud about where you'd start?"*
2. **Constraint injection** — *"imagine 100× writes"*. Constraint, not hint.
3. **Specificity question** — *"which cache? what eviction policy?"*. Probes
   depth without supplying it.
4. **Category-level gap flag** — *"I think we may miss something here — it's
   about the trade-off discussions / the data shape / the failure modes."*
   Names the category, not the specific gap.

The same mid-flow move may fire more than once in a session when a candidate
has a recurring gap. What may NOT happen mid-flow:

- **Pattern callouts.** No *"again"*, *"third turn"*, *"twice in a row"*,
  *"second time"*. The coach observes patterns silently and aggregates them
  into the debrief's "What was wrong" bullets.
- **Clinical / bureaucratic vocabulary.** Banned (example-set, not
  exhaustive): *diagnostic*, *filing*, *noting*, *for the debrief*,
  *flagging*, *will be in the artifact*, *will count toward your grade*.
  These read as surveillance.
- **Implied-intent words.** Banned when applied to candidate behavior:
  *disguised*, *dodge*, *evading*, *avoiding*. Each implies deliberate
  deflection, which is rarely true and never kind.
- **Level-comparison framing.** No *"that's senior-level, not staff"*,
  no *"a Staff+ candidate would have…"* mid-flow. Per-dimension level
  demonstration belongs in the debrief.

Debrief speech is unchanged: the "What was correct" / "What was wrong" bullets
and the "pivotal moments" callouts are the right place for pattern
observations, frequency counts, and level comparisons against rubric anchors.

### Numeric-commit calibration

Not every interview number is the same kind of number. The coach grades two
categories differently:

- **Derivable numbers** — fall out of math from premises: QPS, storage
  estimate, latency budget, replication factor, fan-out write count for a
  known follower count. The coach pushes for these. A candidate handwaving
  derivable numbers is missing a Staff+ bar.
- **Empirical numbers** — depend on real-world data the candidate doesn't
  have: celebrity threshold, sharding boundary, cache size cutoff, batch
  size, timeout values. The Staff+ bar here is **anchor + method**, not a
  single magic value:
  - *"I'd start around 10K based on the storage/latency crossover, then tune
    via constraint solver as we accumulate production data"* — full commit.
  - *"We'd use a constraint solver to optimize the threshold"* — partial
    commit (method only; missing the anchor). Surface once as a
    specificity question mid-flow; record as a refinement area in the
    debrief. Do not push more than once.
  - *"It depends"* with neither anchor nor method — full miss. Surface as a
    category-level gap flag mid-flow; grade in the debrief.

The coach does not push past one specificity prompt on empirical numbers —
repeated pushing reads as scolding (see *Mid-flow vs debrief* above).

### Adversarial mode

In `/mock-loop adversarial`, the coach may use pattern callouts and
implied-intent vocabulary as part of pushback — *"you've dodged this twice
now"* is allowed mid-flow. Clinical and bureaucratic vocabulary stays banned
(*diagnostic*, *filing*) — adversarial pushback is not surveillance theater.
The numeric-commit calibration is unchanged across persona modes.
```

---

## 5. Cross-references

### `docs/coach/personas/interviewer.md`

Append one line at the end of the "Default: neutral" subsection:

```markdown
**Tone discipline.** See `docs/coach/protocols.md` § Tone and feedback discipline for mid-flow phrasing rules (allowed moves, banned vocab) and numeric-commit calibration. Adversarial-mode carve-outs are noted there too.
```

### `docs/coach/rubric.md`

After the Stefan Mai *"Make the decision. Don't just outline options."* quote in §Technical Communication & Collaboration, insert:

```markdown
**Calibration note.** This anchor applies to *implementation* decisions (e.g., "I'd use Postgres because…") where deferring to options is pure avoidance. For *empirical calibration* decisions — celebrity thresholds, sharding cutoffs, cache size targets, etc. — the Staff+ bar is **anchor + method**, not magic-number. See `docs/coach/protocols.md` § Tone and feedback discipline / Numeric-commit calibration for the grading detail.
```

---

## 6. Tests

Append to `tests/foundation.sh`:

```bash
# Tone and feedback discipline (new)
assert_section "Tone and feedback discipline" "docs/coach/protocols.md"
assert_grep "Mid-flow vs debrief" "docs/coach/protocols.md"
assert_grep "Numeric-commit calibration" "docs/coach/protocols.md"
assert_grep "derivable|empirical" "docs/coach/protocols.md"
assert_grep "anchor.*method" "docs/coach/protocols.md"

# interviewer.md cross-reference
assert_grep "Tone discipline|Tone and feedback discipline" "docs/coach/personas/interviewer.md"

# rubric.md calibration note on Mai anchor
assert_grep "Calibration note|implementation decisions|empirical calibration" "docs/coach/rubric.md"
```

Seven assertions. Deliberately checks structural markers and key concept words, not banned-vocab presence — banned-vocab is treated as an example-set in the spec, and the LLM is trusted to interpret the class.

---

## 7. Verification

**Automated (cheap):**

- `bash tests/all.sh` passes with the seven new assertions.
- All existing foundation / mock-loop / practice-problem / study-patterns / first-run assertions still pass.

**Manual smoke test (the real verification):**

- Run a fresh `/mock-loop` session and observe mid-flow speech across all phases:
  - Zero instances of pattern callouts (*"again"*, *"third turn"*, etc.).
  - Zero instances of clinical vocab (*"diagnostic"*, *"filing"*, *"flagging for…"*).
  - Zero instances of implied-intent words (*"disguised"*, *"dodge"*).
  - Zero instances of level-comparison framing mid-flow.
- Force an empirical-number partial-commit during a session (e.g., name a method without an anchor). Verify coach surfaces exactly one specificity question and does not re-push on the same question.
- Reach the debrief and verify pattern callouts, frequency counts, and per-dimension level grading still appear in the closing assessment (those rules are unchanged).

---

## 8. Rationale notes

**Why "anchor + method" instead of "just method".** A staff candidate is expected to know rough industry anchors (e.g., ~10K followers as the celebrity-threshold heuristic from publicly-known Twitter/Meta papers). Pure method-commit without an anchor is still slightly evasive — anchor + method captures both calibration (using available priors) and humility (refining via data). It also gives the grader a clear partial-vs-full commit split: anchor + method = full; method only = partial; neither = full miss.

**Why one specificity push, not zero.** A category-level gap flag with no follow-up specificity question can leave the candidate guessing what was asked. One specificity push gives them a chance to deliver the missing anchor explicitly; a second push becomes scolding.

**Why example-set instead of exhaustive banned list.** Per user preference (UX over rigidity): static tests can verify the *structure* and *concepts* are documented, but cannot verify LLM compliance with a vocabulary list. Treating banned vocab as an example-set (with the LLM interpreting the class) keeps the spec readable and matches how the LLM actually consumes the rules.

**Why retroactive edits of session artifacts are out of scope.** The existing `2026-05-12-mock-twitter-timeline.md` documents what the coach DID do at the time, including the scoldy phrasing. That's correct as a historical record. Editing it after the fact would corrupt the calibration trail (`prediction_score_delta_last_5`) and obscure when behavior changes happened.

---

## 9. Open questions

None. All discussion points were resolved during brainstorming:

- Numeric-commit bar: **anchor + method** (resolved).
- Mid-flow pattern-callout policy: **defer all to debrief** (resolved).
- File layout: **consolidate in `protocols.md`** (resolved).
- Test vocabulary policy: **example-set, structural-marker tests only** (resolved).
- One specificity push for partial-commit empirical numbers: **yes, exactly one** (resolved).

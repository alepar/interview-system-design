# Deep-dive coverage loop + topic-sequencing carve-out — design

**Date:** 2026-05-23
**Status:** Approved, pending implementation plan
**Related:** `docs/coach/personas/interviewer.md`, `.claude/commands/mock-loop.md`, `docs/coach/rubric.md`, `docs/coach/protocols.md`, `README.md`

## 1. Problem

Two issues surfaced from a `/mock-loop` session, both in the deep-dive "commit & drive" mechanics.

**(A) Medium deep-dive picks only one topic.** Today medium "picks **one** deep-dive topic… ensuring at least one named bottleneck area is covered" (`interviewer.md:31`, `mock-loop.md:65`). The coach told the candidate: *"I pick ONE deep-dive topic; you drive depth within it and any subsequent topic picks."* The user wants medium to walk the candidate through **all** the critical bottlenecks, sequencing them one at a time.

**(B) Topic-sequencing is mis-graded as "non-committing."** The coach said: *"you just gave me five candidate areas — models, geo-distribution, edge layer, user db, ride history — without picking one. Same not-committing pattern. Pick one. Drive."* This is the option-listing failure mode (`rubric.md:28`,`:69` — *"never kick the decision back to the interviewer"*) being mis-applied. That principle was written about **technical decisions**, not deep-dive **topic sequencing**. Enumerating the critical areas and letting the interviewer pick the next is legitimate collaboration — the interviewer does exactly this — and should not be penalized, even on hard.

## 2. Scope

In scope (one combined spec — both are deep-dive driving semantics):
- Medium deep-dive coverage loop (A).
- Constraint-injection reactive-vs-proactive rule, codified (supports A).
- Topic-sequencing vs decision-deferral grading carve-out, with a positive breadth signal (B).
- Hard-level interaction refinements (B).

Out of scope:
- Easy and hard deep-dive *selection* behavior (unchanged except where noted in §6).
- The decision-deferral option-listing failure itself — it stays a failure for technical/design decisions.
- Any state-artifact schema change.

## 3. Medium deep-dive coverage loop

Replaces today's "pick one topic." In the Deep Dives phase on **medium**:

1. After HLD, the coach opens by naming **one** specific bottleneck area to dig into. It does **not** announce the full list up-front — that is easy's behavior.
2. The candidate answers. The coach asks follow-up **questions only to fill holes/gaps** in what the candidate said — neutral probing (specificity / category-gap questions). No hints, no proactive constraint-injection, no pressure.
3. When that area is adequately covered, the coach picks the **next** bottleneck.
4. Repeat **until all critical bottlenecks for the problem are covered**.

The coach drives the *sequencing*; the candidate drives the *depth*. The critical-bottleneck set comes from the problem reference (`docs/coach/problems/<slug>.md` Deep dives / Known failure modes / Bar anchors); for freeform problems, coach judgment.

**Three-way distinction across difficulty:**
- **Easy:** announce *all* topics up-front + proactive helping prompts; may proactively constraint-inject as scaffolding.
- **Medium:** reveal *one topic at a time* through the full critical set; neutral hole-filling follow-ups; no proactive guidance/pressure.
- **Hard:** candidate drives topic *selection* and depth; coach silent except reactive interventions.

## 4. Constraint-injection: reactive stays universal, proactive is easy-only

Codify what is currently implicit:
- The four intervention rules (procedural time-warning, stuck-prompt, **constraint-injection**, category-gap flag) fire **reactively** on a bluff-marker trip or a >2-turn stall at **all** levels (easy/medium/hard). Unchanged.
- The coach does **not volunteer** constraint-injection without a trigger at **medium or hard**. *Proactive* (volunteered) constraint-injection is an **easy-only** scaffolding tool.

## 5. Topic-sequencing ≠ decision-deferral (grading carve-out)

The option-listing failure mode (`rubric.md:28`, `:69`) gets a carve-out:
- **Applies** to technical/design **decisions** — deferring "which DB / which concurrency approach" to the interviewer is avoidance. Still penalized; still the canonical option-listing failure.
- **Does not apply** to deep-dive **topic sequencing** — enumerating the critical areas and asking the interviewer which to explore next is legitimate collaboration at **any** level, including hard.

**Positive credit:** enumerating the full critical set of bottleneck areas demonstrates **Problem Navigation** ("identifying the hard part before drawing boxes", `rubric.md:9`) → logged as an above-bar Problem-Navigation signal / a positive drive-vs-wait instance, not merely "not penalized."

*Rejected alternative:* folding this into the staff-method `breadth_menu` bar. That bar is specifically about enumerating candidate **technologies** with one-line pro/con before committing to one; deep-dive area enumeration is *scoping*, not a tech commit, so it belongs under Problem Navigation / drive-vs-wait.

## 6. Hard-level interaction

- Refine the drive-vs-wait canonical failure (`rubric.md:59`, currently *"failing to pick a deep-dive topic when the coach was silent"*): the **failure** is going *silent / passively waiting* for the coach to drive. Actively enumerating the critical areas and asking the coach to sequence is **not** a failure — it is the §5 positive (the drive was demonstrated by the enumeration).
- When a candidate at hard offers a menu of areas and asks the coach to pick, the coach **may pick** the next area. Responding to a collaborative request differs from volunteering into silence. This is the one case where the coach picks a topic at hard.

## 7. File-by-file changes

1. **`docs/coach/personas/interviewer.md`**
   - Difficulty levels table, Deep Dives row, **Medium** cell (line 31): rewrite from "picks one topic" to the §3 coverage loop.
   - The note at line 33: add the §4 reactive-vs-proactive constraint-injection rule.
   - Drive-vs-wait-by-difficulty table, **Medium** row (line 42): coach now drives *all* deep-dive topic selection (was "picks one").
2. **`.claude/commands/mock-loop.md`**
   - Phase 5 Deep Dives, **medium** clause (line 65): rewrite to the §3 loop; update the "Log a pivotal turn" clause so topic-sequencing is not logged as a drive failure.
   - Closing assessment / pivotal-moment guidance: topic-sequencing (enumerate + ask to sequence) must not be logged as a drive-vs-wait failure and **may** be logged as a Problem-Navigation positive (§5, §6).
3. **`docs/coach/rubric.md`**
   - Method sub-bar (line 28): add the §5 carve-out (decision vs topic-sequencing).
   - Drive vs wait section (lines 51–63): refine the canonical failure (§6) and add the positive instance (§5).
   - Pivotal-moment principle (line 69): note the carve-out so the option-listing quote is not read to cover topic sequencing.
4. **`README.md`**
   - Medium difficulty description (line 96): replace "picks one deep-dive topic to ensure a named bottleneck area is covered" with the coverage loop; drop "want pressure on depth" framing.
5. **`docs/coach/protocols.md`**
   - Tone and feedback discipline (Mid-flow vs debrief, ~lines 155–168): one-line note that deep-dive topic sequencing is collaboration, not a mid-flow "non-committing" pattern callout.

## 8. Testing

- Extend the bash content-marker harness:
  - `tests/foundation.sh` (interviewer.md block): assert the medium coverage-loop language (e.g., a pattern like `until all` / `all .* bottlenecks` in interviewer.md).
  - `tests/foundation.sh` (rubric.md / protocols.md blocks) or `tests/mock-loop.sh`: assert the topic-sequencing carve-out language (e.g., `topic sequenc` / `sequencing`).
- Existing assertions must stay green (the word "adversarial", "Refusal gate", staff-method markers, difficulty markers, etc.).
- Run `bash tests/all.sh` after implementation; expect `All tests passed.`

## 9. Non-goals

- No change to the decision-deferral option-listing failure for technical/design choices.
- No change to easy/hard deep-dive *selection* mechanics beyond §6's hard "may pick when asked."
- No new session-artifact or `observed.md` fields. Grading uses existing dimensions (Problem Navigation, drive-vs-wait pivotal).
- No change to the reactive intervention rules themselves (only the proactive-volunteering scope is codified).

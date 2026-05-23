# Soft gates — design

**Date:** 2026-05-22
**Status:** Approved, pending implementation plan
**Related:** `docs/coach/protocols.md`, `.claude/commands/mock-loop.md`, `docs/coach/personas/interviewer.md`

## 1. Problem

The coach hard-declines some explicit user requests. The triggering case:

> *"Adversarial mode requested — declining. Gate requires 3+ prior /mock-loop sessions in the same archetype."*

A learner who explicitly asks for adversarial mode is refused outright. This is the right *default* — adversarial pushback and misdirection only help once a learner can distinguish them from real signal — but a hard refusal of an explicit, informed request is heavier than the situation warrants. The user owns the repo and the practice; the coach should default well and recommend, not block.

The goal: convert **progression/recommendation gates** from hard refusals into **soft gates** — the coach defaults and recommends per the gate, but honors an explicit ask, dropping a one-line note on why it isn't the default. **Anti-cheat, consent, and productive-struggle gates stay hard.**

## 2. Scope

### In scope (softened)

- **Adversarial mode** (`mock-loop.md:32`) — currently declines if <3 prior sessions in the archetype.
- **Difficulty recommendation** (`mock-loop.md:31,34-46`) — already honors an explicit token, but **silently**. Add the missing "not recommended" note when the explicit choice diverges from what would have been recommended.

### Out of scope (stay hard) — with rationale

| Gate | Class | Why it stays hard |
|---|---|---|
| Refusal gate (`/practice-problem`) | Anti-cheat | `protocols.md:17` — "cripples real-time cheat utility." Softening destroys the central anti-cheat property and the cognitive-apprenticeship articulation step. |
| Honor attestation | Consent | Ethics framing; softening means "let me skip agreeing this is practice-only." |
| Never-volunteer-the-answer (`mock-loop.md:76`); no premature reveal / no design dumps (`practice-problem.md:52-53`) | Productive-struggle pedagogy | Same family as the refusal gate — softening collapses productive struggle. |

Internal scoring logic (staff-method grading, scaffolding decrease, trajectory weighting, denominator exclusion) is not user-facing and is unaffected.

### Decision: verbal-note-only

When a user overrides a soft gate, the coach honors it and speaks a one-line note. **No new artifact fields, no `observed.md` changes, no trajectory math.** The existing `difficulty.source: cli` field already records that an explicit token was used; it is untouched. A below-gate override leaves no special trace beyond what is already recorded.

## 3. The soft-gate pattern

A soft gate behaves in three steps:

1. **Compute the default** per the gate's own logic.
2. **Honor an explicit ask** even when off-default.
3. **State one line** on why it isn't the default, obeying `protocols.md § Tone and feedback discipline` (concrete, kind, no clinical/bureaucratic vocab, no scolding). The note is spoken in the Opening and leaves no artifact trace.

This pattern is documented once in `protocols.md`; the slash commands cite it by section, matching how the refusal gate, two-voice modeling, and tone discipline are already factored.

## 4. Note wording

- **Adversarial below baseline** (Opening, replacing the decline):
  > *"One thing — adversarial usually lands better once you've run this archetype a few times neutrally, since pushback only helps if you can tell it from real signal. Running it adversarial since you asked."*
- **Difficulty divergence** (Opening prepend, only when the explicit token ≠ what would have been recommended):
  > *"Based on your last 3 sessions I'd usually start at `<rec>`, but running `<chosen>` as you asked."*

  When the explicit token equals the computed recommendation, stay silent — no note.

## 5. Hard/soft taxonomy

A taxonomy table is added to `protocols.md § Soft gates`, recording the §2 classification, plus a guard line:

> *"Do not move a gate between classes without revisiting this table."*

This prevents anyone (future maintainer or coach) from accidentally softening an anti-cheat gate or re-hardening a progression gate.

## 6. File-by-file changes

1. **`docs/coach/protocols.md`** — add `## Soft gates` section (pattern from §3 + taxonomy from §5 + guard line), placed immediately after `## Refusal gate` so hard and soft gates read together.

2. **`.claude/commands/mock-loop.md`**
   - Line 32: replace *"If gate not met, decline and explain"* with honor-the-request-and-note per `protocols.md § Soft gates`.
   - Difficulty section (line 31): currently *"Difficulty token present → use it directly; skip the recommendation."* Change so the coach **computes the recommendation even when a token is present**, solely to detect divergence. Use the explicit token regardless; emit the divergence note (§4) in the Opening only when they differ.
   - Opening section (lines 52–53): carry the adversarial and difficulty notes when an override occurred.

3. **`docs/coach/personas/interviewer.md`** — line 16: replace *"coach refuses and explains why"* with honor-the-request-and-note, citing `protocols.md § Soft gates`.

4. **`README.md`**
   - Line 91: *"gated on 3+ prior sessions in the same archetype"* → recommended after 3+ sessions; runs earlier if you ask, with a one-line note.
   - Line ~99 (difficulty): note that an explicit choice diverging from the recommendation is honored with a one-line note.

5. **`tests/foundation.sh`** — add `assert_section "Soft gates" "docs/coach/protocols.md"`, mirroring the existing `assert_section "Refusal gate"` check at line 35.

## 7. Testing

- `tests/foundation.sh` gains the `Soft gates` section assertion.
- Existing assertions are unaffected: `tests/mock-loop.sh:18` checks for the word *"adversarial"* (kept); `tests/foundation.sh:60` checks for *"adversarial"* in `interviewer.md` (kept); `tests/practice-problem.sh:11` and `tests/foundation.sh:35` check the refusal gate (untouched).
- Run `bash tests/all.sh` after implementation.

## 8. Non-goals

- No change to the refusal gate, honor attestation, or any productive-struggle behavioral rule.
- No new session-artifact fields or `observed.md` schema changes.
- No trajectory down-weighting of below-gate sessions.
- No change to mid-session difficulty override (already honored at `mock-loop.md:46`).

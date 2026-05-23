# Soft Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the adversarial-mode and difficulty-recommendation gates from hard refusals into soft gates that honor an explicit user ask while speaking a one-line "not recommended" note; keep anti-cheat/consent/productive-struggle gates hard.

**Architecture:** Document the soft-gate pattern + a hard/soft taxonomy once in `docs/coach/protocols.md`; the slash command (`mock-loop.md`) and the interviewer persona cite it. Behavior is verbal-note-only — no new session-artifact fields, no `observed.md` changes, no trajectory math. The only real behavior change is that `/mock-loop` now computes the difficulty recommendation even when an explicit token is supplied, solely to detect divergence for the note.

**Tech Stack:** Markdown prompt/protocol files + a bash content-marker test harness (`tests/*.sh`, helpers in `tests/lib.sh`: `assert_section` greps `^#+ +<title>`, `assert_grep` is `grep -qE`). Run the suite with `bash tests/all.sh`.

**Spec:** `docs/specs/2026-05-22-soft-gates-design.md`

---

### Task 1: Add the `## Soft gates` section to protocols.md

**Files:**
- Modify: `tests/foundation.sh` (protocols.md assertion block, near line 48)
- Modify: `docs/coach/protocols.md` (insert before `## Two-voice modeling`, currently line 19)

- [ ] **Step 1: Write the failing test**

In `tests/foundation.sh`, find this line (currently line 48):

```bash
assert_grep "non-functional" "docs/coach/protocols.md"
```

Add a new line immediately after it:

```bash
assert_section "Soft gates" "docs/coach/protocols.md"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/foundation.sh`
Expected: FAIL with `FAIL: section 'Soft gates' missing in docs/coach/protocols.md`

- [ ] **Step 3: Add the Soft gates section**

In `docs/coach/protocols.md`, replace this line (the heading that currently starts the next section):

```markdown
## Two-voice modeling
```

with the new section followed by the original heading:

```markdown
## Soft gates

Some gates are **soft**: the coach computes a default and recommends it, but honors an explicit user request that goes against the default. Soft gates behave in three steps:

1. **Compute the default** per the gate's own logic.
2. **Honor an explicit ask** even when it is off-default. If the user explicitly types the off-default option, they get it.
3. **State one line** on why it is not the default, obeying § Tone and feedback discipline (concrete, kind, no clinical/bureaucratic vocab, no scolding). The note is spoken at the point of decision (e.g., the `/mock-loop` Opening) and leaves **no artifact trace** beyond fields already recorded.

This is **verbal-note-only**: soft-gate overrides add no new session-artifact fields, no `observed.md` changes, and no trajectory weighting. (`difficulty.source: cli` already records that an explicit difficulty token was used; it is unchanged.)

### Which gates are hard vs soft

| Gate | Class | Why |
|---|---|---|
| Refusal gate (`/practice-problem`) | **Hard** | Anti-cheat — "cripples real-time cheat utility" (§ Refusal gate). |
| Honor attestation | **Hard** | Consent / ethics framing. |
| Never-volunteer-the-answer; no premature reveal / no design dumps | **Hard** | Productive-struggle pedagogy. |
| Adversarial mode (`/mock-loop adversarial`) | **Soft** | Progression — recommended after 3+ archetype sessions; honor an earlier explicit ask with a note. |
| Difficulty recommendation (`/mock-loop`) | **Soft** | Recommendation — an explicit `easy`/`medium`/`hard` token is honored; note when it diverges from the recommendation. |

Do not move a gate between classes without revisiting this table.

## Two-voice modeling
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/foundation.sh`
Expected: PASS, ending with `Phase 1 foundation tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tests/foundation.sh docs/coach/protocols.md
git commit -m "Add Soft gates section + hard/soft taxonomy to protocols"
```

---

### Task 2: Soften the gates in mock-loop.md

**Files:**
- Modify: `tests/mock-loop.sh` (after the difficulty-knob block, near line 44)
- Modify: `.claude/commands/mock-loop.md` (lines 31, 32, 36, 52, 53)

- [ ] **Step 1: Write the failing test**

In `tests/mock-loop.sh`, find this line (currently line 44):

```bash
assert_grep "drive_vs_wait_logged" ".claude/commands/mock-loop.md"
```

Add a new line immediately after it:

```bash
assert_grep "[Ss]oft gate" ".claude/commands/mock-loop.md"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/mock-loop.sh`
Expected: FAIL with `FAIL: pattern '[Ss]oft gate' not in .claude/commands/mock-loop.md`

- [ ] **Step 3: Edit the adversarial gate (line 32)**

In `.claude/commands/mock-loop.md`, replace:

```markdown
   - `adversarial` → check the adversarial gate (3+ prior sessions in the archetype in `state/observed.md`). If gate not met, decline and explain.
```

with:

```markdown
   - `adversarial` → check the adversarial gate (3+ prior sessions in the archetype in `state/observed.md`). This is a **soft gate** (see `docs/coach/protocols.md` § Soft gates): if the gate is not met, still run adversarial as requested, and deliver the soft-gate note in the Opening (§ Opening).
```

- [ ] **Step 4: Edit the difficulty-token branch (line 31)**

Replace:

```markdown
   - Difficulty token present → use it directly; skip the recommendation.
```

with:

```markdown
   - Difficulty token present → use it directly, but still compute the recommendation (§ Difficulty recommendation) to detect divergence; if the explicit token differs from the recommendation, deliver the soft-gate note in the Opening.
```

- [ ] **Step 5: Edit the Difficulty recommendation intro (line 36)**

Replace:

```markdown
Run only if `$ARGUMENTS` did not include a difficulty token.
```

with:

```markdown
Compute the recommendation in all cases. When `$ARGUMENTS` did not include a difficulty token, the recommendation becomes the session difficulty. When a token was supplied, the recommendation is used only to detect divergence for the soft-gate note (`docs/coach/protocols.md` § Soft gates) — the explicit token still wins.
```

- [ ] **Step 6: Edit the Opening persona-mode line (line 52)**

Replace:

```markdown
- Persona mode: *"This is a neutral interview"* OR *"This is an adversarial interview — I'll push back occasionally."*
```

with:

```markdown
- Persona mode: *"This is a neutral interview"* OR *"This is an adversarial interview — I'll push back occasionally."* If adversarial was requested but the adversarial gate was not met (soft gate — see `docs/coach/protocols.md` § Soft gates), first deliver the note: *"One thing — adversarial usually lands better once you've run this archetype a few times neutrally, since pushback only helps if you can tell it from real signal. Running it adversarial since you asked."*
```

- [ ] **Step 7: Edit the Opening difficulty line (line 53)**

Replace:

```markdown
- Difficulty: *"Running as <level>. <one-line behavior summary>. Say 'easy', 'medium', or 'hard' to switch."* Per-level summaries: easy → *"I'll guide requirements, HLD focus, and deep-dive topics."*; medium → *"I'll pick deep-dive topics; the rest is yours to drive."*; hard → *"You drive everything; I only step in for stuck-prompts or bluff markers."* When the level came from a recommendation, prepend *"Based on your last 3 sessions, recommending <level>."*
```

with:

```markdown
- Difficulty: *"Running as <level>. <one-line behavior summary>. Say 'easy', 'medium', or 'hard' to switch."* Per-level summaries: easy → *"I'll guide requirements, HLD focus, and deep-dive topics."*; medium → *"I'll pick deep-dive topics; the rest is yours to drive."*; hard → *"You drive everything; I only step in for stuck-prompts or bluff markers."* When the level came from a recommendation, prepend *"Based on your last 3 sessions, recommending <level>."* When the level came from an explicit token that diverges from the computed recommendation (soft gate — see `docs/coach/protocols.md` § Soft gates), instead prepend *"Based on your last 3 sessions I'd usually start at <rec>, but running <chosen> as you asked."* When the explicit token equals the recommendation, add no extra note.
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bash tests/mock-loop.sh`
Expected: PASS, ending with `Phase 4 /mock-loop static tests passed.`

- [ ] **Step 9: Commit**

```bash
git add tests/mock-loop.sh .claude/commands/mock-loop.md
git commit -m "Soften adversarial + difficulty gates in /mock-loop"
```

---

### Task 3: Soften the adversarial gate description in the interviewer persona

**Files:**
- Modify: `tests/foundation.sh` (interviewer.md assertion block, near line 62)
- Modify: `docs/coach/personas/interviewer.md` (line 16)

- [ ] **Step 1: Write the failing test**

In `tests/foundation.sh`, find this line (currently line 62):

```bash
assert_grep "category of gap" "docs/coach/personas/interviewer.md"
```

Add a new line immediately after it:

```bash
assert_grep "[Ss]oft gate" "docs/coach/personas/interviewer.md"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/foundation.sh`
Expected: FAIL with `FAIL: pattern '[Ss]oft gate' not in docs/coach/personas/interviewer.md`

- [ ] **Step 3: Edit the adversarial gate description (line 16)**

In `docs/coach/personas/interviewer.md`, replace:

```markdown
- Gated on 3+ prior `/mock-loop` sessions in the same archetype. If the user invokes `/mock-loop <problem> adversarial` without meeting the gate, coach refuses and explains why.
```

with:

```markdown
- **Soft gate** (see `docs/coach/protocols.md` § Soft gates): recommended after 3+ prior `/mock-loop` sessions in the same archetype. If the user invokes `/mock-loop <problem> adversarial` without meeting the gate, the coach still runs adversarial as requested and delivers a one-line note on why it isn't the default.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/foundation.sh`
Expected: PASS, ending with `Phase 1 foundation tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tests/foundation.sh docs/coach/personas/interviewer.md
git commit -m "Describe adversarial mode as a soft gate in interviewer persona"
```

---

### Task 4: Update README user-facing descriptions + full-suite verification

**Files:**
- Modify: `README.md` (lines 91 and 99)

No dedicated harness test covers `README.md`; verify with grep + the full suite.

- [ ] **Step 1: Edit the adversarial invocation bullet (line 91)**

In `README.md`, replace:

```markdown
- `/mock-loop ticketmaster adversarial` — adversarial persona (pushes back, occasionally lets you go down a wrong path); gated on 3+ prior sessions in the same archetype.
```

with:

```markdown
- `/mock-loop ticketmaster adversarial` — adversarial persona (pushes back, occasionally lets you go down a wrong path); recommended after 3+ prior sessions in the same archetype. If you ask for it earlier, the coach runs it anyway and notes once why it isn't the default (it's a soft gate).
```

- [ ] **Step 2: Edit the difficulty-recommendation paragraph (line 99)**

Replace:

```markdown
If you omit the difficulty, the coach recommends one based on your last three `/mock-loop` sessions — ≥2 demonstrating Solution Design **and** Technical Excellence at your target level → `hard`; 1 → `medium`; 0 → `easy`. Fewer than three prior sessions falls back to `medium`. You can override mid-session by typing `easy`, `medium`, or `hard` after the opening.
```

with:

```markdown
If you omit the difficulty, the coach recommends one based on your last three `/mock-loop` sessions — ≥2 demonstrating Solution Design **and** Technical Excellence at your target level → `hard`; 1 → `medium`; 0 → `easy`. Fewer than three prior sessions falls back to `medium`. If you pass an explicit difficulty that differs from what the coach would recommend, it runs your choice and notes the divergence in one line. You can override mid-session by typing `easy`, `medium`, or `hard` after the opening.
```

- [ ] **Step 3: Verify the README edits landed**

Run: `grep -n "soft gate\|notes the divergence" README.md`
Expected: two matches — the adversarial bullet (line ~91) and the difficulty paragraph (line ~99).

- [ ] **Step 4: Run the full test suite**

Run: `bash tests/all.sh`
Expected: PASS, ending with `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document soft-gate behavior for adversarial + difficulty in README"
```

---

## Notes for the implementer

- **Edit by text match, not line number.** The line numbers above are where each string lives today; use the exact quoted text as the match target. Task 1 inserts a section into `protocols.md`, but no other task touches that file, so cross-file line numbers stay stable.
- **Do not touch hard gates.** Leave the refusal gate, honor attestation, and the never-volunteer / no-premature-reveal / no-design-dumps rules exactly as they are. The taxonomy table in Task 1 documents why.
- **No state-schema changes.** Do not add fields to the session artifact or `observed.md`. This is verbal-note-only.

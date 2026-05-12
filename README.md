# Interview System Design — AI Coach

A local Claude Code coach for FAANG / AI-lab system-design interview prep.

## Quick start

1. Open this repo in Claude Code.
2. On first run, the coach will ask you a few words about yourself, your goals, and any focus areas. Reply briefly (1–3 sentences).
3. Confirm the honor attestation. The coach is for **practice only** — it will not produce a complete design before you've articulated your own first pass, and is not for use during a live interview.
4. Pick a workflow:

| Command | What it does |
|---|---|
| `/study-patterns` | Coach teaches you a pattern subsection (consistency, caching, geo, etc.). Asks check questions; grades 3-point ordinal. |
| `/practice-problem <slug>` | Coach plays the *interviewee*, narrating reasoning with two-voice modeling. Refuses to produce a complete design until you've typed requirements and a first-pass sketch. |
| `/mock-loop <slug>` | Coach plays the *interviewer* through a 5-phase FSM (Requirements → Core Entities → API → HLD → Deep Dives). Closes with a structured assessment. |

## What's where

- `docs/coach/` — read-only coach reference content (rubric, protocols, personas, patterns, problem answers).
- `docs/specs/` — design and architecture docs.
- `docs/research/` — research synthesis and dogfood notes.
- `docs/plans/` — implementation plans.
- `staff-engineer-study-guide.md` — canonical study guide.
- `state/` — your session state (profile, observed signals, per-session artifacts, transcript archive). Committed across sessions.

## How it works

See `docs/specs/2026-05-12-coach-design.md`. The summary:

- Coach is governed by file-backed rules (`docs/coach/protocols.md`), not by accumulated chat history.
- State is structured markdown — observable, auditable, learner-owned.
- Grading uses reference answers (per problem) and 3-point ordinal scales — no free-form 1–10.
- Coach re-reads persona and rubric files at phase transitions to mitigate persona drift.

## Honest limits

- The coach cannot detect cheating, and it doesn't try. It builds *friction* instead: refusal-as-feature, slow drip, sub-optimality injection.
- It will sometimes be wrong. Grade its grading; the coach's feedback is one signal, not the verdict.

## Tests

```bash
bash tests/all.sh
```

Static checks: file existence, frontmatter keys, required content markers. Behavior validation is via documented dogfood sessions (`docs/research/*-dogfood-notes.md`).

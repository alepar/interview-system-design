# State

User-mutable session state for the AI system-design interview coach.
Files in this directory are created and updated by the coach across
sessions. See `docs/specs/2026-05-12-coach-design.md` §4 for the schema.

- `profile.md` — user-declared identity and goals (created on first workflow run)
- `observed.md` — coach-maintained signals (per-pattern confidence, mistake categories, ratios)
- `sessions/YYYY-MM-DD-<workflow>-<slug>.md` — per-session artifacts
- `archive/YYYY-MM-DD-<workflow>-<slug>.md` — full session transcripts (write-only; never read back)

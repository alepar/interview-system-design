# Catalog cross-audit — design

**Date:** 2026-05-25
**Status:** Draft, pending implementation plan
**Topic:** Cross-examine archetypes (`docs/coach/archetypes.md`) vs. patterns (`docs/coach/patterns/*.md`) vs. the 199 problem files (`docs/coach/problems/*.md`) for misses, contradictions, mis-categorizations, duplicates, pattern coverage gaps, index issues, and archetype taxonomy questions.

## Purpose

The coach catalog grew quickly: 199 problem files were pushed across 12 archetypes in a tight burst (see commits `cf9905f` through `07f76ea`). With that velocity comes risk of internal inconsistency — frontmatter that disagrees with the archetype index, pattern references that point to nothing, problems filed under the wrong archetype, near-duplicates with different filenames, archetypes that have drifted from their stated design pressure, or archetypes that should be merged or split.

The audit surfaces every such issue as a triageable `bd` issue so the catalog can be cleaned up without one-shot judgment calls.

## Scope

**In scope:**
- All 199 problem files under `docs/coach/problems/`.
- The archetype index at `docs/coach/archetypes.md`.
- All 17 pattern files under `docs/coach/patterns/`.
- Five finding categories: structural, mis-categorization, pattern coverage gap, duplicate, index issue.
- One archetype-taxonomy category with four sub-types: merge, split, redefine, boundary.

**Out of scope (explicit non-goals):**
- Personas (`docs/coach/personas/`), protocols, rubric.
- Auto-applying fixes. The audit produces issues; humans apply changes.
- Validating the *content* of mis-categorization findings against an external oracle. There is no oracle — mis-cat findings are triage-by-human by design.
- Suggesting new problems that should exist but don't (catalog-growth recommendations).

## Architecture

Three-phase pipeline. Each phase has a single, well-defined responsibility and produces a persisted artifact, so phases can be re-run independently.

```
                ┌────────────────────────────────────────────┐
Phase 1         │ 12 parallel per-archetype review agents    │
(parallel)      │ Input: archetype slug + problem file list  │
                │        + referenced pattern files          │
                │ Output: phase1/<archetype>.json            │
                └────────────────────────────────────────────┘
                                  │
                12 JSON files (one per archetype)
                                  │
                                  ▼
                ┌────────────────────────────────────────────┐
Phase 2         │ Single consolidator agent                  │
(sequential)    │ Input: all 12 phase1 JSON + archetypes.md  │
                │        + full pattern file list            │
                │ Cross-cuts + taxonomy analysis.            │
                │ May targeted-re-read problem files for     │
                │ split/redefine taxonomy findings.          │
                │ Output: phase2/consolidated.json           │
                └────────────────────────────────────────────┘
                                  │
                                  ▼
                ┌────────────────────────────────────────────┐
Phase 3         │ Beads emitter (deterministic, no LLM)      │
(scripted)      │ Reads consolidated.json, creates bd issues │
                │ with category + severity + archetype       │
                │ labels. Splits into two epics:             │
                │   - audit:catalog-cross-<date>             │
                │   - audit:taxonomy-<date>                  │
                │ Output: phase3/bd-issues-created.log       │
                └────────────────────────────────────────────┘
```

**Artifact directory:** `docs/audit/<run-timestamp>/` (e.g., `docs/audit/2026-05-25-1430/`).

## Components

### Phase 1 — per-archetype review sub-agent

**Input contract:**
- `archetype_slug`: one of the 12 archetype slugs from `archetypes.md`.
- `problem_files`: list of paths to the problem files for that archetype (derived from `archetypes.md` "Problems in catalog" line plus a `ls`-based check of frontmatter `archetype:` field across all problem files — the union covers both directions of structural mismatch).
- `pattern_files`: list of paths to the pattern files referenced from the archetype's "Patterns" line.
- `archetypes_md_excerpt`: the section of `archetypes.md` describing this archetype only.

**Per-finding output schema:**

```json
{
  "id": "<archetype-slug>-NNN",
  "category": "structural | mis_categorization | pattern_gap | duplicate | index | other",
  "severity": "high | medium | low",
  "confidence": "high | medium | low",
  "files": ["docs/coach/problems/<slug>.md"],
  "evidence": "verbatim quote or specific line reference, ≤200 chars",
  "summary": "one-line description of what's wrong",
  "suggested_fix": "concrete next step",
  "cross_archetype_check": {
    "needed": true,
    "candidate_archetype": "<slug or null>",
    "resolved": false
  }
}
```

**Per-archetype envelope:**

```json
{
  "archetype": "<slug>",
  "problems_reviewed": ["<slug>", ...],
  "patterns_reviewed": ["<filename>", ...],
  "findings": [ /* finding objects */ ],
  "self_report": {
    "problems_count_in_index": <int>,
    "problems_count_files_found": <int>,
    "files_not_in_index": [<slug>, ...],
    "index_entries_with_no_file": [<slug>, ...]
  },
  "status": "ok | failed"
}
```

**Severity rubric (uniform across all 12 sub-agents):**
- `high`: catalog is internally broken (broken file ref, frontmatter↔index disagreement, two problems with identical prompts).
- `medium`: catalog is internally consistent but a problem is mis-filed, or a referenced pattern doesn't cover the problem's design pressures.
- `low`: cosmetic / "worth a glance" — naming inconsistency, weak-but-adequate pattern coverage.

**Confidence rubric:**
- `high`: mechanical or quote-backed (file doesn't exist; frontmatter says X, index says Y).
- `medium`: judgment call but well-evidenced (3 of 4 bar-anchors describe a different design pressure).
- `low`: gut feel — flag for human review, don't act on it without verification.

**`cross_archetype_check` semantics:**
Whenever a sub-agent suspects mis-categorization, it sets `needed: true` and names a `candidate_archetype` but does **not** decide. Only Phase 2 has visibility into the candidate archetype. Phase 2 sets `resolved: true` and either keeps the finding (confirmed), downgrades severity, or drops it.

**What Phase 1 does NOT do:**
- No taxonomy judgments. The sub-agent never flags `merge`, `split`, `redefine`, or `boundary`. Those are Phase-2 only.

### Phase 2 — consolidator agent

**Input contract:**
- All 12 `phase1/<archetype>.json` files.
- `docs/coach/archetypes.md` in full.
- The list of all 17 pattern files (filenames only, content read on demand).
- Permission to re-read specific problem files when doing targeted taxonomy analysis.

**Cross-cut responsibilities:**

1. **Resolve cross-archetype checks.** For each Phase-1 finding with `cross_archetype_check.needed: true`, read enough of the candidate archetype's data to decide. Set `resolved: true` and either confirm, downgrade, or drop.
2. **Cross-archetype duplicate detection.** Compare problem slugs and prompts across all archetypes. Emit `category: duplicate` findings where two slugs cover the same canonical prompt.
3. **Orphan-pattern detection.** Any pattern file under `docs/coach/patterns/` that no archetype references — emit as `category: pattern_gap` with `severity: low`.
4. **Archetype-pattern reference validity.** For each archetype's "Patterns" line, verify each referenced pattern file exists. Missing → `category: structural`, `severity: high`.
5. **Global index issues.** Verify every problem file in `docs/coach/problems/` is referenced by exactly one archetype in `archetypes.md`. Unreferenced or multiply-referenced → `category: index`.

**Taxonomy analysis (the four sub-types):**

1. **Merge candidates.** Cluster Phase-1 `mis_categorization_candidate` findings by `(source_archetype, candidate_archetype)` pair. Any pair with 3+ findings → emit `archetype_taxonomy` with `taxonomy_action: merge` and the cluster as evidence.
2. **Boundary candidates.** Same pair-clustering, but for pairs where mis-cat candidates flow both directions (A→B and B→A) — emit `taxonomy_action: boundary`.
3. **Split candidates.** Targeted re-read: for any archetype whose Phase-1 envelope shows >30% of problems flagged as mis-cat candidates, OR whose problems' design pressures (extracted via re-read of bar-anchors) cluster into 2+ distinct themes, emit `taxonomy_action: split` with proposed sub-archetypes.
4. **Redefine candidates.** Targeted re-read: compare the archetype's stated summary in `archetypes.md` to the actual design pressures appearing across its problems' bar-anchors. If the summary describes pressure X but ≥30% of problems are about pressure Y, emit `taxonomy_action: redefine`.

**Taxonomy finding schema (extends the base schema):**

```json
{
  "id": "taxonomy-NNN",
  "category": "archetype_taxonomy",
  "taxonomy_action": "merge | split | redefine | boundary",
  "severity": "medium | low",
  "confidence": "high | medium | low",
  "impact": "high | medium | low",
  "archetypes_affected": ["<slug>", ...],
  "evidence": "...",
  "summary": "...",
  "suggested_fix": "..."
}
```

**Impact rubric (specific to taxonomy):**
- `high`: change touches 20+ problem files (merge, split).
- `medium`: change touches `archetypes.md` plus 5-20 problem files (redefine with re-labels).
- `low`: change touches only `archetypes.md` prose (redefine without re-labels).

**Consolidated output:**

```json
{
  "run_timestamp": "2026-05-25T14:30:00Z",
  "cross_cut": {
    "duplicates_across_archetypes": [ /* findings */ ],
    "orphan_patterns": ["<filename>", ...],
    "archetype_pattern_ref_issues": [ /* findings */ ],
    "global_index_issues": [ /* findings */ ],
    "taxonomy_findings": [ /* taxonomy findings */ ]
  },
  "per_archetype": [ /* the 12 Phase-1 envelopes, with cross_archetype_check.resolved=true */ ]
}
```

### Phase 3 — beads emitter

Deterministic script. No LLM. Reads `phase2/consolidated.json` and emits one `bd` issue per finding.

**Mapping from finding → bd:**

| Finding field | → | bd field |
|---|---|---|
| `summary` | → | issue title, prefixed `[audit] <archetype>: ` |
| `category` | → | label: `audit:structural` / `audit:mis-cat` / `audit:pattern-gap` / `audit:duplicate` / `audit:index` / `audit:taxonomy` / `audit:other` |
| `severity` high/med/low | → | priority `1` / `2` / `3` |
| `confidence` | → | label: `confidence:high|med|low` |
| `files`, `evidence`, `suggested_fix`, `cross_archetype_check` | → | rendered into issue body as Markdown |
| archetype (envelope) | → | label: `archetype:<slug>` |
| `taxonomy_action` (taxonomy only) | → | label: `taxonomy:merge|split|redefine|boundary` |
| `impact` (taxonomy only) | → | label: `impact:high|med|low` |

**Epic split:**
- Non-taxonomy findings → epic `audit:catalog-cross-<run-date>`.
- Taxonomy findings → epic `audit:taxonomy-<run-date>`.

**Title format:** `[audit] <archetype>: <summary>` (taxonomy: `[audit] taxonomy: <summary>`).

**Idempotency:** issue `external_id` = SHA-256 of `{category, taxonomy_action?, sorted(files), summary}`. Re-runs with identical findings skip; non-key fields (evidence, suggested_fix) update on match.

**What Phase 3 is NOT:** not adaptive, no LLM. The expensive thinking happened in Phases 1 and 2. Phase 3 is mechanical so different bd label conventions can be tried by re-running Phase 3 alone.

## Data flow

1. Driver script enumerates the 12 archetypes from `archetypes.md`.
2. Driver dispatches 12 Phase-1 sub-agents in parallel, each with the input contract above.
3. Driver waits for all 12, validates each `phase1/<archetype>.json` against the schema (deterministic JSON-schema check, not LLM). Bad JSON → re-dispatch once; second failure → mark archetype `status: failed` and continue.
4. Driver invokes Phase 2 consolidator with the 12 validated envelopes.
5. Driver validates `phase2/consolidated.json` against schema.
6. Driver invokes Phase 3 emitter, which calls `bd create` once per finding.
7. Run summary written to `docs/audit/<timestamp>/SUMMARY.md` listing counts, failures, and the two epic IDs.

## Error handling

**Phase 1**
- Invalid JSON → re-dispatch once with schema-violation note; second failure → write empty envelope with `status: failed`, continue. Don't block sibling agents.
- Suspiciously empty findings (0 findings for an archetype with 15+ problems, all recently committed) → flag in run summary, not in `bd`. Catches a lazy agent before pollution.
- Schema conformance is checked deterministically before Phase 2 starts.

**Phase 2**
- Contradictory cross-archetype findings (two archetypes both claim a problem with `confidence: high`) → keep with `confidence: low` and a body note for human resolution.
- Pattern referenced by archetype but file missing → `category: structural`, `severity: high`.

**Phase 3**
- `bd create` failure → log to `phase3/bd-issues-created.log` with error + finding JSON; continue. Final summary lists failures so they can be retried.
- Duplicate detection collision (content-hash matches existing issue) → log as `skipped: duplicate`, don't error.

## Verification

Before trusting the backlog, run these checks against the first run's output:

1. **Structural-finding spot check (must pass):** randomly sample 5 `category: structural` findings, verify each evidence quote appears in the named file. Structural findings are mechanical — any false positive means the agents are hallucinating and the run is discarded.
2. **Self-report cross-check:** for each archetype, compute the file list independently (`ls docs/coach/problems/` + grep for frontmatter `archetype:`) and verify it matches `problems_reviewed` in the envelope. Catches silent file skips.
3. **Manual triage of first 10 medium-severity findings.** If 8/10 are garbage, the prompts need revision before continuing.

**Not validated:** mis-categorization findings against an oracle. There is no oracle — they're triage-by-human by design.

## Run artifacts (final layout)

```
docs/audit/2026-05-25-1430/
├── phase1/
│   ├── caching-read-heavy.json
│   ├── fan-out.json
│   ├── realtime-messaging.json
│   ├── concurrent-resource.json
│   ├── ugc-pipeline.json
│   ├── geo-proximity.json
│   ├── search-indexing.json
│   ├── conflict-resolution.json
│   ├── ml-in-loop.json
│   ├── infra-primitives.json
│   ├── ai-infrastructure.json
│   └── frontend.json
├── phase2/
│   └── consolidated.json
├── phase3/
│   └── bd-issues-created.log
└── SUMMARY.md
```

## Open questions for the implementation plan

These are deferred to the implementation-plan stage, not blockers for the design:

- Exact archetype-slug normalization (current files use slugs like `fan-out`, `ml-in-loop`; `archetypes.md` uses prose headings — implementation plan should pin the mapping).
- Whether Phase 1 sub-agents are dispatched via the `Agent` tool with `subagent_type: general-purpose`, or via a custom subagent definition. Likely the former, but worth pinning.
- Whether the driver is a shell script, a Python script, or invoked manually phase-by-phase from the main session. Probably manual orchestration for the first run, scripted only if we expect repeat runs.
- Pattern reference resolution: archetype lines say `docs/coach/patterns/caching.md and networking-transport.md` — the parser needs to handle "and"-joined references.

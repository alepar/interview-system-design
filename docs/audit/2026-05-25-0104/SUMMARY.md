# Catalog cross-audit — run summary

**Run timestamp:** 2026-05-25 01:04 (run id `2026-05-25-0104`)
**Spec:** [`docs/specs/2026-05-25-catalog-cross-audit-design.md`](../../specs/2026-05-25-catalog-cross-audit-design.md)
**Findings doc:** [`FINDINGS.md`](FINDINGS.md)

## bd epics

- **`interview-system-design-ng1`** — Audit: catalog cross 2026-05-25 (79 child issues)
- **`interview-system-design-48c`** — Audit: taxonomy 2026-05-25 (7 child issues)

Total: 88 issues (2 epics + 86 child findings). 7 findings skipped as "No action" confirmations of intentional splits.

## Counts

| Stage | Output |
|---|---|
| Phase 1 (12 parallel agents) | 86 raw findings; all 12 envelopes schema-valid; all 12 self-reports clean (files_found == in_index in every archetype) |
| Phase 2 (consolidator) | 73 per-archetype findings kept (13 dropped on cross-archetype resolution); 7 cross-arch duplicate checks; 7 taxonomy findings; 6 orphan patterns; 0 pattern-ref issues; 0 global-index issues |
| Phase 3 (bd emitter) | 86 issues created, 7 skipped (no-action), 0 failed |

## Severity breakdown (kept findings)

- **High:** 1 (the ad-click-aggregator contradiction in `archetypes.md`)
- **Medium:** 29
- **Low:** 50 (low-severity ≠ trivial; many are "worth a glance" calls)

## Headline findings

1. **`ad-click-aggregator` contradiction** — `archetypes.md` §9 (ml-in-loop) lists it as a top-3 prompt; the file is filed under §10 (infra-primitives) and §10's "Problems in catalog" list includes it. `interview-system-design-ng1.45` is the bd issue. **Fix in one of two ways**: move the file (frontmatter + §10's list) or revise §9's top-3.
2. **Split `realtime-messaging`** (taxonomy, impact:high) — three distinct sub-clusters (interactive messaging, message-protocol primitives, live-media CDN); 42% of problems sit on the boundary. `interview-system-design-48c.1`.
3. **Redefine `ml-in-loop`** (taxonomy, impact:medium) — summary still says "candidate-gen → ranking → re-rank funnel" but archetype now houses ML-platform infra (`feature-store`, `model-rollout-shadow`) and embedded inference (`autonomous-driving-inference`, `voice-assistant-routing`). `interview-system-design-48c.2`.
4. **Tighten `infra-primitives` ↔ `concurrent-resource` boundary** (taxonomy, impact:medium) — `distributed-lock` and `idempotent-payment` self-describe as primitives but sit in concurrent-resource; `stripe-payments` and `kubernetes-scheduler` sit in infra-primitives but are application-level. Articulate the build-vs-use rule explicitly. `interview-system-design-48c.4`.
5. **Pattern-coverage gaps are systemic** — 27 `pattern_gap` findings. Notable: `ml-specific.md` lacks safety-critical embedded inference; `frontend.md` lacks ref-buffer/rAF, MSE/EME, SSE streaming; `ai-infra.md` lacks gang scheduling, KV-disaggregation, agent platforms; `consistency-coordination.md` has only one OT-vs-CRDT entry but the conflict-resolution archetype leans on 5+ specific CRDT variants.
6. **6 orphan pattern files** not referenced by any archetype: `core-concepts.md`, `load-balancing.md`, `papers.md`, `reliability-observability.md`, `security-privacy.md`, `tradeoffs.md`. May be intentional cross-cutting refs but should be documented as such.

## Verification

- **Phase 1 schema check:** all 12 envelopes valid; all `self_report` counts match disk reality (files_found == in_index in every archetype).
- **Phase 2 schema check:** consolidated.json passes.
- **Spot-check of finding evidence (3 random medium findings):** all evidence quotes appear verbatim (modulo Markdown emphasis markers) in the named files.
- **Headline finding verified:** `ad-click-aggregator.md` confirmed to have `archetype: infra-primitives` frontmatter; `archetypes.md` line 91 confirmed to list "Design Ad Click Aggregator" as a top-3 prompt of §9; line 105 confirmed to include `ad-click-aggregator` in §10's problems list. Real contradiction.

## Artifact tree

```
docs/audit/2026-05-25-0104/
├── SUMMARY.md                            ← this file
├── FINDINGS.md                           ← human-readable findings
├── phase1/                               ← 12 per-archetype envelopes
│   ├── ai-infrastructure.json
│   ├── caching-read-heavy.json
│   ├── concurrent-resource.json
│   ├── conflict-resolution.json
│   ├── fan-out.json
│   ├── frontend.json
│   ├── geo-proximity.json
│   ├── infra-primitives.json
│   ├── ml-in-loop.json
│   ├── realtime-messaging.json
│   ├── search-indexing.json
│   └── ugc-pipeline.json
├── phase2/
│   └── consolidated.json                 ← cross-cuts + taxonomy
└── phase3/
    ├── emit.py                           ← bd-issue emitter
    ├── build_findings_md.py              ← Markdown findings generator
    └── bd-issues-created.log             ← per-issue creation log
```

## Re-running

Phase 3 is idempotent only within a single bd database. Re-running `python3 docs/audit/2026-05-25-0104/phase3/emit.py` against the same database will create duplicate issues (the spec's content-hash idempotency is documented as a design goal but the script doesn't implement deduplication against existing bd issues yet — close the existing epic first if you need a fresh emit).

The Phase 1 + Phase 2 outputs are fully self-contained — to re-run from scratch, delete `phase1/` + `phase2/` + `phase3/bd-issues-created.log` and dispatch new agents (the Phase-1 prompts and Phase-2 prompt are in the conversation that produced this run).

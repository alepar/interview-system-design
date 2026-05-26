#!/usr/bin/env python3
"""Phase 3 emitter: read phase2/consolidated.json, emit bd issues, log to bd-issues-created.log.

Filters out findings whose suggested_fix is "No action" (or starts with "No action").
Routes per-archetype findings and cross-archetype duplicates to EPIC_A (catalog-cross).
Routes taxonomy findings to EPIC_B (taxonomy).
Synthesizes orphan-pattern findings from cross_cut.orphan_patterns and emits to EPIC_A.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

RUN_DIR = Path("docs/audit/2026-05-25-0104")
CONSOLIDATED = RUN_DIR / "phase2" / "consolidated.json"
LOG_PATH = RUN_DIR / "phase3" / "bd-issues-created.log"

EPIC_A = Path("/tmp/epic_a.txt").read_text().strip()  # catalog-cross
EPIC_B = Path("/tmp/epic_b.txt").read_text().strip()  # taxonomy


def is_no_action(suggested_fix: str) -> bool:
    if not suggested_fix:
        return False
    return suggested_fix.strip().lower().startswith("no action")


def severity_to_priority(sev: str) -> str:
    return {"high": "1", "medium": "2", "low": "3"}.get(sev, "2")


def build_body(finding: dict, archetype: str | None = None) -> str:
    lines = []
    if archetype:
        lines.append(f"**Archetype:** `{archetype}`")
    lines.append(f"**Category:** `{finding.get('category', 'unknown')}`")
    if finding.get("taxonomy_action"):
        lines.append(f"**Taxonomy action:** `{finding['taxonomy_action']}`")
    lines.append(f"**Severity:** {finding.get('severity', 'unknown')}")
    lines.append(f"**Confidence:** {finding.get('confidence', 'unknown')}")
    if finding.get("impact"):
        lines.append(f"**Impact:** {finding['impact']}")
    if finding.get("archetypes_affected"):
        lines.append(f"**Archetypes affected:** {', '.join(finding['archetypes_affected'])}")
    if finding.get("files"):
        lines.append(f"**Files:** {', '.join('`' + f + '`' for f in finding['files'])}")
    lines.append("")
    lines.append(f"**Evidence:** {finding.get('evidence', '(none)')}")
    lines.append("")
    lines.append(f"**Suggested fix:** {finding.get('suggested_fix', '(none)')}")
    cac = finding.get("cross_archetype_check") or {}
    if cac.get("resolved"):
        note = cac.get("resolution_note") or "(no note)"
        candidate = cac.get("candidate_archetype")
        lines.append("")
        lines.append(f"**Cross-archetype resolution:** candidate `{candidate}`, {note}")
    lines.append("")
    lines.append(f"_Source: `{finding.get('id', '?')}` in `docs/audit/2026-05-25-0104/`._")
    return "\n".join(lines)


def labels_for(finding: dict, archetype: str | None) -> list[str]:
    labels = ["audit"]
    cat = finding.get("category")
    cat_map = {
        "structural": "audit:structural",
        "mis_categorization": "audit:mis-cat",
        "pattern_gap": "audit:pattern-gap",
        "duplicate": "audit:duplicate",
        "index": "audit:index",
        "other": "audit:other",
        "archetype_taxonomy": "audit:taxonomy",
    }
    if cat in cat_map:
        labels.append(cat_map[cat])
    conf = finding.get("confidence")
    if conf:
        labels.append(f"confidence:{conf}")
    if archetype:
        labels.append(f"archetype:{archetype}")
    if finding.get("taxonomy_action"):
        labels.append(f"taxonomy:{finding['taxonomy_action']}")
    if finding.get("impact"):
        labels.append(f"impact:{finding['impact']}")
    return labels


def title_for(finding: dict, archetype: str | None) -> str:
    summary = finding.get("summary", "(no summary)")
    if finding.get("category") == "archetype_taxonomy":
        return f"[audit] taxonomy: {summary}"[:200]
    if archetype:
        return f"[audit] {archetype}: {summary}"[:200]
    return f"[audit] {summary}"[:200]


def emit(finding: dict, archetype: str | None, parent_epic: str, log_file) -> bool:
    if is_no_action(finding.get("suggested_fix", "")):
        log_file.write(f"SKIPPED (no-action): {finding.get('id', '?')} - {finding.get('summary', '')[:80]}\n")
        return False
    title = title_for(finding, archetype)
    body = build_body(finding, archetype)
    labels = ",".join(labels_for(finding, archetype))
    priority = severity_to_priority(finding.get("severity", "medium"))
    cmd = [
        "bd", "create", title,
        "-t", "task",
        "-p", priority,
        "-l", labels,
        "--parent", parent_epic,
        "--silent",
        "--description", body,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        issue_id = result.stdout.strip()
        log_file.write(f"CREATED: {issue_id} - {title[:80]}\n")
        return True
    except subprocess.CalledProcessError as e:
        log_file.write(f"FAILED: {finding.get('id', '?')} - {title[:80]}\n  stderr: {e.stderr.strip()}\n")
        return False


def synthesize_orphan_patterns(orphan_files: list[str]) -> list[dict]:
    out = []
    for i, fname in enumerate(orphan_files, start=1):
        out.append({
            "id": f"orphan-pattern-{i:03d}",
            "category": "pattern_gap",
            "severity": "low",
            "confidence": "high",
            "files": [f"docs/coach/patterns/{fname}"],
            "evidence": f"Pattern file `{fname}` exists under docs/coach/patterns/ but is not referenced by any archetype in docs/coach/archetypes.md.",
            "summary": f"Orphan pattern: {fname} not referenced by any archetype",
            "suggested_fix": f"Either reference `{fname}` from one or more archetypes in archetypes.md (if intended as cross-cutting, document that explicitly), or remove the file if no longer needed.",
            "cross_archetype_check": {"needed": False, "candidate_archetype": None, "resolved": True},
        })
    return out


def main():
    data = json.loads(CONSOLIDATED.read_text())
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    counters = {"created": 0, "skipped": 0, "failed": 0}

    with LOG_PATH.open("w") as log:
        log.write(f"# Phase 3 emit log — run 2026-05-25-0104\n")
        log.write(f"# EPIC_A (catalog-cross) = {EPIC_A}\n")
        log.write(f"# EPIC_B (taxonomy) = {EPIC_B}\n\n")

        # Per-archetype findings → EPIC_A
        log.write("## Per-archetype findings\n")
        for env in data.get("per_archetype", []):
            arche = env.get("archetype")
            for f in env.get("findings", []):
                ok = emit(f, arche, EPIC_A, log)
                counters["created" if ok else "skipped"] += 1

        # Cross-archetype duplicates → EPIC_A
        log.write("\n## Cross-archetype duplicates\n")
        for f in data.get("cross_cut", {}).get("duplicates_across_archetypes", []):
            ok = emit(f, None, EPIC_A, log)
            counters["created" if ok else "skipped"] += 1

        # Archetype pattern-ref issues → EPIC_A
        log.write("\n## Archetype pattern-ref issues\n")
        for f in data.get("cross_cut", {}).get("archetype_pattern_ref_issues", []):
            ok = emit(f, None, EPIC_A, log)
            counters["created" if ok else "skipped"] += 1

        # Global index issues → EPIC_A
        log.write("\n## Global index issues\n")
        for f in data.get("cross_cut", {}).get("global_index_issues", []):
            ok = emit(f, None, EPIC_A, log)
            counters["created" if ok else "skipped"] += 1

        # Synthesized orphan-pattern findings → EPIC_A
        log.write("\n## Orphan patterns (synthesized)\n")
        for f in synthesize_orphan_patterns(data.get("cross_cut", {}).get("orphan_patterns", [])):
            ok = emit(f, None, EPIC_A, log)
            counters["created" if ok else "skipped"] += 1

        # Taxonomy findings → EPIC_B
        log.write("\n## Taxonomy findings\n")
        for f in data.get("cross_cut", {}).get("taxonomy_findings", []):
            ok = emit(f, None, EPIC_B, log)
            counters["created" if ok else "skipped"] += 1

        log.write(f"\n## Summary\n")
        log.write(f"Created: {counters['created']}\n")
        log.write(f"Skipped (no-action): {counters['skipped']}\n")

    print(json.dumps(counters))


if __name__ == "__main__":
    main()

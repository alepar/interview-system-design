#!/usr/bin/env python3
"""Build a human-readable FINDINGS.md from phase2/consolidated.json."""

import json
from pathlib import Path

RUN_DIR = Path("docs/audit/2026-05-25-0104")
CONSOLIDATED = RUN_DIR / "phase2" / "consolidated.json"
OUT = RUN_DIR / "FINDINGS.md"


SEV_RANK = {"high": 0, "medium": 1, "low": 2}


def severity_badge(sev):
    return {"high": "**HIGH**", "medium": "MEDIUM", "low": "low"}.get(sev, sev)


def render_finding(f, archetype=None):
    lines = []
    title = f.get("summary", "(no summary)")
    sev = f.get("severity", "?")
    conf = f.get("confidence", "?")
    cat = f.get("category", "?")
    fid = f.get("id", "?")
    tax = f.get("taxonomy_action", "")
    tax_part = f" / {tax}" if tax else ""
    lines.append(f"### [{severity_badge(sev)} · conf:{conf}] {title}")
    lines.append("")
    lines.append(f"**Finding ID:** `{fid}` · **Category:** `{cat}{tax_part}`")
    if archetype:
        lines.append(f"**Archetype:** `{archetype}`")
    if f.get("archetypes_affected"):
        lines.append(f"**Archetypes affected:** {', '.join(f['archetypes_affected'])}")
    if f.get("files"):
        lines.append(f"**Files:** {', '.join('`' + ff + '`' for ff in f['files'])}")
    if f.get("impact"):
        lines.append(f"**Impact:** {f['impact']}")
    lines.append("")
    lines.append(f"**Evidence:**  \n> {f.get('evidence', '(none)')}")
    lines.append("")
    lines.append(f"**Suggested fix:** {f.get('suggested_fix', '(none)')}")
    cac = f.get("cross_archetype_check") or {}
    if cac.get("resolved") and cac.get("resolution_note"):
        lines.append("")
        lines.append(f"**Cross-archetype resolution:** candidate `{cac.get('candidate_archetype')}` — {cac.get('resolution_note')}")
    lines.append("")
    lines.append("---")
    lines.append("")
    return "\n".join(lines)


def main():
    data = json.loads(CONSOLIDATED.read_text())
    per_archetype = data.get("per_archetype", [])
    cross_cut = data.get("cross_cut", {})

    # Aggregate counts
    total_per_archetype = sum(len(env.get("findings", [])) for env in per_archetype)
    total_dup = len(cross_cut.get("duplicates_across_archetypes", []))
    total_pattern_ref = len(cross_cut.get("archetype_pattern_ref_issues", []))
    total_index = len(cross_cut.get("global_index_issues", []))
    total_orphan = len(cross_cut.get("orphan_patterns", []))
    total_tax = len(cross_cut.get("taxonomy_findings", []))

    # Sort each archetype's findings by severity then category
    for env in per_archetype:
        env["findings"].sort(key=lambda f: (SEV_RANK.get(f.get("severity"), 9), f.get("category", "")))

    out = []
    out.append("# Catalog cross-audit — findings")
    out.append("")
    out.append("**Run:** `2026-05-25-0104` · **Spec:** `docs/specs/2026-05-25-catalog-cross-audit-design.md` · **bd epics:** `interview-system-design-ng1` (catalog-cross), `interview-system-design-48c` (taxonomy)")
    out.append("")
    out.append("## Counts")
    out.append("")
    out.append(f"- Per-archetype findings: **{total_per_archetype}** (resolved cross-archetype checks already applied)")
    out.append(f"- Cross-archetype duplicate candidates: **{total_dup}** (most confirmed as intentional splits)")
    out.append(f"- Archetype pattern-ref issues: **{total_pattern_ref}**")
    out.append(f"- Global index issues: **{total_index}**")
    out.append(f"- Orphan pattern files (no archetype references them): **{total_orphan}**")
    out.append(f"- Taxonomy findings: **{total_tax}**")
    out.append("")

    out.append("## Headline")
    out.append("")
    out.append("- **`ad-click-aggregator` is filed under `infra-primitives` but listed as a top-3 prompt of `ml-in-loop` in `archetypes.md`.** Hard contradiction in the index. Move the file (frontmatter to `ml-in-loop` + update archetype 9's Problems-in-catalog list) or revise the §9 top-3.")
    out.append("- **`realtime-messaging` is doing three jobs** (interactive messaging, message-protocol primitives, live-media CDN). Recommend splitting.")
    out.append("- **`ml-in-loop` summary doesn't match its contents anymore** — `feature-store`, `model-rollout-shadow` are ML platform infra; `autonomous-driving-inference`, `voice-assistant-routing` are embedded inference. Redefine or relocate.")
    out.append("- **`infra-primitives` ↔ `concurrent-resource` boundary is fuzzy** — articulate a build-the-primitive vs. application-using-the-primitive rule in `archetypes.md`.")
    out.append("")

    out.append("---")
    out.append("")
    out.append("## Taxonomy findings (epic: `interview-system-design-48c`)")
    out.append("")
    for f in sorted(cross_cut.get("taxonomy_findings", []), key=lambda x: (SEV_RANK.get(x.get("severity"), 9), x.get("taxonomy_action", ""))):
        out.append(render_finding(f))

    out.append("## Per-archetype findings (epic: `interview-system-design-ng1`)")
    out.append("")
    for env in sorted(per_archetype, key=lambda e: e.get("archetype", "")):
        arche = env.get("archetype")
        findings = env.get("findings", [])
        if not findings:
            continue
        sev_summary = {"high": 0, "medium": 0, "low": 0}
        for f in findings:
            sev_summary[f.get("severity", "low")] = sev_summary.get(f.get("severity", "low"), 0) + 1
        out.append(f"### archetype: `{arche}` — {len(findings)} findings ({sev_summary['high']} high, {sev_summary['medium']} medium, {sev_summary['low']} low)")
        out.append("")
        for f in findings:
            out.append(render_finding(f, archetype=arche))

    out.append("## Cross-archetype duplicate candidates (epic: `interview-system-design-ng1`)")
    out.append("")
    for f in cross_cut.get("duplicates_across_archetypes", []):
        out.append(render_finding(f))

    out.append("## Orphan patterns (epic: `interview-system-design-ng1`)")
    out.append("")
    out.append("These pattern files exist under `docs/coach/patterns/` but are not referenced by any archetype in `archetypes.md`. They may be intentional cross-cutting references, or they may be candidates for cleanup.")
    out.append("")
    for fname in cross_cut.get("orphan_patterns", []):
        out.append(f"- `docs/coach/patterns/{fname}`")
    out.append("")

    OUT.write_text("\n".join(out))
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

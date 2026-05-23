#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PROMPT=".claude/commands/mock-loop.md"
assert_file "$PROMPT"
assert_grep "personas/interviewer.md" "$PROMPT"
assert_grep "protocols.md" "$PROMPT"
assert_grep "rubric.md" "$PROMPT"
assert_grep "Requirements" "$PROMPT"
assert_grep "Core Entities" "$PROMPT"
assert_grep "API Design" "$PROMPT"
assert_grep "HLD" "$PROMPT"
assert_grep "Deep Dives" "$PROMPT"
assert_grep "constraint-injection" "$PROMPT"
assert_grep "hint-injection" "$PROMPT"
assert_grep "adversarial" "$PROMPT"
assert_grep "calibration" "$PROMPT"
assert_grep "pivotal moment" "$PROMPT"
assert_grep "What was correct" "$PROMPT"
assert_grep "What was wrong" "$PROMPT"
assert_grep "state/sessions" "$PROMPT"
assert_grep "Practice mode" "$PROMPT"

# Staff-method sub-bar (new in 2026-05-20 design)
assert_grep "Method sub-bar.*Staff" "docs/coach/rubric.md"
assert_grep "simplest workable baseline.*bottleneck" "docs/coach/rubric.md"
assert_grep "commit to one choice" "docs/coach/rubric.md"
assert_grep "Target level.*Simple.*bottleneck arc.*Commit-with-criteria.*Breadth menu" "docs/coach/rubric.md"

# Staff-method closing-assessment sub-step and schema (new in 2026-05-20 design)
assert_grep "Fill staff_method" ".claude/commands/mock-loop.md"
assert_grep "simple_to_bottleneck_arc.*demonstrated.*missed.*not_graded" ".claude/commands/mock-loop.md"
assert_grep "commit_with_criteria" ".claude/commands/mock-loop.md"
assert_grep "breadth_menu.*demonstrated.*absent" ".claude/commands/mock-loop.md"

# Difficulty knob — CLI grammar + recommendation (new in 2026-05-21 design)
assert_grep "Difficulty recommendation" ".claude/commands/mock-loop.md"
assert_grep "easy\|medium\|hard" ".claude/commands/mock-loop.md"
assert_grep "Running as.*level|Say.*easy.*medium.*hard" ".claude/commands/mock-loop.md"
assert_grep "Fill difficulty record" ".claude/commands/mock-loop.md"
assert_grep "difficulty\.source|difficulty_source" ".claude/commands/mock-loop.md"
assert_grep "drive_vs_wait_logged" ".claude/commands/mock-loop.md"
assert_grep "[Ss]oft gate" ".claude/commands/mock-loop.md"
assert_grep "coverage loop" ".claude/commands/mock-loop.md"

echo "Phase 4 /mock-loop static tests passed."

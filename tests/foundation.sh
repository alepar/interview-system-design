#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Directories
assert_dir ".claude/commands"
assert_dir "docs/coach"
assert_dir "docs/coach/personas"
assert_dir "docs/coach/patterns"
assert_dir "docs/coach/problems"
assert_dir "state"
assert_dir "state/sessions"
assert_dir "state/archive"

# State README
assert_file "state/README.md"
assert_grep "profile\.md" "state/README.md"
assert_grep "observed\.md" "state/README.md"

# rubric.md
assert_file "docs/coach/rubric.md"
assert_section "Problem Navigation" "docs/coach/rubric.md"
assert_section "Solution Design" "docs/coach/rubric.md"
assert_section "Technical Excellence" "docs/coach/rubric.md"
assert_section "Technical Communication" "docs/coach/rubric.md"
assert_grep "Mid-level|L4" "docs/coach/rubric.md"
assert_grep "Senior|L5" "docs/coach/rubric.md"
assert_grep "Staff|L6" "docs/coach/rubric.md"
assert_grep "3-point ordinal|above bar|at bar|below bar" "docs/coach/rubric.md"
assert_grep "Hello Interview|hellointerview" "docs/coach/rubric.md"

# protocols.md
assert_file "docs/coach/protocols.md"
assert_section "Refusal gate" "docs/coach/protocols.md"
assert_section "Two-voice modeling" "docs/coach/protocols.md"
assert_section "Slow drip" "docs/coach/protocols.md"
assert_section "Sub-optimality injection" "docs/coach/protocols.md"
assert_section "Phase transitions" "docs/coach/protocols.md"
assert_section "Re-read schedule" "docs/coach/protocols.md"
assert_section "Bluff prompts" "docs/coach/protocols.md"
assert_section "Honor attestation" "docs/coach/protocols.md"
assert_section "No trailing-question" "docs/coach/protocols.md"
assert_section "observed.md update protocol" "docs/coach/protocols.md"
assert_grep "Aloud" "docs/coach/protocols.md"
assert_grep "Thinking" "docs/coach/protocols.md"
assert_grep "functional requirements" "docs/coach/protocols.md"
assert_grep "non-functional" "docs/coach/protocols.md"

echo "Phase 1 foundation tests passed."

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PROMPT=".claude/commands/study-patterns.md"
assert_file "$PROMPT"
assert_grep "personas/coach.md" "$PROMPT"
assert_grep "protocols.md" "$PROMPT"
assert_grep "rubric.md" "$PROMPT"
assert_grep "interleav" "$PROMPT"
assert_grep "3-point ordinal|yes / partial / no" "$PROMPT"
assert_grep "progress_index|pause|resume" "$PROMPT"
assert_grep "state/sessions" "$PROMPT"
assert_grep "observed.md" "$PROMPT"
assert_grep "honor reminder.+NOT|no reminder" "$PROMPT"

echo "Phase 3 /study-patterns static tests passed."

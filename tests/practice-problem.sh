#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PROMPT=".claude/commands/practice-problem.md"
assert_file "$PROMPT"
assert_grep "personas/coach.md" "$PROMPT"
assert_grep "protocols.md" "$PROMPT"
assert_grep "rubric.md" "$PROMPT"
assert_grep "refusal gate|Refusal gate" "$PROMPT"
assert_grep "Aloud" "$PROMPT"
assert_grep "Thinking" "$PROMPT"
assert_grep "slow drip|Slow drip|one component per turn" "$PROMPT"
assert_grep "sub-optimality" "$PROMPT"
assert_grep "honor reminder|Practice mode" "$PROMPT"
assert_grep "state/sessions" "$PROMPT"
assert_grep "state/observed.md" "$PROMPT"
assert_grep "state/archive" "$PROMPT"
assert_grep "bluff" "$PROMPT"
assert_grep "scaffolding" "$PROMPT"

echo "Phase 2 /practice-problem static tests passed."

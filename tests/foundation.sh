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

echo "Phase 1 foundation tests passed."

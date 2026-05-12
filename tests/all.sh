#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Phase 1
[[ -f "$SCRIPT_DIR/foundation.sh" ]] && bash "$SCRIPT_DIR/foundation.sh"

# Phase 2-4 will source their own test files; added in later tasks.
[[ -f "$SCRIPT_DIR/practice-problem.sh" ]] && bash "$SCRIPT_DIR/practice-problem.sh"
[[ -f "$SCRIPT_DIR/study-patterns.sh" ]] && bash "$SCRIPT_DIR/study-patterns.sh"
[[ -f "$SCRIPT_DIR/mock-loop.sh" ]] && bash "$SCRIPT_DIR/mock-loop.sh"
[[ -f "$SCRIPT_DIR/first-run.sh" ]] && bash "$SCRIPT_DIR/first-run.sh"

echo "All tests passed."

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# All three commands must handle first-run when state/profile.md is missing.
for cmd in practice-problem study-patterns mock-loop; do
  PROMPT=".claude/commands/$cmd.md"
  assert_grep "first-run|first run" "$PROMPT"
  assert_grep "state/profile.md|profile\.md does not exist" "$PROMPT"
  assert_grep "tell me a few words|tell me a few words about yourself" "$PROMPT"
  assert_grep "honor attestation|honor_attestation|Honor attestation" "$PROMPT"
done

echo "First-run flow static tests passed."

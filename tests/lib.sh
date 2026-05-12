#!/usr/bin/env bash
# Test helpers for the coach validation suite.

assert_file() {
  local f=$1
  [[ -f "$f" ]] || { echo "FAIL: missing file $f"; exit 1; }
}

assert_dir() {
  local d=$1
  [[ -d "$d" ]] || { echo "FAIL: missing dir $d"; exit 1; }
}

assert_grep() {
  local pattern=$1
  local file=$2
  grep -qE "$pattern" "$file" || { echo "FAIL: pattern '$pattern' not in $file"; exit 1; }
}

assert_yaml_field() {
  # Extract YAML frontmatter (first --- to second ---) and check for a top-level key.
  local key=$1
  local file=$2
  sed -n '/^---$/,/^---$/p' "$file" | grep -qE "^${key}:" \
    || { echo "FAIL: frontmatter key '$key' missing in $file"; exit 1; }
}

assert_section() {
  # Check for a markdown heading (any level) with the given title.
  local title=$1
  local file=$2
  grep -qE "^#+ +${title}" "$file" \
    || { echo "FAIL: section '${title}' missing in $file"; exit 1; }
}

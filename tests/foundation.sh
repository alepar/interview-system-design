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

# personas/coach.md
assert_file "docs/coach/personas/coach.md"
assert_grep "collaborative" "docs/coach/personas/coach.md"
assert_grep "no over-praise|no.+praise" "docs/coach/personas/coach.md"
assert_grep "great question" "docs/coach/personas/coach.md"
assert_grep "trailing question|trailing-question" "docs/coach/personas/coach.md"

# personas/interviewer.md
assert_file "docs/coach/personas/interviewer.md"
assert_grep "neutral" "docs/coach/personas/interviewer.md"
assert_grep "adversarial" "docs/coach/personas/interviewer.md"
assert_grep "time.boxing|time-box" "docs/coach/personas/interviewer.md"
assert_grep "category of gap" "docs/coach/personas/interviewer.md"

# archetypes.md
assert_file "docs/coach/archetypes.md"
for arch in "High-throughput read systems" "Fan-out" "Real-time messaging" \
            "Concurrent access" "User-generated content" "Geo" "Search" \
            "Conflict resolution" "ML-in-the-loop" "Infrastructure primitives" \
            "AI-Infrastructure" "Front-End"; do
  assert_grep "$arch" "docs/coach/archetypes.md"
done

# patterns 3A-3E
assert_file "docs/coach/patterns/3A-core-concepts.md"
assert_grep "Definition" "docs/coach/patterns/3A-core-concepts.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3A-core-concepts.md"

assert_file "docs/coach/patterns/3B-networking-transport.md"
assert_grep "Definition" "docs/coach/patterns/3B-networking-transport.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3B-networking-transport.md"

assert_file "docs/coach/patterns/3C-load-balancing.md"
assert_grep "Definition" "docs/coach/patterns/3C-load-balancing.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3C-load-balancing.md"

assert_file "docs/coach/patterns/3D-storage-databases.md"
assert_grep "Definition" "docs/coach/patterns/3D-storage-databases.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3D-storage-databases.md"

assert_file "docs/coach/patterns/3E-caching.md"
assert_grep "Definition" "docs/coach/patterns/3E-caching.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3E-caching.md"

# patterns 3F-3J
assert_file "docs/coach/patterns/3F-async-streaming.md"
assert_grep "Definition" "docs/coach/patterns/3F-async-streaming.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3F-async-streaming.md"

assert_file "docs/coach/patterns/3G-consistency-coordination.md"
assert_grep "Definition" "docs/coach/patterns/3G-consistency-coordination.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3G-consistency-coordination.md"

assert_file "docs/coach/patterns/3H-data-structures.md"
assert_grep "Definition" "docs/coach/patterns/3H-data-structures.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3H-data-structures.md"

assert_file "docs/coach/patterns/3I-api-idempotency.md"
assert_grep "Definition" "docs/coach/patterns/3I-api-idempotency.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3I-api-idempotency.md"

assert_file "docs/coach/patterns/3J-architectural.md"
assert_grep "Definition" "docs/coach/patterns/3J-architectural.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3J-architectural.md"

# patterns 3K-3O
assert_file "docs/coach/patterns/3K-reliability-observability.md"
assert_grep "Definition" "docs/coach/patterns/3K-reliability-observability.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3K-reliability-observability.md"

assert_file "docs/coach/patterns/3L-security-privacy.md"
assert_grep "Definition" "docs/coach/patterns/3L-security-privacy.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3L-security-privacy.md"

assert_file "docs/coach/patterns/3M-ml-specific.md"
assert_grep "Definition" "docs/coach/patterns/3M-ml-specific.md"
assert_grep "Production systems|Canonical use" "docs/coach/patterns/3M-ml-specific.md"

assert_file "docs/coach/patterns/3N-papers.md"
assert_grep "Definition" "docs/coach/patterns/3N-papers.md"
assert_grep "Paxos|Raft|Spanner|MapReduce" "docs/coach/patterns/3N-papers.md"

assert_file "docs/coach/patterns/3O-tradeoffs.md"
assert_grep "Definition" "docs/coach/patterns/3O-tradeoffs.md"
assert_grep "vs " "docs/coach/patterns/3O-tradeoffs.md"

# patterns ai-infra and frontend
assert_file "docs/coach/patterns/ai-infra.md"
for pat in "Continuous batching" "PagedAttention" "Prefix caching" "KV-cache" \
           "Speculative decoding" "Model.router" "Mixture-of-Experts|MoE" \
           "Semantic caching" "Eval pipeline" "Safety pipeline" "FSDP|distributed training"; do
  assert_grep "$pat" "docs/coach/patterns/ai-infra.md"
done

assert_file "docs/coach/patterns/frontend.md"
for pat in "RADIO" "Virtualized lists" "Optimistic UI" "IndexedDB" \
           "Service worker" "WebSocket" "Code.splitting|code-splitting" \
           "CRDT|OT" "intersection observer|lazy.load"; do
  assert_grep "$pat" "docs/coach/patterns/frontend.md"
done

# staff-engineer-study-guide.md additions
assert_grep "Category 11" "docs/research/staff-engineer-study-guide.md"
assert_grep "AI.Infrastructure|AI Infrastructure" "docs/research/staff-engineer-study-guide.md"
assert_grep "Category 12" "docs/research/staff-engineer-study-guide.md"
assert_grep "Front.End|Front End" "docs/research/staff-engineer-study-guide.md"
assert_grep "RADIO" "docs/research/staff-engineer-study-guide.md"

# problems: tinyurl, ticketmaster, dropbox
for problem in tinyurl ticketmaster dropbox; do
  f="docs/coach/problems/${problem}.md"
  assert_file "$f"
  assert_yaml_field "slug" "$f"
  assert_yaml_field "archetype" "$f"
  assert_section "Bar anchors" "$f"
  assert_section "Canonical decomposition" "$f"
  assert_section "Requirements" "$f"
  assert_section "Core entities" "$f"
  assert_section "API" "$f"
  assert_section "HLD" "$f"
  assert_section "Deep dives" "$f"
  assert_section "Known failure modes" "$f"
  assert_grep "Mid-level" "$f"
  assert_grep "Senior" "$f"
  assert_grep "Staff" "$f"
done

# problems: twitter-timeline, uber
for problem in twitter-timeline uber; do
  f="docs/coach/problems/${problem}.md"
  assert_file "$f"
  assert_yaml_field "slug" "$f"
  assert_yaml_field "archetype" "$f"
  assert_section "Bar anchors" "$f"
  assert_section "Canonical decomposition" "$f"
  assert_section "Requirements" "$f"
  assert_section "Core entities" "$f"
  assert_section "API" "$f"
  assert_section "HLD" "$f"
  assert_section "Deep dives" "$f"
  assert_section "Known failure modes" "$f"
  assert_grep "Mid-level" "$f"
  assert_grep "Senior" "$f"
  assert_grep "Staff" "$f"
done


# Tone and feedback discipline (new in 2026-05-12 design)
assert_section "Tone and feedback discipline" "docs/coach/protocols.md"
assert_grep "Mid-flow vs debrief" "docs/coach/protocols.md"
assert_grep "Numeric-commit calibration" "docs/coach/protocols.md"
assert_grep "derivable|empirical" "docs/coach/protocols.md"
assert_grep "anchor.*method" "docs/coach/protocols.md"

# Task 2: Tone discipline cross-reference in interviewer persona
assert_grep "Tone discipline|Tone and feedback discipline" "docs/coach/personas/interviewer.md"

# Task 3: Calibration note in rubric Mai anchor
assert_grep "Calibration note|implementation decisions|empirical calibration" "docs/coach/rubric.md"

# Staff-method check cross-reference (new in 2026-05-20 design)
assert_grep "staff-method sub-bar" "docs/coach/protocols.md"
assert_grep "staff_method_trajectory|staff_method trajectory" "docs/coach/protocols.md"

# Difficulty levels section in interviewer.md (new in 2026-05-21 design)
assert_section "Difficulty levels" "docs/coach/personas/interviewer.md"
assert_grep "easy.*medium.*hard|Easy.*Medium.*Hard" "docs/coach/personas/interviewer.md"
assert_grep "Drive-vs-wait logging by difficulty|Drive vs wait at non-hard" "docs/coach/personas/interviewer.md"

echo "Phase 1 foundation tests passed."

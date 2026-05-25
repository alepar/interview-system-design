---
slug: crdt-primitive
archetype: conflict-resolution
sources:
  shapiro_crdt: lip6.fr/Marc.Shapiro/papers/2011/CRDTs_SSS-2011.pdf
  inria_rr7506: inria.hal.science/inria-00555588/en/ (A comprehensive study of Convergent and Commutative Replicated Data Types)
  delta_crdt: arxiv.org/abs/1603.01529 (Almeida, Shoker, Baquero — Delta State Replicated Data Types)
  crdt_wikipedia: en.wikipedia.org/wiki/Conflict-free_replicated_data_type
  weidner_survey: mattweidner.com/2023/09/26/crdt-survey-2.html
---

# CRDT Primitive (conflict-free replicated data types from scratch)

## Bar anchors
- **Mid-level (L4/E4):** Knows a CRDT is a data structure that merges without conflict and gives "eventual consistency." Can describe a grow-only counter (array of per-replica counts, sum to read). Doesn't distinguish state-based from op-based, can't state the convergence conditions, and reaches for last-writer-wins without noting its data loss.
- **Senior (L5/E5):** Distinguishes state-based (CvRDT) from op-based (CmRDT); names the core types (G-Counter, PN-Counter, OR-Set, LWW-Register). Knows state-based needs a commutative+associative+idempotent merge and op-based needs reliable delivery. Can explain why a naive remove-from-set isn't a CRDT. May not state the semilattice/monotonicity condition precisely, may not know delta-CRDTs, and may hand-wave tombstone GC.
- **Staff+ (L6/E6+):** Drives proactively. States the theorem: a **state-based CRDT converges iff its states form a join-semilattice under merge (⊔ commutative, associative, idempotent) and every update is monotonically inflationary** (the new state ≥ old in the partial order); an **op-based CRDT converges iff all concurrent operations commute AND a causal-broadcast layer delivers each op exactly once in causal order.** Derives G-Counter (componentwise max), PN-Counter (two G-Counters; decrement can't live in one because merge=max would erase it), and **OR-Set as principled add-wins** (each add carries a unique tag; remove takes only the tags it has *observed*, so a concurrent add carries a fresh unseen tag and wins). Names **δ-CRDTs** (ship small delta-states, not whole state) and the metadata/tombstone-GC problem (safe only under causal stability). Picks LWW only with server-assigned/HLC timestamps, never wall clocks, and names the silent-data-loss tradeoff.

## Canonical decomposition

### Requirements
**Functional:**
- Replicas accept reads/writes locally with no coordination; all replicas converge to the same value once they've seen the same set of updates
- Support counters (inc/dec), sets (add/remove/re-add), registers (assign), and maps composing them
- Tolerate arbitrary message reordering/duplication (state-based) or causal-ordered exactly-once delivery (op-based)
- Survive network partition with no lost *adds*

**Non-functional (with numbers):**
- Strong eventual consistency: replicas that delivered the same updates are byte-identical
- Merge must be O(state) or better; δ-CRDTs target O(delta) bandwidth
- Metadata overhead bounded: OR-Set tags GC'd under causal stability; vector clocks capped (e.g. Dynamo truncates at ~10 entries)
- LWW-Register: O(1) per key (one timestamp + value)

### Core entities
- **Replica:** a node with a local copy + a unique replica/site id
- **State (CvRDT):** an element of a join-semilattice; `merge(a,b) = a ⊔ b` (least upper bound)
- **Operation (CmRDT):** a commutative update broadcast over causal delivery
- **Tag/dot:** `(replica_id, counter)` unique identifier for an add (OR-Set) or version (vector clock)
- **Tombstone:** retained metadata for a removed element until causal stability allows GC

### API
- `inc()/dec()`, `value() → int` (counters)
- `add(e)/remove(e)`, `contains(e) → bool`, `elements() → set` (sets)
- `assign(v)`, `read() → v` (registers)
- `merge(other) → state` (state-based) or `apply(op)` over causal broadcast (op-based)

### HLD
Two families. **State-based (CvRDT):** each replica holds a state in a join-semilattice and periodically gossips its full state; on receipt, `merge` takes the least upper bound. Convergence is guaranteed by the semilattice laws (merge commutative, associative, idempotent) plus monotone (inflationary) updates — so merges in any order/multiplicity reach the same join. It tolerates lossy, duplicating, reordering channels (gossip is enough) but pays O(state) bandwidth. **Op-based (CmRDT):** each replica broadcasts small operations; convergence requires that concurrent ops *commute* and that the network delivers each op exactly once in causal order (a causal-broadcast middleware). Cheaper bandwidth (O(op)) but a stronger delivery contract.

**The canonical types.** *G-Counter*: vector of per-replica non-negative ints; inc bumps your entry; value=sum; merge=componentwise max (a semilattice). *PN-Counter*: a pair of G-Counters (P for increments, N for decrements); value=ΣP−ΣN. Decrement can't share one G-Counter because merge=max would silently discard it — the monotonicity requirement forbids it. *G-Set* (add-only) and *2P-Set* (add+remove via a tombstone set, but removed-then-never-re-addable — broken for carts). *LWW-Element-Set / LWW-Register*: keep the value with the highest timestamp; allows re-add but **loses concurrent writes silently**, and is only safe with monotone timestamps (HLC or server-assigned), never raw wall clocks. *OR-Set (observed-remove)*: every add stamps the element with a unique tag; the element is present iff it has at least one tag not in the tombstone set; remove moves only the *currently observed* tags to tombstones — so a concurrent add (with a fresh, unobserved tag) survives. This is principled **add-wins**, and is the correct set semantics for collaborative state.

**δ-CRDTs** (Almeida et al.) keep the semilattice guarantee but ship a small *delta-state* (the join-irreducible change) instead of the whole state, recovering op-based bandwidth without requiring causal exactly-once delivery. Composition: a JSON-CRDT (Automerge-style) is built by nesting OR-Map of registers/sets — naive composition breaks (a map of sets needs OR semantics on both levels), which is the subtle part.

### Deep dives
1. **Why the semilattice laws are exactly the right conditions.** Merge must be *idempotent* (re-delivering the same state changes nothing — survives duplication), *commutative* (order of gossip doesn't matter — survives reordering), and *associative* (batching doesn't matter). Together they make merge a join over a partial order, and any two replicas that have absorbed the same set of updates compute the same least upper bound regardless of how the updates arrived. Updates must be *inflationary* (move up the lattice) so a later merge can't "undo" them. Prove G-Counter satisfies this (componentwise max is a join; inc only raises an entry). This is the whole foundation — a candidate who can state and motivate it is at the Staff+ bar.
2. **OR-Set add-wins vs the broken alternatives.** Walk the failure of 2P-Set (once removed, never re-addable — the tombstone is permanent) and of a naive "set of elements" (concurrent add+remove of x: merge order decides the result → divergence, or you pick remove-wins and silently lose adds). OR-Set fixes it: tag each add `(replica, counter)`; `remove(x)` records the set of x's tags the remover has *seen*; on merge, x is present iff it has a tag present-and-not-tombstoned. A concurrent `add(x)` carries a fresh tag the `remove` never observed, so x correctly survives — add-wins, no divergence, supports re-add. Note the dual (remove-wins) is also a legal CRDT — *same data type, different merge*, a Staff+ nuance. This is the same mechanism that fixes the Dynamo shopping-cart resurrection bug (see `shopping-cart-crdt`).
3. **Metadata growth and causal-stability GC.** Every principled set/register carries metadata (tags, vector clocks, tombstones) that grows with operations. You can only GC a tombstone once you're certain *every* replica has observed the corresponding remove (causal stability) — impossible to guarantee under unbounded offline, which is why production systems either bound it (Dynamo truncates vector clocks at ~10 entries, accepting rare spurious merges) or scope clocks to a session/epoch. Sequential dots compress to ranges (ORSWOT). Contrast with `yjs`, which sidesteps tombstone GC by storing deletions as a tiny delete-set rather than per-element tombstones.

## Known failure modes
1. **LWW on unsynchronized wall clocks silently loses writes.** Two replicas write concurrently; clock skew makes one "win" arbitrarily and the other vanishes with no trace. Production answer: never use raw wall clocks — use hybrid logical clocks (HLC) or a server-assigned monotonic order (Figma's approach), and surface concurrent values via an MV-Register when silent loss is unacceptable.
2. **Unbounded vector-clock / tag growth ("actor explosion").** Long-lived objects edited by many transient replicas accumulate per-replica entries forever, bloating every message and merge. Production answer: dotted version vectors (one dot per value), clock truncation with a timestamp (Dynamo's threshold ~10), or scoping clocks to a bounded set of server-side actors rather than every client.
3. **Op-based CRDT used without causal broadcast.** If the delivery layer drops, duplicates, or reorders ops across the causal boundary, concurrent non-commuting deliveries diverge (e.g. add then remove delivered in opposite orders). Production answer: either provide the causal-broadcast middleware the model assumes, or switch to a state-based/δ-CRDT whose merge tolerates arbitrary channels.

## (Spine note)
`crdt-primitive` owns the general CRDT math and toolbox. Text-specific sequence CRDTs and the OT-vs-CRDT text decision live in `collaborative-text-editor`; the production library reality is `yjs`; the application of OR-Set to carts is `shopping-cart-crdt`. Vector clocks *as a storage primitive* live in infra-primitives `dynamodb` — reference, don't re-derive.

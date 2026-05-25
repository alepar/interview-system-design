---
slug: collaborative-text-editor
archetype: conflict-resolution
sources:
  interleaving_papoc19: martin.kleppmann.com/papers/interleaving-papoc19.pdf (DOI 10.1145/3301419.3323972)
  fugue: arxiv.org/abs/2305.00583 (Weidner, Gentle, Kleppmann — The Art of the Fugue)
  eg_walker: arxiv.org/abs/2409.14252 (Gentle & Kleppmann — Eg-walker, EuroSys 2025)
  rga: "Roh, Jeon, Kim, Lee — Replicated Abstract Data Types (RGA), 2011"
  woot: "Oster, Urso, Molli, Imine — WOOT, 2006"
  crdt_benchmarks: github.com/dmonad/crdt-benchmarks
---

# Collaborative Text Editor (OT-vs-CRDT for text + sequence CRDTs)

## Bar anchors
- **Mid-level (L4/E4):** Proposes a shared string with locking or "send diffs." Doesn't recognize that concurrent character edits need a convergence algorithm, can't name OT or CRDTs, treats it as a chat app with a textarea.
- **Senior (L5/E5):** Frames the choice as OT vs CRDT; knows OT needs a central server while a sequence CRDT can run peer-to-peer by giving each character a stable identifier. Can name one or two sequence CRDTs (RGA, Logoot) and the tombstone problem. May not know the interleaving anomaly, can't compare the sequence CRDT families precisely, and treats "it converges" as sufficient.
- **Staff+ (L6/E6+):** Drives proactively. Separates **convergence from intention preservation** and names the **interleaving anomaly** as the field's key result (Kleppmann et al., PaPoC 2019): Logoot and LSEQ allow concurrent insertions to interleave *character-by-character* into unreadable garbage, RGA has a lesser variant — *convergence alone does not guarantee usability*. Names the sequence-CRDT family with their tradeoffs — **WOOT** (permanent tombstones, can't GC), **Logoot/LSEQ** (dense position identifiers, but Logoot ids grow unbounded; LSEQ randomizes to stay sub-linear), **Treedoc** (dense binary tree), **RGA** (linked list + tombstones) — and lands on **Fugue/FugueMax** (Weidner/Gentle/Kleppmann 2023) as the first algorithm proven to satisfy **maximal non-interleaving**, and **Eg-walker** (Gentle & Kleppmann, EuroSys 2025) as the frontier: an OT/CRDT hybrid using **an order of magnitude less steady-state memory than CRDTs, loading orders of magnitude faster, and merging long-running branches orders of magnitude faster than OT.** Quotes the dmonad benchmark trace (~260k ops, ~182k inserts).

## Canonical decomposition

### Requirements
**Functional:**
- N users (possibly peer-to-peer, possibly offline) edit one text document; all converge
- Concurrent insertions/deletions at arbitrary positions merge without losing data or interleaving runs
- Cursor positions survive concurrent edits (anchor-stable)
- Bounded memory/storage growth despite deletions (tombstone management)

**Non-functional (with numbers):**
- Reference workload: the ~260k-operation Martin/B4 editing trace (~182k inserts, ~77k deletes)
- Pure unoptimized sequence CRDTs store ~60–88 bytes of metadata per character
- Document open must be fast (CRDTs that replay full history are slow to load)
- Peer-to-peer capable (no required central server) for the CRDT branch

### Core entities
- **Element/Item:** one character (or coalesced run) with a unique, totally-ordered position identifier
- **Position identifier:** dense order key (Logoot fraction, RGA `(timestamp, site)`, Fugue tree node)
- **Tombstone:** a deleted element retained so concurrent ops still resolve against it
- **Document:** the ordered visible sequence derived from elements minus tombstones

### API
- `insert(pos, char)` → mint a new position id between neighbors; broadcast
- `delete(elementId)` → tombstone the element; broadcast
- `merge(remoteOps)` → integrate by position id; converge
- `relativePosition(index) → anchor` / `resolve(anchor) → index` (cursor stability)

### HLD
The CRDT approach gives every character a **unique, immutable, totally-ordered position identifier**, so insertion order is decided by comparing identifiers rather than by transforming indices (OT). Insert mints an id strictly between its neighbors' ids; delete tombstones the element (retained so a concurrent insert "after this character" still resolves). Convergence is automatic: all replicas sort by the same identifiers. The families differ in *how* identifiers are chosen and *what anomalies* result:
- **Logoot/LSEQ** use dense fractional/path identifiers (a key in a dense order). Logoot ids grow unbounded with edits; LSEQ randomizes allocation to keep growth sub-linear. **Both interleave** concurrent same-position runs character-by-character.
- **RGA** uses `(timestamp, site)` ids in a linked list with tombstones; it has a *lesser* interleaving anomaly and is the common production-grade choice (Yjs's YATA is RGA-adjacent).
- **WOOT** keeps a tree of characters with permanent tombstones (no GC) — historically important, impractical at scale.
- **Fugue/FugueMax** model positions as nodes in a tree (each node a parent + side, in-order traversal, dots break ties) and is proven to achieve **maximal non-interleaving** — concurrently inserted runs stay contiguous.

The OT alternative (central server, transform functions) is simpler operationally but cannot run peer-to-peer and merges long divergences in O(n²). The frontier **Eg-walker** is a hybrid: it stores the operation DAG and rebuilds only a local index over the branch frontier when merging, getting CRDT-style P2P merge with OT-style steady-state memory and fast load. **Tombstone growth** is the recurring tax: deletions leave metadata; GC is only safe under causal stability (every replica has seen the delete), which offline editing prevents — so production systems either keep tombstones tiny (Yjs delete-set) or assume bounded divergence.

### Deep dives
1. **The interleaving anomaly (the headline result).** Two users, document "Hello ", concurrently insert "Alice!" and "Bob!". A correct editor yields "Hello Alice!Bob!" or "Hello Bob!Alice!" — never "Hello ABloibce!!". Kleppmann et al. (PaPoC 2019) proved Logoot and LSEQ produce exactly this character-jumble under concurrent same-position runs, and RGA a milder version. The lesson: **convergence ≠ correctness** — all these CRDTs converge to *a* state, but an unreadable one. Fugue/FugueMax define and achieve *maximal non-interleaving*. A candidate who can construct the counterexample and name the fix is unambiguously at the Staff+ bar; one who says "CRDTs converge so we're fine" is not.
2. **Sequence-CRDT family tradeoffs + tombstone GC.** Compare identifier schemes on three axes: identifier size growth (Logoot unbounded, LSEQ sub-linear, RGA constant per element, Fugue ~constant), interleaving (Logoot/LSEQ bad, RGA lesser, Fugue none), and GC (WOOT never, others under causal stability). Explain why GC is hard: to drop a tombstone you must know every replica has observed the delete, which unbounded offline editing makes impossible — so you either bound divergence or, like Yjs, store deletes as a compact delete-set rather than per-character tombstones (turning O(deletes) metadata into a few KB). 
3. **OT vs CRDT vs Eg-walker — the actual decision.** OT: central server, small steady-state, but no P2P and O(n²) long-branch merge. Pure CRDT: P2P, automatic merge, but historically heavy memory and slow document load (replay history). Eg-walker: keeps the op DAG, rebuilds a local index only over the frontier on merge — order-of-magnitude less steady-state memory than CRDTs, fast load, and long-branch merge far faster than OT. The Staff+ framing: pick OT when you already have a central server and don't need offline P2P; pick a non-interleaving sequence CRDT (RGA-family/Fugue) or Eg-walker when you need P2P/offline; either way, *name the interleaving and load-cost tradeoffs explicitly*.

## Known failure modes
1. **Character interleaving on concurrent same-position runs** (Logoot/LSEQ). Two pasted paragraphs merge into alternating-character soup. Production answer: use RGA-family, Fugue/FugueMax (maximal non-interleaving), or Eg-walker — and test the concurrent-run case explicitly, since it passes any convergence check.
2. **Slow document open / memory blowup.** Pure CRDTs that replay the full op history take seconds to load a large doc and hold large in-memory metadata. Production answer: columnar binary snapshots (Yjs), run coalescing, or migrate to Eg-walker (steady-state memory an order of magnitude smaller).
3. **Unbounded tombstones.** Years of edits leave deletion metadata that never GCs because causal stability can't be guaranteed under offline editing. Production answer: store deletes as a compact delete-set (Yjs) rather than per-element tombstones, or define an epoch/"no concurrent edits older than N days" assumption that licenses GC.

## (Spine note)
`collaborative-text-editor` owns the text-specific OT-vs-CRDT decision and sequence CRDTs. The general CRDT math is `crdt-primitive`; OT specifically is `google-docs`; the production library reality (YATA, encoding, GC, benchmarks) is `yjs`. Cursor anchoring under concurrent edits is `presence-awareness`.

---
slug: version-control-merge
archetype: conflict-resolution
sources:
  git_merge_strategies: git-scm.com/docs/merge-strategies
  github_git234_ort: github.blog/open-source/git/highlights-from-git-2-34/
  diff3: codeinput.com/blog/git-conflict-revisions
  merge_eval_ase2024: homes.cs.washington.edu/~mernst/pubs/merge-evaluation-ase2024.pdf
  recursive_merge: blog.plasticscm.com/2012/01/more-on-recursive-merge-strategy.html
---

# Version-Control Merge (git 3-way merge, diff3, recursive → ort)

## Bar anchors
- **Mid-level (L4/E4):** Thinks merging is "take the latest file." Doesn't know about a common ancestor, why conflicts happen, or how git decides what to combine.
- **Senior (L5/E5):** Knows git does a **3-way merge** using the common ancestor (base) plus the two branch tips, auto-combining non-overlapping changes and marking conflicts where both sides changed the same region. Knows rebase replays commits. May not name diff3, the merge-base/LCA computation, recursive vs ort, or why line-based merge is fundamentally limited.
- **Staff+ (L6/E6+):** Drives proactively. Frames merge as **diff3(base, ours, theirs)** (the 1979 algorithm): auto-apply a hunk changed on only one side, conflict only where both sides changed the same region differently. Computes the **merge base** as the lowest common ancestor in the commit DAG, and handles **criss-cross merges** (multiple LCAs) with the **recursive** strategy (merge the bases into a *virtual ancestor*, then 3-way against that). Knows **ort** (Git 2.34 default) is a from-scratch in-memory rewrite — **~500× faster on rename-heavy merges, >9000× on rebase sequences** via caching — and does **rename detection** (a file edited on one side and renamed on the other gets the edits applied to the renamed path). Contrasts **line-based** merge (git) with **semantic/AST** merge (Spork/3DM) and explains why merge conflicts are *unavoidable* (concurrent edits to the same lines). Treats git as the **async, after-the-fact** counterpart to real-time OT/CRDT, and notes content-addressing (SHA) dedups blobs. Cites that conflicted code is empirically more bug-prone.

## Canonical decomposition

### Requirements
**Functional:**
- Merge two divergent branches: auto-combine independent changes, flag true conflicts
- Compute the correct common ancestor, including criss-cross histories
- Detect renames so edits follow a moved/renamed file
- Support rebase (replay commits) as well as merge (preserve divergence)

**Non-functional (with numbers):**
- ort vs recursive: ~500× faster on rename-heavy merges, >9000× on rebase series (caching)
- Merge-conflict rate ~9–19% of merges (workload-dependent — cite the specific study)
- Content-addressed storage (SHA): identical blobs dedup; corruption detectable
- Async / offline by nature (no real-time convergence requirement)

### Core entities
- **Commit DAG:** commits with parent edges; branches are pointers into it
- **Blob/tree:** content-addressed file content / directory snapshot (SHA)
- **Merge base:** lowest common ancestor(s) of the two tips
- **diff3 result:** merged file with auto-resolved hunks + conflict regions
- **Virtual ancestor:** synthetic base built by merging multiple LCAs (recursive/ort)

### API
- `git merge-base A B` → common ancestor(s)
- `git merge B` (into A) → 3-way merge, conflict markers on overlap
- `git rebase B` → replay A's commits onto B (new SHAs, linear history)
- merge strategies: `-s ort` (default), `-X find-renames=<n>`, `-X ours/theirs`

### HLD
Git stores everything **content-addressed**: every file is a blob keyed by the SHA of its content, every directory a tree, every commit points to a tree + parent commit(s). Identical content (across branches, forks, history) dedups to one blob, and corruption is detectable (hash mismatch). A **merge** of branch B into A finds the **merge base** — the lowest common ancestor of the two tips in the commit DAG — and runs a **3-way merge** (`diff3`): for each region, if only one side changed it relative to the base, take that change automatically; if both sides changed the same region differently, emit a **conflict** with markers for the human to resolve. Independent changes (different files, different regions) merge cleanly; conflicts are *unavoidable* exactly when concurrent edits touch the same lines — there's no information to auto-resolve them.

**Criss-cross histories** have **multiple** lowest common ancestors (two branches merged each other before). The **recursive** strategy handles this by merging the multiple bases pairwise into a single **virtual ancestor**, then doing the final 3-way merge against it (reducing spurious conflicts). **ort** ("Ostensibly Recursive's Twin," Git 2.34 default) is a full in-memory rewrite that processes all changes without touching the working tree, caches intermediate merge results (so a rebase replaying N similar commits reuses work), and does **rename detection** — a file modified on one side and renamed on the other has the modifications applied to the renamed destination. Performance: ~500× faster than recursive on rename-heavy merges, >9000× across a rebase series. **Rebase** replays commits onto a new base (new SHAs, linear history) and may re-present similar conflicts at each replayed commit, whereas merge resolves once. Git's merge is **line-based**, so it can't use code structure — motivating **semantic/AST merge** (e.g. Spork's 3DM-Merge on Java ASTs) that resolves rename+edit and reorder cases line-based merge can't.

### Deep dives
1. **3-way merge + diff3, and why conflicts are unavoidable.** The base is the information that lets git distinguish "you changed X, I didn't" (take yours) from "we both changed X differently" (conflict). diff3 formalizes this. The unavoidability is information-theoretic: when both sides rewrite the same lines, there is no third input that says which is correct — so a human must decide. The Staff+ framing contrasts this with real-time OT/CRDT, which avoid *most* conflicts by tracking *operations* (insert-at-stable-position commutes) rather than diffing *line states* after the fact — git only sees two snapshots and their ancestor, so it can't know the operations that produced them. This is the deep reason git conflicts and Google Docs (mostly) doesn't.
2. **Merge base, criss-cross, recursive → ort.** Computing the LCA is straightforward for linear history but a criss-cross (two prior cross-merges) yields multiple LCAs, and picking one arbitrarily inflates conflicts. The **recursive** strategy merges the candidate bases into a **virtual ancestor** (recursively, if they themselves criss-cross) and uses that as the 3-way base. **ort** keeps the algorithm but re-engineers the implementation: all in memory, no per-step working-tree writes, and **cached merge results** so a rebase (a series of similar merges) reuses prior work — hence the >9000× rebase speedup and 500× rename-heavy speedup. Rename detection is part of correctness, not just speed: without it, "edit on branch A, rename on branch B" loses the edit (treated as add+delete).
3. **Line-based vs semantic merge, and the cost of conflicts.** Line-based merge produces *spurious* conflicts (two edits to adjacent unrelated lines) and *misses* semantic ones (a function renamed on one side, called on the other), and empirically merge conflicts land in ~9–19% of merges with conflicted code ~2× (and ~26× when manual resolution was needed) more likely to carry a bug. **Semantic/AST merge** (Spork/3DM, IntelliMerge) operates on the parse tree to resolve rename/reorder cases and cut spurious conflicts, at the cost of language-specific tooling. The Staff+ judgment: line-based is language-agnostic and good enough mostly; reach for semantic merge where rename+edit and reordering dominate (large refactors). Either way, *name git as the async, snapshot-diffing cousin of the real-time operation-tracking systems in this archetype.*

## Known failure modes
1. **Spurious or missed conflicts from line-based heuristics.** Adjacent unrelated edits conflict; a rename+edit silently drops the edit. Production answer: rename detection (`-X find-renames`), and semantic/AST merge for refactor-heavy codebases.
2. **Criss-cross merge producing inflated conflicts.** Multiple LCAs picked arbitrarily. Production answer: recursive/ort virtual-ancestor construction (merge the bases first), which ort does by default and caches.
3. **Repeated conflict resolution during rebase.** Replaying N commits re-presents similar conflicts at each step. Production answer: `git rerere` (reuse recorded resolutions), or merge (resolve once) when the history-linearity isn't worth the repeated resolution; ort's caching also reduces the cost.

## (Spine note)
`version-control-merge` is the **async, after-the-fact** member of this archetype — it diffs snapshots against a common ancestor, where the real-time members (`google-docs` OT, `collaborative-text-editor`/`yjs` CRDTs) track operations to avoid conflicts. Content-addressing connects to infra-primitives storage; the line-vs-operation contrast is the key cross-reference.

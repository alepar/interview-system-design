---
slug: google-sheets
archetype: conflict-resolution
sources:
  sheets_handbook: systemdesignhandbook.com/guides/google-sheets-system-design/
  sheets_cell_cap: "Google Workspace Updates Blog, Ten million cells in Google Sheets, 2022"
  wave_ot: svn.apache.org/repos/asf/incubator/wave/whitepapers/operational-transform/operational-transform.html
  ot_consistency: arxiv.org/pdf/1302.3292 (On Consistency of Operational Transformation Approach)
  dependency_graph: en.wikipedia.org/wiki/Dependency_graph
---

# Google Sheets (collaborative spreadsheet: OT on a grid + dependency DAG)

## Bar anchors
- **Mid-level (L4/E4):** Treats a sheet as a 2D array with locking per cell. Doesn't address concurrent edits, formula recalculation, or what happens when a row is inserted while someone edits a cell below it.
- **Senior (L5/E5):** Applies OT per cell (the grid partitions the edit space, so disjoint-cell edits commute), maintains a cell dependency graph, recalculates dependents on change. Knows range operations are tricky. May not articulate why range ops are the hard OT case, how the dependency DAG is re-toposorted under concurrency, or formula consistency.
- **Staff+ (L6/E6+):** Drives proactively. Notes the **grid naturally partitions the edit space** (most concurrent edits hit disjoint cells and commute trivially — LWW per (row,col) suffices) but that **range operations (insert/delete row/column) are the hard OT case** because they **shift every downstream cell reference**: `T(SetCell(A1,"=B2+1"), InsertRow(1))` must yield `SetCell(A2,"=B3+1")` — the op's *operands* (cell refs) are rewritten by concurrent structural ops. Maintains a **cell-dependency DAG** re-toposorted on structural change, recalculating only transitively-dirty cells, with **cycle detection** for circular references. Ensures **formula consistency** (no editor sees a formula referencing a not-yet-existent cell mid-transform). Quotes the **10M-cell cap, ~100 concurrent editors**, and that recalc degrades well before the cap (timeouts ~1.2M formula-cells).

## Canonical decomposition

### Requirements
**Functional:**
- Many users concurrently edit cells and formulas in one sheet; everyone converges
- Insert/delete rows and columns; all formula references shift correctly
- Formulas recalculate consistently under concurrent edits (no stale or dangling references)
- Detect and flag circular references rather than loop forever

**Non-functional (with numbers):**
- 10M-cell cap per sheet; ~100 concurrent editors (then throttled/view-only)
- Incremental recalc (full recalc of 10M cells per keystroke infeasible)
- Recalc degrades well before the cap: timeouts ~1.2M formula-cells, sluggish >100k rows
- Convergence via a central OT serializer (linear op history, like Docs)

### Core entities
- **Cell:** (row, col) → value or formula; addressed by reference (A1-style)
- **Op:** `SetCell(ref, value)` | `InsertRow/Col(i)` | `DeleteRow/Col(i)` | range cut/paste
- **DependencyDAG:** edges from a cell to the cells whose formulas reference it
- **RevisionLog:** central linear op history (OT serializer, as in `google-docs`)

### API
- WebSocket `client → server`: `{baseRevision, op}` (SetCell / structural op)
- `server → clients`: transformed op + new revision (broadcast)
- internal: `recalc(dirtySet)` → topological recompute of transitively-dependent cells
- internal: `detectCycle(DAG)` → flag circular references

### HLD
Like Docs, Sheets uses a **central OT serializer** with a linear revision log (so it dodges TP2 — see `google-docs`), but the op set and transforms differ because the document is a **grid + a formula graph**, not a string. **Cell-value edits** are the easy case: the grid partitions the space, so `SetCell(A1)` and `SetCell(B7)` commute trivially, and concurrent edits to the *same* cell resolve LWW by the server's order. The **hard case is range operations**: `InsertRow(i)` / `DeleteRow(i)` (and column variants, and cut/paste over ranges) shift the addresses of every cell at or below `i`, which means the transform must rewrite the *operands* (cell references) of every concurrent op — `T(SetCell(A5,"=B6"), InsertRow(3))` becomes `SetCell(A6,"=B7")`, and a `SetCell` into a row that a concurrent `DeleteRow` removed must resolve to a sensible location or `#REF!`.

Behind the editing layer sits a **cell-dependency DAG** (edges from each cell to the formulas that reference it). On any edit, the engine marks the transitively-dependent cells dirty and **recomputes them in topological order** — never the whole sheet. Structural ops re-toposort the affected subgraph. **Cycle detection** runs alongside the toposort to flag circular references (`=A1` in A1) rather than loop. **Formula consistency** is a read-side guarantee: an editor's formula bar reflects the current committed server state, never a mid-transform intermediate, so no one sees a formula pointing at a cell that doesn't exist yet. Scaling a 10M-cell sheet uses per-sheet process affinity, chunked viewport sync (send only visible cells + a buffer), and incremental recalc; cross-sheet references resolve through a separate dependency layer.

### Deep dives
1. **Range operations: the hard OT case.** Cell-value OT is nearly trivial (grid partitions the space). The difficulty is that `InsertRow`/`DeleteRow` shift the *coordinate system* every other op references, so transforms must rewrite operands, not just positions. Derive `T(SetCell(A5,f), InsertRow(3))` (→ A6, and f's row references +1) and `T(SetCell(A5,f), DeleteRow(5))` (the cell vanished → the set is dropped or its formula becomes `#REF!`). This is exactly where the theory bites: research shows simple insert/delete signatures can satisfy TP1 but not both TP1 and TP2 — which is why Sheets, like Docs, leans on a central serializer so it only transforms against a linear history. The Staff+ signal is recognizing range ops as operand-rewriting, not position-shifting.
2. **The dependency DAG + incremental recalc.** A spreadsheet is a reactive dataflow graph: a change to A1 must recompute every cell transitively depending on A1, in dependency (topological) order, and nothing else. Maintain the DAG incrementally; on a value edit, mark the dependent subgraph dirty and recompute it toposorted; on a structural edit, re-toposort the affected region. Cycle detection (no valid topological order exists) flags circular references instead of infinite-looping. At 10M cells the engine must be incremental and lazy — recalc degrades well before the cell cap (timeouts around ~1.2M formula-cells), so viewport-driven and on-demand recompute matter. This dataflow dimension is what makes Sheets harder than a text doc: convergence of *edits* isn't enough; the *derived* state (formula results) must also be consistent.
3. **Formula consistency under concurrent structural edits.** The subtle correctness requirement: while one user inserts a row and another edits a formula referencing cells around it, no editor should ever observe a formula bound to a cell that doesn't exist or has the wrong address. The OT transforms keep references valid (rewriting operands), and the read path always renders the committed server state — so the worst outcome is a deterministic `#REF!` (cell genuinely deleted), never a torn/dangling formula. Combined with incremental recalc, this gives "everyone converges to the same values *and* the same formulas," which is the spreadsheet-specific bar beyond plain text convergence.

## Known failure modes
1. **Concurrent insert/delete-row composing to a counterintuitive location or `#REF!`.** A `SetCell` targets a row a concurrent `DeleteRow` removes. Production answer: transforms rewrite references to the correct shifted location, and resolve to a deterministic `#REF!` when the target genuinely vanished — never a silent wrong-cell write.
2. **Recalc storm at a high-fan-in cell.** Editing a cell that thousands of formulas reference triggers a massive recompute. Production answer: incremental, lazy, viewport-driven recalc — recompute visible/needed dependents first, defer the rest; the dependency DAG bounds work to the dirty subgraph, never the whole sheet.
3. **Circular reference.** A formula cycle has no valid evaluation order. Production answer: cycle detection during toposort flags it and shows an error, rather than looping infinitely or diverging.

## (Spine note)
`google-sheets` extends `google-docs` (OT) onto a grid + dataflow graph; the CRDT alternative is discussed in `crdt-primitive`/`collaborative-text-editor`.

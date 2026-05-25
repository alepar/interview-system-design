---
slug: incremental-indexing
archetype: search-indexing
sources:
  percolator_paper: usenix.org/legacy/event/osdi10/tech/full_papers/Peng.pdf
  caffeine_blog: developers.google.com/search/blog/2010/06/our-new-search-index-caffeine
  percolator_register: theregister.com/2010/09/24/google_percolator/
  percolator_tikv: tikv.org/deep-dive/distributed-transaction/percolator/
  lucene_segments: blog.mikemccandless.com/2011/02/visualizing-lucenes-segment-merges.html
---

# Incremental Indexing Pipeline (Percolator / Caffeine vs batch reindex)

## Bar anchors
- **Mid-level (L4/E4):** Proposes rebuilding the index periodically from the document corpus (a batch job). Knows fresher is better. Doesn't recognize why batch reindex doesn't scale for freshness or what an incremental alternative looks like unprompted. *(Note: this is a 25-min follow-up problem, not a full solo slot — typically paired with `google-search` or `elasticsearch`.)*
- **Senior (L5/E5):** Recognizes that fully re-running a batch index pipeline to incorporate small updates is wasteful and slow, and proposes incremental updates — appending new documents and merging. Knows Lucene-style segment-based indexing does this. May not articulate Percolator's observer/transaction model, the resource-for-freshness tradeoff, or the snapshot-isolation mechanics.
- **Staff+ (L6/E6+):** Drives proactively. Explains **why batch-MapReduce reindex fails at web scale** (pre-Caffeine: each doc spent **2–3 days** being indexed because the whole index was rebuilt in layered passes). Names **Percolator** (Peng & Dabek, OSDI 2010): **observers** that fire on column-change notifications + **ACID snapshot-isolation transactions** on Bigtable, the engine behind **Caffeine**. Quantifies the result: **median doc >100× faster**, average doc age in results **−50%**, at a cost of **~2× resources** (and ~30× vs MapReduce in raw overhead; ~50 Bigtable ops/doc; transaction latency 2–5s). Names the **Timestamp Oracle** (~2M timestamps/sec) and the **notify-column-in-a-separate-locality-group** trick (scan millions of dirty cells, not trillions of total). Knows the **segment-based alternative** (Lucene immutable segments + tiered merge) is simpler and sufficient when you don't need cross-row transactions.

## Canonical decomposition

### Requirements
**Functional:**
- Incorporate document updates into a huge index without rebuilding the whole thing
- Maintain consistency when one update triggers dependent recomputation (e.g. link graph)
- Bound the latency from "document changed" to "change reflected in the index"
- Recover correctly from worker failures mid-update (idempotent, no lost/duplicated work)

**Non-functional (with numbers):**
- Pre-Caffeine batch: doc age 2–3 days; Caffeine: median doc >100× faster, age −50%
- Resource cost: ~2× the batch system for the same crawl rate (Percolator ~30× raw overhead)
- ~50 Bigtable ops per processed document
- Transaction latency 2–5s typical, minutes in outliers
- Timestamp Oracle ~2M timestamps/sec from one machine

### Core entities
- **Document cell:** a row in a Bigtable-class repository; columns hold content, derived data, locks
- **Observer:** code that fires when a watched column changes (the unit of incremental work)
- **Transaction:** snapshot-isolation, 2PC with a primary lock + secondary locks
- **Notify column:** a separate locality group marking dirty cells (cheap to scan for work)
- **Segment (alternative):** immutable Lucene file set; updates = new segments + background merge

### API
- Internal: `txn.get/set(row, col)` under snapshot isolation (read at start ts, commit at commit ts)
- Internal: `observer.on_change(col)` → fires downstream incremental computation
- Internal: scan the notify column → find dirty cells → run observers → commit
- (Segment-based alt: `index.add(doc)` → buffer → flush new segment → background merge)

### HLD
**The problem.** A web-scale index can't be rebuilt from scratch to absorb each update — pre-Caffeine, Google rebuilt the index in layered batch passes over the whole web, so a freshly-crawled page waited ~2–3 days (and the main layer refreshed ~every two weeks). Freshness is a correctness property for news, so batch reindex is structurally inadequate.

**Percolator / Caffeine.** Percolator turns indexing into **incremental processing on Bigtable**. Documents and their derived data live as cells in a Bigtable-class store. **Observers** are registered on columns: when a column changes (e.g. a page's content), the observer fires and recomputes just the affected derived data (postings, link contributions), which may write other columns and trigger further observers — a dependency chain that is the indexing pipeline expressed incrementally. To keep this consistent under concurrency, Percolator adds **ACID multi-row transactions with snapshot isolation** to Bigtable via **two-phase commit**: a transaction reads at a start timestamp and commits at a commit timestamp from a centralized **Timestamp Oracle** (~2M ts/sec); one lock is the **primary** and secondaries point to it, so commit/cleanup is atomic even if a worker dies. Finding work cheaply matters: the **notify column** lives in a *separate locality group*, so a worker scanning for dirty cells reads millions of dirty cells, not the trillions of total cells. Result: median doc moves >100× faster, average doc age in results drops ~50% — bought with ~2× the resources (random-access incremental work is inherently costlier than sequential MapReduce scans).

**The simpler alternative.** Most systems don't need cross-row transactions and use **segment-based incremental indexing** (Lucene/Elasticsearch): buffer new docs in memory, flush them as **immutable segments**, and **background-merge** small segments into larger ones in a logarithmic staircase; updates/deletes are new segments / tombstones reclaimed at merge. This gives incremental freshness without a transactional repository — the right default unless you have Percolator's specific need (consistent incremental computation over a mutable web-scale graph).

### Deep dives
1. **Observer + snapshot-isolation transactions** — Observers make the pipeline reactive: a content change fires an observer that recomputes derived data and may write columns that fire further observers, so updates ripple through the dependency graph incrementally instead of via a global recompute. Snapshot-isolation transactions make that safe under concurrency: each transaction reads a consistent snapshot at its start timestamp and commits atomically at its commit timestamp via 2PC. The **primary-lock** pattern is what makes the 2PC recoverable — the outcome of a transaction is decided solely by whether the primary lock was converted to a write record, so a worker that dies mid-commit leaves enough state for another worker to roll forward or clean up deterministically. This is the mechanism that lets thousands of workers incrementally mutate a shared web-scale index without corrupting it.
2. **The resource-for-freshness tradeoff** — Percolator is *not* free: it incurs ~30× the raw resource overhead of MapReduce per unit work (and Caffeine ~2× the previous system for the same crawl rate), because random reads/writes and per-cell locking are far costlier than MapReduce's big sequential scans. The trade is deliberate: you spend ~2× resources to get >100× freshness and ~50% lower doc age — worth it for a search index where freshness is revenue/quality, not worth it for an offline analytics job. The Staff+ point is naming this explicitly: incremental processing buys latency with throughput-efficiency, so you choose it only where freshness has real value, and you keep batch for the rest (Caffeine still does heavy offline computation like PageRank in batch).
3. **Segment-based incremental as the pragmatic default** — Outside Google-scale link-graph indexing, the dominant pattern is Lucene-style segments: immutable, append-only segment files plus a background **tiered merge** that consolidates small segments and reclaims deleted-doc space. This achieves incremental freshness (new docs searchable after a flush/refresh) without any transactional repository, at the cost of write amplification from merges and eventual-consistency-style visibility (a doc is searchable after refresh, durable after flush). The interview discipline: reach for Percolator-style transactional incremental processing only when you genuinely need consistent incremental computation over a mutable graph; for "make my index fresher," segment-based incremental + a good merge policy is simpler and sufficient.

## Known failure modes
1. **Observer livelock on a hot cell** — A frequently-changing cell triggers its observer repeatedly, and contending transactions abort and retry, making no progress (livelock). Mitigation: exponential backoff with jitter on transaction conflict, batching notifications so a burst of changes fires one observer run, and conflict-rate metrics to detect hot cells and shard or rate-limit them.
2. **Notification storm on a schema/global change** — A change touching many documents (a schema migration, a global re-scoring) marks a huge fraction of cells dirty at once, flooding observer dispatch and saturating the cluster. Mitigation: rate-limit observer dispatch, batch notifications, and stage large changes as controlled rollouts rather than a single global mark-dirty — treat a global recompute as a planned batch job, not an incremental storm.
3. **Lock-cleanup race on worker death or tablet split** — A worker dies mid-transaction, or a Bigtable tablet splits, leaving locks whose owner is gone; another worker must decide whether the transaction committed. Mitigation: the primary-lock pattern makes the outcome unambiguous (only the primary lock's state decides commit vs abort), and lazy lock cleanup lets a later transaction safely roll forward or roll back the dead one based on the primary — so no transaction is left in an undecidable state.

## (Scope note)
This is a ~25-min deep-dive / follow-up problem (best paired with `google-search` or `elasticsearch`), not a full 50-min solo slot.

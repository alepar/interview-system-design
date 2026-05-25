---
slug: shopping-cart-crdt
archetype: conflict-resolution
sources:
  dynamo_paper: allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
  vogels_dynamo: allthingsdistributed.com/2007/10/amazons_dynamo.html
  mit_6824_dynamo: css.csail.mit.edu/6.824/2014/notes/l17-dynamo.txt
  weidner_orset: mattweidner.com/2023/09/26/crdt-survey-2.html
  shapiro_crdt: lip6.fr/Marc.Shapiro/papers/2011/CRDTs_SSS-2011.pdf
---

# Shopping Cart CRDT (Dynamo cart, resurrection anomaly, OR-Set fix)

## Bar anchors
- **Mid-level (L4/E4):** Stores the cart in a strongly-consistent DB and locks on write. Doesn't address availability under partition or what happens when two devices edit the cart concurrently.
- **Senior (L5/E5):** Knows Dynamo-style stores prefer availability ("always writeable"), use vector clocks to detect concurrent versions, and return siblings for the app to merge. Knows the cart merges by union. May not name the deleted-item resurrection anomaly or its principled fix, and may try to re-derive the storage engine.
- **Staff+ (L6/E6+):** Drives proactively. States the design goal — **"add to cart" must never be rejected, even under partition** (a lost add is lost revenue; a ghost item is a minor annoyance) — and the mechanism: vector clocks identify concurrent writes, the store returns **siblings** to the application, which **merges**. Names the **classic anomaly**: the published **union-merge resurrects deleted items** (set-union over concurrent {add, remove} keeps the removed item). Fixes it **principally with an OR-Set add-wins** (each add tags the item with a unique UUID; remove takes only the *observed* tags; a concurrent add carries a fresh unseen tag and survives) — and uses a **PN-Counter** for quantities. **Explicitly delineates**: vector clocks, sloppy quorum (N=3/R=2/W=2), hinted handoff, and read repair are the **storage layer** (infra-primitives `dynamodb`) — *referenced, not re-derived*; the focus here is **application-level merge semantics**. Quotes the 99.9th-percentile SLA framing.

## Canonical decomposition

### Requirements
**Functional:**
- Add/remove items to a cart; the cart is highly available, including under network partition
- Concurrent edits from multiple devices/replicas reconcile without losing adds
- A removed item stays removed (no resurrection) even under concurrency
- Track per-item quantity correctly under concurrent increments

**Non-functional (with numbers):**
- "Always writeable" — never reject an add (availability over consistency)
- Dynamo SLAs measured at the 99.9th percentile (e.g. 300ms @ 500 req/s)
- N=3, R=2, W=2 default quorum (storage layer — referenced)
- Convergence with no lost adds; bounded sibling/metadata growth

### Core entities
- **Cart:** an OR-Set of items (+ a PN-Counter per item for quantity)
- **Item add:** `(item_id, unique_tag=(replica,counter))`
- **Tombstone set:** the tags observed-and-removed
- **Sibling:** a concurrent version returned by the store on read (vector-clock-incomparable)

### API
- `add(item)` → mint a unique tag; record `(item, tag)`
- `remove(item)` → move all *currently observed* tags of `item` to the tombstone set
- `get() → siblings` (storage returns concurrent versions) → `merge(siblings)` (application)
- `merge(a,b)` → union of `(item,tag)` minus tombstoned tags; PN-Counter merge for quantities

### HLD
The cart sits on a Dynamo-class store configured for **availability**: writes go to whatever replicas are reachable (sloppy quorum; hinted handoff stores a write for an unreachable owner and replays it later), so **an add-to-cart always succeeds** even during a partition. The store uses **vector clocks** to track causality; when it can't tell which of two versions is newer (concurrent writes during a partition), it returns **both as siblings** to the application on the next read, and the application **merges** them and writes back the reconciled value (read repair pushes the merged value to stale replicas). *All of that — vector clocks, sloppy quorum, hinted handoff, read repair, N/R/W — is the storage layer and is owned by `dynamodb`; here we take it as given and focus on the merge.*

The naive application merge is **set-union of the two carts**, and that's the famous bug: if one branch removed an item and the other didn't, the union **resurrects** the removed item (the remove is silently dropped). Amazon explicitly accepted this tradeoff in 2007 (a ghost item beats a lost sale), but the **principled fix is an OR-Set**. Each `add(item)` stamps the item with a **unique tag** `(replica, counter)`; the cart contains an item iff it has a tag that is present and not tombstoned; `remove(item)` moves only the tags the remover has **observed** into the tombstone set. Now a concurrent `add` carries a **fresh tag the remove never saw**, so the item correctly survives that branch and is absent in the branch that only removed — **add-wins, no resurrection, re-add supported**. Per-item **quantity** uses a **PN-Counter** (not LWW, which would lose concurrent increments). Tombstone tags are GC'd under causal stability (or bounded like Dynamo's vector-clock truncation at ~10 entries).

### Deep dives
1. **The resurrection anomaly and why union-merge causes it.** Walk it concretely: cart {A,B}; partition; device 1 removes B → {A}; device 2 adds C → {A,B,C}; merge by union → {A,B,C} — **B is back from the dead** because union has no way to know B was deliberately removed (the remove left no trace the union respects). This is the canonical Dynamo cart anomaly (Vogels: "an add-to-cart operation is never lost; however, deleted items can resurface"). The Staff+ move is to *name it as the cost of LWW/union merge over a set*, then reach for the data type that fixes it rather than hand-waving.
2. **OR-Set add-wins as the principled fix.** Tag every add with a unique id; define presence as "has a non-tombstoned tag"; remove tombstones only *observed* tags. Now {remove B} tombstones B's known tag, but a concurrent {add B} (or the surviving item) carries a tag the remove never saw → B's status resolves to *present* iff any live tag exists. Re-add works (new tag), and a deliberate remove that has observed all current tags wins over no concurrent add. This is the OR-Set from `crdt-primitive` applied to a real product problem — the bridge that makes the abstract data type concrete. Note the dual (remove-wins) exists; carts want add-wins (don't lose the customer's add).
3. **Delineation from the storage engine + quantity semantics.** Be explicit about the layer boundary: the candidate should *say* "vector clocks, sloppy quorum, hinted handoff, read repair, and N/R/W tuning are the storage engine — I'll use Dynamo/`dynamodb` for that — and design the *merge* on top." This avoids re-deriving a KV store and keeps the round focused on conflict semantics. Then handle **quantity**: "2 of item X" edited concurrently to 3 and to 5 must not LWW to one value — use a **PN-Counter** so concurrent increments sum correctly. The combination (OR-Set membership + PN-Counter quantity) is the correct cart CRDT.

## Known failure modes
1. **Deleted-item resurrection** under union/LWW merge. Production answer: OR-Set add-wins (unique add tags + observed-remove tombstones); never plain set-union over concurrent versions.
2. **Lost concurrent quantity increments.** LWW on quantity discards one of two concurrent "+1"s. Production answer: PN-Counter per item so increments commute and sum.
3. **Unbounded sibling / tag growth.** Repeated unresolved concurrent writes accumulate siblings and tags. Production answer: causal-stability GC of tombstones, dotted version vectors / clock truncation (Dynamo caps at ~10 entries, accepting rare spurious merges) — a storage-layer concern referenced here, not re-derived.

## (Delineation / spine note)
`shopping-cart-crdt` is the **application-level** conflict-resolution problem: OR-Set membership + PN-Counter quantity + merge-on-read. The **storage engine** (vector clocks, sloppy quorum, hinted handoff, read repair) is infra-primitives `dynamodb` — reference it, don't rebuild it. The OR-Set/PN-Counter theory is `crdt-primitive`.

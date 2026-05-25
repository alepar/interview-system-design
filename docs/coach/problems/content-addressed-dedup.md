---
slug: content-addressed-dedup
archetype: ugc-pipeline
sources:
  lbfs: pdos.csail.mit.edu/papers/lbfs:sosp01/lbfs.pdf
  datadomain: usenix.org/legacyurl/avoiding-disk-bottleneck-data-domain-deduplication-file-system
  sparse_indexing: usenix.org/legacy/events/fast09/tech/full_papers/lillibridge/lillibridge_html/index.html
  fastcdc: usenix.org/system/files/conference/atc16/atc16-paper-xia.pdf
  dropbox_content_hash: dropbox.com/developers/reference/content-hash
---

# Content-Addressed Dedup (chunking + fingerprint dedup)

## Bar anchors
- **Mid-level (L4/E4):** Hashes whole files and skips duplicates. Doesn't address chunking, the boundary-shift problem, the fingerprint index, or global vs local dedup.
- **Senior (L5/E5):** Chunks files, hashes each chunk (content-addressed), stores each unique chunk once; knows fixed vs variable chunking and Merkle trees for integrity. May not articulate content-defined chunking precisely, the fingerprint-index disk bottleneck, sparse indexing, or the dedup-ratio/locality tradeoffs.
- **Staff+ (L6/E6+):** Drives proactively. Contrasts **fixed-block** chunking (simple, but a 1-byte insert shifts all downstream boundaries → near-zero dedup on edited files — the **boundary-shift problem**) with **content-defined chunking (CDC)** via a **rolling hash** (Rabin/Buzhash: cut a boundary where the low k bits of the rolling fingerprint match a value, so a single-byte change affects only the surrounding chunk; LBFS: 48-byte window, low-13-bits ⇒ ~8KB expected chunk). Stores each unique chunk **content-addressed** (chunk = hash; SHA-256, collision negligible at 160-bit+) once — **global dedup** across all data beats per-user. Names the **fingerprint-index disk bottleneck** (800TB@8KB ⇒ ~100B chunks ⇒ ~2TB of fingerprints — can't fit in RAM; each chunk lookup risks a disk seek) and the fixes (**sparse indexing** — sample hashes + exploit stream locality; Data Domain's locality-preserving cache). Knows **Merkle trees** for integrity + efficient diff (Git/IPFS), **FastCDC** (~10× faster than Rabin CDC), the **chunk-size tradeoff** (smaller = more dedup but bigger index + fragmentation), and the **read-amplification/restore-fragmentation** cost of dedup. References Dropbox's hash-of-hashes content hash.

## Canonical decomposition

### Requirements
**Functional:**
- Split data into chunks; store each unique chunk once (dedup across files/users/versions)
- Survive edits/insertions without losing dedup (CDC, not fixed blocks)
- Verify integrity and compute diffs efficiently (Merkle)

**Non-functional (with numbers):**
- CDC expected chunk ~8KB (LBFS); SHA-256 chunk fingerprints
- Fingerprint index: ~2TB for 800TB@8KB (~100B chunks) — exceeds RAM → disk bottleneck
- Dedup ratios 10–50× on backup workloads; global > per-user
- Chunk-size tradeoff: smaller chunk = more dedup, bigger index, more fragmentation

### Core entities
- **Chunk:** a variable-size piece of data (CDC), content-addressed by its hash
- **Fingerprint index:** hash → chunk location (the scaling bottleneck)
- **Merkle tree:** hash-of-hashes over chunks for integrity + diff
- **Recipe/manifest:** the ordered list of chunk hashes that reconstitutes a file

### API
- `chunk(data) → [chunks]` (CDC via rolling hash)
- `store(chunk)`: hash → if hash unseen, store; else skip (dedup); record hash in the recipe
- `reconstruct(recipe) → data` (fetch chunks by hash in order)
- `diff(treeA, treeB)`: compare Merkle roots → descend only differing subtrees

### HLD
Data is split into **chunks**, each identified by its **content hash** (content-addressed storage: the address *is* the hash), and each unique chunk is stored exactly **once** — so duplicate data (across files, versions, or users) collapses to shared chunks. The critical choice is **how to chunk**. **Fixed-size** blocks are trivial but suffer the **boundary-shift problem**: inserting one byte near the start shifts every subsequent block's contents, changing all their hashes, so an edited file dedups almost nothing. **Content-defined chunking (CDC)** fixes this with a **rolling hash** (Rabin fingerprint over a sliding window, or Buzhash/Gear): a chunk boundary is declared wherever the low *k* bits of the rolling fingerprint hit a magic value (LBFS: a 48-byte window, low 13 bits ⇒ expected 2^13 = 8KB chunks), so a single-byte edit only re-chunks the **surrounding** region — dedup survives edits/insertions. Each chunk's hash is SHA-256-class (collision negligible at 160-bit+), so dedup decisions are made purely by hash. **Global dedup** (across all data) yields far higher savings than per-user, and backup workloads see **10–50× dedup**.

The scaling wall is the **fingerprint index** (hash → location): 800TB of unique data at 8KB chunks is ~100 billion chunks ⇒ ~2TB of fingerprints, which can't fit in RAM — so every incoming chunk's lookup risks a **disk seek** (the chunk-lookup disk bottleneck). The fixes exploit **locality**: **sparse indexing** (Lillibridge) samples only a fraction of chunk hashes into an in-RAM index and dedups each segment against its few most-similar prior segments; Data Domain keeps a locality-preserving cache so streams that recur hit RAM. **Merkle trees** (hash-of-hashes from chunk leaves to a root) give integrity verification and **efficient diff** — compare roots, descend only differing subtrees — used by Git, IPFS, and Dropbox's hash-of-hashes content hash. **FastCDC** speeds CDC ~10× over classic Rabin. The unavoidable tension is the **chunk-size tradeoff** (smaller chunks find more duplicates but blow up the index and fragment data → slower restores from read amplification).

### Deep dives
1. **CDC vs fixed-block (the boundary-shift problem).** Fixed blocks dedup well only for *unchanged* files; one inserted byte shifts every later block, destroying dedup — so fixed chunking is barely better than whole-file dedup for edited data. CDC sets boundaries **by content**, not position: a rolling hash over a sliding window cuts a chunk wherever the fingerprint's low bits match a target (expected chunk size = 2^bits), so an edit only disturbs the chunk(s) around it and the rest still dedup. This is the single most important idea in the problem — it's why backup/sync systems (Dropbox uses fixed 4MB blocks for simplicity; restic/borg/Data Domain use CDC) get high dedup on real, edited data. FastCDC (Gear-hash, cut-point skipping, normalization) makes CDC ~10× faster than Rabin at the same ratio. The Staff+ point: dedup quality on *changing* data depends entirely on content-defined boundaries.
2. **The fingerprint-index disk bottleneck + locality fixes.** Dedup needs a hash→location index, and at scale it's too big for RAM (800TB@8KB ⇒ ~2TB of fingerprints), so naive per-chunk lookups thrash the disk — the documented "chunk-lookup disk bottleneck" that caps inline dedup throughput. The fixes all exploit **backup-stream locality** (the same data recurs in the same order): **sparse indexing** keeps only sampled hashes in RAM and dedups a segment against its most-similar few prior segments; **Data Domain** uses a locality-preserving cache + Bloom filter to avoid disk lookups for new chunks. This is the scaling crux — recognizing that dedup is bottlenecked by the *index*, not the storage, and that locality (not a bigger index) is the lever, is the depth signal.
3. **Merkle trees, chunk-size tradeoff, and the restore cost.** **Merkle trees** make content-addressed storage powerful: hashing chunks up to a root gives O(1) integrity checks and **efficient diff/sync** (compare roots; descend only where they differ — Git, IPFS, rsync-style sync) and cheap equality (compare hashes, not bytes). The **chunk-size tradeoff** is fundamental: smaller chunks find more duplicates (better ratio) but multiply the fingerprint index, slow dedup, and **fragment** logically-sequential data across the store — which causes **read amplification** on restore (reconstructing a file gathers scattered chunks via many seeks). So dedup trades write-time storage savings for read-time restore cost. The Staff+ framing: pick chunk size to balance dedup ratio against index size and restore performance, and accept that aggressive dedup makes restores slower (locality-aware layout / caching mitigates it).

## Known failure modes
1. **Near-zero dedup on edited files (fixed blocks).** Insertions shift fixed-block boundaries, destroying dedup. Production answer: content-defined chunking (rolling hash) so edits only re-chunk locally; FastCDC for speed.
2. **Fingerprint-index can't fit in RAM (disk-seek thrash).** Per-chunk lookups bottleneck on disk at scale. Production answer: sparse indexing + locality-preserving cache + Bloom filter to skip disk lookups for new chunks; exploit stream locality.
3. **Slow restores / read amplification.** Heavy dedup fragments data so reconstruction gathers scattered chunks. Production answer: tune chunk size, locality-aware container layout, caching; accept the storage-savings-vs-restore-speed tradeoff and size it to the workload (backup tolerates slower restore).

## (Delineation note)
`content-addressed-dedup` is the **dedup primitive** underlying `dropbox`, `google-photos`, and `backup-incremental`. The object store that holds chunks is infra-primitives `s3`/`colossus`; Git's content-addressing is the version-control archetype. Here it's CDC + content-addressing + the fingerprint-index bottleneck + Merkle diff.

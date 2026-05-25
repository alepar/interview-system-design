---
slug: backup-incremental
archetype: ugc-pipeline
sources:
  rsync: en.wikipedia.org/wiki/Rsync
  restic_refs: restic.readthedocs.io/en/stable/100_references.html
  incremental_forever: unitrends.com/blog/truth-lies-and-bcdr-incremental-forever/
  dedup_ratios: techtarget.com/searchdatabackup/tip/Understanding-data-deduplication-ratios-in-backup-systems
  merkle: oxen.ai/blog/merkle-tree-101
---

# Incremental Backup (incremental-forever + dedup)

## Bar anchors
- **Mid-level (L4/E4):** Copies all files on a schedule. Doesn't address incremental backups, dedup, the rsync delta, or restore from increments.
- **Senior (L5/E5):** Full + incremental backups (only changed files), dedup duplicates, versioned snapshots, retention. Knows the rsync rolling-checksum idea. May not articulate incremental-forever + synthetic full, content-defined chunking for dedup, the two-checksum rsync algorithm, or RPO/restore tradeoffs.
- **Staff+ (L6/E6+):** Drives proactively. Uses **incremental-forever** (one initial full, then only changes — small, fast, low bandwidth) plus **synthetic full** (merge full+incrementals on the *target* without re-reading the source, to keep restores fast). Dedups via **content-defined chunking** (restic: 64-byte window, 512KiB–8MiB blobs, ~1MiB avg, random polynomial to resist watermark attacks; borg: Buzhash) for **10–50× backup dedup**. Explains the **rsync delta algorithm** (two checksums per block: a fast **rolling weak checksum** (Adler-32) to find candidate matches as the window slides + a **strong hash** (MD5/SHA) to confirm — only non-matching blocks transferred; adaptive block size ≈ sqrt(file size)). Uses **Merkle trees** / content-addressing for versioned snapshots + cheap diff + integrity. Sizes **RPO** by backup frequency (incrementals are small enough to run hourly/sub-hourly) and reasons about **restore (RTO)** — long incremental chains slow restore, which synthetic fulls fix. Handles retention/GC of unreferenced chunks.

## Canonical decomposition

### Requirements
**Functional:**
- Back up data efficiently (only changes after the first full); dedup across backups
- Restore to any retained point-in-time; keep versioned snapshots
- Bound RPO (how much data loss) and RTO (how fast to restore)

**Non-functional (with numbers):**
- Incremental-forever: full once, then deltas; synthetic full for fast restore
- Dedup 10–50× (CDC); restic blobs 512KiB–8MiB (~1MiB avg)
- rsync: Adler-32 rolling + MD5/SHA strong; block ≈ sqrt(file size)
- RPO via frequency (hourly/sub-hourly increments); RTO via synthetic full

### Core entities
- **Snapshot:** a point-in-time version (a Merkle tree / list of chunk references)
- **Chunk:** CDC-chunked, content-addressed, deduped across snapshots
- **Increment:** the changed chunks since the last backup
- **Synthetic full:** a merged full restore point built on the target from full+increments

### API
- `backup()`: CDC-chunk changed data → store unseen chunks (dedup) → write a snapshot (chunk refs)
- `rsync delta`: weak rolling checksum scan → strong-hash confirm → send only non-matching blocks
- `restore(snapshot)`: gather the snapshot's chunks by hash → reconstruct
- `prune(retention)`: GC chunks no longer referenced by any retained snapshot

### HLD
The strategy is **incremental-forever**: take one initial **full** backup, then forever after capture **only the changes** since the last successful backup — each increment is small and fast (low bandwidth, short backup window), and there's no periodic re-full. To keep **restores** fast (a naive incremental-forever restore must replay a long chain), the target periodically builds a **synthetic full** — merging the last full + subsequent increments **on the backup target**, without re-reading the source — producing a fresh full restore point that improves RTO while preserving frequent small increments. **Dedup** is layered in via **content-defined chunking** (restic: 64-byte rolling window, blobs 512KiB–8MiB averaging ~1MiB, a per-repo random polynomial to defeat chunk-size fingerprinting; borg: Buzhash), so identical data across snapshots/files is stored once — backup workloads dedup **10–50×** because of copy-data redundancy.

For *transfer* efficiency (and for file-level sync), the **rsync algorithm** finds the minimal delta between a new file and its prior version using **two checksums per fixed-size block**: a fast **rolling weak checksum** (Adler-32, 4 bytes) computed incrementally as the window slides to find *candidate* block matches, then a **strong checksum** (MD5/SHA, e.g. 16 bytes) to *confirm* and avoid false positives — only blocks that don't match are sent (block size adapts to ≈ sqrt(file size), capped). Snapshots are organized as **Merkle trees / content-addressed** structures (each snapshot is a tree of chunk hashes), which gives integrity verification, cheap **diff** between versions (compare hashes), and natural dedup. **Retention** prunes old snapshots and **GCs chunks** no longer referenced by any retained snapshot. **RPO** is set by backup frequency (increments are cheap enough to run hourly or sub-hourly), and **RTO** by restore speed (synthetic fulls and locality-aware chunk layout keep it bounded).

### Deep dives
1. **Incremental-forever + synthetic full (the RPO/RTO balance).** Incremental-forever minimizes the backup window and bandwidth (only changes after the first full) and lowers **RPO** (cheap increments can run frequently). But the cost is **restore (RTO)**: reconstructing the latest state from a full + a long chain of increments is slow and fragile (one corrupt increment breaks the chain). The fix is **synthetic full** — periodically merge full+increments *on the target* (no source re-read) into a fresh full restore point, so restore is from a recent full + few increments. This is the canonical backup tradeoff: increments optimize the write/RPO side, synthetic fulls optimize the read/RTO side. The Staff+ point: name both axes (RPO via frequency, RTO via synthetic full) and the chain-length risk.
2. **Dedup via CDC across backups.** Backups are extremely redundant (the same files, mostly unchanged, captured repeatedly — "copy data" can be 10–20× the unique data), so **content-defined chunking** dedup is the big storage win (10–50×). CDC (not fixed blocks) is essential because files change between backups and fixed-block dedup would miss shifted data (the `content-addressed-dedup` boundary-shift problem). restic/borg's parameters (CDC window, ~1MiB avg blobs, random polynomial against watermark attacks) and the fingerprint-index/locality concerns carry over directly. The interplay with incremental-forever is the insight: incrementals reduce *what you scan/transfer*, dedup reduces *what you store* — together they make "keep many frequent versions" affordable. Reference `content-addressed-dedup` for the chunking/index depth.
3. **The rsync two-checksum delta + Merkle snapshots.** rsync's delta is a beautiful mechanism: to send only the *differences* between a new file and a reference, the receiver sends block checksums; the sender slides a window byte-by-byte computing a **fast rolling weak checksum** (Adler-32) to cheaply find candidate matches, confirming each with a **strong hash** (MD5/SHA) to avoid collisions — transmitting only the non-matching regions. The rolling checksum is what makes scanning every offset affordable (incremental update as the window slides). For *versioning*, snapshots are **Merkle/content-addressed** trees: each snapshot references chunks by hash, so unchanged subtrees are shared (dedup) and diffing two snapshots is comparing hashes (Git's model). Together: rsync minimizes transfer, Merkle/CDC minimizes storage and enables cheap version diff + integrity. The framing: backup = (incremental capture: rsync/CDC) + (dedup storage: content-addressed Merkle) + (fast restore: synthetic full) + (retention GC).

## Known failure modes
1. **Slow/fragile restore from a long increment chain.** Incremental-forever restores replay many increments; one corrupt link breaks the chain. Production answer: periodic synthetic fulls (recent restore point), integrity verification (Merkle hashes), redundancy of critical chunks.
2. **Storage blowup without dedup.** Keeping many frequent versions naively explodes storage. Production answer: content-defined chunking dedup (10–50×) across snapshots; retention policy + GC of unreferenced chunks.
3. **Backup window too long / RPO too high.** Full backups can't run frequently; data-loss window grows. Production answer: incremental-forever (only changes — small/fast, run hourly/sub-hourly for low RPO); rsync delta to minimize transfer; synthetic full to keep RTO bounded.

## (Delineation note)
`backup-incremental` is the **incremental + dedup backup** UGC-adjacent pipeline. The chunking/dedup primitive is `content-addressed-dedup`; file sync is `dropbox`; the object store is infra-primitives `s3`/`colossus`. Here it's incremental-forever + synthetic full + rsync delta + Merkle/CDC dedup + retention.

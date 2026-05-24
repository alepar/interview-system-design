---
slug: colossus
archetype: infra-primitives
sources:
  colossus_peek: cloud.google.com/blog/products/storage-data-transfer/a-peek-behind-colossus-googles-file-system
  colossus_placement: cloud.google.com/blog/products/storage-data-transfer/how-colossus-optimizes-data-placement-for-performance
  gfs_paper: static.googleusercontent.com/media/research.google.com/en//archive/gfs-sosp2003.pdf
  hdfs_arch: hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsDesign.html
---

# Google Colossus / GFS / HDFS / Meta Tectonic (distributed filesystem)

## Bar anchors
- **Mid-level (L4/E4):** Knows HDFS at category level (NameNode + DataNodes; chunks replicated 3 ways). Doesn't address distributed metadata, append-only semantics, erasure coding, or tiered storage unprompted.
- **Senior (L5/E5):** Articulates GFS-class architecture: single master holds metadata, chunkservers hold chunks; 64 MB chunks (GFS); 3-way replication default. Discusses leases for primary chunkserver coordination on writes. Knows about append-only programming model. May not address Colossus's distributed-metadata scaling jump or per-file erasure coding.
- **Staff+ (L6/E6+):** Drives proactively. Cites the **GFS → Colossus scaling jump**: GFS's single-master NameNode was the RAM-bound bottleneck capping cluster size at hundreds of PBs and tens of millions of files; Colossus distributed metadata to **Curators** backed by **Bigtable**, achieving a published **100× scale increase over the largest GFS cluster**. Quantifies Colossus: "multi-exabyte filesystems (two specific filesystems exceed 10 EB each); one Colossus filesystem per cluster" — and 1 MB default chunks (down from GFS's 64 MB). Articulates the **append-only programming model**: GFS supports concurrent append via **record-append semantics** (each append is atomic at the chunkserver, returning an offset; readers may see records in any order but each record is atomic). This simplifies recovery dramatically — no in-place mutation means no torn writes; recovery is "find the last consistent state per chunk and discard partial appends past it." Names the **L4 SSD cache as a control-plane decision**: Colossus's L4 advises Curators on file placement based on observed access patterns (ML-driven, the published "CacheSack" pattern); hybrid placement (1 SSD replica + EC-on-HDD for cost-tuned hot files). Discusses **per-file erasure coding**: Colossus lets each file specify its EC scheme — small / latency-sensitive files use replication (3×); large / cold files use Reed-Solomon (e.g., 17+13) for ~1.76× cost vs 3×. Quantifies **Colossus on Hyperdisk ML**: 2500 nodes reading at 1.2 TB/sec. Stretch (Sr Staff bar): contrasts with **Meta Tectonic** (distributed metadata via per-tenant shards; serves blob storage + warm storage + chunk store in one fabric); names the **small-file problem** as a persistent failure mode (when most files are << chunk size, metadata service pressure dominates).

## Canonical decomposition

### Requirements
**Functional:**
- Append-only file system: open, append (atomic for records), close, read
- Per-file configurable replication scheme (replication or erasure coding per-file)
- Scalable distributed metadata (no single-master RAM ceiling)
- Tiered storage: SSD hot tier + HDD bulk tier + tape/cold for archive
- Multiple tenant workloads: search index, video, ML checkpoints — each with different access patterns
- Cross-cluster (cross-zone) data movement with locality-aware clients

**Non-functional (with numbers):**
- Multi-exabyte per filesystem (Colossus published: filesystems >10 EB each)
- 100× scale over GFS (Colossus distributed metadata vs GFS single master)
- 1 MB default chunks (Colossus; down from GFS's 64 MB)
- 3-way replication default for hot files; (17, 30) Reed-Solomon ~1.76× cost for cold
- Read throughput: 1.2 TB/sec at 2500 nodes (Hyperdisk ML benchmark)
- HDFS comparable: 500+ PB per cluster (LinkedIn published)
- Append latency: ms-class for record-append; recovery latency seconds for chunk re-replication

### Core entities
- **Cluster / Filesystem:** the unit; one Colossus filesystem per cluster
- **Curator:** distributed metadata service node; holds metadata in Bigtable; partitioned namespace
- **Chunkserver / Storage server:** holds chunks (1 MB Colossus default); 3-way replicated or EC-coded
- **L4 cache:** SSD tier in front of HDD chunkservers; ML-advised placement
- **File:** identified by path; metadata = (chunk list, EC scheme, owner, ACL, modification time)
- **Chunk:** unit of storage; identified by chunk_id; replicas distributed across racks/zones
- **Lease:** held by primary chunkserver for ordering concurrent writes (GFS pattern)

### API
- `open(path, mode=read|append) → file_handle` — append-only, no random-write
- `append(file_handle, data) → offset` — atomic record-append; returns the offset where the record was placed
- `read(file_handle, offset, length) → data`
- `close(file_handle)` — finalizes; further writes via re-open in append mode
- `delete(path)` — async garbage collection (chunks may persist briefly)
- Metadata: `stat(path)` → file metadata; `list(directory)` → child entries

### HLD
**Metadata plane**: a **distributed Curator service** holds the file → chunks mapping; metadata stored in **Bigtable** (which itself is built on Colossus — a beautiful bootstrap circularity). Each Curator owns a partition of the namespace; partitioning by file path (or hash) spreads load. Clients consult Curators to resolve file → chunks → chunkservers; Curators are stateless (state in Bigtable) so failures cause failover without data loss. This is the **scaling jump from GFS**: GFS's single NameNode held all metadata in RAM, capping cluster scale at the master's memory; Colossus's distributed metadata removes that ceiling, enabling exabyte filesystems with tens of billions of files.

**Data plane**: chunks live on chunkservers; default chunk size **1 MB** (Colossus; down from GFS's 64 MB) — smaller chunks enable low-latency workloads (YouTube, Gmail, Search) at the cost of higher metadata overhead. Each chunk is replicated 3× (default) or erasure-coded (per-file configurable, e.g., RS(17,30) for ~1.76× storage cost at comparable durability). Placement: chunks spread across racks/zones for fault-tolerance; the **L4 SSD cache** sits in front of HDD chunkservers with ML-driven placement decisions (CacheSack pattern — predicts which chunks will be accessed soon and warms them to SSD).

**Write path**: client wants to append to file F. Consults Curator for file metadata + current writable chunk. Curator returns the chunk's chunkserver set + grants a **lease** to one chunkserver (the **primary**) for the duration of the write window (typical 1-minute lease). Client sends data to all chunkservers (replicas or EC shards); primary chunkserver orders concurrent writes; replicas apply in primary's order; primary acks to client on success. Record-append semantics: multiple concurrent appends to the same file from different clients are atomic per-record (each record gets a unique offset, ordering is per-chunk-primary's choice).

**Per-file erasure coding**: each file specifies its EC scheme at creation (or in a per-directory policy). Hot small files use 3× replication (fast read on any single replica, low repair cost). Cold large files use Reed-Solomon (e.g., (17, 30): 17 data shards + 13 parity, 1.76× storage cost, survives 13 shard losses, repair requires reading 17 surviving shards). **Hybrid placement**: 1 SSD replica + EC-on-HDD for hot-tier files with cost optimization (SSD gives latency; HDD with EC gives durability + cost-efficiency).

**L4 cache + CacheSack**: the L4 is an SSD tier in front of HDD chunkservers. CacheSack (Google's published ML-driven placement system) categorizes files by access pattern (sequential vs random, hot vs cold, time-since-creation), predicts future access, advises Curators on which chunks to keep in L4 SSD. Read-cache vs writeback-cache modes: read-cache (most common) holds copies; writeback-cache absorbs writes before they hit HDD.

**Tiered storage**: SSD (L4) → HDD (chunkservers) → tape archive for very cold. Lifecycle policies migrate files between tiers based on access pattern. Cross-cluster data movement is expensive; clients are aware of locality and prefer in-cluster reads.

### Deep dives
1. **Metadata scaling: GFS single-master → Colossus distributed Curators on Bigtable.** GFS (Ghemawat et al., SOSP 2003) used a single NameNode that held all file → chunks → locations metadata in RAM. This worked for hundreds-of-PB clusters but capped further growth: NameNode RAM is the ceiling (each file's metadata ≈ hundreds of bytes; 10M files ≈ GB of metadata; the ceiling is reached at 100M-1B files). HDFS inherits this (with HA NameNode replicating to a standby). **Colossus's distributed metadata** removes the ceiling: Curators are stateless services; metadata lives in Bigtable (which is built on Colossus — recursive bootstrap). Each Curator owns a namespace partition; partitions resharded as needed. Client lookups: hash(path) → Curator → Bigtable read → metadata. Tens of billions of files become tractable. The 100× scale jump over GFS is the published headline. **Why Bigtable specifically**: it's the existing high-scale KV store at Google; using it bootstraps Colossus on existing primitives. Staff+ commit: the metadata architecture, the Bigtable dependency, the namespace partitioning strategy, what happens during Bigtable degradation (Colossus reads/writes stall; in practice Bigtable's own redundancy absorbs this).

2. **Chunk size: GFS 64 MB → Colossus 1 MB. Why smaller.** GFS chose 64 MB chunks to amortize metadata + TCP setup overhead per chunk: a typical GFS workload (MapReduce intermediate output) was sequential reads of large files, so large chunks meant fewer metadata lookups per byte read. Colossus reduced to 1 MB (64× smaller) because: (a) modern workloads include latency-sensitive applications (YouTube video segment reads, Gmail message reads, Search index segment reads) where 64 MB granularity is too coarse — fetching a 64 MB chunk to read a 100 KB message wastes bandwidth; (b) modern metadata architecture (distributed Curators) can handle the increased metadata count without ceiling concerns; (c) finer-grained replication enables better parallelism on degraded reads (when a replica is down, EC reconstruction is parallelized across more chunks). Trade-off: 64× more metadata entries per byte of data; per-cluster metadata size grows from GB-scale to TB-scale, which the distributed Curator architecture handles. Staff+ commit: chunk-size choice with criteria (latency-sensitive workloads → small; throughput-sequential workloads → large; mixed → small + locality-aware client caching), address the metadata-pressure consequence.

3. **Per-file erasure coding + hybrid placement.** Colossus lets each file specify its EC scheme: 3× replication for small/hot files; Reed-Solomon (e.g., (17, 30)) for large/cold files. The published economics: 3× replication = 3× storage cost; RS(17, 30) = 30/17 ≈ 1.76× storage cost at comparable durability. **Trade-off**: replication has parallel reads (any 1 of 3 replicas suffices); EC has serial reads (must read k=17 shards and reconstruct). For random-read workloads on EC files, this is expensive. **Hybrid placement** addresses this: 1 SSD replica (for low-latency reads) + EC-on-HDD (for durability + cost-efficient cold storage). The SSD replica handles 99%+ of reads; the EC shards on HDD provide durability + redundancy. Repair: EC-shard loss requires reading 17 surviving shards (more network than replication's read-1-shard repair); SSD-replica loss is replication-style cheap repair from EC shards. Staff+ commit: per-file EC vs replication decision criteria; hybrid placement when applicable; address the small-file problem (EC overhead doesn't pay off for files << k × shard_size).

## Known failure modes
1. **Metadata bottleneck on directory listing under fan-out workloads.** MapReduce-style job lists a directory with millions of files; Curator gets hammered. Production answer: **directory sharding** — for high-fanout directories, split the metadata across multiple Curator shards (transparent to clients via a routing layer); cache listings at clients with TTL; rate-limit listing operations per client.

2. **Small-file problem.** When most files are << default chunk size (1 MB), metadata pressure dominates: 1B 10KB files = 1B metadata entries; metadata storage > data storage; metadata access pattern dominates Curator load. Production answer: aggregate small files into containers (HBase / Parquet / SequenceFile patterns); per-file overhead amortized across many records; SQL-on-FS query engines (Hive, Spark) work directly on aggregated formats.

3. **Re-replication storm when a rack fails.** Rack failure loses many chunks simultaneously; background repair tries to re-replicate them all at once → network saturates; cluster degraded for hours. Production answer: throttled background repair (per-rack bandwidth budget); prioritized by replication factor remaining (chunks with 1 copy remaining repair first; chunks with 2 of 3 remaining repair second); rack-aware placement avoids correlated failures in the first place (chunks spread across racks at write time).

## Notes for the coach
- **This is plausibly-asked at Google (Colossus is the substrate for Bigtable / Spanner / YouTube / Gmail), Meta (Tectonic is the equivalent), and ML-heavy companies building checkpoint stores.** Distinct enough from S3 to be a separate question; appropriate when the candidate has S3 background and you want to probe FS semantics.
- **The GFS → Colossus distributed-metadata jump (100×) is the central architectural insight.** A candidate who proposes a single-NameNode design without acknowledging the scaling ceiling is anchoring on HDFS-era patterns; the Staff+ candidate articulates the distributed-Curators-on-Bigtable evolution.
- **The 64 MB → 1 MB chunk size shift is the modern-workload literacy signal.** Connects chunk size to workload latency requirements.
- **Per-file EC + hybrid placement is the cost-architecture flex.** A candidate who proposes uniform replication for all files is missing the cost-optimization story; the Sr Staff candidate articulates per-file EC selection with hybrid SSD-replica + EC-on-HDD placement.
- **The L4 CacheSack ML-driven placement** is a 2024+ literacy signal. Citing it shows current-frontier awareness.
- **No direct AI-infra counterpart** — distributed filesystem is generic; the closest AI-infra analog is "checkpoint store" for training jobs (which uses Colossus / Tectonic at Google / Meta), but the substrate is generic.
- **Cross-coverage:** distinct from `s3` (object store semantics: write-once-read-many, no in-place mutation, GET/PUT API); `colossus` is filesystem semantics (open/append/close, hierarchical namespace, record-append). Both are storage substrates; the right choice depends on the application's access pattern.
- **Don't allow drift into "design YouTube video storage" or "design Gmail message storage" — stay on the filesystem primitive.** Application-specific concerns (transcoding, full-text search) are separate problems; this question is about the underlying append-only distributed FS.

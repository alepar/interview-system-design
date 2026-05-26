# Data Structures Worth Naming

Source: `staff-engineer-study-guide.md`.

## Bloom Filter

**Definition.** A Bloom filter is a space-efficient probabilistic data structure that tests set membership with zero false negatives and a tunable false-positive rate, using k hash functions over a bit array.

**Canonical use.** RocksDB and Cassandra use a Bloom filter per SSTable so that reads for non-existent keys skip the disk-level binary search, dramatically reducing read amplification in LSM-tree storage.

**Production systems.** RocksDB (SSTable filters), Apache Cassandra (row cache and SSTable filters), web crawlers (URL seen-set at Google/Common Crawl scale).

**Alternatives.** Cuckoo filter (supports deletion, slightly better space efficiency); hash set (exact membership, O(n) memory vs O(1/ε) bits).

## Count-Min Sketch and HyperLogLog

**Definition.** Count-Min Sketch is a sublinear-space frequency estimator using multiple hash functions over a 2-D counter array; HyperLogLog estimates the cardinality of a set (distinct count) in O(log log n) space with ~2% error.

**Canonical use.** Twitter uses Count-Min Sketch to maintain approximate trending-topic hit counts across billions of tweets without storing per-item state; Redis HyperLogLog counts distinct daily active users per feature flag with fixed 12 KB memory.

**Production systems.** Redis HyperLogLog command, Apache Flink (built-in sketches for streaming aggregations), Presto/Trino approximate queries.

**Alternatives.** Exact hash-set counting (correct, O(n) memory); reservoir sampling (for per-item distributions rather than cardinality).

## Skip List

**Definition.** A skip list is a probabilistic linked-list data structure with O(log n) average search, insert, and delete by maintaining multiple levels of express lanes that skip over subsets of nodes.

**Canonical use.** Redis uses a skip list to implement sorted sets (ZADD/ZRANGE) because it supports O(log n) range queries and concurrent lock-free reads more naturally than a balanced BST.

**Production systems.** Redis sorted sets, LevelDB/RocksDB memtable (often skip list or red-black tree).

**Alternatives.** Red-black tree (same asymptotic complexity, deterministic, harder concurrent implementation); B-tree (better cache locality for disk-based storage).

## Trie / Suffix Tree / FST

**Definition.** A trie stores strings as a prefix tree enabling O(k) lookups (k = key length); a suffix tree indexes all suffixes of a string for O(m) substring search; a Finite State Transducer (FST) is a compressed automaton mapping strings to outputs with minimal memory, used for static dictionaries.

**Canonical use.** Search autocomplete stores the top-k completions for each prefix node in a trie, enabling sub-millisecond prefix queries; Lucene stores its term dictionary as an FST for compact in-memory lookup into the posting lists on disk.

**Production systems.** Lucene/Elasticsearch (FST term dictionary), Aho-Corasick trie (multi-pattern matching in WAFs), Radix trie in IP routing (Linux kernel).

**Alternatives.** Hash map for exact-key lookups (O(1), no prefix queries); ternary search tree (more cache-friendly than trie for sparse alphabets).

## Inverted Index, Posting Lists, BM25

**Definition.** An inverted index maps each term to a posting list of document IDs (and optionally positions/frequencies) that contain it; BM25 (Best Match 25) is a probabilistic relevance ranking function that scores documents by term frequency saturation and inverse document frequency.

**Canonical use.** Elasticsearch builds an inverted index at index time so full-text queries resolve to posting-list intersections in microseconds, then ranks results by BM25 score.

**Production systems.** Apache Lucene/Elasticsearch, Apache Solr, Postgres full-text search (GIN index + tsvector).

**Alternatives.** Vector similarity search (dense embeddings + HNSW) for semantic rather than lexical relevance; prefix B-tree for structured string queries.

## Geohash, S2, H3, Quadtree, R-tree, k-d Tree

**Definition.** Geohash encodes (lat, lon) into a hierarchical base-32 string where shared prefixes imply proximity; S2 uses a Hilbert-curve projection onto a cube for uniform-area cells; Uber H3 uses hexagonal cells for better isotropy; quadtree and R-tree are spatial index trees that recursively partition 2-D space; k-d tree generalizes binary search to k dimensions for exact nearest-neighbor queries.

**Canonical use.** Uber's dispatch system uses H3 hexagons to partition the city into equal-area supply/demand cells for surge pricing and driver matching; Yelp uses geohash prefixes to find nearby restaurants by filtering on a shared prefix and expanding radius as needed.

**Production systems.** Uber H3 (ride dispatch, pricing), PostGIS R-tree (GiST index), Redis GEO commands (geohash), Google S2 (Google Maps, internal routing).

**Alternatives.** Bounding-box query with lat/lon index (simple, less efficient for radius queries); PostgreSQL earthdistance extension (approximate, no spatial index).

## LSM-Tree vs B-Tree

**Definition.** An LSM-tree (Log-Structured Merge-tree) buffers writes in memory and flushes to immutable sorted files (SSTables) that are periodically compacted, favoring write throughput; a B-tree updates pages in place, providing better read performance and lower write amplification for random reads at the cost of write-heavy workloads.

**Canonical use.** RocksDB/Cassandra use LSM-trees for high-ingest event streams where write throughput dominates; PostgreSQL and MySQL InnoDB use B-trees for OLTP workloads with mixed reads and writes requiring predictable random-access latency.

**Production systems.** RocksDB, Apache Cassandra, LevelDB (LSM); PostgreSQL, MySQL InnoDB, SQLite (B-tree).

**Alternatives.** B+ tree (leaf-linked variant of B-tree, used in most RDBMS); fractal tree (Tokutek TokuDB, write-optimized like LSM with better point reads).

## Merkle Tree

**Definition.** A Merkle tree is a hash tree where each leaf is a data block hash and each internal node is the hash of its children, enabling O(log n) proof that any data block belongs to the tree and O(log n) detection of divergence between two trees.

**Canonical use.** Cassandra's nodetool repair uses Merkle trees to compare the hash of each token range between replicas; only the subtrees whose root hashes differ require data transfer, reducing anti-entropy bandwidth from O(data) to O(differences).

**Production systems.** Apache Cassandra (anti-entropy repair), Git (commit/tree/blob DAG is a Merkle DAG), IPFS (content-addressed storage), Bitcoin/Ethereum (transaction Merkle root in block headers).

**Alternatives.** Full-data checksum (simpler, O(data) comparison cost); bloom-filter comparison (probabilistic, no repair targeting).

## Consistent Hash Ring

**Definition.** Consistent hashing maps both nodes and keys onto a circular hash space so that adding or removing a node redistributes only K/n keys on average (K = keys, n = nodes) rather than remapping all keys.

**Canonical use.** Cassandra uses a consistent hash ring (with virtual nodes / vnodes for load balance) to assign partition ownership, so cluster expansion requires migrating only the token ranges transferred to the new node.

**Production systems.** Apache Cassandra (vnodes), Amazon DynamoDB (consistent hashing partition layer), Memcached client-side sharding (ketama).

**Alternatives.** Rendezvous (highest random weight) hashing (simpler, equally minimal remapping, no ring data structure); range-based sharding (easier rebalance but requires a metadata lookup).

## Roaring Bitmaps

**Definition.** Roaring bitmaps use a hybrid encoding — plain bitmap arrays for dense regions, sorted integer arrays for sparse regions, and run-length encoded runs — to store large sets of integers far more compactly and efficiently than a flat bitset.

**Canonical use.** Elasticsearch stores per-shard document ID sets as Roaring bitmaps so that boolean query (AND/OR) posting-list intersections operate on compressed bitmaps in CPU cache rather than scanning arrays.

**Production systems.** Apache Lucene/Elasticsearch (DocIdSet), Apache Druid (filter bitmaps), Apache Spark (RoaringBitmap aggregations).

**Alternatives.** Plain bitset (fast for dense sets, memory-wasteful for sparse); sorted integer array (memory-compact for very sparse sets, slow union/intersection).

## HNSW / IVF-PQ

**Definition.** HNSW (Hierarchical Navigable Small World) is a graph-based approximate nearest-neighbor index that routes queries through progressively finer layers for O(log n) search; IVF-PQ (Inverted File with Product Quantization) compresses vectors into quantized codes and limits search to the nearest Voronoi cells for sub-linear search with configurable recall/speed trade-offs.

**Canonical use.** Pinecone and pgvector use HNSW for low-latency semantic search over embedding vectors; Meta FAISS uses IVF-PQ to index billion-scale image embedding libraries where memory compression outweighs the recall penalty.

**Production systems.** FAISS (Meta, IVF-PQ and HNSW), pgvector (Postgres HNSW index), Pinecone, Weaviate, Qdrant.

**Alternatives.** Flat exact search (correct, O(n) query time, feasible only for small n); ScaNN (Google, anisotropic quantization, state-of-the-art recall/speed on large datasets).

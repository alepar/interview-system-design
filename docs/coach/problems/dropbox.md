---
slug: dropbox
archetype: ugc-pipeline
sources:
  hello_interview: hellointerview.com/learn/system-design/problem-breakdowns/dropbox
---

# Dropbox (Cloud File Storage and Sync)

## Bar anchors
- **Mid-level (L4/E4):** Produces a chunked-upload design with S3-compatible object storage for blobs and a relational metadata DB (Postgres) for file/folder hierarchy. Handles the basic sync flow (client polls for changes). Defines presigned URL pattern for direct client-to-S3 uploads. Does not need to lead the dedup, conflict resolution, or cross-region replication discussion unprompted.
- **Senior (L5/E5):** Proactively dives into: chunking strategy (fixed-size vs rolling hash), content-addressable storage with SHA-256 hash per chunk enabling cross-file dedup, sync delta algorithm (`GET /changes?since=cursor`), and large-file resumability (multi-part upload with per-chunk presigned URLs). Explains the metadata DB schema including version history and chunk manifest. Addresses sync conflict (last-writer-wins for files vs user-visible conflict copy for concurrent edits).
- **Staff+ (L6/E6+):** Drives the entire session. Proactively raises: bandwidth cost optimization (dedup reduces upload cost; delta sync reduces download cost; CDN caching for public share links), cross-region replication for durability and latency (S3 CRR or GCS multi-region), conflict resolution strategy for collaborative docs (CRDT vs last-writer-wins), version history GC policy (cost vs retention trade-off), and privacy implications of cross-user dedup (same hash → same blob; a user deleting their copy must not delete a shared blob). Discusses operational concerns: orphaned chunk cleanup, storage billing reconciliation, and quota enforcement.

## Canonical decomposition

### Requirements
**Functional:**
- Upload files from any device; files become available on all linked devices
- Sync file changes across devices in near-real-time
- Share files or folders via a link (public or with specific users)
- Maintain full version history (allow restore to previous version)
- Support large files (up to 50GB per file)

**Non-functional (with numbers):**
- 1 billion registered users; 500 million active per month
- Average 10GB storage per user → 10 exabytes total managed storage
- 500 million files uploaded per day ≈ 5,800 uploads/sec average; burst to 50,000 uploads/sec
- Metadata read latency <100ms p95 (file list, folder tree)
- Sync notification latency <5s p95 (change visible on second device)
- 99.99% durability (files must not be lost); 99.9% availability for upload/download
- Bandwidth cost is a primary operational concern — dedup and delta sync are not optional at this scale

### Core entities
- **File:** file_id, owner_id, parent_folder_id, name, current_version_id, created_at, is_deleted
- **FileVersion:** version_id, file_id, version_number, size_bytes, chunk_ids[] (ordered), created_at, device_id
- **Chunk:** chunk_hash (PK, SHA-256), size_bytes, blob_ref (S3 key), ref_count
- **Folder:** folder_id, owner_id, parent_folder_id, name, created_at
- **Device:** device_id, user_id, platform, sync_cursor, last_seen_at
- **ShareLink:** link_id, file_id, owner_id, permission (read/write), expires_at, is_public

### API
- `POST /uploads` body={file_id, version, total_size, chunk_count, chunk_hashes[]} → {upload_id, missing_chunk_hashes[], presigned_urls{hash→url}}
- `PUT <presigned_url>` — direct client-to-S3 chunk upload (parallel, no app-server in path)
- `POST /uploads/:id/commit` body={chunk_hashes[]} → {version_id} (finalizes the version, triggers sync)
- `GET /files/:id` → {file, current_version, chunk_hashes[]}
- `GET /changes?cursor=<sync_cursor>` → {events[{type, file_id, version_id}], next_cursor} (sync poll endpoint)
- `POST /files/:id/share` body={permission, expires_at, emails[]?} → {link_id, share_url}
- `GET /files/:id/versions` → {versions[{version_id, created_at, size_bytes}]}
- `POST /files/:id/restore` body={version_id} → {new_version_id}

### HLD
File uploads bypass the application server for blob data. The client first calls `POST /uploads` with the list of chunk SHA-256 hashes for the new version. The Upload Service checks which chunk hashes already exist in the Chunk table (content-addressable store) and returns only the missing hashes with time-limited S3 presigned PUT URLs (one per missing chunk, valid for 30 minutes). The client uploads missing chunks in parallel directly to Amazon S3 (or Google Cloud Storage), then calls `POST /uploads/:id/commit`. The Upload Service verifies all chunks exist in S3, inserts FileVersion and Chunk records in Postgres, decrements/increments chunk ref_counts, and publishes a `file.changed` event to a Kafka topic. This design means unchanged chunks are never re-uploaded — cross-version and cross-user dedup at the chunk level.

Metadata (files, folders, versions, chunk manifests) lives in a sharded Postgres cluster, sharded by `owner_id`. A Redis cache layer (write-through) holds hot folder listings and file metadata. The `changes` table is an append-only event log per user; the sync cursor is an auto-increment sequence number in this table. `GET /changes?cursor=N` returns all events with sequence > N, allowing any device to compute the delta since its last sync.

Sync notifications use a long-polling gateway (or WebSocket for mobile clients). When a `file.changed` event is published to Kafka, a Notification Service fans it out to all devices registered for that user via their persistent long-poll connection. The device receives the change event, calls `GET /changes?cursor=...` to get the delta, downloads only the missing chunks for the new version using presigned GET URLs, and reassembles the file locally. CDN (Cloudflare) fronts the S3 presigned GETs for public share links, caching reads at edge PoPs.

### Deep dives
1. **Chunking strategy and deduplication** — Fixed-size chunks (4MB default) are simple to implement but create false differences when data is inserted mid-file (all subsequent chunk boundaries shift). Rolling-hash chunking (Rabin fingerprinting) produces variable-size chunks (1–8MB) with boundaries tied to content, so inserting a byte at the start only re-chunks the first affected segment. Content-addressable storage (CAS) with SHA-256 as the chunk key enables dedup both within a user (version history reuse) and across users (two users uploading the same file share storage). Cross-user dedup has a privacy implication: a user must not be able to infer whether another user has the same file. Mitigation: never expose chunk hashes externally; dedup is server-side only; chunk ref_count prevents deletion of a shared blob when one owner deletes their copy.
2. **Sync algorithm and conflict resolution** — Each device maintains a `sync_cursor` (last event sequence number seen). On reconnect, the device calls `GET /changes?cursor=<last_cursor>` to receive the ordered list of changes since last sync. The server returns events with file_id, new version_id, and the chunk delta (new_chunks minus chunks the client already has). The client downloads only missing chunks and applies the new version. Conflict detection: if two devices both modify the same file while offline, the server receives two commits for the same base version. Resolution policy: last-writer-wins (the second commit creates version N+2; the first commit's version N+1 is preserved in history). For users who care, Dropbox exposes the conflict as a "conflicted copy" — a new file named `filename (John's conflicted copy 2026-05-12)` — so both edits survive. Collaborative documents (Google Docs-style) are out of scope; for those, a CRDT-based approach would be needed.
3. **Large file resumability** — For a 50GB file, a single upload attempt is unlikely to complete without interruption. The client splits the file into N chunks and calls `POST /uploads` to get presigned URLs. Each chunk is uploaded independently; the client tracks which chunks have been acknowledged by S3 (ETag or 200 response). On connection loss, the client resumes by calling `POST /uploads` again with the same chunk hashes; the Upload Service re-checks which hashes are missing in S3 and returns presigned URLs only for those. This makes resumability a natural property of the CAS design — the client retries until all chunks exist in S3. `POST /uploads/:id/commit` is idempotent: if the same version_id is committed twice, the server returns the existing version_id without error.

## Known failure modes
1. **Partial upload on disconnect (orphaned in-progress upload)** — Client uploads 40% of chunks and disconnects. Those chunks exist in S3 but the version is never committed. Mitigation: a cleanup job runs daily, scanning the `uploads` table for uncommitted uploads older than 24 hours. It identifies chunk hashes referenced only by the stale upload (ref_count contributed only by this upload) and deletes them from S3. S3 Lifecycle Rules are also configured to delete objects under the `tmp/uploads/` prefix after 48 hours as a safety net.
2. **Storage write succeeded, metadata write failed (orphaned blobs)** — S3 PUT succeeds for all chunks, but the Postgres transaction for FileVersion/Chunk records fails (DB crash or timeout). The blobs exist in S3 with no metadata reference. Mitigation: the Upload Service maintains an `upload_chunks` staging table written before S3 upload begins. The reconciliation job compares S3 object keys to staging records; blobs in S3 with no corresponding committed FileVersion after 24h are treated as orphaned and deleted. Postgres transactions use a two-phase approach: write chunk hashes to staging, confirm S3 ETags, then promote to the canonical Chunk table atomically.
3. **Concurrent edit on the same file from two devices** — User edits `report.docx` on laptop (offline) and phone (offline) simultaneously. Both submit commits when they reconnect; the server receives two version N+1 candidates. Mitigation: the commit endpoint checks the base version; the second commit fails the optimistic version check (expected version N, actual version N+1). The server stores the second device's commit as a `conflict version` and creates a "conflicted copy" file in the same folder. Both versions are preserved in history. A webhook or push notification tells both devices to display the conflict. For destructive cases (one device deletes, one device edits), delete wins: the edit is stored as a conflict version against the deleted file's history, accessible via version restore.

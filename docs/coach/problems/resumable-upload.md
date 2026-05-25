---
slug: resumable-upload
archetype: ugc-pipeline
sources:
  s3_mpu_limits: docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html
  s3_mpu_overview: docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html
  s3_presigned: docs.aws.amazon.com/AmazonS3/latest/userguide/PresignedUrlUploadObject.html
  tus_protocol: tus.io/protocols/resumable-upload
  gcs_resumable: docs.cloud.google.com/storage/docs/performing-resumable-uploads
---

# Resumable Upload (chunked/resumable large-file upload protocol)

## Bar anchors
- **Mid-level (L4/E4):** Single `PUT` of the whole file. Doesn't handle large files, network failures mid-upload, or resume.
- **Senior (L5/E5):** Split into chunks, upload in parallel, resume failed chunks; presigned URLs direct-to-storage. Knows S3 multipart exists. May not articulate the part limits, the ETag/checksum integrity, the tus offset protocol, orphaned-part cleanup, or direct-to-storage security.
- **Staff+ (L6/E6+):** Drives proactively. Uses **S3 multipart upload** (5MB min part except last, 5GB max part, 10,000 parts max ⇒ 5TB object max; switch to multipart ≥100MB) with **parallel part uploads** (16–64MB optimal; resume by re-sending only failed parts — track per-part state), each part returning a number+**ETag** (the final object ETag is the **MD5 of concatenated part-MD5s + "-N"**; per-part checksums, CRC64NVME default, fail with BadDigest on mismatch). Uploads **direct-to-storage via presigned URLs** (bytes bypass the app server; max 7-day expiry; short TTL to limit leak risk). Cleans up **orphaned parts** with an `AbortIncompleteMultipartUpload` lifecycle rule (~7 days — incomplete parts are billable). Knows the **tus** protocol (offset-based: `HEAD` returns `Upload-Offset` to resume, `PATCH` writes from that offset, `POST` creates with `Upload-Length`; Concatenation extension for parallel) and that tus (client→server) vs S3-multipart (client→storage) are **alternatives, pick one**. Cites GCS resumable (session URI, 256KiB-multiple chunks, Range-based resume, 1-week expiry).

## Canonical decomposition

### Requirements
**Functional:**
- Upload large files reliably; resume after a network failure without restarting
- Upload parts in parallel for throughput; verify integrity per part and whole-object
- Upload direct to storage (keep the app server out of the byte path); clean up failed uploads

**Non-functional (with numbers):**
- S3: 5MB min part, 5GB max part, 10,000 parts, 5TB object; multipart ≥100MB; 16–64MB optimal part
- Presigned URL max 7-day expiry (short TTL preferred)
- tus: HEAD→Upload-Offset resume, PATCH writes, POST creates with Upload-Length
- Orphaned-part cleanup: AbortIncompleteMultipartUpload ~7 days (billable until aborted)

### Core entities
- **Upload session:** uploadId + the set of parts (numbers, ETags, checksums, status)
- **Part:** a chunk (5MB–5GB), uploaded independently, retried independently
- **Presigned URL:** a short-lived signed URL for a direct-to-storage part upload
- **Offset (tus):** the byte position to resume from

### API
- S3: `CreateMultipartUpload → uploadId`; `UploadPart(uploadId, partNumber)` (presigned) → ETag; `CompleteMultipartUpload([{partNumber, ETag}])`
- tus: `POST` (Upload-Length) → URL; `HEAD` → Upload-Offset; `PATCH` (Upload-Offset, body) → new offset
- resume: list uploaded parts / read Upload-Offset → send only what's missing
- cleanup: lifecycle `AbortIncompleteMultipartUpload` after N days

### HLD
A large file can't be a single request — a drop near the end wastes the whole transfer — so the upload is **chunked and resumable**. The two dominant designs:

**S3 multipart upload** (client → storage): `CreateMultipartUpload` returns an `uploadId`; the file is split into **parts** (5MB minimum except the last, 5GB max, up to **10,000** parts ⇒ **5TB** object max; AWS recommends multipart at ≥100MB, ~16–64MB parts for the throughput/parallelism balance); each part is uploaded **independently and in parallel** (often via a **presigned URL** so bytes go **directly to the bucket**, bypassing the app server — the app only signs URLs), returning a **part number + ETag**. To **resume** after failure, list the already-uploaded parts and send only the missing ones. `CompleteMultipartUpload` assembles the object from the part list; the resulting **ETag is the MD5 of the concatenated part MD5s + "-N"** (not a whole-object MD5), and per-part **checksums** (CRC64NVME default) let S3 reject corrupt parts (BadDigest). **Orphaned parts** from abandoned uploads remain **billable** until aborted, so an `AbortIncompleteMultipartUpload` **lifecycle rule** (e.g. 7 days) cleans them up.

**tus** (client → server): an open offset-based protocol — `POST` to a creation URL with `Upload-Length` creates the upload; a `HEAD` returns the current `Upload-Offset` (where to resume); `PATCH` requests write bytes from that offset, and the new offset = old + bytes received. Its Concatenation extension allows parallel partial uploads merged into one. **tus and S3-multipart are alternatives to the same problem** (client-to-server vs client-to-storage) — pick one, not both (Uppy uses single-chunk ≤100MiB, multipart above). **Presigned URLs** carry a **7-day max expiry** (short TTL preferred — a leaked URL allows uploads until it expires). GCS's resumable upload mirrors this (a session URI, 256KiB-multiple chunks, Range-based resume, 1-week session expiry). Completion typically emits an event that triggers the processing pipeline (`youtube-upload`/`instagram-upload`).

### Deep dives
1. **S3 multipart mechanics + integrity.** The part limits encode the design space: 5MB min (except last) / 5GB max / 10,000 parts ⇒ 5TB object, and a 16–64MB part size balances fewer API calls (large parts) against parallelism (small parts). Parts upload independently and in parallel, so **resume = re-send only the failed parts** (track per-part status). Integrity is layered: each part has a checksum (CRC64NVME default; BadDigest on mismatch), and the **whole-object ETag is MD5-of-concatenated-part-MD5s + "-N"** (a Merkle-ish hash — *not* a plain object MD5, a common gotcha when verifying). The Staff+ point: multipart gives parallelism + resumability + per-part integrity, and the ETag semantics matter for correctness checks.
2. **Direct-to-storage via presigned URLs (and its security).** Routing gigabytes through the app server is wasteful and a bottleneck; **presigned URLs** let the client upload **directly to object storage** — the app server only validates and issues a short-lived signed URL (handling a string, not the bytes). Security implications: the URL grants upload rights until it expires (max 7 days; URLs from temp credentials expire with the credential), so **short TTLs** (minutes) limit the blast radius of a leaked URL, and you scope the URL to the exact key/operation. This is the standard pattern across `youtube-upload`/`instagram-upload`/`google-photos`. The framing: keep the app server out of the byte path, sign per-part URLs, and use tight expiries.
3. **tus offset protocol + orphan cleanup.** tus is the clean open standard for client→server resumable upload: state is just a byte **offset** — `HEAD` to learn where to resume, `PATCH` to append from that offset — so a client that crashed reconnects, asks "how much did you get?", and continues. It's the alternative to S3 multipart (Uppy frames it as "tus OR S3-multipart, not both"), suited when the server (not the storage) terminates uploads. Either way, **incomplete uploads leak resources**: S3 charges for orphaned parts until aborted, so an `AbortIncompleteMultipartUpload` lifecycle rule (7 days) is mandatory hygiene; tus servers similarly expire stale uploads. The framing: resumability requires tracking partial state (parts/offset), and that state must be **garbage-collected** or it accumulates cost.

## Known failure modes
1. **Whole upload lost on a late failure.** A single-request upload of a multi-GB file restarts on any drop. Production answer: chunked multipart/tus; resume by sending only missing parts / from the last offset; parallel parts for throughput.
2. **Orphaned parts accumulating cost.** Abandoned multipart uploads leave billable parts. Production answer: `AbortIncompleteMultipartUpload` lifecycle rule (~7 days); tus stale-upload expiry; monitor incomplete uploads.
3. **Leaked presigned URL / corrupt part.** A long-lived signed URL is abused, or a part arrives corrupt. Production answer: short presigned-URL TTL scoped to the key/op; per-part checksums (BadDigest on mismatch) + whole-object ETag verification on complete.

## (Delineation note)
`resumable-upload` is the **upload protocol** stage shared by `youtube-upload`, `instagram-upload`, `google-photos`, and `dropbox`. The object store is infra-primitives `s3`; the processing that the completion event triggers is the per-pipeline problem. Here it's multipart/tus chunking + resume + presigned direct-to-storage + integrity + cleanup.

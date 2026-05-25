---
slug: calendar-sync
archetype: conflict-resolution
sources:
  rfc6578: rfc-editor.org/rfc/rfc6578.html (Collection Synchronization for WebDAV)
  rfc4791: "RFC 4791 — Calendaring Extensions to WebDAV (CalDAV)"
  rfc5545: datatracker.ietf.org/doc/html/rfc5545 (iCalendar)
  rfc5546: rfc-editor.org/rfc/rfc5546 (iTIP)
  if_match: developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/If-Match
---

# Calendar / Contacts Sync (offline-first CalDAV / CardDAV, record-level conflicts)

## Bar anchors
- **Mid-level (L4/E4):** Polls "get all events" periodically and overwrites local state. No incremental sync, no conflict handling, no lost-update protection.
- **Senior (L5/E5):** Incremental sync via per-resource ETags and a collection tag; conditional PUT to avoid clobbering; knows the "edited on two devices" case needs resolution. May not name RFC 6578 sync-tokens, the 412 lost-update pattern, iCalendar SEQUENCE, or recurring-event exceptions.
- **Staff+ (L6/E6+):** Drives proactively. Uses **RFC 6578 sync-collection REPORT** with a **DAV:sync-token** for incremental sync (server returns added/modified/deleted since the token + a new token), distinguishing the collection-wide **CTag** from per-resource **ETags**. Implements **lost-update prevention via conditional PUT** (`If-Match: <etag>` → **412 Precondition Failed** if another client changed it first → client GETs latest and retries). Uses **iCalendar SEQUENCE** as the organizer-incremented revision (RFC 5546 iTIP: bumped on DTSTART/RRULE/STATUS changes, *not* on attendee REPLY). Frames "edited offline on two devices" as a **record-level** conflict (both PUT `If-Match: v1`; the second gets 412 → conflict UI / merge), and names **recurring-event exceptions** (RECURRENCE-ID overrides, EXDATE) as the hard case. Notes this is the **no-real-time corner** (poll intervals 1–15 min; mobile throttled to 15–24 min under battery optimization) and that the protocol does **record-level**, not automatic field-level, merge.

## Canonical decomposition

### Requirements
**Functional:**
- Sync calendars/contacts across devices and servers, offline-first
- Incremental: fetch only what changed since last sync
- Prevent lost updates when two clients edit the same event/contact
- Resolve the "edited on two devices while offline" conflict
- Handle recurring events and their per-instance exceptions

**Non-functional (with numbers):**
- Poll interval 1–15 min (mobile throttled to 15–24 min under battery optimization)
- Per-collection: 10²–10⁵ events; record-level (not field-level) protocol conflict granularity
- Lost-update prevention via If-Match → 412 (well-behaved clients <1% 412 rate)
- Cross-vendor interop (Apple ↔ Google ↔ Fastmail ↔ Thunderbird)

### Core entities
- **Collection:** a calendar/address book (has a CTag and a sync-token)
- **Resource:** one event (VEVENT) or contact (vCard), with an **ETag**
- **sync-token:** opaque cursor for incremental collection sync (RFC 6578)
- **SEQUENCE:** iCalendar per-event revision counter (organizer-incremented)
- **RECURRENCE-ID / EXDATE:** override/exception markers for a recurring series

### API
- `REPORT sync-collection {sync-token}` → {added, modified, deleted resources + new sync-token}
- `GET /collection/event.ics` → resource + its ETag
- `PUT /collection/event.ics` with `If-Match: <etag>` → 200, or **412** if changed first
- full resync fallback when the server returns 410/invalid sync-token

### HLD
A client keeps a per-collection **sync-token**. To sync, it issues a **`REPORT sync-collection`** with its cached token; the server returns the resources **added/modified/deleted since that token** (each with its **ETag**) plus a **new sync-token** — so the client transfers only deltas, not the whole collection. (The older **CTag** is a collection-wide "something changed" marker that forces a full listing; RFC 6578 sync-tokens exist precisely to avoid that.) To **write**, the client does a conditional **`PUT` with `If-Match: <last-known ETag>`**: if another client already changed the resource, the server returns **412 Precondition Failed**, and the client must **GET the latest version and retry** (resolving or surfacing the conflict) — this is the canonical **lost-update prevention**.

The **"edited offline on two devices"** case is a **record-level** conflict: phone (offline) and laptop (offline) both edit the same event from ETag v1; whichever syncs first wins and bumps to v2; the second's `If-Match: v1` gets **412**, forcing a GET + conflict resolution (the protocol does *not* auto-merge fields — that's the client's job, and most clients present a conflict queue or last-writer-wins by user choice). For **invitations**, **iCalendar SEQUENCE** is the revision the **organizer** increments on substantive changes (DTSTART/DTEND/RRULE/STATUS, per RFC 5546 iTIP), and attendees' RSVPs (REPLY) do *not* bump it — so conflicting versions of an invite are ordered by SEQUENCE. The hard case is **recurring events**: a single edit to one instance of a weekly meeting creates a separate resource with the same UID and a **RECURRENCE-ID** override (and an EXDATE on the master), so sync and conflict resolution must treat the series + its overrides as a coherent set, preserving the originating **VTIMEZONE** (normalizing to UTC would corrupt RRULE semantics across DST).

### Deep dives
1. **Incremental sync: sync-token vs CTag vs ETag.** Three change-detection layers: **ETag** per resource (changed on every edit to that event), **CTag** per collection (changed on any edit anywhere in it — coarse), and the **RFC 6578 sync-token** (an opaque cursor letting the server return *just* the delta + a fresh token). A naive client polls + diffs full listings (CTag-driven); a good one uses sync-tokens for O(changes) transfer. Servers may keep limited history and **invalidate old tokens** (return 410), forcing a **full resync** fallback — the client must handle that gracefully. The Staff+ point: name why sync-tokens superseded CTag (avoid full-collection listing on every change).
2. **Lost-update prevention via conditional PUT.** Optimistic concurrency at the record level: every write carries `If-Match: <etag>`; the server rejects with **412** if the resource moved on, and the client GETs + retries. This is the HTTP-native equivalent of compare-and-swap and is what keeps two devices from silently clobbering each other. Contrast with the real-time members of this archetype: calendar sync is **record-granular, after-the-fact** (like git, not like OT) — it detects the conflict and asks the human/policy to resolve, rather than merging operations. That's the right design for low-concurrency, structured records edited rarely-but-offline.
3. **Recurring events: the genuinely hard case.** A weekly meeting is one VEVENT with an RRULE; editing *one* instance creates an override resource sharing the UID with a **RECURRENCE-ID** (and the master gets an EXDATE for that date). Concurrent edits — one to the whole series, one to a single instance — must compose so the series and its exceptions stay consistent (e.g. "change all future occurrences" splits the RRULE). Timezones compound it: the VTIMEZONE must travel with the event and *not* be normalized to UTC, or recurrence + DST math drifts. This is where calendar sync stops being "CRUD with ETags" and becomes a real domain-modeling problem — the Staff+ depth area.

## Known failure modes
1. **Lost update from unconditional PUT.** Two devices overwrite each other. Production answer: `If-Match: <etag>` conditional PUT → 412 → GET-latest-and-retry; never PUT without the precondition.
2. **Stale sync-token after server compaction.** The server discarded the history the client's token points into. Production answer: detect 410/invalid-token and fall back to a full resync, then resume incremental — don't assume the token is valid forever.
3. **Recurring-event / timezone corruption.** Editing one instance or normalizing to UTC breaks the series. Production answer: model overrides via RECURRENCE-ID + EXDATE, carry VTIMEZONE with the event, and treat "this instance" vs "this and future" vs "all" as distinct operations.

## (Spine note)
`calendar-sync` is the record-granular, offline-first, after-the-fact member of this archetype (closer to `version-control-merge` than to OT/CRDT). It shares the offline-first sync shape with `local-first-sync` (here over CalDAV/HTTP rather than a bespoke engine).

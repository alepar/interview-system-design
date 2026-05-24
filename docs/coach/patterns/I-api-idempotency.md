# API and Idempotency Patterns

Pattern reference for `/study-patterns 3I`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3I.

## Idempotency Keys (Stripe Pattern)

**Definition.** A client-generated UUID is sent as an idempotency key header; the server stores the key with the response in a dedup table (with TTL) so that any retry of the same request returns the cached response rather than executing the operation again.

**Canonical use.** Stripe's payment API accepts an `Idempotency-Key` header so that a client whose HTTP connection dropped mid-request can safely retry the charge without fear of double-billing, because the server returns the original charge object for the same key.

**Production systems.** Stripe Payments API, Braintree, AWS SQS deduplication IDs (FIFO queues).

**Alternatives.** Conditional writes via database UNIQUE constraint on the operation's natural key (simpler, but leaks DB details into API contract); at-most-once with client-side timeouts (loses messages rather than deduplicating).

## Optimistic Concurrency with Version Numbers / ETags

**Definition.** The server attaches a version number or ETag to a resource, and the client includes it in an update request as a precondition; the server rejects the write with 412 Precondition Failed if the resource has since changed, preventing lost updates without holding a lock.

**Canonical use.** A collaborative document editor reads a page at version 42, makes edits, and submits `If-Match: "42"`; if another user saved version 43 in between, the server returns 412 and the client must re-fetch and merge before retrying.

**Production systems.** HTTP ETags (RFC 7232), AWS S3 object ETags, DynamoDB conditional expressions (`ConditionExpression: version = :expected`).

**Alternatives.** Pessimistic row-level locking (correct, serialized, blocks concurrent readers); CRDT-based merge (no conflict, always converges, more complex data model).

## Pagination: Offset, Cursor, Keyset

**Definition.** Offset pagination uses `LIMIT n OFFSET k` SQL (simple, but O(n+k) cost and inconsistent on inserts); cursor pagination encodes the position as an opaque server-side token; keyset pagination filters by the last seen indexed value (e.g., `WHERE id > last_id LIMIT n`), giving O(log n) stable pages.

**Canonical use.** A social feed API replaces offset pagination with keyset pagination on `(created_at DESC, id DESC)` so that new posts appearing at the top do not shift subsequent pages, and each page query hits the index directly rather than scanning from row 0.

**Production systems.** GitHub REST API (cursor-based via Link headers), Stripe API (cursor via `starting_after` object ID), Twitter/X timeline (keyset on snowflake ID).

**Alternatives.** Seek method / deferred join (keyset variant with a join to avoid full-row scan on wide tables); GraphQL Relay cursor connections (standard cursor spec for graph APIs).

## Webhooks vs Polling vs SSE vs WebSockets

**Definition.** Polling has the client repeatedly request updates (simple, wasteful); webhooks have the server push an HTTP POST to a client-registered URL on each event (server-initiated, requires client to be publicly reachable); SSE (Server-Sent Events) is a unidirectional server-to-client stream over HTTP/1.1 using `text/event-stream`; WebSockets are a full-duplex TCP upgrade over HTTP enabling low-latency bidirectional messaging.

**Canonical use.** A payment system uses webhooks to notify a merchant's server of charge events asynchronously; a live sports score widget uses SSE for server-to-client score pushes without the overhead of a full WebSocket handshake; a chat application uses WebSockets for bidirectional real-time message exchange.

**Production systems.** Stripe/GitHub webhooks, Twitch chat (WebSockets), GitHub Copilot (SSE for streaming completions), Slack RTM API (WebSockets).

**Alternatives.** Long polling (simulates push without SSE/WebSocket, higher latency than SSE); gRPC server streaming (binary, multiplexed, better for internal services).

## API Versioning: URI, Header, Content Negotiation

**Definition.** URI versioning embeds the version in the path (e.g., `/v1/`), making it cache-friendly and explicit but coupling clients to URLs; header versioning uses a custom request header (e.g., `API-Version: 2024-01-01`); content negotiation uses `Accept: application/vnd.api+json;version=2` to decouple version from URL structure.

**Canonical use.** Stripe versions its API by date in a custom header (`Stripe-Version: 2023-10-16`) so each customer account is pinned to the version at signup, and breaking changes are introduced as new date-versioned behaviors rather than new URL paths.

**Production systems.** Stripe (header date versioning), AWS APIs (URI versioning for most services), GitHub REST API (URI `/v3/` + custom `X-GitHub-Api-Version` header).

**Alternatives.** Query-parameter versioning (`?version=2`, simple but cache-unfriendly); never-break API evolution with additive-only changes and deprecation policy (avoids versioning complexity for stable APIs).

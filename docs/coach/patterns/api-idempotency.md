# API and Idempotency Patterns

Source: `staff-engineer-study-guide.md`.

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

## Saga / Compensating Transactions

**Definition.** A long-lived multi-step distributed transaction where each forward step has a paired **compensating action** that semantically undoes its effect; on partial failure at step N, the saga rolls back by executing compensations for steps 1..N-1 in reverse order. Each step and its compensation must be idempotent (compensating twice equals compensating once), because retries are inevitable in the failure paths the pattern exists to handle.

**Canonical use.** A ticket-purchase workflow (Ticketmaster: reserve seat → charge card → issue ticket → email confirmation) cannot run as a single ACID transaction because the payment provider, email service, and seat DB don't share a transaction manager; instead each step is paired with a compensation (release seat, refund charge, void ticket, send apology email) and the saga executes compensations in reverse if any step fails.

**Production systems.** Stripe payments (refund as compensation for charge; Garcia-Molina & Salem SIGMOD 1987 referenced in Stripe's design); Ticketmaster reservation+payment+fulfillment; Uber trip booking; airline booking systems (hold seat → charge → ticket).

**Alternatives.** Two-phase commit / 2PC (correct strong consistency, but heavy coordinator-blocking protocol that doesn't survive WAN partitions and isn't supported by external SaaS APIs like Stripe or SendGrid); event sourcing with no compensations (eventual consistency, append-only log of facts, no rollback — works only when partial state is acceptable to downstream consumers).

## Saga Orchestration vs Choreography

**Definition.** **Choreography**: each service listens for events and emits its own next event autonomously — no central coordinator, decoupled, but the workflow is implicit in the event topology and hard to reason about / audit. **Orchestration**: a central coordinator (durable workflow engine) drives an explicit state machine, calls each step, persists progress, and triggers compensations on failure — easier to reason about, monitor, and modify, at the cost of a coordinator dependency.

**Canonical use.** A marketplace payment splitting one charge across N merchants uses **orchestration** (Temporal workflow) so the state of "which merchants are credited so far" is explicit and resumable after coordinator restart; an order-fulfillment pipeline across loosely-coupled microservices (order, inventory, shipping, billing) often uses **choreography** because each service already owns its event stream and no team wants to depend on a central coordinator.

**Production systems.** Temporal (orchestration; production at Uber/Snap/Stripe/Coinbase); AWS Step Functions (managed orchestration state machine); Netflix Conductor (orchestration); Camunda / Zeebe (BPMN orchestration); Uber Cadence (Temporal's predecessor, still in use). Choreography typically rides on Kafka or an event bus without a named engine.

**Alternatives.** Hand-rolled state machine in a relational DB with a cron worker (works for low-complexity sagas, lacks visibility/replay/versioning of a dedicated engine); pure 2PC where all participants are in-house (avoids saga complexity but rules out external SaaS steps). **Failure modes to flag regardless of style**: isolation gap (other transactions can observe intermediate saga state — e.g., a seat shows "held" mid-saga); uncompensatable side-effects (an email already sent, a wire transfer already disbursed, a physical package shipped) that require human workflows or accept-the-loss policy rather than automated rollback; compensation-of-compensation pathology if compensating actions themselves can fail and aren't idempotent.

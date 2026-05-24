# Asynchronous / Streaming

Pattern reference for `/study-patterns 3F`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3F.

## Message Queue vs Publish-Subscribe

**Definition.** A message queue delivers each message to exactly one consumer (point-to-point), while publish-subscribe fans a message out to all subscribers of a topic.

**Canonical use.** Use a queue for work distribution (e.g., image encoding jobs) and pub-sub for event fan-out (e.g., order-placed event consumed by billing, inventory, and notification services simultaneously).

**Production systems.** Amazon SQS (queue), Google Pub/Sub (pub-sub).

**Alternatives.** RabbitMQ supports both models via exchange types; Kafka can emulate both via consumer-group cardinality.

## Kafka: Partitions, Consumer Groups, Log Compaction, ISR, Exactly-Once

**Definition.** Kafka is a distributed commit log that orders messages within partitions, scales consumers via consumer groups (one partition owner per group), retains data via log compaction, tracks in-sync replicas (ISR) for durability, and offers exactly-once semantics via idempotent producers and transactional APIs.

**Canonical use.** Use partitioning by user ID to preserve per-user ordering across a horizontally scaled consumer group processing activity events.

**Production systems.** LinkedIn (original), Confluent Kafka, Uber's real-time data pipeline.

**Alternatives.** Apache Pulsar (separate storage layer, multi-tenancy); AWS Kinesis (managed, lower ops overhead).

## At-Least-Once + Idempotent Handler

**Definition.** At-least-once delivery guarantees no message is lost but allows duplicates; pairing it with an idempotent consumer (keyed dedup table or natural idempotency) achieves effective exactly-once processing without distributed transaction overhead.

**Canonical use.** A payment processor acknowledges the queue message only after committing the charge, and deduplicates by idempotency key so a retry never double-charges.

**Production systems.** Stripe payment workers, AWS SQS standard queues with application-level dedup.

**Alternatives.** Exactly-once Kafka transactions (higher latency, Kafka-only); at-most-once (acceptable only for lossy metrics, not money).

## Stream Processing: Windows and Watermarks

**Definition.** Stream processing frameworks execute continuous queries over unbounded data; windows (tumbling = fixed non-overlapping, sliding = overlapping, session = gap-bounded) group events in time, and watermarks estimate how late events can arrive before a window is closed.

**Canonical use.** A fraud-detection pipeline uses a 5-minute tumbling window keyed by card number to count transactions; a watermark of 30 s allows for out-of-order network delays before emitting the window result.

**Production systems.** Apache Flink (event-time processing, exactly-once checkpoints), Apache Spark Structured Streaming, AWS Kinesis Data Analytics.

**Alternatives.** Kafka Streams (simpler, JVM-only, no cluster manager); Materialize (SQL over streaming with incremental view maintenance).

## Change Data Capture (CDC)

**Definition.** CDC reads the database's replication log (e.g., Postgres WAL, MySQL binlog) to stream every row-level insert/update/delete as an event, decoupling downstream consumers from polling the source database.

**Canonical use.** Sync an OLTP Postgres database to an Elasticsearch search index in near real-time without touching application code, by routing WAL events through Debezium into Kafka.

**Production systems.** Debezium (open-source CDC connector), Kafka Connect with JDBC/CDC connectors, AWS DMS.

**Alternatives.** Dual-write from application code (risks inconsistency on partial failure); polling with updated_at timestamp (misses deletes, adds load).

## Backpressure and Dead-Letter Queues

**Definition.** Backpressure is a flow-control signal from a slow consumer to its upstream producer to slow emission; a dead-letter queue (DLQ) captures messages that repeatedly fail processing so they do not block the main queue.

**Canonical use.** A video transcoding worker signals backpressure via queue depth metrics to throttle upstream ingest, and routes messages that fail after 3 retries to a DLQ for manual inspection.

**Production systems.** AWS SQS DLQ, RabbitMQ dead-letter exchange, Kafka retry topics (Confluent pattern).

**Alternatives.** Dropping messages (acceptable for low-value telemetry); blocking the producer (simpler but risks cascade stall).

## Circuit Breaker, Bulkhead, Retry with Exponential Backoff and Jitter

**Definition.** A circuit breaker trips to fail-fast when a downstream service error rate exceeds a threshold; a bulkhead isolates thread/connection pools per dependency to prevent one slow dependency from starving all others; retry with exponential backoff and jitter spreads retry storms across time.

**Canonical use.** An API gateway wraps each microservice call in a circuit breaker so a degraded payment service returns a cached response instantly rather than holding connections until timeout.

**Production systems.** Netflix Hystrix (circuit breaker, now maintenance mode), Resilience4j, AWS SDK built-in retry with jitter.

**Alternatives.** Timeout-only (simpler, no fast-fail); service mesh (Envoy/Istio) handles these at the infrastructure layer without application code changes.

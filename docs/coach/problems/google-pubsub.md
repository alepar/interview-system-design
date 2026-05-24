---
slug: google-pubsub
archetype: infra-primitives
sources:
  sqs_visibility: docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
  pubsub_overview: docs.cloud.google.com/pubsub/docs/overview
  pubsub_exactly_once: docs.cloud.google.com/pubsub/docs/exactly-once-delivery
  sqs_dlq: docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
---

# Google Pub/Sub / AWS SQS+SNS (pub/sub fan-out service)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic queue: publisher writes to a topic, subscribers read; at-least-once delivery. May discuss SQS as "AWS message queue." Doesn't address fan-out scale, visibility timeouts, ack semantics, or push-vs-pull unprompted.
- **Senior (L5/E5):** Names fan-out (one publish → multiple subscribers). Articulates SQS-style per-subscription queues vs Kafka-style shared log with offsets. Discusses visibility timeouts as the lease-based redelivery mechanism. Knows about dead-letter queues at category level. May or may not differentiate push vs pull or address ordering.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **the architectural fork from Kafka**: SQS uses **per-subscription queues** (each subscription has its own backing store, allowing unbounded subscriber count); Kafka uses **shared log + per-consumer offsets** (subscriber count caps at partition count). For 1M subscribers/topic, only the per-subscription-queue model scales (storage cost grows linearly but is acceptable; consumer-group rebalance overhead doesn't apply because there's no shared resource to rebalance). Cites **SQS operational constants**: default visibility timeout 30s, max 12h; **~120,000 in-flight messages per queue** (standard and FIFO); this in-flight cap is the central operational constraint. Names **visibility timeout = lease pattern**: client `Receive`s message → message becomes invisible to other consumers for `visibility_timeout` seconds → client `Delete`s on success OR `ChangeMessageVisibility`-extends OR lets it expire (redelivered). Identifies the **lease-expiry-on-slow-consumer failure mode**: slow processing exceeds timeout → message re-delivered → duplicate processing → consumer must be idempotent. Articulates **push vs pull delivery semantics**: pull (SQS, Pub/Sub pull) = subscriber polls, natural backpressure; push (Pub/Sub push, SNS) = service POSTs to subscriber endpoint, requires HTTP retry + circuit breaker on subscriber failure. Names **FIFO vs Standard SQS trade-off**: FIFO maintains per-MessageGroupId order at ~O(10×) lower throughput than Standard (3K msgs/sec batched vs effectively unlimited); Pub/Sub uses **ordering keys** with per-key throughput cap of ~1 MB/s. Discusses **exactly-once delivery (Pub/Sub)** as opt-in per subscription with caveats: pull-only, higher latency, ack deadline 60s default, 600s max lease extension. Stretch (Sr Staff bar): articulates **SNS→SQS fan-out pattern** (SNS topic delivers each message to all subscribed SQS queues, each consumer has independent visibility timeout + DLQ); addresses the **DLQ poison-pill anti-pattern** (setting `maxReceiveCount=1` drops legitimate transient failures; production sweet spot is 3-5 for fast-failing, 10+ for tolerant retry).

## Canonical decomposition

### Requirements
**Functional:**
- One publisher publishes a message; many subscribers each receive a copy (unbounded fan-out target: 1M+ subscribers per topic)
- At-least-once delivery default; opt-in exactly-once (Pub/Sub) or FIFO-with-dedup (SQS FIFO)
- Per-subscription ack deadline / visibility timeout (consumer takes a lease while processing)
- Dead-letter queue for poison-pill messages (max-receive-count exceeded)
- Optional ordered delivery within a key (Pub/Sub ordering keys; SQS FIFO MessageGroupId; Kafka partition keys)
- Cross-region replication for disaster recovery

**Non-functional (with numbers):**
- 100K publishes/sec target; subscription count up to 10× publish rate (1M subscribers)
- Pub/Sub published SLA: 99.95% availability, sub-100ms publish latency p99
- SNS standard topic: ~100K publishes/sec/region default quota
- SQS visibility timeout: default 30s, min 0, max 12h
- SQS in-flight cap: ~120,000 messages per queue (standard and FIFO)
- SQS Standard: effectively unlimited throughput; FIFO: ~300 API calls/s un-batched, 3K msgs/s batched, 30K msgs/s in high-throughput mode
- Pub/Sub ordering keys: ~1 MB/s per ordering key cap
- Max message size: 256KB (SQS); 10MB (Pub/Sub)
- Max retention: 14 days (SQS); 7 days (Pub/Sub)

### Core entities
- **Topic / Exchange:** publisher endpoint; messages are written here
- **Subscription:** per-subscriber state + queue; subscribes to a topic; holds messages until acked (or visibility expires)
- **Message:** data + metadata (message_id, attributes, MessageGroupId for FIFO ordering, OrderingKey for Pub/Sub)
- **Lease / Visibility window:** the time after `Receive` during which the message is invisible to other consumers; renewable via `ChangeMessageVisibility`
- **Dead-letter queue (DLQ):** target queue for messages exceeding `maxReceiveCount`
- **MessageDeduplicationId (FIFO):** SHA-256 hash of content (or client-provided); 5-minute dedup window

### API
- Publisher: `Publish(topic, message, attributes, ordering_key?)` → message_id
- Subscriber (pull): `Receive(subscription, max_messages, visibility_timeout)` → list of messages; `Delete(receipt_handle)` to ack; `ChangeMessageVisibility(receipt_handle, new_timeout)` to extend lease
- Subscriber (push): subscriber registers an HTTPS endpoint; service POSTs messages with signature; subscriber returns 2xx to ack or non-2xx to fail (triggers retry)
- Admin: `CreateTopic`, `CreateSubscription`, `SetDeadLetterQueue(subscription, dlq, maxReceiveCount)`
- FIFO-specific: `MessageGroupId` field for ordering within a group; `MessageDeduplicationId` for dedup

### HLD
The architectural fork from Kafka: **per-subscription queue model** instead of **shared log + offsets**. Each subscription has its own backing store; when a message is published to a topic, it's copied into each subscription's queue. Consumers `Receive` from their subscription's queue; on success, they `Delete` the message; on failure (visibility expiry without Delete), the message is redelivered. This model scales fan-out trivially (adding a subscriber = creating a new subscription queue, no rebalance) but doubles storage per subscription. Kafka's offset model is storage-efficient (one copy of each message + per-consumer offsets) but caps consumer parallelism at partition count.

**SQS architecture** (inferred from public re:Invent talks): a distributed queue store with per-shard durability; messages are sharded across queue partitions; `Receive` consults partitions in parallel and returns up to N messages with receipt handles. The receipt handle is the lease — it carries an expiration time; on `Delete(receipt_handle)`, the message is permanently removed; on expiration without Delete, the message becomes visible again (with an incremented receive-count). The **120K in-flight cap** per queue is the operational ceiling: under slow-consumer scenarios, in-flight messages accumulate (received but not deleted, not yet expired) and at 120K, new Receives fail until in-flight count drops.

**Pub/Sub architecture**: similar per-subscription queue model but with different operational constants. Subscriptions can be **pull** (subscriber polls, similar to SQS) or **push** (Pub/Sub POSTs to subscriber's HTTPS endpoint with adaptive rate based on 2xx/5xx responses). Push enables serverless-style consumers (Cloud Run, Cloud Functions) that scale on demand. Pull supports exactly-once delivery (opt-in per subscription); push does not because of the at-least-once nature of HTTP retry semantics.

**Ordering**: by default, Pub/Sub and SQS Standard deliver out-of-order (maximizes parallelism). For per-key ordering: (a) **Pub/Sub ordering keys** — messages with the same ordering key route to the same subscriber instance in order; per-key throughput cap ~1 MB/s; (b) **SQS FIFO MessageGroupId** — same semantics, lower throughput than Standard (~3K msgs/s batched per queue, 30K msgs/s in high-throughput mode); (c) **Kafka partition key** — per-partition ordering, throughput scales with partition count. Per-key ordering vs no-ordering is a 10× throughput trade typically.

**SNS+SQS fan-out**: SNS topic delivers each message to all subscribed SQS queues (each consumer has independent visibility timeout, DLQ, retention). Adding a consumer = adding a queue + subscription, no producer change. At-least-once delivery to each queue. This is the AWS-canonical pub/sub-with-durable-consumer pattern.

### Deep dives
1. **The per-subscription queue model vs shared-log-with-offsets architectural fork.** Kafka stores one copy of each message + per-consumer offsets — storage efficient (1× of message size + N × offset_record_size where N = consumer count); but consumer parallelism caps at partition count (more consumers than partitions → idle consumers; rebalance required to redistribute partitions on consumer join/leave). For 1M subscribers/topic, Kafka's model breaks: 1M partitions per topic is operationally infeasible (each partition has metadata overhead, replication overhead, leader-election overhead). **SQS/Pub-Sub per-subscription queues**: each subscription has its own queue; messages copied on publish. Storage = N × message_size where N = subscription count; cost grows linearly but is acceptable at $0.40/GB-month (S3-ish) for retention windows of hours-to-days. **No rebalance**: adding/removing subscribers doesn't affect existing subscribers; per-subscription state is independent. For unbounded fan-out (notifications to mobile devices, webhook delivery to thousands of merchants), this is the only architecture that scales. Trade-off: storage cost; loss of "all subscribers see the same offset" property (replaying history for a new subscriber requires the topic to retain messages, which Pub/Sub doesn't do by default — once acked, gone). Staff+ commit: pick model with criteria for the workload (Kafka for ≤10K subscribers needing replay; Pub-Sub/SQS for 100K+ subscribers; hybrid for both).

2. **Visibility timeout as the lease pattern + the 120K in-flight cap.** SQS visibility timeout is the lease-based redelivery primitive. Default 30s, min 0, max 12h. On `Receive(visibility_timeout=N)`, the message is invisible to other consumers for N seconds; the consumer must Delete or `ChangeMessageVisibility` before expiration to prevent redelivery. The consumer can extend incrementally via heartbeat. The **120K in-flight cap** per queue (~120K messages received-but-not-deleted simultaneously) is the operational ceiling. Slow consumer scenario: consumers receive faster than they delete; in-flight grows; at 120K, new Receives fail (HTTP 429 / quota exceeded); throughput collapses. Production answer: monitor in-flight count as a SLI; auto-scale consumer pool aggressively; tune visibility timeout to match p99 processing latency (too short causes premature redelivery + duplicates; too long causes slow recovery from failed consumers); DLQ on max-receive-count to drain stuck messages off the main queue. Anti-pattern: too-long visibility timeout (e.g., 12h) means a crashed consumer's messages stay invisible for 12h before redelivery — too slow for any real production. Staff+ commit: visibility-timeout policy, in-flight monitoring, auto-scaling triggers, DLQ thresholds.

3. **Push vs pull delivery and the backpressure semantics.** **Pull** (SQS, Pub/Sub pull): subscriber polls; subscriber controls rate; slow subscriber just polls less; broker never overruns it. Natural backpressure. Latency: poll-interval-bound (e.g., 1s poll → 1s minimum delivery latency). **Push** (Pub/Sub push, HTTP webhook from SNS): broker POSTs to subscriber's HTTPS endpoint with adaptive rate based on 2xx/5xx responses; lower latency (broker pushes immediately on publish) but subscriber backpressure is harder (broker must detect overload via 5xx + slow ack and rate-limit; subscriber must be capable of HTTP 429 / Retry-After). Pub/Sub push has built-in adaptive flow control (broker increases push rate on consistent 2xx, decreases on 5xx). **Exactly-once delivery** in Pub/Sub is **pull-only** because exactly-once requires the broker to know the subscriber's success state authoritatively; HTTP push has at-least-once semantics due to network-failure retries. Pull subscriber can use ack IDs that change on each redelivery → broker validates ack against latest ID → duplicate suppression. Trade: pull is simpler operationally but has poll-interval latency; push is lower-latency but requires subscriber-side HTTP infrastructure + retries + idempotency. Staff+ commit: pick model with criteria (high-throughput sustained consumption + EOS needed → pull; serverless / event-driven with low latency → push; mixed → both via separate subscriptions on the same topic).

## Known failure modes
1. **In-flight ceiling reached under slow consumers.** Consumers receive messages faster than they delete; in-flight count grows toward 120K; new Receives fail. Production answer: aggressive auto-scaling of consumer pool (CloudWatch alarm on `ApproximateNumberOfMessagesNotVisible` triggers scale-out); per-message processing time SLI; DLQ to drain consistently-failing messages off the main queue; in extreme cases, replicate the queue (publish to 2 queues, consume from both — accept duplicate processing in exchange for 2× in-flight capacity).

2. **Lease theft / split-brain on visibility-timeout expiry.** Consumer's lease expires (slow processing or network blip); broker redelivers to another consumer; original consumer completes processing + Deletes → message Deleted but two consumers processed it (duplicate effect). Production answer: idempotent consumer (use message_id as dedup key in downstream system); fencing token (some systems support monotonic per-message receive-count → consumer validates token before writing); for FIFO with MessageDeduplicationId, broker dedups at publish — but visibility-timeout duplicates aren't covered by that.

3. **Subscriber back-pressure not propagated in push mode.** Push subscriber is overwhelmed; returns 5xx; broker retries with exponential backoff. If subscriber doesn't reduce its accept rate, the retry loop continues; if subscriber crashes entirely, messages accumulate at broker → eventually DLQ or retention drops them. Production answer: subscriber returns HTTP 429 with Retry-After header (broker honors it); Pub/Sub adaptive push rate control automatically reduces push rate on consistent 5xx; circuit breaker at subscriber that returns 5xx during outages.

## Notes for the coach
- **This is plausibly-asked at AWS / Google / Stripe infra rounds** based on the public architecture surface (AWS re:Invent SQS talks, Google Pub/Sub engineering blog). Discriminated from Kafka by the fan-out scale; this is the right framing if the candidate steers a "design WhatsApp delivery" or "design notifications service" prompt during the Kafka problem.
- **The 120K in-flight cap is the concrete operational constant** every Staff+ candidate should know about SQS — surfacing it grounds the problem in production reality. Cite the AWS docs reference.
- **The Kafka-vs-pub/sub architectural fork is the L7 discrimination probe.** A candidate who treats this as "just another message queue" without articulating why per-subscription-queue model exists is missing the central design pressure.
- **Exactly-once-delivery as opt-in pull-only is the EOS-honesty signal.** Most candidates claim "exactly-once delivery" naively; the Sr Staff candidate articulates that Pub/Sub's EOS is opt-in, pull-only, with substantial latency cost.
- **The push-vs-pull semantics affects subscriber architecture choice.** Push for serverless / event-driven; pull for high-throughput sustained / batched processing. Naming both with criteria is the Staff+ depth.
- **No direct AI-infra counterpart** — the AI-infra `inference-batching` queue uses iteration-level scheduling rather than durable per-subscription state, so the mapping is loose. The pub/sub primitive is generic.
- **Cross-coverage:** sits adjacent to `kafka` (the alternative architecture for messaging), `stripe-payments` (uses pub/sub for webhook delivery — the outbox-to-Kafka or outbox-to-SQS pattern is the canonical pub/sub use case for transactional consistency). When other problems mention "fan-out delivery" or "webhook delivery," this is the substrate.
- **Don't allow drift into "design WhatsApp" or "design notifications" — stay on the pub/sub primitive shape.** Application-layer concerns (presence, group membership, mobile push notifications) are separate problems; this question is about the underlying durable-pub-sub primitive.

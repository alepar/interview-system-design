---
slug: ad-click-aggregator
archetype: ml-in-loop
sources:
  bytebytego_vol2: bytebytego.com (Vol 2 Chapter 6: Ad Click Event Aggregation)
  hello_interview_ad: hellointerview.com/learn/system-design/problem-breakdowns/ad-click-aggregator
  arena_hard_auto: arxiv.org/abs/2406.11939
  flink_exactly_once: flink.apache.org/2018/02/28/an-overview-of-end-to-end-exactly-once-processing-in-apache-flink-with-apache-kafka-too.html
---

# Google AdSense / YouTube ads ad-click aggregator (distributed counter + streaming-batch reconciliation)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic counter: increment per click in a DB. May discuss caching aggregates. Doesn't address dedup, late events, lambda-vs-kappa, or billing-grade correctness unprompted.
- **Senior (L5/E5):** Names a streaming aggregation pipeline (Kafka + Flink/Spark Streaming + DB). Articulates dedup via event_id at category level. Discusses time windows (1-minute, 1-hour aggregates). May or may not surface watermarks, lambda-vs-kappa architectures, or the streaming↔batch reconciliation pattern explicitly.
- **Staff+ (L6/E6+):** Drives proactively. Articulates the **lambda vs kappa architectural fork**: lambda runs streaming (fast, approximate) + batch (slow, authoritative) pipelines in parallel and reconciles periodically; kappa runs only streaming with replay-from-Kafka for backfill. Trade: lambda is more expensive (two pipelines, two code paths to maintain) but gives clear separation between real-time visibility and billing-grade accuracy; kappa is simpler but requires the streaming pipeline to be billing-accurate, which is harder. Names **watermarks for late events** explicitly: watermark = "we believe no events older than this will arrive"; window closes at watermark; late events go to side-output or update an already-closed window (Flink's allowed_lateness pattern). Trade: tight watermark = faster visibility but more late-event drops; loose watermark = slower visibility but more inclusive. Articulates **deduplication via event_id with bounded state**: each click has a unique event_id; dedup state holds seen IDs for a window (Bloom filter for memory efficiency at the cost of false positives; exact set for billing-grade); state must be checkpointed (Flink checkpoint barrier — Chandy-Lamport variant) for fault tolerance. Names the **billing-grade vs real-time speed trade-off**: advertisers see real-time counts (best-effort streaming, includes late stragglers within hours); bills based on **reconciled offline counts** (daily batch authoritative); discrepancy is documented + observable. Cites **Arena-Hard-Auto** (Li et al. 2024) for the related LLM-judge cost benchmark ($25 for 500 prompts at 89.1% human-agreement) — same streaming-vs-batch pattern reappears in LLM-as-judge eval pipelines. Stretch (Sr Staff bar): articulates **canary strings + n-gram overlap detection** for fraud/contamination (ad-click context); names **Flink's TwoPhaseCommitSinkFunction** for end-to-end exactly-once when sinking to external store.

## Canonical decomposition

### Requirements
**Functional:**
- Ingest ad-click events at high throughput (billions of events/day)
- Real-time aggregation: per-advertiser, per-campaign, per-creative click counts visible within seconds
- Billing-grade authoritative aggregation: reconciled against fraud detection + late events + retries; published daily
- Dedup: same click event_id appearing multiple times (network retries, double-tap from user) counted once
- Late event handling: clicks arriving minutes-to-hours after their event-time still counted (within a budget)
- Fraud detection integration: bot-clicks identified and removed from billing counts

**Non-functional (with numbers):**
- Google AdSense scale: billions of clicks/day
- Sub-second real-time visibility for advertisers (best-effort)
- Daily-batch billing-grade accuracy (Hello Interview canonical target)
- Dedup window: 24h-class (event_id seen within 24h = duplicate; older = treated as unique for billing)
- Watermark policy: tight watermark (~5 min) for real-time; allowed_lateness 24h for billing pipeline
- 99.9% dedup accuracy on real-time pipeline; 100% on batch reconciliation
- Cost: LLM-judge analog (Arena-Hard-Auto: $25 for 500 prompts at 89.1% human-agreement) — illustrative of the cost-vs-accuracy trade

### Core entities
- **Click event:** (event_id, advertiser_id, campaign_id, creative_id, user_id?, timestamp, click_context)
- **Aggregate:** (advertiser_id, campaign_id, creative_id, time_window) → click_count
- **Watermark:** monotonically-advancing timestamp; defines "no more events older than this should be expected"
- **Dedup state:** per-window set of seen event_ids (Bloom filter for cheap; exact set for billing); checkpointed for fault tolerance
- **Lambda pipeline:** streaming (Flink) + batch (Spark on S3 logs); reconciliation joins them periodically
- **Outbox / dead-letter:** events that fail dedup or arrive past allowed_lateness; manual review queue

### API
- Ingestion: clients POST clicks to the ingest API (or via Pub/Sub topic); idempotent on event_id
- Real-time read: `GET /aggregates?advertiser=X&window=last_5min` → approximate count
- Billing read: `GET /billable_aggregates?advertiser=X&day=2026-05-24` → authoritative count (published daily)
- Admin: `POST /reprocess?day=X` → manual re-reconciliation if a discrepancy is found

### HLD
**Ingestion path**: clicks arrive at the ingest API → published to **Kafka** (durable log, partition by advertiser_id for ordering within a campaign). The streaming layer (Flink) consumes from Kafka. Two parallel paths:

**1. Real-time streaming aggregation (the "speed layer" of lambda)**: Flink job reads from Kafka; dedups by event_id (Bloom filter + small exact set for recent events); windowing by event-time (typically 1-min and 5-min windows); writes aggregates to a fast KV store (Redis / Cassandra). Watermark advances based on max-observed event-time minus a small fixed delay (~5 min); window closes at watermark; aggregates published. Late events (arriving past watermark) go to a side-output for later reconciliation. Real-time aggregates are visible to advertisers within seconds.

**2. Batch billing-grade aggregation (the "batch layer" of lambda)**: Kafka topic is also persisted to S3 (Kafka tiered storage or a parallel sink job). Daily Spark batch job reads the day's S3 logs; runs fraud detection (bot-click identification via signal modeling); dedups with full exact state (no Bloom filter — exactness matters for billing); aggregates by (advertiser, campaign, day); writes the authoritative counts to a billing database. Late events from previous days are included (up to allowed_lateness, typically 7 days).

**3. Reconciliation pipeline**: daily job compares streaming-pipeline counts with batch-pipeline counts; produces a delta report per advertiser; if delta exceeds threshold (e.g., 1%), alerts ops + opens an investigation case. Common delta sources: late events (counted in batch but missed in streaming due to tight watermark), fraud-filtered events (counted in streaming but removed in batch), Bloom-filter false positives (counted as duplicates in streaming, included in batch).

**Exactly-once semantics**: Flink's checkpoint mechanism (Chandy-Lamport variant) gives operator-level exactly-once; combined with **Flink's TwoPhaseCommitSinkFunction** to external sinks (Cassandra, S3, Postgres), achieves end-to-end exactly-once for the streaming path. The catch: latency floor = checkpoint interval (typically 1-10s); not free.

**Dedup via event_id**: each click carries a unique event_id (generated client-side at first emit). Dedup state holds seen IDs for the dedup window (typically 24h). Bloom filter for cheap "probably seen" check; exact set for "seen in the last N seconds" (fast hot path). Checkpoint includes the dedup state so a Flink failure + restart doesn't lose dedup memory.

### Deep dives
1. **Lambda vs kappa architecture, with the real-time-vs-billing-accuracy trade.** **Lambda**: streaming (fast, approximate) + batch (slow, authoritative) run in parallel; reconciliation joins them periodically. Pros: clear separation between user-visible real-time and billing-authoritative; failures in streaming pipeline don't affect billing; batch pipeline can use slower/cheaper compute. Cons: two pipelines = two codebases, two operational concerns, two failure modes; potential drift between the two implementations causing reconciliation surprises. **Kappa**: only streaming, with replay-from-Kafka for backfill / reprocessing. Pros: one codebase; one operational concern. Cons: streaming pipeline must be billing-accurate (harder; requires exactly-once semantics + watermark policies that don't drop billable events); reprocessing requires replaying gigabytes of Kafka history with the new code (expensive if the change is in the aggregation logic). For ad-billing systems, **lambda is the production sweet spot** — the cost of running both pipelines is justified by the clear separation between real-time visibility (where 1% inaccuracy is fine) and billing (where exactness is contractual). Twitter, LinkedIn, and most ad platforms run lambda. Some modern systems (Materialize, Flink with re-keying) are moving toward kappa for simpler ops. Staff+ commit: pick architecture with criteria; address what happens when the two pipelines drift (alerting, investigation playbook).

2. **Watermarks and late events.** Event-time vs processing-time: a click that occurred at T=10:00:00 might arrive at the broker at T=10:05:00 (delayed by client retries, network blips, mobile-device offline-then-online). Aggregating by **event-time** is what advertisers care about (clicks attributed to when they happened, not when they arrived); aggregating by **processing-time** is simpler but produces drift. Watermark = "we believe no more events with event-time < W will arrive" — heuristic decision based on max-observed event-time minus a delay (e.g., max_event_time - 5min). When watermark advances past window end, the window closes; output is finalized. **Late events** (arriving after watermark passes their window): go to side-output (Flink's "allowed_lateness" pattern updates already-closed windows with the late event; output is republished). Trade-off: tight watermark = fast visibility but drops more late events; loose watermark = slow visibility but more inclusive. For ad-click: tight (~5 min) for real-time visibility; loose (24h-7d allowed_lateness) for billing reconciliation. Staff+ commit: watermark policy, allowed_lateness budget, what happens to events arriving past allowed_lateness (drop or DLQ for manual review).

3. **Deduplication via event_id with bounded state.** Each click has a unique event_id (client-generated UUID at first emit; carried through retries). Dedup state = set of seen event_ids; check on every event; if seen, drop. **Bloom filter** for memory efficiency: probabilistic "probably seen"; false positives possible (might drop a legitimate event as duplicate, undercounting); false negatives impossible. **Exact set** for billing-grade: stores all seen IDs; memory grows linearly with seen events. Hybrid: Bloom filter for the hot recent window (fast, cheap, OK for real-time pipeline where 0.1% false positive is acceptable) + exact set in batch reconciliation (no false positives, slower but billing-correct). State must be **checkpointed** for fault tolerance: Flink's checkpoint barrier captures dedup state atomically with the rest of the operator state; on restart, dedup memory restored. **Bounded state**: dedup window = 24h typically; older IDs aged out (assumption: a duplicate retry won't arrive >24h after the original). Anti-pattern: unbounded dedup state grows forever; eventually OOMs the operator. Staff+ commit: window duration, Bloom filter false-positive rate target (e.g., 0.1% — calibrated so that real-time count is within tolerance), what happens at window boundary (events near the boundary might be seen as "new" if their original was just aged out — a deliberate trade for bounded state).

## Known failure modes
1. **Watermark advances past late events → lost billing revenue or over-counted clicks.** Tight watermark drops late events from the window; billing for that window is final; later-arriving events go to DLQ. Production answer: side-output for late events with manual review queue; periodic reconciliation against authoritative batch pipeline (which uses allowed_lateness 24h-7d); alert on late-event rate exceeding threshold; for high-value advertisers, configurable per-advertiser allowed_lateness.

2. **Dedup state explosion.** Window too long (e.g., 30d), seen-event-id set grows unboundedly; checkpoint times grow; eventual OOM. Production answer: tight window (24h default; up to 7d for high-priority); downstream idempotency (the destination KV / billing DB is keyed by event_id, so even if dedup misses, the destination dedups); periodic state compaction; tiered state (recent in memory, older on disk).

3. **Streaming/batch reconciliation surfaces large divergence.** Advertisers see "5000 clicks" real-time but "4700 billable" after reconciliation — they question the difference. Production answer: surface both numbers transparently in advertiser dashboards; document the divergence reasons (bot detection in batch, late dedup, refund for invalid clicks); per-advertiser dashboards with drill-down to specific events removed; SLA on the maximum acceptable drift (e.g., <2% typical, alerts on >5%).

## Notes for the coach
- **This is asked-confirmed at Google AdSense per Hello Interview tag** ("Design an Ad Click Aggregator"); ByteByteGo Vol 2 Ch 6 covers it; reported at Google, Meta, Amazon Staff/Principal rounds per SystemDesignHandbook.
- **The lambda-vs-kappa trade is the L7 architectural flex.** Most candidates default to kappa as "the modern approach"; the Staff+ candidate articulates lambda as the production answer for billing-grade systems and the kappa case for non-billing analytics.
- **Watermarks + allowed_lateness is the streaming-systems-literacy signal.** A candidate proposing a fixed-window aggregator without articulating watermarks is at Senior; the Staff+ candidate names them with explicit trade-offs.
- **The billing-vs-real-time separation is the production-grade move.** Most candidates collapse them into one pipeline; the Sr Staff candidate articulates why they should be separate (correctness budget differs) and how reconciliation works.
- **Cross-coverage with AI-infra `eval-pipeline-at-scale`:** the AI version uses similar streaming-vs-batch reconciliation for LLM-as-judge eval (Arena-Hard-Auto $25 per 500 prompts at 89.1% agreement). The pattern transfers; the substrate is different.
- **No direct standalone counter primitive** — this problem subsumes "distributed counter" via the streaming aggregation pipeline. If the candidate proposes a simple atomic counter, redirect: "what about dedup + late events + billing accuracy?"
- **Don't allow drift into "design fraud detection" or "design ad auction" — stay on the aggregation pipeline.** Fraud detection is a separate ML pipeline that filters input; ad auction is a separate problem entirely (real-time bidding). This problem is about the counter/aggregator substrate.

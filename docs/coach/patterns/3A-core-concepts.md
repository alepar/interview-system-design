# Core Concepts

Pattern reference for `/study-patterns 3A`. Each entry: definition (1 sentence) + canonical use (1 sentence) + 1–2 named production systems + 1–2 alternatives.

Source: `staff-engineer-study-guide.md` §3A.

## Scalability

**Definition.** The ability of a system to handle growing load by adding resources, either vertically (bigger machines) or horizontally (more stateless instances).

**Canonical use.** Stateless web-tier services are scaled horizontally behind a load balancer so each node is interchangeable and no session state blocks scale-out.

**Production systems.** AWS EC2 Auto Scaling Groups, Google Cloud Run.

**Alternatives.** Vertical scaling (simpler, has hard ceiling); database read replicas for read-heavy load.

## CAP Theorem and PACELC

**Definition.** CAP states a distributed system can guarantee at most two of Consistency, Availability, and Partition Tolerance; PACELC extends this by specifying the latency vs consistency trade-off even when no partition exists.

**Canonical use.** Choose between CP (strong consistency, e.g., banking ledger) and AP (high availability, e.g., shopping cart) at design time based on which failures are more tolerable.

**Production systems.** HBase (CP), Cassandra (AP/eventual by default), DynamoDB (configurable).

**Alternatives.** Tunable consistency (Cassandra quorum reads), CRDT-based eventual consistency for conflict-free merges.

## Latency vs Throughput vs Bandwidth

**Definition.** Latency is time to complete one request; throughput is requests completed per unit time; bandwidth is the raw data capacity of a channel.

**Canonical use.** A real-time chat system optimizes for low latency; a batch analytics pipeline optimizes for throughput even at the cost of higher per-request latency.

**Production systems.** Redis (sub-millisecond latency), Apache Kafka (high throughput).

**Alternatives.** Asynchronous processing trades latency for throughput; streaming reduces bandwidth vs full-scan batch jobs.

## SPOF and Fault Tolerance

**Definition.** A Single Point of Failure (SPOF) is any component whose failure brings down the entire system; fault tolerance is the design property that eliminates SPOFs via redundancy and graceful degradation.

**Canonical use.** Eliminate SPOFs by deploying at least two instances of each critical component (load balancer, database primary, message broker) with automatic failover.

**Production systems.** AWS RDS Multi-AZ, HAProxy with keepalived.

**Alternatives.** Active-passive failover (simpler, wastes standby capacity); active-active multi-master (higher complexity, better utilization).

## Numbers to Know (Jeff Dean's Latency Table)

**Definition.** A set of order-of-magnitude latency benchmarks every engineer should internalize: ~250 µs to read 1 MB from RAM, ~1 ms from SSD, ~20 ms from spinning disk, ~50–150 ms cross-datacenter RTT, ~500 µs for a mutex lock/unlock.

**Canonical use.** Use these numbers during back-of-envelope estimation to sanity-check whether a design can meet its latency SLOs before committing to an architecture.

**Production systems.** Referenced universally; codified in Google's internal "numbers every engineer should know" document.

**Alternatives.** No substitute for memorizing these; rough powers-of-ten estimates (ns/µs/ms/s) are the minimum viable version.

## Back-of-Envelope Estimation

**Definition.** A rapid calculation combining traffic, storage, and bandwidth numbers to derive whether a proposed design is feasible at the required scale.

**Canonical use.** Estimate QPS = DAU × requests/day / 86,400, storage = write rate × record size × retention, and cache size = hot data fraction × total data, before choosing technologies.

**Production systems.** Standard practice at Google, Meta, and Amazon design interviews; codified in Alex Xu's *System Design Interview* Vol. 1, Ch. 2.

**Alternatives.** Full capacity planning tools (cloud cost calculators) for production; order-of-magnitude mental math suffices in interviews.

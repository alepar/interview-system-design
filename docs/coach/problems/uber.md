---
slug: uber
archetype: geo-proximity
sources:
  hello_interview: hellointerview.com/learn/system-design/problem-breakdowns/uber
---

# Uber (Ride-Sharing Dispatch)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic dispatch design: drivers report GPS location periodically, a rider requests a ride, the server finds nearby drivers by distance and assigns the closest one. Defines core endpoints (request ride, update location), picks a relational store for rides. Does not need to name a specific geo index or discuss real-time update throughput unprompted.
- **Senior (L5/E5):** Names a geo index (H3 hexagonal grid or geohash) and explains why naive lat/lng range queries don't scale. Discusses real-time location update throughput (~250K writes/sec), the matching algorithm (nearest-K filter then ranking by ETA + acceptance probability), and the driver state machine (offline → idle → matched → en_route → in_progress). Identifies the WebSocket requirement for low-latency driver communication and justifies Kafka for the location update pipeline.
- **Staff+ (L6/E6+):** Drives the session proactively. Raises surge pricing as a distinct subsystem (supply/demand ratio per H3 cell, separate pricing service). Discusses batched matching every 2s to reduce churn when supply is sparse. Addresses driver crossing a region boundary mid-ride (cross-region state handover). Quantifies WebSocket connection cost at scale (10M concurrent connections × memory per connection). Proposes a lossy location update strategy for idle drivers to reduce write amplification, and defines a driver-missing-from-pool SLO (TTL before eviction from geo index).

## Canonical decomposition

### Requirements
**Functional:**
- Rider requests a ride (pickup + dropoff)
- Fare estimate and ETA before confirmation
- Driver receives match offer and accepts/declines
- Real-time location tracking for both rider and driver during the ride
- Payment processing on ride completion

**Non-functional (with numbers):**
- 10M concurrent drivers worldwide
- 250,000 location writes/sec at peak (drivers update every ~4s; 10M / 4s = 2.5M/sec globally, ~250K/sec per major region)
- Ride-match latency <2s from request to driver offer delivered
- 99.99% availability for the matching path (revenue-critical)
- Location data freshness: driver position must be ≤8s stale for active matches
- Ride history retention: 7 years (regulatory)

### Core entities
- **Rider:** rider_id, name, payment_method_id, rating
- **Driver:** driver_id, name, vehicle_info, status (offline|idle|matched|en_route|in_progress), current_h3_cell, last_location_ts, rating
- **Ride:** ride_id, rider_id, driver_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, fare_cents, created_at, completed_at
- **LocationUpdate:** driver_id, lat, lng, h3_cell, ts (ephemeral; not persisted long-term)

### API
- WebSocket `driver → server`: `{type: "location", lat, lng, ts}` (every 4s while online)
- WebSocket `server → driver`: `{type: "offer", ride_id, pickup_lat, pickup_lng, rider_name, estimated_fare}` + accept/decline response
- `POST /rides` body={pickup_lat, pickup_lng, dropoff_lat, dropoff_lng} → {ride_id, eta_seconds, estimated_fare_cents}
- `GET /rides/:id` → {ride_id, status, driver_location?, eta_seconds}
- WebSocket `server → rider`: `{type: "location_update", lat, lng}` (driver position during ride)
- `POST /rides/:id/complete` body={actual_distance_km} → {final_fare_cents}

### HLD
The driver location update path starts at a WebSocket Gateway (stateful, one connection per driver). Each incoming location frame is forwarded to a Kafka topic `driver-locations` partitioned by H3 cell (resolution 7, ~5km² cells). A Location Indexer service consumes from Kafka and maintains an in-memory geo index per region: a hash map of H3 cell → list of (driver_id, lat, lng, ts). This index is also mirrored into Redis Geo (GEOADD keyed by H3 resolution-5 parent cell) for cross-instance queries and persistence across restarts. Idle drivers' updates are rate-limited to one write per 8s if they haven't moved more than 10 meters, reducing write amplification by ~50%.

The ride request path hits the Matching Service: on `POST /rides`, it resolves the pickup coordinates to an H3 cell, queries the geo index for all idle drivers in the cell and its 6 neighbors (k-ring 1), ranks them by estimated ETA (routing API call, parallelized, bounded at 100ms) and historical driver acceptance probability (stored in Redis per driver_id), then pushes an offer to the top-ranked driver via the WebSocket Gateway. If the driver declines or doesn't respond within 10s, the offer falls through to the next candidate. The ride state machine transitions are persisted in a ScyllaDB (Cassandra-compatible) table keyed by ride_id, enabling fast status lookups and append-only audit history.

Fare estimation runs at request time: the Pricing Service computes base fare from routing distance + duration, then applies a surge multiplier derived from the real-time supply/demand ratio for the pickup H3 cell (computed every 30s and cached in Redis). Payment is processed asynchronously on ride completion via a Payment Service that calls Stripe/Braintree and writes the result to Postgres (financial ledger, separate from operational data).

All stateless services (Matching, Pricing, Ride Status) are horizontally scaled behind an AWS ALB. The WebSocket Gateway is horizontally scaled with sticky routing: a consistent-hash ring maps driver_id to a specific gateway pod, so offer pushes from the Matching Service route to the correct pod via an internal gRPC call.

### Deep dives
1. **Geo indexing — H3 vs geohash vs S2** — Geohash encodes lat/lng into a base-32 string; prefix queries give nearby cells but cells are rectangular, causing uneven coverage near poles and non-uniform neighbor relationships. S2 (Google) uses spherical geometry with square cells and is accurate but complex. H3 (Uber's open-source hex grid) uses hexagonal cells which have equal distance to all 6 neighbors (no diagonal-vs-edge asymmetry), uniform area at each resolution, and clean k-ring neighbor expansion. H3 resolution 8 (~0.7 km² cells) is appropriate for dense urban matching; resolution 9 (~0.1 km²) for dense city centers. Cross-cell search uses H3's k-ring(cell, 1) to check the 7 cells around the pickup point, expanding to k-ring(2) if no idle drivers are found.
2. **Location update path at 250K writes/sec** — 10M drivers updating every 4s gives 2.5M writes/sec globally; with regional sharding, a single large region handles ~250K/sec. Each WebSocket gateway pod batches incoming frames and publishes to Kafka in micro-batches (10ms window), giving ~400 Kafka messages/sec per pod instead of 40K. The Location Indexer maintains the in-memory H3 map and updates Redis Geo asynchronously. Idle drivers (no movement >10m) skip the Redis write; only the in-memory index is updated to preserve freshness for matching without burning Redis write throughput. WebSocket connections consume ~50KB RAM each; 10M connections require ~500 GB across the gateway fleet, necessitating connection-aware pod sizing.
3. **Batched matching for low-supply markets** — Matching drivers one-at-a-time (first request wins) causes thrashing: when only 2 drivers serve 10 simultaneous requests, 8 requests get serially declined and latency spikes. Batched matching collects all outstanding ride requests for a cell every 2s and solves an assignment problem (Hungarian algorithm or greedy nearest-neighbor) to maximize total acceptance probability across the batch. This reduces average match latency by 30–40% at low supply. The batch window (2s) is configurable per market and disabled in high-supply scenarios where immediate matching is faster.

## Known failure modes
1. **Driver WebSocket disconnect (phone backgrounded or network drop)** — The gateway detects the TCP closure and marks the driver's connection as gone. The Location Indexer retains the last-known location with a 30s TTL; if no reconnect arrives, the driver is evicted from the idle pool and removed from the geo index. During the 30s window, the driver is considered unavailable for new matches but an in-progress ride's state is unaffected (managed by ride state machine in ScyllaDB). On reconnect, the driver re-registers their location and status, re-entering the idle pool within one update cycle (4s).
2. **Match-but-driver-declines or no-response** — After delivering an offer via WebSocket, the Matching Service starts a 10s acceptance timer. On timeout or explicit decline, the ride falls through to the next-ranked driver candidate. If all candidates in the initial k-ring are exhausted, the search expands to k-ring(2) and retries. After 60s total without a match, the ride request times out and the rider receives a "no drivers available" response. Declined offers are logged to feed driver acceptance-probability scores, improving future ranking.
3. **Driver crosses a region boundary mid-ride** — Rides that originate in Region A but complete in Region B require cross-region access to the ride state. The ride record in ScyllaDB is written to the origin region's primary and replicated asynchronously to all regions (Cassandra multi-region replication, typically <500ms lag). The region that owns the ride_id at creation time remains the "leader" for all state transitions; the driver's location updates in Region B are routed back to Region A's WebSocket gateway via an internal cross-region gRPC call for the duration of the ride. On handover edge cases (network partition at boundary), the ride state is recovered from ScyllaDB by either region on reconnect; the last-writer-wins conflict resolution is safe here because ride state transitions are monotonically forward (you can't go from `completed` back to `in_progress`).

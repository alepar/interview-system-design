# Load Balancing

Source: `staff-engineer-study-guide.md`.

## L4 vs L7 Load Balancers

**Definition.** L4 load balancers route based on transport-layer info (IP, TCP port) without inspecting payload; L7 load balancers inspect HTTP headers, cookies, and paths to make routing decisions.

**Canonical use.** Use L4 for raw TCP throughput (database proxies, game servers) where payload parsing overhead is unacceptable; use L7 for HTTP microservices where routing by URL path or header is needed.

**Production systems.** AWS Network Load Balancer (L4), AWS Application Load Balancer / Nginx / HAProxy (L7).

**Alternatives.** DNS-based load balancing (no single LB component, but limited to coarse-grained routing); anycast routing for geographic distribution without a central LB.

## Load-Balancing Algorithms

**Definition.** The algorithm determines which backend receives each request: round-robin cycles evenly, weighted RR accounts for heterogeneous capacity, least-connections routes to the least-busy server, least-response-time factors in observed latency, IP hash pins a client to a server by hashing the source IP, and consistent hash minimizes remapping when the server set changes.

**Canonical use.** Use consistent hashing when backends are stateful caches (Memcached, Redis cluster) so that adding or removing a node reshuffles only 1/N keys instead of all; use least-connections for backends with highly variable request duration.

**Production systems.** Nginx (round-robin, least-connections, IP hash), HAProxy (least-connections, consistent-hash), AWS ALB (round-robin, least-outstanding-requests).

**Alternatives.** Random selection (surprisingly effective with many backends); power-of-two-choices (pick 2 at random, send to the less loaded one) for low-overhead approximation of least-connections.

## Anycast Routing, GeoDNS, and Latency-Based Routing

**Definition.** Anycast announces the same IP prefix from multiple PoPs so BGP routes each user to the topologically nearest one; GeoDNS returns different A records based on the resolver's geographic region; latency-based routing (AWS Route 53) measures actual RTT and directs traffic to the lowest-latency endpoint.

**Canonical use.** Use anycast for DDoS absorption and global DNS resolution (traffic is automatically absorbed at the nearest PoP and doesn't transit to origin); use latency-based DNS for multi-region app deployments where you want active-active with per-region affinity.

**Production systems.** Cloudflare (anycast), AWS Route 53 (GeoDNS + latency-based), Google Cloud DNS.

**Alternatives.** Client-side geo detection with redirect (adds a round-trip); global load balancers (GCP GCLB, AWS Global Accelerator) that use proprietary backbone routing instead of public BGP.

## Sticky Sessions

**Definition.** Sticky sessions (session affinity) force all requests from a given client to be routed to the same backend server, typically via a cookie or IP hash, to preserve in-process or in-memory session state.

**Canonical use.** Use sticky sessions only when migrating a legacy stateful app that cannot be refactored, and pair with session replication or an external session store so that a server failure doesn't lose the session.

**Production systems.** AWS ALB sticky sessions (duration-based cookies), Nginx `ip_hash`.

**Alternatives.** Externalize session state to Redis or a DB so any backend can serve any request (preferred stateless design); JWT-based tokens carry state client-side, eliminating server-side session entirely.

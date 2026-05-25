---
slug: online-auction
archetype: concurrent-resource
sources:
  auction_techinterview: techinterview.org/post/3233462610/system-design-auction-system/
  ebay_autobid: ebay.com/help/buying/bidding/automatic-bidding?id=4014
  sd_handbook_auction: systemdesignhandbook.com/guides/design-online-auction/
  ockenfels_roth: cramton.umd.edu/market-design-papers/ockenfels-roth-late-bidding.pdf
  hi_online_auction: hellointerview.com/learn/system-design/problem-breakdowns/online-auction
---

# Online Auction (concurrent bidding, eBay-style)

## Bar anchors
- **Mid-level (L4/E4):** Stores a current_bid and updates it when a higher bid arrives. Doesn't address two bids arriving at once (lost update), proxy bidding, or last-second sniping.
- **Senior (L5/E5):** Serializes concurrent bids and only accepts a bid above the current max; uses a transaction. Knows reads (watchers) vastly outnumber writes (bids) and caches the current price. May not articulate OCC compare-and-set precisely, proxy/auto-bidding, soft-close anti-snipe, or the read/write path split.
- **Staff+ (L6/E6+):** Drives proactively. Resolves concurrent bids with **optimistic concurrency control**: an atomic conditional update `UPDATE auctions SET current_bid=?, version=version+1 WHERE id=? AND version=? AND current_bid<?` — exactly one concurrent bid wins, others get "outbid" and resubmit (no expensive row lock, no lost update). Implements **proxy/automatic bidding** (store the bidder's secret max; auto-increment the current bid by the minimum increment to keep them winning until their max is exceeded — all in a transaction; ties go to the earliest bidder). Adds **soft-close / anti-snipe** (a bid in the final window extends the end time, repeating until quiet) and contrasts with eBay's hard close (allows sniping — empirically heavy on eBay, light on auto-extend Amazon). Splits the **read path** (millions of watchers, current bid cached with ~1s TTL, aggressive caching) from the **write path** (few bidders, strict consistency). For very hot auctions, a **Redis atomic counter + Lua** check-and-update avoids row locks. Targets effectively-once settlement via idempotency keys.

## Canonical decomposition

### Requirements
**Functional:**
- Accept bids; the highest valid bid wins at close; concurrent bids resolve correctly (no lost update)
- Proxy/automatic bidding (bid up to a hidden max on the user's behalf)
- Prevent last-second sniping (optional soft close)
- Show the live current price to many watchers

**Non-functional (with numbers):**
- Hot auctions: thousands of bids/sec on the write path; millions of watchers on the read path
- Current bid cached ~1s TTL; bid history ~30s; auction metadata ~1h CDN
- Strict consistency on the write (one winner per bid round); effectively-once settlement
- Soft-close extension window (e.g. last 5 min → extend 5 min)

### Core entities
- **Auction:** id, current_bid, current_bidder, version, end_time, status
- **Bid:** auction_id, bidder, amount, proxy_max (encrypted), ts
- **ProxyBid:** a stored max-bid the system auto-increments on the bidder's behalf

### API
- `POST /auctions/:id/bids {amount, proxy_max?}` → OCC conditional update; 200 win / 409 outbid (retry)
- `GET /auctions/:id` → current bid (cached ~1s) + metadata (cached)
- internal: on each bid, run proxy auto-increment; on bid in final window, extend end_time

### HLD
The defining tension is **strict consistency on a tiny write path vs heavy caching on a huge read path**. Watchers (millions) read the current price, served from cache with a tight TTL (~1s for current bid, ~30s for history, ~1h for metadata) — staleness of a second is fine for display. Bidders (few, but concurrent) hit the write path, where correctness is everything. A bid is an **OCC conditional update**: read the current bid + version, then `UPDATE … SET current_bid=?, version=version+1 WHERE id=? AND version=? AND current_bid < ?`. If another bid committed first, the version/`current_bid<` predicate fails (0 rows), the bidder is told "outbid," and they resubmit with fresh data — so concurrent bids serialize to exactly one winner per round with no lost update and no held row lock. For very high bid rates, the compare-and-set can move to a **Redis atomic counter + Lua** to avoid DB row contention.

**Proxy/automatic bidding**: a bidder submits a hidden maximum; the system stores it (encrypted) and, on each competing bid, **auto-increments** the current price by the minimum increment to keep the proxy bidder winning — until a competitor exceeds the max — all within a transaction; exact-max ties go to the **earliest** bidder. **Soft-close / anti-snipe**: if a bid lands in the final window (e.g. last 5 min), extend the end time by that window and repeat until no bid arrives in the final window — neutralizing last-second snipes (empirically rampant on eBay's hard close, minimal on auto-extend platforms). Settlement at close picks the high bid and charges via the payment service with an **idempotency key** (effectively-once, no double-charge on retry).

### Deep dives
1. **OCC for concurrent bids (the core).** Two bids arriving "simultaneously" must not both succeed (lost update) and must not require a slow exclusive lock on a hot auction row. OCC is the fit: the conditional `UPDATE … WHERE version=? AND current_bid<newbid` is atomic at the DB, so exactly one of two concurrent bids commits; the loser sees 0 affected rows → "outbid" → retry. This avoids `SELECT FOR UPDATE` contention (which would serialize and queue all bidders) while guaranteeing no lost update. The retry-on-conflict cost is acceptable because true simultaneous bids on one item are rare except on hot auctions — where you escalate to a Redis Lua compare-and-set. The Staff+ point: bidding is a compare-and-set on a single value; OCC expresses that without locks.
2. **Proxy bidding + tie-breaking.** Real auctions auto-bid: a user sets a max and the system bids the minimum increment above competitors on their behalf, revealing only the current price, not the max. Implementing this means each incoming bid triggers a transaction that compares against stored proxy maxes and may auto-raise the price (possibly multiple times) to keep the highest proxy bidder winning at increment+1 over the runner-up. Edge cases: equal maxes resolve to the earliest submitter (timestamp tie-break); increments scale with price. This is where naive "store the bid" designs break — proxy bidding is a little auction-resolution engine that must run atomically per incoming bid.
3. **Soft-close anti-snipe + read/write split.** Sniping (bidding in the last second so others can't react) is a real adversary; a **hard close** (fixed end time, eBay) allows it, while a **soft close** extends the auction whenever a bid lands in the final window, repeating until quiet — so the auction ends only when bidding actually stops. The empirical evidence (Ockenfels & Roth) is heavy sniping on eBay vs little on auto-extend Amazon. Separately, the **read/write split** is what makes auctions scale: the current price is read by millions (cache it, ~1s TTL, eventual-consistent display) but written by few under strict consistency — conflating them (e.g. strongly-consistent reads for every watcher) would crush the system. Name both: anti-snipe for fairness, read/write split for scale.

## Known failure modes
1. **Lost update on concurrent bids.** Two bids overwrite each other and one is silently lost. Production answer: OCC conditional update (`WHERE version=? AND current_bid<?`) so exactly one wins and the other retries; Redis Lua CAS for hot auctions.
2. **Last-second sniping.** A bid in the final instant denies others a chance to respond. Production answer: soft-close / anti-snipe extension (extend the end on a late bid, repeat until quiet); communicate the rule; accept hard-close only if sniping is acceptable.
3. **Double-charge / double-settle at close.** Retried settlement charges the winner twice. Production answer: idempotency key on the settlement payment (effectively-once); idempotent close processing so re-running the close doesn't re-charge.

## (Delineation note)
`online-auction` is the concurrent-bidding (compare-and-set on a value) variant of the archetype. The seat-hold variant is `ticketmaster`; the inventory-decrement variant is `flash-sale`/`ecommerce-inventory`. The payment engine is `stripe-payments`; idempotency depth is `idempotent-payment` — reference, don't re-derive.

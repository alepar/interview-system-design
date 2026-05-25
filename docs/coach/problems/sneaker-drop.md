---
slug: sneaker-drop
archetype: concurrent-resource
sources:
  nike_antibot: complex.com/sneakers/a/cmplxvictor-deng/nike-explains-anti-bot-protection
  queueit_sneaker_bots: queue-it.com/blog/sneaker-bot-prevention/
  queueit_fifo_random: queue-it.com/blog/first-in-first-out-randomization/
  queueit_hype: queue-it.com/blog/hype-event-protection-waiting-room/
  snkrs_methods: stashed-sneakers.com/blogs/blog-posts/nike-snkrs-drop-methods-guide-stashed
---

# Sneaker Drop (limited-edition drop, bot contention + fairness)

## Bar anchors
- **Mid-level (L4/E4):** Treats it like a normal sale with limited stock. Doesn't recognize that bots are the dominant traffic and that pure first-come-first-served rewards them.
- **Senior (L5/E5):** Adds a waiting room, rate limiting, and inventory holds; knows bots are a problem. May not articulate the fairness mechanism (randomization / raffle), behavioral bot detection, the demand:supply reality, or why the waiting room must gate *before* the site.
- **Staff+ (L6/E6+):** Drives proactively. Frames **bots as the dominant adversary** (10–40% of Nike SNKRS submissions; one Supreme drop saw 1.9B purchase attempts, 97% inorganic) and **fairness as the core design goal**, not just throughput. Uses a **virtual waiting room that gates before the site** (a checkpoint, not a post-hoc filter — >50% of blocked bots share one IP) with **randomized admission** (random queue position at T0, then FIFO) so fast bots gain no edge, and/or a **raffle/draw model** (random winner selection — Nike LEO's 2–3 min entry window then random pick) that defeats first-come bots entirely. Layers **behavioral bot detection** (mouse/swipe/accelerometer biometrics → ML), per-account **entry limits + account verification** (raffle bots mass-create fake accounts), and **inventory reservation + checkout window** for winners. Notes demand:supply (~1-in-2,000 for top releases) and that randomization shifts the problem from "be fastest" to "be lucky + verified human."

## Canonical decomposition

### Requirements
**Functional:**
- Sell a tiny limited drop fairly to humans despite massive bot demand
- Admit/select buyers fairly (not "fastest bot wins"); enforce one-per-person
- Hold inventory for selected buyers through a checkout window; never oversell

**Non-functional (with numbers):**
- Bots 10–40% of submissions (up to 97% of traffic on hyped drops); demand:supply ~1-in-2,000 top tier
- Waiting room gates before the origin (>50% of bots from one IP)
- Random admission / raffle for fairness; per-account entry limits
- Checkout/hold window for winners (minutes); zero oversell

### Core entities
- **Entry:** a user's request to buy / raffle entry (validated human, account-verified)
- **Waiting room queue:** admission gate (randomized position, then FIFO)
- **Raffle/draw:** random winner selection from validated entries
- **Hold:** inventory reserved for a winner during their checkout window

### API
- `POST /drop/:id/enter` → waiting-room/raffle entry (bot-checked, account-verified)
- admission: at T0, assign random queue positions → FIFO admit at sustainable rate
- raffle: collect entries in a window → random winner selection → notify + checkout window
- `POST /drop/:id/checkout` (winners only, within window) → reserve → purchase

### HLD
The architecture inverts the usual goal: **fairness over raw throughput**, because the adversary (bots) is most of the traffic. A **virtual waiting room sits in front of the origin as a checkpoint** — it gates traffic *before* it reaches the app (so the site never sees the bot flood) and is where bot mitigation happens (rate limits, IP/behavioral analysis — over half of blocked bots come from a single IP). Two fairness models:
- **Randomized waiting room**: users who arrive before T0 wait behind a countdown; at T0 each gets a **random** queue position (neutralizing fast internet/bots), then the queue drains FIFO at a rate the checkout can sustain; late arrivals go to the back.
- **Raffle / draw** (Nike SNKRS LEO, "Let Everyone Order"): collect entries during a 2–3 minute window, then pick winners **randomly** — first-come speed is irrelevant, so bots can't win by being fastest; they must instead mass-create entries (countered by account verification + per-account entry limits).

**Bot detection** runs throughout: behavioral biometrics (mouse movement, mobile swipe, accelerometer) fed to ML models distinguish humans from scripts; device fingerprinting and velocity checks flag automation. Selected **winners** get an inventory **hold** (reservation with a checkout-window TTL) and a purchase flow; unredeemed holds release back. Oversell prevention is the same atomic-decrement/token mechanism as `flash-sale`, but the *contention* problem is largely solved upstream by randomization (the gate admits at most inventory-scale winners). The product reality: demand:supply is brutal (~1-in-2,000 for top releases), so the system's job is to make the lottery fair and bot-resistant, not to serve everyone.

### Deep dives
1. **Why randomization/raffle beats first-come (the fairness core).** Pure FCFS is a bot-optimization target: whoever automates the fastest request wins, so humans lose. Randomization removes the speed advantage — a **random queue position at T0** (or a **random raffle draw**) gives every validated entrant equal odds regardless of bot speed. This reframes the contention problem: instead of an engineering race to be first (which bots win), it's a lottery among verified humans (which bots can only game by faking many entrants — a different, account-verification-shaped problem). Nike's LEO draw and SNKRS raffles are the production embodiment. The Staff+ insight: when the adversary optimizes latency, change the game from "fastest wins" to "random among the eligible."
2. **Bot mitigation as a first-class layer.** Bots are 10–40%+ of submissions (up to 97% of traffic on hype drops), so detection isn't an afterthought — it's a gate in front of the origin. Layers: a **waiting room checkpoint** (absorbs the flood before the app, blocks obvious automation by IP/velocity — >50% of bots share an IP), **behavioral biometrics** (mouse/swipe/accelerometer → ML classifier), **device fingerprinting**, and **account verification + per-account entry limits** (because raffle bots pivot to mass-creating fake accounts). The point: no single technique suffices; it's defense-in-depth, and the waiting room's value is being a checkpoint *before* traffic hits the site (unlike post-hoc bot filters).
3. **Holds, checkout windows, and the demand:supply reality.** Winners (admitted or drawn) get an inventory **hold** with a checkout-window TTL (reserve → buy → confirm, release on timeout) — the same reservation pattern as `ticketmaster`, but the number of holders is already clamped to ~inventory by the gate, so contention at the hold layer is mild. The harder reality is **demand:supply** (~1-in-2,000 top tier; millions of entries for tens of thousands of pairs), which means the system is fundamentally a fair lottery with a small fulfillment tail — and resale/scalping pressure (StockX) is the economic backdrop motivating bots. Design for fairness + verification first; the oversell-prevention mechanics (atomic decrement, hold TTL) are the easy part.

## Known failure modes
1. **Bots win the drop (FCFS exploited).** Pure first-come lets the fastest scripts take all stock. Production answer: randomized admission / raffle draw (speed-independent) + behavioral bot detection + account verification + per-account entry caps.
2. **Waiting room / origin overwhelmed.** The bot flood takes down the site before fairness even applies. Production answer: a waiting-room checkpoint in front of the origin (gate before the app), IP/velocity blocking, rate limits — absorb and filter before traffic reaches the booking path.
3. **Fake-account mass entry (gaming the raffle).** Bots create thousands of accounts to multiply raffle odds. Production answer: account verification (identity/payment/history signals), per-account and per-payment-method entry limits, and ML on entry patterns; randomization alone isn't enough without verified eligibility.

## (Delineation note)
`sneaker-drop` is the **fairness-and-bot-contention** variant of the archetype — distinct from `flash-sale` (raw atomic-decrement contention) and `ticketmaster` (seat holds + waiting room) by making randomization/raffle and bot mitigation the centerpiece. Oversell mechanics are shared (reference `flash-sale`); the payment engine is `stripe-payments`.

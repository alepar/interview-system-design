---
slug: ad-auction-rtb
archetype: ml-in-loop
sources:
  openrtb_spec: iabtechlab.com/standards/openrtb (IAB Tech Lab OpenRTB 2.6 Specification)
  twitter_pacing_2021: blog.x.com/engineering/en_us/topics/infrastructure/2021/how-we-built-twitter-s-highly-reliable-ads-pacing-service
  xu_smart_pacing_2015: arxiv.org/abs/1506.05851 (Xu et al. "Smart Pacing for Effective Online Ad Campaign Optimization" KDD 2015)
  google_first_price_2019: blog.google/products/admanager/update-first-price-auctions-google-ad-manager
  edelman_gsp_nber: nber.org/papers/w11765 (Edelman/Ostrovsky/Schwarz GSP NBER w11765)
---

# Real-time bidding ad auction — sub-100ms OpenRTB pipeline + GSP/first-price/VCG mechanics + PID pacing + ghost-ads

## Bar anchors
- **Mid-level (L4/E4):** "Send bid to exchange; pick highest." No latency budget; no auction mechanism awareness.
- **Senior (L5/E5):** Names OpenRTB, eCPM = pCTR × bid, second-price. Discusses pacing. May or may not address latency budget decomposition, first-price migration, ghost-ads for measurement, or PID pacing internals.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **OpenRTB 100-300ms hard cap** [IAB spec]; allocates budget across: 10ms publisher→exchange / 15ms exchange/fanout / 50ms DSP scoring / 15ms exchange auction / 10ms response. Cites Google Ad Manager 2019 migration from second-price to **first-price auctions** (removed last-look advantage); GSP not strategy-proof; VCG truthful but harder to explain; Facebook uses VCG. Names **eCPM ranking score** = pCTR × bid (or pCTR × pCVR × bid for CPA). Cites **Twitter ads pacing**: 10s recompute cadence; 24-way sharded by account-id hash; Zookeeper leader election; 3 instances/shard tolerate 2 failures; cross-DC failover once in 2 years. Names **Xu KDD 2015 smart-pacing** that learns per-campaign pace rate from offline+online data balancing smooth delivery vs eCPM max. Names **ghost-ads** for counterfactual incrementality measurement: enter $0 bid for control users so they remain in same supply-demand context as treated users — eliminates CPM-inflation bias of naive holdouts. Stretch (Sr Staff bar): articulates **bid-shading** in first-price (bid below true value to optimize profit) as non-trivial learning problem itself.

## Canonical decomposition

### Requirements
**Functional:**
- Per-impression auction at <100ms (OpenRTB 2.6 hard cap; 100-300ms range)
- eCPM ranking (pCTR × bid) with auction mechanism (first-price now dominant)
- Budget pacing per-campaign + per-advertiser + per-day
- Counterfactual incrementality measurement via ghost-ads
- Brand safety, frequency capping, viewability prediction

**Non-functional (with numbers):**
- IAB OpenRTB 2.6: hard response cap 100-300ms; missed responses dropped (= lost revenue)
- ~178 trillion bid requests/year globally [Irish Council for Civil Liberties 2022]
- ~91% programmatic display via RTB
- Google AdX, Amazon Publisher Services, The Trade Desk each process millions of QPS at peak
- Twitter ads pacing: 10s recompute; 24-way sharded; 3 instances/shard tolerate 2 failures
- A/B power: 50K-100K impressions/arm for 10-20% relative diff; 10M+ for 0.1% absolute

### Core entities
- **Bid request:** impression_opportunity (publisher, user, context, format)
- **Bid response:** bid (CPM), creative, win-notice URL
- **Campaign:** advertiser, budget (daily + lifetime), targeting rules, pacing parameters
- **PID state:** per-campaign (setpoint, measured, integral, derivative) for pacing controller
- **Ghost-bid:** $0 or auction-eligible-but-never-served bid for control users

### API
- DSP: `POST /bid` body=OpenRTB BidRequest → BidResponse within 80ms internal SLO
- Exchange: orchestrates fanout to DSPs; runs auction; returns winner
- Internal: pCTR_model.score(features) → probability; pacing.get_multiplier(campaign_id) → factor

### HLD
**Bid request** arrives at exchange from publisher (10ms RTT). Exchange **fanouts** to eligible DSPs (15ms). Each DSP runs: feature lookup from feature store (<5ms; Aerospike HMA blends DRAM + flash for sub-ms at scale), CTR model inference (<5ms after feature fetch via aggressive distillation), bidding policy + pacing decision, return bid response. Exchange runs **auction** (15ms): rank by eCPM = pCTR × bid; first-price (winner pays own bid) or second-price (winner pays next-down bid, historical GSP); apply Quality Score multiplier (Google: ad relevance × landing page experience + expected CTR, position-normalized; landing-page ~50% weight). **Pacing service** (Twitter pattern): per-campaign PID controller recomputes every 10s; 24-way sharded by account-id hash; Zookeeper leader election; 3 instances per shard tolerate 2 failures; spend accumulated asynchronously via Live Spend Counter; pacing reads aggregates (per-impression DB writes infeasible at millions of QPS). **Ghost-bid pipeline**: for control users, enter $0 bid (or auction-eligible-but-never-served); keeps control in same supply-demand context as treated users; eliminates CPM-inflation bias of naive holdouts.

### Deep dives
1. **Latency budget decomposition.** Network ~25ms, exchange fanout ~15ms, DSP scoring **~50ms** (within which CTR model must execute <20ms, often <5ms after feature fetch), aggregation/response ~10ms. Hard p99 SLO ~80ms internal because publisher cuts off at 100ms. **CTR model in <5ms** forces aggressive knowledge distillation: deep teacher trained offline; small student (small MLP, small embedding budget) deployed; feature lookups parallelized with bid-policy evaluation. Feature store reads <5ms (Tecton <100K QPS at <5ms median; Redis 0.45ms p99 GET).

2. **GSP vs first-price vs VCG mechanism choice.** **GSP** (historical Google/Yahoo): pay next-lower bid × (your QS / next-lower QS). Not strategy-proof; truthful bidding not dominant; multiple equilibria [Edelman et al. NBER]. **First-price** (Google Ad Manager 2019+): pay own bid. Strategy-proof against last-look manipulation; removes floor-price gaming; requires bid-shading (bid below true value to optimize profit) — non-trivial learning problem. **VCG** (Facebook): pay externality your impression imposes on other bidders (welfare-maximizing). Truthful + welfare-optimal but harder to explain to advertisers. **Soft-floors abandoned** because publishers misreported strategically [UCLA Anderson Review].

3. **PID + smart-pacing + ghost-ads.** **PID controller** (Twitter ads pacing): setpoint = desired_%_budget_at_time_t; measured = actual_%_spent; output = bid multiplier or throttle probability. Proportional reacts to current deviation; Integral corrects accumulated error; Derivative anticipates trend. **Smart-pacing** (Xu KDD 2015): learns per-campaign pace rate from offline+online data balancing smooth delivery vs eCPM max; static rate-throttling underspends or overpays. Twitter's published architecture: recompute every 10s per campaign; 24-way sharded by account-id hash; spend accumulated asynchronously via Live Spend Counter; pacing reads aggregates. **Ghost-ads** for incrementality: naive holdout removes demand → CPMs differ between treated/control → downstream measurement biased. Ghost-bid: $0 bid (or auction-eligible-but-never-served) for control users → same supply-demand context as treated [Johnson/Lewis/Nubbemeyer Google].

## Known failure modes
1. **Tail-latency death.** Single slow DSP causes auctions to abandon it, losing revenue. Production answer: tight per-DSP timeouts; aggressive exclusion + exponential-backoff re-inclusion.

2. **Budget-pacing oscillation** when controller gain is too high. Production answer: tuned PID gains; damping factor; rate-limit on multiplier changes.

3. **Calibration drift breaking auction economics.** Same model AUC but absolute pCTR shifted → systematic over- or under-bidding. Production answer: continuous calibration monitoring; per-slice ECE; isotonic-regression recalibration hourly.

4. **A/B test under-power for CTR lift.** 0.1% absolute CTR delta on 1% baseline needs ~10M+ impressions/arm; production tests often under-powered. Production answer: power calc before launch; minimum-detectable-effect targets.

5. **Ghost-ads bias from CPM inflation.** Naive holdout reduces clearing prices for control users; downstream measurement biased. Production answer: ghost-bid keeps control in same supply-demand context as treated.

## Notes for the coach
- **Asked-confirmed at Google AdX, Meta Ads, The Trade Desk, Criteo, Amazon Ads.** IAB OpenRTB spec, Twitter ads pacing blog, Aerospike RTB case studies — all explicit interview-prep canon.
- **The latency budget decomposition is the Staff+ baseline.** Candidates who can allocate the 100ms across publisher→exchange→DSP→auction→response components demonstrate RTB-specific knowledge.
- **The first-price migration + bid-shading is the 2019+ deep-cut.** Candidates who default to "we use second-price" miss the industry shift after Google Ad Manager 2019.
- **Ghost-ads is the counterfactual-evaluation depth probe.** Candidates who name ghost-bids for incrementality measurement demonstrate measurement-design sophistication.
- **Adversarial probe: "you're under SMS-pumping-style click fraud — 10M fake clicks/hour. What happens to pacing + pCTR?"** Strong answer: per-account fraud detection (IVT/SIVT classification at edge); rate-limit at API; pCTR model degrades quickly (fraud clicks inflate training data) — invalidate fraud-suspected impressions from training set; shadow-mode re-validate model. Weak answer: "we block fraud" without the training-data poisoning path.

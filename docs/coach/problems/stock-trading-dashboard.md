---
slug: stock-trading-dashboard
archetype: frontend
sources:
  sitepoint_streaming_react: sitepoint.com/streaming-backends-react-controlling-re-render-chaos/
  lightningchart_fintech: lightningchart.com/blog/trader/fintech-charts-comparison/
  echarts_canvas_svg: apache.github.io/echarts-handbook/en/best-practices/canvas-vs-svg/
  tradingview_lightweight: github.com/tradingview/lightweight-charts
---

# Stock trading dashboard — ref-buffer + rAF flush + Canvas/WebGL charts + Web Worker alert engine + BroadcastChannel multi-tab

## Bar anchors
- **Mid-level (L4/E4):** `setState` per tick; React re-renders crash at 50+ ticks/sec.
- **Senior (L5/E5):** Names throttle/debounce. May or may not articulate ref-buffer + rAF flush, renderer choice by scale, or Web Worker for alerts.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. **The high-frequency UI problem.** Bar articulates **render-decoupling**: (a) all incoming ticks go into a JS ref (NOT state), accumulated in ring buffer; (b) `requestAnimationFrame` loop drains buffer and commits batched updates to React state ≤60 Hz; (c) chart library reads directly from ref via imperative API (D3 + canvas, or TradingView Lightweight Charts) bypassing React reconciler. Plus (d) **per-symbol subscription management** — visible symbols subscribed, off-screen unsubscribed; (e) **alert engine in Web Worker** so main thread never stalls during flash crash. **Renderer choice by scale**: DOM/SVG <1k elements; Canvas 2D for depth-of-book; **WebGL via GPU sustains 60fps on 500K candlesticks**. **Architectural twin** of `chatgpt-claude-chat-ui` AND `figma-canvas-client` — same buffer + rAF + ref pattern.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Real-time price ticks for 100+ symbols simultaneously
- Candlestick / depth-of-book / line charts at 60 FPS
- Alert rules (price threshold, % change, volume spike)
- Order entry with optimistic UI
- Multi-tab support (BroadcastChannel)

**Non-functional:**
- Per-tick payload ~80 bytes binary (Protobuf) or ~200 bytes JSON
- Frame budget 16ms; up to 4ms for tick-batch processing per frame
- Dashboard concurrent symbols: 20-100; charting canvas ~1200×400 px each
- INP ≤200ms on user interactions (zoom, scrub, add symbol)
- TradingView Lightweight Charts: 60fps to ~10k points, 30-45fps past 50k; ~186 KB minified, ~61 KB gzipped, tree-shakable to ~40 KB
- ECharts: Canvas renderer for >~1k points
- WebGL: sustained 60fps on 500K candlesticks

### Architecture (A)
**Layered**: WebSocket transport (binary protocol) → Web Worker decoder → ref-buffer ring → rAF-driven React state flush → Canvas/WebGL chart imperative redraw + DOM order-entry forms + Web Worker alert engine.

### Data model (D)
- **Tick**: `{symbol, price, volume, ts, sequence}` (last-value-per-symbol per frame)
- **Subscriptions**: `Set<symbolId>` of visible symbols + ~10 lookahead
- **Alert rules**: per-user list evaluated in worker

### Interface (I)
- WebSocket protocol (binary): subscribe/unsubscribe by symbol; ticks broadcast
- Imperative chart API: `chart.appendTick(symbol, price)` reads from ref

### Optimization (O)
**Ref + rAF flush pattern** (verbatim signature):
```js
tickBuffer.current.push(t);
if (!flushScheduled) {
  flushScheduled = true;
  requestAnimationFrame(flush);
}
```
Per-frame `flush` extracts last-value-per-symbol and `setState`s once. React sees one update per frame instead of one update per message. Aligns state updates to display refresh rate.

**Renderer choice by scale**: DOM/SVG <1k elements; Canvas 2D for depth-of-book/order ladders; WebGL for full interactive charts (sustained 60fps on 500K candlesticks). SVG/DOM bottlenecks past ~1k elements due to style/layout cost. **ECharts 5.3+** SVG renderer rebuilt with virtual DOM (2-10× perf gain in SVG path).

**Canvas charting**: DOM/SVG melts at 60 lines × 60fps; pure canvas with explicit redraw of visible window.

**Web Worker for derived metrics**: moving averages, alert rules; main thread only renders.

**Binary protocol**: Protobuf/MessagePack over WebSocket; decoded in worker to keep parse cost off main thread.

**HFT UI hygiene**: throttle mouse-move to ~20ms for tooltips; append-only series mutations to avoid array churn/GC; isolate chart canvas in own flex container so neighbor DOM mutations don't trigger style recalc.

**Symbol fan-in**: multiplex thousands of symbols over single WebSocket with subscription channel model. Per-symbol subscription/unsubscription on visibility change.

**Backpressure/overflow**: if buffer exceeds N entries (tab backgrounded), drop oldest + emit overflow event for telemetry.

**Reconnect with resume**: on reconnect send last-sequence-id; server replays since then.

**Multi-tab**: BroadcastChannel for shared WebSocket vs per-tab connection (single-leader pattern).

## Known failure modes
1. **UI hang from forgotten setState per tick** — fatal at 20+ msg/s. Production answer: ref-buffer + rAF flush coalescing.
2. **Memory leak in chart libraries** that retain all historical points. Production answer: cap visible window + downsample older.
3. **Tab-background freeze** (browsers throttle rAF to 1 Hz). Production answer: accept; on foreground, flush all queued ticks + rebuild from last sequence.
4. **Alert false-positive during reconnect-replay** if rules see "old" ticks as new. Production answer: gate rule evaluation behind `wasReplayed: true` flag.
5. **Order-entry race** between user click and price tick. Production answer: capture displayed price into request payload; server validates against current with tolerance band; returns `Reject(price_moved)` for re-confirm.

## Notes for the coach
- **Plausibly-asked at Bloomberg, TradingView, Robinhood, Interactive Brokers, Coinbase, hedge-fund tech.** Public engineering writeups (matt.sh, SitePoint).
- **Tier-1 prep** for AI-lab interviews because streaming-token rendering is identical RAF-batched architecture.
- **Architectural twin** of `chatgpt-claude-chat-ui` AND `figma-canvas-client` — drill one, prep all three.
- **The ref-buffer + rAF flush is the canonical Staff+ unlock.** Mid-senior candidates setState per tick and crash; Staff+ candidates name the verbatim pattern.
- **The renderer-by-scale (DOM <1k / Canvas / WebGL >10k) is the depth probe.** Cite TradingView Lightweight Charts numbers (60fps to ~10k, 30-45fps past 50k).
- **Adversarial probe: "20 msg/s × 100 symbols = 2000 updates/s — how many React renders?"** Strong answer: if naive setState-per-update, 2000/s scheduled (React batches but coalesces poorly under heavy load); with ref-buffer + rAF flush, exactly 60 renders/s on 60Hz display, batching to last-value-per-symbol. Weak answer: "React handles it."

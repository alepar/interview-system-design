---
slug: autocomplete-typeahead
archetype: frontend
sources:
  greatfrontend_autocomplete: greatfrontend.com/questions/system-design/autocomplete
  aria_combobox: w3.org/WAI/ARIA/apg/patterns/combobox/
  mdn_abortcontroller: developer.mozilla.org/en-US/docs/Web/API/AbortController
---

# Autocomplete typeahead — async-hazards taxonomy + ARIA combobox 1.2 + normalized cache + virtualized list

## Bar anchors
- **Mid-level (L4/E4):** Fetches per keystroke; renders results in `<ul>`. No debounce, no cancellation, no race-condition handling.
- **Senior (L5/E5):** Names debounce + AbortController. Discusses ARIA. May or may not address race-condition via sequence numbers, cache structures, or IME composition.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Articulates the **four async hazards explicitly**: (a) **request cancellation** via AbortController; (b) **debounce vs throttle** — debounce input 300ms trailing edge, throttle dropdown scroll; (c) **cache strategy** — LRU keyed by normalized query, stale-while-revalidate; (d) **race-condition guard via sequence numbers** — every request stamped with incrementing sequence, commit only if equal to current; AbortController alone insufficient because cached late responses still useful. Names **3 cache structures with trade-offs**: hash map query→results (O(1), high dup), flat result list (no dup, expensive client filter), **normalized store query→resultIds + shared entity store keyed by ID** (best for long-lived SPAs). Cites **ARIA combobox 1.2**: `aria-controls` (not deprecated `aria-owns`), `aria-haspopup` only if popup isn't a listbox; **DOM focus stays on combobox input**; AT focus moves via `aria-activedescendant`. Names **cache TTL by data volatility**: Google search ~hours, Facebook people-search ~30min, **stock-exchange tickers NO caching**. Mobile input hardening: `autocapitalize/autocomplete/autocorrect="off"`, `spellcheck="false"`.

## Canonical decomposition

### Requirements (R)
**Functional:**
- User types in input → suggestions appear in dropdown
- Keyboard navigation (Arrow/Home/End/Enter/Esc/Tab)
- Configurable: data source, debounce, min query length, max results
- Generic enough to be reused across product surfaces
- ARIA combobox 1.2 compliance

**Non-functional:**
- First suggestion painted ≤100ms after trailing-edge debounce; p99 end-to-end ≤300ms
- List bounded 8-10 visible rows; virtualize past ~100 items
- Cache LRU ~100 entries × 2KB = ~200 KB

### Architecture (A)
**4 components** per GreatFrontEnd canonical: Input field UI, Results popup, Cache, central Controller owning (searchString, activeResultIndex, openState, configuration).

### Data model (D)
- **Query state**: `{searchString, debouncing, fetching, results: [], activeIndex, isOpen, sequence}`
- **Cache**: normalized — `{queryToIds: Map<query, id[]>, entitiesById: Map<id, Entity>}`
- **Sequence counter**: monotonic; every request stamped; commit only matching

### Interface (I)
**Public props**: `fetchSuggestions(query, signal): Promise<Result[]>`, `debounceMs=300`, `minQueryLength=2`, `maxResults=10`, `onSelect`, `renderItem`.

**ARIA contract**: input `role="combobox"` + `aria-expanded` + `aria-controls={listboxId}` + `aria-activedescendant={focusedOptionId}` + `aria-autocomplete="list"`.

### Optimization (O)
**State machine**: idle → debouncing → fetching → showing | error | empty; each transition triggers ARIA live announcement.

**Race-condition guard**: each request stamped with sequence number; commit results only if `sequence === currentSequence`. AbortController complements but doesn't replace — cached late responses still useful.

**Keyboard model**: ArrowDown/Up wraps; Enter selects; Esc closes + restores typed text; Tab closes + moves focus; Home/End jump to first/last; visual focus stays in input, `aria-activedescendant` shifts SR-announced item without moving DOM focus.

**IME composition** [compositionstart/compositionend]: do not fire requests mid-composition.

**Mobile** safe-area: listbox repositions above input when on-screen keyboard occupies viewport.

**Telemetry**: shown-but-not-selected vs accepted events for offline-ranker training.

## Known failure modes
1. **Stale-but-shown results** from out-of-order responses (classic). Production answer: sequence numbers on every request; commit only on match. AbortController alone insufficient — cached late responses still useful.
2. **Memory leak from never-cleared debounce timers** on unmount mid-fetch. Production answer: `useEffect` cleanup canceling pending debounce + AbortController.
3. **XSS via rendering raw HTML** in suggestion text. Production answer: render as text; allow client-side `<mark>` only on matched substring.
4. **Keyboard trap** when listbox steals Tab (explicitly forbidden by APG). Production answer: Tab always closes listbox + moves focus.
5. **Wasted bandwidth** from missing minimum-query-length gate. Production answer: enforce `minQueryLength` before fetch.

## Notes for the coach
- **Asked-confirmed** at Meta, Google, Amazon, Airbnb per candidate reports. GreatFrontEnd flagship (free).
- **The sequence-number race-condition guard is the Staff+ unlock.** Mid-senior candidates default to AbortController alone; Staff+ candidates name sequence numbers as the canonical fix because cached late responses still populate the cache for future hits.
- **The normalized cache structure is the depth probe.** Three cache structures with explicit trade-offs (hash map / flat list / normalized) demonstrates SPA-architecture maturity.
- **Adversarial probe: "user types 'goo' then immediately 'good' — what does the user see at each moment?"** Strong answer: typing 'goo' fires debounced request seq=1; 'good' before 300ms cancels timer + starts new debounce, then fires seq=2; seq=1 response arrives but is dropped because seq !== currentSequence; seq=2 commits. User sees blank → 'good' results. Weak answer: "we abort old requests" without walking through the cache + sequence interplay.

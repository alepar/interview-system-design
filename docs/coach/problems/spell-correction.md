---
slug: spell-correction
archetype: search-indexing
sources:
  jurafsky_noisy_channel: web.stanford.edu/~jurafsky/slp3/slides/6_Spell.pdf
  symspell: github.com/wolfgarbe/SymSpell
  brill_moore: "Brill & Moore, An Improved Error Model for Noisy Channel Spelling Correction, ACL 2000"
  bk_tree: en.wikipedia.org/wiki/BK-tree
  reformulation_logs: jeffhuang.com/papers/Reformulation_CIKM09.pdf
---

# Query Spell Correction (did-you-mean)

## Bar anchors
- **Mid-level (L4/E4):** Proposes a dictionary + edit distance to find the closest word. Knows Levenshtein distance. Doesn't address the language-model side, query-log learning, candidate-generation cost, or the inline latency budget unprompted. *(Note: this is a ~25-min deep-dive, best paired with `autocomplete` or as a follow-up to `amazon-product-search`, not a full solo slot.)*
- **Senior (L5/E5):** Uses edit distance (Levenshtein/Damerau-Levenshtein, ≤2) to generate candidates and ranks them by frequency (a unigram language model — Norvig-style). Knows query logs help and that correction must be fast/inline. May not articulate the noisy-channel decomposition, fast candidate generation (SymSpell/BK-tree/Levenshtein automaton), context-sensitive real-word errors, or the auto-replace-vs-suggest policy.
- **Staff+ (L6/E6+):** Drives proactively. Frames correction as the **noisy channel model**: `argmax P(correction|typo) ∝ P(typo|correction)·P(correction)` — an **error model** (channel) × a **language model** (prior). Trains the error model from **query logs** (typo→click-to-correction reformulations; consecutive queries within Levenshtein ≤2) and uses **context-sensitive** correction for real-word errors ("peace"→"piece" via n-grams). Knows **fast candidate generation** matters: naive Norvig generate-and-test is huge (an avg 5-letter word has ~3M errors within edit-distance 3), so uses **SymSpell symmetric-delete** (only 25 deletes cover those 3M, ~6 orders of magnitude faster, language-independent), **BK-trees** (triangle-inequality pruning), or **Levenshtein automata**. Quantifies: **10–15% of web queries are misspelled**; Damerau: >80% of errors are a single edit; inline budget **<10–20ms**. Decides **auto-replace vs "did you mean"** by confidence.

## Canonical decomposition

### Requirements
**Functional:**
- Given a (possibly misspelled) query, propose the most likely intended query
- Handle non-word errors (typo → not a word) and real-word errors (valid word, wrong context)
- Learn corrections from query-log behavior, not just a static dictionary
- Decide whether to auto-correct or show "did you mean X" based on confidence

**Non-functional (with numbers):**
- ~10–15% of web search queries are misspelled
- >80% of errors are a single insertion/deletion/substitution/transposition (Damerau)
- Inline latency budget <10–20ms added to the query path
- Edit distance ≤2 covers the vast majority of single-typo errors
- Candidate generation must be ~O(1)-ish, not O(dictionary × edits)

### Core entities
- **Dictionary / frequency table:** known terms with corpus/query frequencies (the LM prior)
- **Error model:** P(typo|correction) — from a confusion matrix or query-log pairs
- **Candidate index:** SymSpell delete-index / BK-tree / Levenshtein automaton for fast fuzzy lookup
- **CorrectionPolicy:** confidence threshold → auto-replace vs suggest vs do-nothing

### API
- `GET /correct?q=<query>` → {suggestion, confidence, action: replace|suggest|none}
- Internal: `candidates(q) → terms within edit-distance ≤2` (fast generation)
- Internal: `score(c) = P(q|c)·P(c)` (error model × language model); pick argmax
- Internal: offline → mine typo→correction pairs from query-log reformulations

### HLD
Correction is the **noisy channel model**: the user intended a correct query `c`, a noisy channel (their typing) produced the observed `q`, and we recover `argmax_c P(c|q) = argmax_c P(q|c)·P(c)`. Two models: the **error/channel model** `P(q|c)` (how likely this typo given that intended word — a simple version is 0.95 for "unchanged" with the rest spread over edits; a better version uses a confusion matrix of single-edit error counts, or Brill-Moore context-dependent substring edits) and the **language model** `P(c)` (how likely the word/query is — from corpus *and* query frequency, which is the in-domain signal that makes search-query correction work).

**Candidate generation** must be fast because it's inline. Generating all edits of the query and intersecting with the dictionary (Norvig) is conceptually clean but explosive — an average 5-letter word has ~3M errors within edit-distance 3. **SymSpell** flips this: precompute only *deletes* of dictionary words (and only deletes of the query at lookup), since a delete-to-delete match covers insertions/substitutions/transpositions by symmetry — an avg 5-letter word needs only **25 deletes** to cover those ~3M errors, ~6 orders of magnitude faster and language-independent. Alternatives: **BK-trees** index words by edit distance and prune via the triangle inequality; **Levenshtein automata** recognize exactly the strings within distance k of a target in O(candidate length), enabling fuzzy lookup over a normal index (Lucene's `FuzzyQuery`).

The **best candidate** maximizes error-model × language-model score. **Real-word errors** ("peace of cake") need **context**: an n-gram language model (e.g. Google Web 1T 5-grams) scores the word in context to catch valid-but-wrong words a dictionary lookup would pass. The **error model is trained from query logs**: sequential reformulations where a user typed X, didn't click, then typed a within-edit-distance-2 Y and did click are mined as typo→correction pairs — learning corrections specific to the domain's vocabulary (product names, slang, brands). Finally a **policy** decides the action by confidence: high-confidence → silently auto-replace and search the correction (with an "showing results for X / search instead for Y" affordance); medium → "did you mean X"; low → do nothing. The whole path must add <10–20ms.

### Deep dives
1. **The noisy-channel decomposition** — Splitting `P(c|q)` into `P(q|c)·P(c)` (Bayes) turns one hard problem into two tractable ones: an error model that only needs to know how typos happen (mostly single edits — Damerau found >80% of human errors are one insertion/deletion/substitution/transposition, so a confusion matrix over single edits captures most signal), and a language model that only needs to know what's likely (word/query frequency). The two are estimated independently and combined at scoring time. The Staff+ nuance: for *search queries* the language model should be the **query-frequency** distribution, not generic English — users search for product names, brands, and entities that a dictionary LM would penalize, so the in-domain prior is what makes the corrector right for the domain.
2. **Fast candidate generation (why SymSpell wins)** — The bottleneck is generating plausible corrections within the latency budget. Norvig's generate-all-edits-and-intersect is elegant but scales as alphabet × length × edit-distance — ~3M candidates within distance 3 for a short word, hopeless inline. **SymSpell's symmetric-delete** insight: if you only ever delete characters (from both dictionary terms at index time and the query at lookup time), then any single insertion/substitution/transposition error reduces to a *delete-to-delete* match — so you generate only ~25 deletes instead of ~3M edits, a ~10⁶× reduction, and it's language-independent (no alphabet enumeration). BK-trees (metric-tree pruning via the triangle inequality) and Levenshtein automata (FSA that accepts exactly the within-k strings, O(n) membership) are the other production-grade options; the common theme is *avoid enumerating the edit space* and instead structure the dictionary so fuzzy lookup is sublinear.
3. **Learning from query logs + auto-replace policy** — A static dictionary can't keep up with new product names, brands, or trending terms, and can't learn domain-specific corrections. Query logs provide supervision for free: sequential **reformulations** (user types X, no click, retypes Y within Levenshtein ≤2, clicks) are mined as typo→correction training pairs, continuously refreshing the error model with real corrections the population actually makes. The serving-side decision is then a **confidence-gated policy**: auto-replace only when confidence is high (and always show the "search instead for original" escape hatch, because auto-correcting a deliberate rare query — a real product code — and hiding it tanks CTR), suggest "did you mean" in the medium band, and stay silent when unsure. A/B test the policy: over-correction is a real CTR risk, especially for proper nouns and bilingual queries.

## Known failure modes
1. **Over-correction on rare proper nouns / product codes** — A legitimately rare query (a brand, a SKU, a surname) looks like a misspelling of a common word and gets auto-replaced, hiding the user's real intent. Mitigation: per-vertical dictionaries (product/brand/geo terms protected), a high confidence threshold for auto-replace, and always surfacing "search instead for <original>" so a wrong auto-correct is one click to undo.
2. **Bilingual / multi-locale queries** — A user mixing languages or searching in a non-default locale gets corrected against the wrong language model, producing nonsense suggestions. Mitigation: per-locale error + language models, a language-detect short-circuit that skips correction when the query language is ambiguous or detected as non-default, and locale-scoped query-log training.
3. **Latency budget blown** — Correction is inline before search, so a slow corrector adds directly to every query's latency. Naive candidate generation (Norvig at distance 3) or unbounded fuzzy match misses the <10–20ms budget. Mitigation: SymSpell/BK-tree/Levenshtein-automaton candidate generation (sublinear), cap edit distance at 2, cache corrections for head queries, and compute correction in parallel with (not serially before) initial retrieval where the architecture allows.

## (Scope note)
This is a ~25-min deep-dive, best paired with `autocomplete` for a full query-understanding round or as a follow-up to `amazon-product-search` — not a full 50-min solo slot.

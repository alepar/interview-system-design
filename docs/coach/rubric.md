# Rubric

The coach grades every session against four universal dimensions × per-level Bar anchors.
Scale: 3-point ordinal (above bar / at bar / below bar) per dimension per level.
Sources: Hello Interview problem breakdowns and per-level essays; the four-dimension framework from `staff-engineer-study-guide.md` §2.

## Dimensions

1. **Problem Navigation** — clarifying questions, requirements gathering, prioritization, identifying the hard part before drawing boxes.
2. **Solution Design** — workable architecture meeting requirements; balancing performance, scalability, maintainability, cost.
3. **Technical Excellence** — depth of knowledge, concrete technology choice with justification, CAP/PACELC reasoning, failure modes, dive-deep on 2–3 components.
4. **Technical Communication & Collaboration** — clear explanation, responsiveness to feedback, hint-receptivity without defensiveness, legible diagrams.

## Per-level bars

For each dimension below, the per-level Bar anchors quote material from public sources.

### Problem Navigation
- **Mid-level (L4/E4):** *"A common mistake is to be overbroad ('the system should be highly available!' or 'the system should be highly consistent!') when the reality is that availability and consistency usually imply tradeoffs which can be made differently for different parts of the system. 'Ordering needs to be consistent to avoid double orders', 'Search can be eventually consistent within 30s'."* — Hello Interview, hellointerview.com/blog/system-design-requirements
- **Senior (L5/E5):** *"expectations shift towards more in-depth knowledge — about 60% breadth and 40% depth."* — Hello Interview, YouTube Top-K Videos problem breakdown (hellointerview.com/learn/system-design/problem-breakdowns/top-k). At senior level, requirements are gathered with specificity and prioritization driven by the candidate, not the interviewer.
- **Staff+ (L6/E6+):** *"Good staff-level engineers design simple systems that solve problems elegantly. A very common response to a challenge is 'let me see if [a more sophisticated approach] is actually required' whereas a senior engineer will try to solve the complex flavor. Interviewer: You need location search over a set of places. Staff Candidate: How many places are we talking about here? Interviewer: 10,000 Staff Candidate: Are they updated frequently? Interviewer: No, not really. Staff Candidate: Great, let's sync periodically and search in memory."* — Stefan Mai, "5 Keys to Staff-Level System Design Interviews" (hellointerview.com/blog/staff-level-system-design)

### Solution Design
- **Mid-level:** *"For this question, a Mid-Level candidate will be able to come up with an end-to-end solution that probably isn't optimal. They'll have some insights into pinch points of the system and be able to solve some of them. They'll have familiarity with relevant technologies, but will make some mistakes."* — Hello Interview, YouTube Top-K Videos problem breakdown (hellointerview.com/learn/system-design/problem-breakdowns/top-k)
- **Senior:** *"[Senior] expectations shift towards more in-depth knowledge — about 60% breadth and 40% depth."* — Hello Interview, YouTube Top-K Videos problem breakdown (hellointerview.com/learn/system-design/problem-breakdowns/top-k)
- **Staff+:** *"[Staff+] I'm looking for about 40% breadth and 60% depth in your understanding."* — Hello Interview, YouTube Top-K Videos problem breakdown (hellointerview.com/learn/system-design/problem-breakdowns/top-k)

  **Method sub-bar (Staff+).** A Staff+ design progresses top-down: simplest workable baseline → name the bottleneck → describe ways to resolve → state criteria guiding the tech selection → commit to one choice. Optionally enumerate 2–3 candidate technologies with one-line pro/con before committing (breadth bonus, not required). The anti-pattern is naming a specific technology (*"I'd use DynamoDB"*) without surfacing the criteria that led there. Per Stefan Mai's option-listing principle (see Communication anchor), the commit is required even when the menu is shown — never kick the decision back to the interviewer.

  | Target level | Simple→bottleneck arc | Commit-with-criteria | Breadth menu (optional) |
  |---|---|---|---|
  | L4 (Mid) | not graded | not graded | demonstrated → above-bar signal |
  | L5 (Senior) | demonstrated → above-bar; missed → neutral | at-bar expectation | demonstrated → above-bar signal |
  | L6+ (Staff+) | required (missed → below-bar) | required (missed → below-bar) | demonstrated → above-bar bonus |

  This check is observed silently mid-flow per `docs/coach/protocols.md` § Tone and feedback discipline / Mid-flow vs debrief; it surfaces only in the closing assessment.

### Technical Excellence
- **Mid-level:** *"If you introduce an API gateway, for example, expect that I may ask you what it does and why it's needed in your design."* — Evan King, "The System Design Interview: What is Expected at Each Level" (hellointerview.com/blog/the-system-design-interview-what-is-expected-at-each-level)
- **Senior:** *"I start the interview with the presumption that candidates have a thorough understanding of the fundamentals… when you introduce technical elements like a load balancer or an API gateway, I won't probe into their basic functionalities unless you expose a lack of understanding."* — Evan King, "The System Design Interview: What is Expected at Each Level" (hellointerview.com/blog/the-system-design-interview-what-is-expected-at-each-level)
- **Staff+:** *"a candidate might introduce Temporal.io as a solution to address specific challenges like distributed system orchestration or workflow management… If this is a technology I'm less acquainted with, a great staff candidate would skillfully elucidate its functionalities… effectively broadening my understanding."* — Evan King, "The System Design Interview: What is Expected at Each Level" (hellointerview.com/blog/the-system-design-interview-what-is-expected-at-each-level)

### Technical Communication & Collaboration
- **Mid-level:** Communicates clearly; accepts hints; does not get defensive when challenged. (Synthesized from the four-dimension framework in `staff-engineer-study-guide.md` §2.)
- **Senior:** *"'I'm going to go with Postgres here because I need transactions across tables and durability. I don't think this is going to be a scaling bottleneck but we can come back to this later if needed.' is a great response… a. Make the decision. Don't just outline options. b. Justify your decisions, but don't attempt to make an airtight case."* — Stefan Mai, "5 Keys to Staff-Level System Design Interviews" (hellointerview.com/blog/staff-level-system-design)

  **Calibration note.** This anchor applies to *implementation* decisions (e.g., "I'd use Postgres because…") where deferring to options is pure avoidance. For *empirical calibration* decisions — celebrity thresholds, sharding cutoffs, cache size targets, etc. — the Staff+ bar is **anchor + method**, not magic-number. See `docs/coach/protocols.md` § Tone and feedback discipline / Numeric-commit calibration for the grading detail.

- **Staff+:** *"At this level, the candidate is often seen as a peer in the conversation, contributing significantly to the discussion with insights that may even enlighten the interviewer."* — Evan King, "The System Design Interview: What is Expected at Each Level" (hellointerview.com/blog/the-system-design-interview-what-is-expected-at-each-level)

## Drive vs wait (pivotal cross-cutting moment)

*"More junior candidates can expect the interviewer to jump in here and point out places where the design could be improved. More senior candidates should be able to identify these places themselves and lead the discussion."* — Evan King, "The System Design Interview: What is Expected at Each Level" (hellointerview.com/blog/the-system-design-interview-what-is-expected-at-each-level)

This is the L5/L6 pivot. Logged as a `pivotal_moment` in every `/mock-loop` session artifact.

**Difficulty-conditioned logging.** This pivotal moment is logged in the session artifact based on the session's `difficulty.level`:

- **Hard:** logged normally — the canonical instance is failing to pick a deep-dive topic when the coach was silent.
- **Medium:** logged only on signals where the coach was silent (HLD-focus selection, within-topic depth). The deep-dive-selection sub-signal is N/A because protocol made the coach drive it.
- **Easy:** not logged. The coach drove the meaningful inflection points by protocol; insufficient candidate-driven moments remain to produce a meaningful signal.

The session artifact's `difficulty.drive_vs_wait_logged` flag (per `.claude/commands/mock-loop.md` § Closing assessment step 6) records the per-session outcome.

## Pivotal-moment principle

Per Stefan Mai's option-listing failure mode: interviewers decide on 1–2 *pivotal moments* per session, not weighted aggregates. The coach commits these to `state/sessions/*.md` rather than reporting an aggregate score.

*"One candidate I worked with was very sharp but kept falling into this trap of outlining options for major decisions. Each response had a list of 2-4 different options for me to choose. I had to respond to them with 'Well, which one would you choose?'. How can I know whether they'll be a good fit for the role if I'm not actually seeing their decisions?"* — Stefan Mai, "5 Keys to Staff-Level System Design Interviews" (hellointerview.com/blog/staff-level-system-design)

## Scoring guidance for the LLM-judge

Per Zheng et al. (arXiv:2306.05685, Table 4): use reference-guided judging (the per-problem reference answer in `docs/coach/problems/`) — reduces failure rate from 70% to 15%. Use **3-point ordinal**, not free-form 1–10 (silent-shortcut bias, arXiv:2509.26072). Always evaluate in both orders to mitigate position bias; do not reward verbosity.

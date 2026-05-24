---
slug: eval-pipeline-at-scale
archetype: ai-infrastructure
sources:
  inspect_ai: inspect.aisi.org.uk/
  ai21_swe_bench: ai21.com/blog/scaling-agentic-evaluation-swe-bench/
  arena_hard_auto: arxiv.org/abs/2406.11939
  openai_evals: github.com/openai/evals
---

# Eval pipeline at scale (offline + online evaluation for frontier models)

## Bar anchors
- **Mid-level (L4/E4):** Basic pipeline: dataset of prompts → model → grader → aggregate scores. Doesn't address LLM-judge cost, contamination, result versioning.
- **Senior (L5/E5):** Names LLM-as-judge as a separate cost-bearing component. Discusses contamination detection (held-out sets). Articulates result versioning (model + prompt + judge versions). Knows offline batch vs online continuous distinction.
- **Staff+ (L6/E6+):** Drives proactively. Names Inspect AI as the de facto eval framework (adopted by Anthropic, DeepMind, Grok; built by UK AISI). Cites AI21 SWE-bench-at-scale numbers: 200K+ evaluations, 8K parallel runs sustained (target 100K), 35K isolated evaluations/day. Per-instance runtime: lightweight 3.5min, reasonable 10min, thorough 2hr+. Cites Arena-Hard-Auto: GPT-4-Turbo as judge over 500 prompts at $25 with 89.1% human-agreement. Pod-pooling pattern (provision 500 pods once, serve dozens of runs each). Names regression detection methodology (output diffing, statistical significance, behavioral fingerprinting). Position-bias mitigation in pairwise judges (double-randomized A/B/B/A scoring). Stretch (Sr Staff bar): contamination via n-gram overlap detection between training data and eval sets; canary strings as data-leakage probes.

## Canonical decomposition

### Requirements
**Functional:**
- Run regression suites across hundreds of benchmarks per model candidate (MMLU, HumanEval, MATH, GPQA, SWE-bench, etc.)
- LLM-as-judge for open-ended evaluations with cost control
- Sandbox-per-sample for agentic evals (code-exec, browser-use)
- Resume-from-failure semantics across long eval runs (one rank fails mid-run; don't lose all work)
- Regression detection between model versions; surface behavior changes for human review

**Non-functional (with numbers):**
- 200K+ eval runs per evaluation campaign (AI21)
- 8K parallel runs sustained (target 100K)
- 35K isolated evaluations per day
- Per-instance runtime: 3.5min (lightweight) → 10min (reasonable) → 2hr+ (thorough)
- Full SWE-bench wall time with parallelism: ~20 min (AI21) / 7 min (Modal --modal flag on 500-task variant)
- LLM-judge cost: $25 / 500 prompts via Arena-Hard-Auto pattern
- Sample reuse across reruns: failed runs retried, passed samples cached

### Core entities
- **EvalRun:** run_id, model_id, model_version, eval_set, started_ts, completed_ts, status
- **Sample:** sample_id, eval_id, prompt, expected_output, scorer_config, score, judge_version
- **EvalSet:** set_id, samples (list), tags, version, contamination_canary_strings
- **JudgeResult:** judge_id, judge_version, score, confidence, ts, prompt_position_bias_check
- **SandboxJob:** job_id, sample_id, sandbox_image, exec_command, output, exit_code

### API
- `POST /v1/evals` body={model, eval_set, scorer, parallelism, budget} → {run_id, est_completion_ts}
- `GET /v1/evals/:run_id` → {status, completed_samples, aggregate_scores, cost_so_far}
- `POST /v1/evals/:run_id/retry` body={sample_ids?} → retry failed samples
- `GET /v1/regressions` query=model_a,model_b → diff report

### HLD
The eval orchestrator runs on Inspect-class framework with three concepts: **Dataset** (eval samples with input + target), **Solver** (how the model arrives at its answer — may include tool use, multi-step), **Scorer** (text match, model-graded, or custom validation). The **batch orchestrator** assigns samples to a worker pool with parallelism factor respecting downstream rate limits (per-model API rate limits, sandbox host capacity). Each sample runs in a sandbox (Docker, Kubernetes pod, or Modal sandbox) with per-sample isolation when needed for agentic evals (code-exec, file write). **Pod-pooling pattern** (AI21): provision N pods once at run start, serve dozens of samples per pod, reduces per-sample cold-start cost. **LLM-as-judge layer**: for open-ended outputs, a separate judge model scores each output; uses position-bias mitigation (double-randomized A/B/B/A for pairwise comparisons); judge version pinned for reproducibility. **Eval-set semantics** (Inspect): automatic retries on transient failure with configurable strategy; resume from failure (next run picks up where last left off); sample reuse across reruns (don't re-run passing samples on a retry). **Regression detection**: run same eval on model v1 and v2, diff outputs at per-sample granularity; statistical significance testing on aggregate scores (Bonferroni-corrected); surface behavior changes via diff dashboard. **Contamination detection**: periodic n-gram overlap check between recent training data and held-out eval sets; canary strings inserted in eval sets to detect data leakage into training corpus.

### Deep dives
1. **Sandbox provisioning model with pod-pooling.** Per-sample fresh container guarantees isolation purity but pays cold-start cost on every sample (10s of seconds for Docker-image-pull). Pod-pooling (AI21's pattern): provision ~500 K8s pods once at run start; each pod serves dozens of samples sequentially; per-sample cleanup script restores known state between samples. Risk: cross-sample contamination (cached files, stale env vars) → tested via canary-pattern detection on pool reuse. Modal supports 50K+ concurrent sandbox sessions for this workload; SWE-bench 500-task benchmark runs in 7 minutes with --modal flag (vs hours with per-sample fresh containers). Staff+ commit: per-sample-fresh vs pool, contamination mitigation, pool refresh cadence.

2. **Eval-set retry, resume, and sample reuse.** A 200K-sample eval run will hit transient failures (network blip, rate limit, sandbox crash). Naive retry from scratch is prohibitively wasteful. Inspect's "Eval Sets" semantics: automatic retries on transient failure with configurable backoff; resume from failure with exactly-once execution per sample; cache passing samples across reruns (don't re-execute samples that already passed). The state durability layer: sample status (pending | running | passed | failed | retrying) persisted in a transactional store; retry policy classifies failures as transient (retry) vs deterministic (terminal). Staff+ commit: state durability, retry budget per sample, classification heuristic for transient vs deterministic failure.

3. **LLM-as-judge cost control + position-bias mitigation.** Arena-Hard-Auto: GPT-4-Turbo as judge over 500 challenging prompts at $25 total with 89.1% human-agreement. At 200K samples × $0.10 per judge call = $20K per full run — non-trivial budget. Cost controls: purpose-built small judge models (a fine-tuned 7B judge trained from GPT-4 preferences) for cheap-path; batching multiple comparisons per judge call (10× cost reduction); skip judging for samples where automated scorer is high-confidence. Position-bias mitigation: judges trained on (A vs B) systematically favor the first-presented option; double-randomized A/B/B/A scoring averages the bias out. Judge-version pinning ensures reproducibility across reruns; new judge version requires re-judging affected samples (or running in parallel for transition validation). Staff+ commit: judge cost-per-sample, position-bias methodology, when to re-judge on judge-version change.

## Known failure modes
1. **Judge model drift causes false regressions/improvements.** Judge model updated mid-campaign; affected samples now scored differently; aggregate score moves without the candidate model changing. Production answer: judge-version pinning per run; golden-set sanity checks (known-correct samples that the judge should still score correctly); explicit re-judge campaign when judge version updates with diff dashboard for affected samples.

2. **Eval set leakage into training data.** A new model trained on data that inadvertently includes the eval prompts → eval performance is inflated. Production answer: canary strings inserted into eval sets at construction (rare phrase that wouldn't appear naturally); periodic n-gram overlap detection between training data and eval sets; quarantine + investigate when canary string appears in training corpus.

3. **Position bias in pairwise judges inflates one side.** Judge consistently picks the option presented first (or second); aggregate scores reflect bias not quality. Production answer: double-randomized A/B/B/A scoring (each comparison run twice with positions swapped, scores averaged); statistical test for position effect (if first-position win rate > 55% consistently, judge is biased — recalibrate or swap to different judge).

## Notes for the coach
- **This is plausibly-asked.** Inspect AI is publicly used by Anthropic, DeepMind, Grok; AI21's 200K SWE-bench post is a primary source on production eval scale; Modal's SWE-bench post establishes the sandbox provisioning model. Eval-pipeline design is a natural Staff+ probe at any safety-focused lab (Anthropic, DeepMind via Safety Cases).
- **The Inspect adoption signal is the Anthropic/DeepMind-specific anchor.** A candidate who names Inspect as the eval framework demonstrates literacy with the 2025-2026 production stack.
- **Pod-pooling vs per-sample-fresh is the operational depth probe.** Most candidates default to per-sample fresh containers (safe but slow); the production answer is pool with contamination mitigation.
- **Position-bias mitigation in LLM-as-judge is a non-obvious depth signal.** Surface as a category gap if not addressed.

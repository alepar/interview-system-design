---
slug: agentic-tool-orchestrator
archetype: ai-infrastructure
sources:
  anthropic_managed_agents: anthropic.com/engineering/managed-agents
  cognition_cloud_agents: cognition.ai/blog/what-we-learned-building-cloud-agents
  mcp_spec: modelcontextprotocol.io/specification/2025-11-25
  exponent_anthropic_mle: tryexponent.com/blog/anthropic-system-design-interview
---

# Agentic tool orchestrator (durable multi-step agent loops with cost caps)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic loop: LLM emits a tool call, executor runs the tool, result is appended to conversation, LLM is called again — repeat until done. Defines an `Agent` entity with conversation state. Knows about retries on tool failure but treats them as in-memory state. Doesn't address durability, idempotency, cost caps, or hypervisor-snapshot resume unprompted.
- **Senior (L5/E5):** Names durable execution (Temporal / Restate / Inngest pattern) as the answer to crash-mid-run. Articulates per-tool retry budget with backoff, max-iterations cap to prevent infinite loops, and per-run cost cap. Discusses idempotency for side-effecting tool calls (idempotency keys on POST-style operations). Names secrets-broker pattern (tool gets short-lived scoped token, not raw user credentials). Identifies trace/replay for debugging (Langfuse / Phoenix). Handles sandbox isolation for code-exec tools at category level (gVisor or Firecracker).
- **Staff+ (L6/E6+):** Drives the session proactively. Names Anthropic's Managed Agents 3-tier architecture (Harness brain / Sandbox hands / Session log) and reasons why decoupling them enables horizontal scaling — any Harness instance can pick up any Session, sandboxes are cattle not pets. Names Cognition's hypervisor-snapshot session state (capture VM memory + process tree + filesystem; idle compute shuts down, resumes exactly on event). Quantifies context super-linearity (single 500K-token request can cost more than thousands of short requests) and bounds per-session token budget accordingly. Handles identity chaining (agent inherits dispatching engineer's permissions across downstream systems with tamper-evident audit). MCP as the tool protocol with lazy tool-discovery (only tool names at session start; load schemas on demand — 98.7% token reduction via code-execution against MCP). Cost caps as multi-dimensional: max tokens, max wall-clock, max sub-agent recursion depth, max tool-call count. Stretch (Sr Staff bar): mentions that all 12 published prompt-injection defenses bypassed >90% in joint Anthropic/OpenAI/DeepMind testing — defense-in-depth + capability scoping + human approval for irreversible actions.

## Canonical decomposition

### Requirements
**Functional:**
- Accept agent-task submissions (natural-language goal, optional tools available)
- Run multi-step LLM-driven tool-use loop (search, code-exec, browser, MCP-exposed APIs)
- Persist agent state durably so crashed runs can resume
- Enforce per-run cost caps (tokens, time, tool calls)
- Surface trace for debug and audit; support human-in-loop checkpoints for irreversible actions
- Sandbox isolation for arbitrary code/command execution

**Non-functional (with numbers):**
- 50+ tool calls per typical task; SWE-bench-style trajectories hit 100s of LLM calls
- Thousands of concurrent long-running agent sessions (Cognition reports thousands of concurrent VMs)
- Per-session wall-clock from minutes (interactive) to hours (long autonomous tasks)
- Cost cap enforcement: hard kill within ~10s of breach
- 99.9% session-resume success on crash (durability target)
- Per-session idle cost near-zero (hypervisor-snapshot model: pay for active compute only)
- Audit retention: tamper-evident, retained per compliance SLO (years for enterprise)

### Core entities
- **Session:** session_id, tenant_id, goal, tools_allowed, status (running | paused | completed | failed), durable_event_log
- **Harness instance:** harness_id, currently_owned_sessions, stateless (any harness can pick up any session)
- **Sandbox:** sandbox_id, isolation_primitive (Firecracker | gVisor | bubblewrap), lifetime (per-call | per-session), credentials_scope
- **Tool invocation:** invocation_id, session_id, tool_name, args, result_or_error, idempotency_key, ts
- **Cost budget:** session_id, max_tokens / max_wall_clock / max_tool_calls / max_recursion_depth, consumed_so_far
- **Audit event:** event_id, session_id, ts, actor (agent | human), action, signed_hash_chain

### API
- `POST /v1/sessions` body={tenant, goal, tools_allowed, budgets} → {session_id, status}
- `POST /v1/sessions/:id/resume` → resume from last checkpoint
- `POST /v1/sessions/:id/approve` body={action_id} → human approval for irreversible action checkpoint
- `GET /v1/sessions/:id/trace` → full event log with tool calls, LLM responses, decisions
- `DELETE /v1/sessions/:id` → cancel, free sandbox + emit final audit event

### HLD
Three decoupled tiers (Anthropic Managed Agents pattern). The **Harness** is the LLM-driving brain — a stateless service that loops: read latest events from Session log → call LLM → parse tool call → dispatch to Sandbox → write tool result to Session log → repeat. Any Harness instance can pick up any Session (horizontal scaling is trivial). The **Sandbox** is the hands — short-lived isolated compute that executes tool calls. Cattle not pets: provisioned lazily, killed after use; credentials never persist inside (secrets-broker pattern: sandbox gets a short-lived scoped token for each call, the underlying user credential never leaves the broker). Firecracker microVM for untrusted-code-execution tools (125ms cold start, hardware-virtualized isolation); gVisor or bubblewrap for tools with weaker threat models. The **Session log** is the durable append-only event log (Cognition snapshots include full VM state for resume; lighter implementations use event sourcing in a transactional store). Cost-cap **enforcer** runs on every event-log append: if budget exceeded, emit hard-stop event that all Harness instances honor. **MCP protocol** is the tool wire format (JSON-RPC 2.0); lazy tool discovery means only tool names live in the system prompt, schemas fetched on demand (Anthropic published 98.7% token reduction via code-execution-against-MCP vs naive load-all-schemas). **Audit pipeline** consumes the event-log stream and writes tamper-evident hash-chained records to long-term storage with per-tenant retention SLO.

### Deep dives
1. **Anthropic Managed Agents three-tier decoupling.** The Harness (brain), Sandbox (hands), Session (durable event log) are independent processes that scale independently. Any Harness instance can pick up any Session because Session state lives in the durable log — Harness is stateless. Sandboxes are ephemeral (cattle): provisioned lazily on first tool call in a session, killed after the call or after session-idle timeout; no persistent credentials live inside. Anthropic reports p50 TTFT dropped ~60% and p95 dropped >90% after this decoupling vs the prior monolithic architecture. Trade-off: more network hops per tool call (Harness → Session log write → Sandbox dispatch → Session log write) vs the prior in-process tool call. The win is horizontal scalability + crash resilience: a Harness crash leaves the Session intact; another Harness picks up on the next scheduling tick. Staff+ commit: the three-tier boundary, the event log as the durability seam, the cattle-not-pets sandbox lifecycle.

2. **Hypervisor-snapshot session state (Cognition pattern).** For long-running coding agents that may wait minutes-to-hours between events (CI result, user review, async tool result), holding compute warm is prohibitively expensive. Cognition snapshots full VM state (memory, process tree, filesystem) at the hypervisor level — compute shuts down while idle, on-event resume in seconds with exact prior state. Trade-off: snapshot storage cost (terabytes for thousands of concurrent sessions) vs always-on compute cost. Tiered snapshot retention (recent in fast storage, older in cold), delta snapshots vs full, periodic compaction manage the cost. Anti-pattern: try to checkpoint via JSON serialization of agent state — fails on in-process file mutations from compilers/installers, shell history, in-memory caches. The hypervisor boundary captures everything that matters. Staff+ commit: snapshot frequency (every event vs periodic), storage tier policy, resume-latency SLO, what happens to mid-task tool calls in flight at snapshot time (idempotency + verification on resume).

3. **MCP tool protocol + lazy discovery + code-execution-against-MCP.** With hundreds of tools available, naive "dump all schemas in system prompt" costs 50K+ tokens per request just for tool definitions — and intermediate tool results pass back through the model (a 2-hour meeting transcript adds 50K tokens). MCP (Model Context Protocol, JSON-RPC 2.0) is the standard wire format. Lazy discovery: at session start, only tool names are loaded; schemas fetched on demand via MCP `list_tools` or `describe_tool`. Code-execution-against-MCP goes further: instead of the LLM emitting JSON tool calls that the harness dispatches, the LLM emits *code* that runs in a sandbox and uses MCP servers as a library. The 2-hour transcript stays in the sandbox filesystem, never passes through the model. Anthropic published a case where this dropped token usage from 150K to 2K (98.7% reduction). Trade-off: more sandbox compute cost, more complex error handling (code crashes vs JSON parse errors). Staff+ commit: tool retrieval policy, when to use direct tool call vs code-execution-against-MCP, sandbox lifecycle for MCP code.

## Known failure modes
1. **Agent infinite-loops on a flaky tool.** Cost cap by tokens alone insufficient — a tool that fails fast and gets retried 1000 times burns wall-clock and tool-call budget without burning tokens. Production answer: multi-dim cap (max_iterations × max_tokens × max_wall_clock × max_sub_agent_depth × per-tool retry budget); supervisor model that watches for non-progress (LLM keeps making the same tool call) and forces escalation to human or terminates. Anti-pattern: rely on the LLM's own judgment to stop — it won't.

2. **Tool call leaks credentials.** Naive design embeds user OAuth token in the sandbox environment; a malicious tool (or prompt-injected legitimate tool) can exfiltrate it. Production answer: secrets-broker pattern — tool requests a short-lived scoped token at call-time from a broker process running outside the sandbox; broker mints token with minimum scope (read-only access to specific resource) and short TTL; raw user credential never leaves the broker. For OAuth-flow-based tools, the broker handles refresh and exchange; the sandbox sees only the scoped derivative.

3. **Crash mid-run loses partial state.** Without durable execution, a crashed Harness loses everything between checkpoints. Production answer: durable workflow checkpoint at every step boundary (event-log append is the commit); idempotent tool semantics so retries on resume don't cause double-effect (idempotency keys on POST-style tool calls); post-resume verification step that re-checks observed state vs expected (compiler ran? file written? — verify before continuing). For non-idempotent tools, the agent must surface to human-in-loop checkpoint before invocation rather than retrying blindly.

## Notes for the coach
- **This is confirmed asked at Anthropic for MLE roles** per Exponent's 2026 guide: "Design an agentic AI system that can autonomously adapt to new tasks." The Anthropic Managed Agents engineering post is a primary-source architecture from Anthropic — citing it (or naming its three-tier decoupling) is the Anthropic-specific Staff+ signal.
- **Cognition's hypervisor-snapshot insight is the Sr Staff differentiator.** Most candidates default to "checkpoint the agent state as JSON" — that approach breaks for any real coding-agent because process state and FS mutations don't serialize cleanly. The hypervisor boundary is the production answer, and most candidates won't reach for it unprompted.
- **MCP literacy is the 2026 signal.** Candidates who know MCP and the code-execution-vs-tool-calls trade-off are tracking the current production stack. Candidates who don't even reference MCP are anchoring on 2023-2024 patterns (LangChain, AutoGPT). Reward the former.
- **Prompt injection is unsolved.** The honest acknowledgement (12 defenses bypassed >90% in joint Anthropic/OpenAI/DeepMind testing) plus capability scoping + human-in-loop for irreversible actions is the safety-bar move. Penalize the candidate who claims to have "solved" prompt injection with a single layer; reward the candidate who builds defense-in-depth + restricts agent capabilities + escalates to human for high-stakes actions.

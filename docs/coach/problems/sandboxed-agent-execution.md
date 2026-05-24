---
slug: sandboxed-agent-execution
archetype: ai-infrastructure
sources:
  anthropic_claude_code_sandboxing: anthropic.com/engineering/claude-code-sandboxing
  anthropic_mcp_code_exec: anthropic.com/engineering/code-execution-with-mcp
  firecracker_internals: anthony-balitrand.fr/2025/08/12/firecracker-microvms-the-power-behind-aws-lambda/
  ai21_swe_bench: ai21.com/blog/scaling-agentic-evaluation-swe-bench/
---

# Sandboxed agent execution platform (substrate for code-exec agents)

## Bar anchors
- **Mid-level (L4/E4):** Produces a basic Docker-per-task design: each agent code execution runs in a fresh container; container is killed after the call. Recognizes that sandboxing is a security boundary. Doesn't address cold-start latency, capability model, MCP, or audit trail beyond "log everything."
- **Senior (L5/E5):** Names isolation primitive choices at category level (gVisor, Firecracker, full VM) with rough latency awareness. Articulates capability/permission model — agent gets scoped access to filesystem and network, not full shell. Discusses MCP as the tool protocol. Names cost-cap enforcement (max iterations, wall-clock cap). Handles audit log for forensic incident response. Discusses cold-start vs warm-pool trade-off.
- **Staff+ (L6/E6+):** Drives the session proactively. Compares isolation primitives with concrete numbers: E2B Firecracker microVMs 90-150ms cold start with hardware-virtualized isolation; Modal gVisor 2-5s cold start with syscall-interception isolation; Daytona 27-90ms; Blaxel 25ms. Names Claude Code's specific stack: Linux bubblewrap + macOS Seatbelt, network access only through Unix-domain-socket proxy outside the sandbox, reduces permission prompts by 84% in Anthropic internal usage. Articulates the capability DSL (Claude Code's per-pattern bash approval) with persistence and scope. Names MCP lazy tool loading: only tool names at session start, retrieval-based discovery on demand — Anthropic published 98.7% token reduction via code-execution-against-MCP (150K → 2K tokens in their example). Cost-cap multi-dimensional: max iterations × max tokens × max wall-clock × max recursion depth × per-tool retry budget. Audit log tamper-evident hash-chained. Stretch (Sr Staff bar): justifies isolation primitive against threat model (untrusted code in compromised agent exfiltrating SSH keys — Firecracker hardware boundary required, not gVisor); 50K+ concurrent sandbox sessions at Modal-scale; SWE-bench eval economics (200K runs at AI21, 8K parallel sustained, 500 tasks in 7 min).

## Canonical decomposition

### Requirements
**Functional:**
- Spawn per-task isolated sandbox on demand (file system, optional network, CPU, optional GPU)
- Execute arbitrary code in sandbox (bash, python, browser actions) under capability constraints
- Per-task lifetime model: short-lived (per tool call) or session-scoped (lifetime of agent)
- Capability DSL: per-pattern bash approval (Claude Code style); per-domain network access; per-path filesystem
- MCP protocol for tool definition + invocation
- Tamper-evident audit log of every action

**Non-functional (with numbers):**
- Cold start <150ms (Firecracker target; E2B 90-150ms achieved)
- Concurrent capacity: thousands of sandboxes per host (Firecracker: 150 microVMs/sec/host, <5MiB overhead each); Modal supports 50K+ concurrent
- Per-sandbox memory budget: configurable (typical agent task: 256MB-2GB)
- Audit retention: years (compliance); tamper-evident hash chain
- Permission prompt reduction: 84% (Anthropic's Claude Code internal number) — most actions auto-approved via capability scope
- SWE-bench eval throughput: 500 tasks in 7 min (Modal); 35K isolated evaluations / day (AI21)

### Core entities
- **Sandbox:** sandbox_id, isolation_primitive (Firecracker | gVisor | bubblewrap), lifetime (per_call | per_session), base_image, capability_set, created_ts, owner_session_id
- **Capability:** scope (bash_pattern | net_domain | fs_path), allow / deny, persistence (session | project | global)
- **ToolDefinition:** tool_name, mcp_server, schema (lazy-loaded), required_capabilities
- **Execution:** execution_id, sandbox_id, command, args, stdout, stderr, exit_code, audit_event_ids, ts
- **AuditEvent:** event_id, sandbox_id, tool_invocation, capability_check_result, signed_hash, ts

### API
- `POST /v1/sandboxes` body={isolation_primitive, lifetime, base_image, capabilities, mcp_servers} → {sandbox_id, ready_in_ms}
- `POST /v1/sandboxes/:id/exec` body={command, args, timeout} → SSE stream of stdout/stderr + final exit code
- `POST /v1/sandboxes/:id/capability` body={scope, allow_deny} → capability update (subject to user approval if interactive)
- `GET /v1/sandboxes/:id/audit` → full audit chain for forensic review
- `DELETE /v1/sandboxes/:id` → kill, emit final audit event

### HLD
The platform runs a **sandbox host fleet** of bare-metal or large-VM nodes running Firecracker (for untrusted-code execution) or gVisor (for semi-trusted) or bubblewrap (for trusted-but-namespace-isolated). A **scheduler** assigns incoming sandbox requests to hosts (bin-packing on memory, respecting per-tenant quotas). The **sandbox manager per host** maintains a small pool of pre-warmed base images for sub-150ms cold start; on request, it clones the warm image, applies the requested capability set, and returns the sandbox_id. **Capability enforcement** runs in the sandbox-supervisor process (outside the sandbox): every bash command, network egress, filesystem mutation is matched against the capability set; deny by default. **Network egress proxy** is a Unix-domain-socket proxy outside the sandbox (Claude Code model) — sandbox has no direct network; all egress goes through the proxy which enforces per-domain capability + audit. **MCP protocol layer** loads tool definitions lazily: at sandbox start, only tool names are registered; on first invocation, the schema is fetched from the MCP server. For code-execution-against-MCP, the LLM emits Python code that invokes MCP servers as a library; this keeps intermediate results in the sandbox filesystem rather than passing them through the model (98.7% token reduction). **Audit pipeline** consumes every capability-check event and exec event, writes tamper-evident hash-chained records to a compliance store. **Cost-cap enforcer** runs as a sidecar tracking wall-clock + memory + CPU + tool-call count per session; hard-stop on breach.

### Deep dives
1. **Isolation primitive selection with cold-start numbers.** Firecracker microVMs: hardware-virtualized, own kernel per microVM, kernel exploits can't escape; boot ~125ms, 150 microVMs/sec/host, <5MiB overhead each; AWS Lambda uses it under the hood. gVisor: syscall-interception runtime, "own kernel" via user-space syscall implementation, no hardware virt boundary; Modal uses it for sandboxes that need GPU access (A100/H100) but cold start is 2-5 seconds for non-trivial environments. bubblewrap: namespace-based isolation (Linux user namespaces, mount namespaces); fast (sub-100ms) but weaker boundary — process-level isolation, not kernel-level. Claude Code uses bubblewrap on Linux + Seatbelt on macOS for the local-developer-trust threat model. Trade-off: stronger isolation → higher overhead, except Firecracker which is engineered for sub-150ms. Staff+ commit: name primitive, justify against threat model — untrusted-code execution from a network-reachable agent demands Firecracker; trusted developer's local code can use bubblewrap.

2. **Capability/permission DSL with persistence.** Claude Code's per-pattern bash approval reduces user permission prompts by 84%. The DSL: `Bash(git status:*)` allows any `git status ...` command; `Read(./src/**/*.ts)` allows reading TypeScript files in src; `Edit(./CLAUDE.md)` allows editing one file. Patterns can be glob, regex, or command-prefix; persistence scope is per-session (just this conversation), per-project (any future session on this repo), or per-user (across all projects). Default deny; explicit allow on first encounter persists per the chosen scope. The matching engine is on the critical path of every tool call — must be fast (<1ms typical). Staff+ commit: pattern grammar (glob? regex? command-prefix? all three?), persistence storage (per-tenant config in central store, or per-project file checked into repo), default-deny semantics, conflict resolution (specific patterns override general).

3. **MCP protocol + lazy discovery + code-execution-against-MCP.** Naive design: at agent start, load all 100+ tool schemas into the system prompt = 50K+ tokens before any user input. Intermediate tool results pass back through the model (a 2-hour meeting transcript = 50K tokens). Anthropic published a case where this dropped from 150K to 2K tokens (98.7% reduction) via code-execution-against-MCP: instead of LLM emitting JSON tool calls, the LLM emits Python code that runs in the sandbox and uses MCP servers as a library. Intermediate data stays in the sandbox filesystem; only summaries pass to the LLM. Lazy tool discovery: at session start, register only tool names with brief descriptions; on demand, the agent emits `mcp.describe('transcript_summarizer')` which fetches the full schema. Trade-off: more sandbox compute cost (running Python vs LLM dispatching JSON), more complex error handling (Python exceptions vs JSON parse errors). Staff+ commit: tool retrieval policy, when to use direct tool call vs code-execution-against-MCP (direct for simple synchronous tools; code-exec for data-heavy or multi-step), sandbox lifecycle for MCP code.

## Known failure modes
1. **Sandbox escape via kernel exploit.** gVisor or bubblewrap container may not fully contain a determined attacker exploiting a kernel CVE. Production answer: Firecracker for any untrusted-code execution (hardware virt boundary survives kernel exploits within the microVM); immutable per-task base image (no persistence of attacker artifacts); no cross-task secret access (each sandbox has its own scoped credentials, never the user's raw token); periodic kernel patching of the Firecracker host. Threat-model justification: assume the agent will be prompt-injected; assume the resulting code will be hostile; design accordingly.

2. **Cost runaway via infinite tool loops.** Agent gets stuck in retry loop on a failing tool, burns through token + wall-clock + tool-call quota. Production answer: max_iterations cap (e.g., 50 tool calls per session), per-tenant cost cap with hard shut-off, alerting on anomalous spend (5× tenant baseline triggers human review), per-tool retry budget that decrements globally not per-tool-instance (otherwise agent can call tool A 10 times, tool B 10 times, etc, escaping the per-tool limit). For SWE-bench-class long-running tasks where 100+ tool calls is normal, the cap must be calibrated per workload class.

3. **Tool definition bloat at scale.** Adding 100+ tools to an agent inflates every request by tens of K tokens just for definitions, even when only 1-2 tools are actually invoked. Production answer: lazy tool loading via MCP retrieval — only tool names live in the system prompt, schemas fetched on demand. For data-heavy workflows (transcript processing, log analysis), code-execution-against-MCP keeps intermediate data in the sandbox filesystem entirely, never passing through the model. The 98.7% token reduction from Anthropic's published case isn't an outlier — it's the typical magnitude when intermediate data dominates token count.

## Notes for the coach
- **This is plausibly-asked at Anthropic.** Claude Code engineering posts (sandboxing, MCP code execution) are primary-source architectures from Anthropic — a candidate who cites them by name demonstrates Anthropic-specific literacy. The substrate question is distinct from the orchestrator question (`agentic-tool-orchestrator`): this problem is about the sandbox layer specifically, not the agent loop.
- **The isolation-primitive comparison with concrete numbers is the Staff+ unlock.** Most candidates say "Docker" or "container" without engaging with the threat model. The candidate who names Firecracker vs gVisor vs bubblewrap with cold-start numbers and threat-model justification is at L6+ bar.
- **MCP literacy is the 2026 signal** (same note as `agentic-tool-orchestrator`). Code-execution-against-MCP is the specific Anthropic-pioneered pattern; naming it unprompted is the Sr Staff differentiator.
- **The 84% permission-prompt-reduction number is the Anthropic-specific UX-architecture anchor.** It quantifies why capability scoping matters — without it, the agent UX degrades to "ask every time" which is operationally untenable.
- **Cost-cap multi-dimensionality is the safety-bar move.** Token-only cap misses agents that burn wall-clock and tool calls without burning tokens (e.g., infinite retry on a failing tool that returns short error messages). Multi-dim cap is the production answer.

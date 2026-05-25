---
slug: multiplayer-game-sync
archetype: conflict-resolution
sources:
  gambetta: gabrielgambetta.com/client-server-game-architecture.html
  valve_source: developer.valvesoftware.com/wiki/Source_Multiplayer_Networking
  gaffer_lockstep: gafferongames.com/post/deterministic_lockstep/
  gaffer_snapshot: gafferongames.com/post/snapshot_interpolation.md
  ggpo: en.wikipedia.org/wiki/GGPO
---

# Multiplayer Game Sync (authoritative server, prediction, rollback netcode)

## Bar anchors
- **Mid-level (L4/E4):** "Each client sends its position to the others." Doesn't address authority, cheating, latency hiding, or what happens when packets are lost/reordered.
- **Senior (L5/E5):** Authoritative server simulates the game; clients send inputs and render server state; client-side prediction hides latency. Knows interpolation smooths motion and there's a tick rate. May not distinguish lockstep vs snapshot vs rollback, explain server reconciliation precisely, or lag compensation.
- **Staff+ (L6/E6+):** Drives proactively. Distinguishes the three families and their tradeoffs: **deterministic lockstep** (send *inputs* only, every client runs the identical simulation — bandwidth ∝ input not object count, ~90 bytes for 120 frames; cheat-resistant; but **latency = the most-lagged player** and **float-determinism across platforms is hard**; RTS); **snapshot interpolation / state sync** (server simulates at a fixed tick, clients render ~100ms behind by interpolating between snapshots — Source's **66.6 tick / 15ms**, **cl_interp 0.1**; **lag compensation rewinds the server ≤1s** to validate a shot from the shooter's view; FPS); **rollback** (GGPO: **predict** the remote player's input, simulate immediately, and on misprediction **roll back to the last correct frame and replay 1–7 frames** — fighting games). Explains **client-side prediction + server reconciliation** via **input sequence numbers** (the server echoes the last processed input; the client discards acked inputs and **replays the unacked ones** on the corrected state). Names the **authoritative server as the primary anti-cheat** ("don't trust the player"). Cites CS:GO 64/128 tick.

## Canonical decomposition

### Requirements
**Functional:**
- Many clients share a consistent game world in real time despite latency and loss
- Local input feels instant (no input lag) while the server stays authoritative
- Hits/interactions are fair and cheat-resistant
- Tolerate packet loss/reordering (UDP)

**Non-functional (with numbers):**
- Server tick: 66.6 Hz default (Source, 15ms); CS:GO 64 tick (Valve MM) / 128 tick (FACEIT)
- Client interpolation delay ~100ms (cl_interp 0.1); lag-compensation rewind window ≤1s
- Rollback window typically 1–7 frames (~16–116ms at 60 FPS)
- Lockstep input payload tiny (~90 bytes worst case for 120 frames), independent of object count

### Core entities
- **Authoritative server state:** the canonical world (the only truth that matters)
- **Input (command):** a client's per-tick input, tagged with a **sequence number**
- **Snapshot:** server world state at a tick (state-sync) — interpolated between on the client
- **Prediction buffer:** unacked local inputs replayed after reconciliation / rollback
- **History buffer:** recent player positions (for lag compensation, ~1s)

### API
- `client → server`: input(sequence_number, command) over UDP
- `server → client`: snapshot(tick, state, last_processed_input_seq)
- client reconciliation: drop inputs ≤ acked seq; replay the rest on the server state
- (rollback) on remote-input arrival: if mispredicted, rewind to frame F, replay F→now

### HLD
The **server is authoritative**: clients send **inputs** (not state), the server simulates the world at a fixed **tick**, and sends back **snapshots** — clients are "privileged spectators." This is the anti-cheat foundation ("don't trust the player"): a client can't teleport because it doesn't own the state. To hide latency, the client does **prediction** — it applies its own input locally immediately, tagging each input with a **sequence number** — and **reconciliation**: each snapshot carries the **last input sequence the server processed**, so the client discards acked inputs and **replays the still-unacked ones** on top of the authoritative state (correcting any divergence smoothly).

The three families trade differently:
- **Deterministic lockstep** sends only inputs; every client runs the *same* deterministic simulation, so bandwidth is ∝ input size and **independent of object count** (a million-unit RTS costs the same as one unit). The costs: **every player's latency = the most-lagged player** (you can't simulate a turn until all inputs arrive), and **floating-point determinism across compilers/OSes/CPUs is brutally hard** — any divergence desyncs the game.
- **Snapshot interpolation / state sync** (Source): the server ticks at **66.6 Hz**; clients render **~100ms in the past** (cl_interp 0.1), interpolating between the last two snapshots for smooth motion. **Lag compensation** keeps ~**1s of player-position history** and **rewinds the server** to the shooter's view-time (Current Server Time − latency − interpolation) to validate a hit — so you aim *where you see* the enemy, no leading.
- **Rollback** (GGPO): the client **predicts** the remote input (assume they keep doing what they did), simulates immediately for zero input lag, and on a misprediction **rolls back to the last confirmed frame and replays 1–7 frames** with the corrected input. Great for 2-player fighting games (preserves offline timing/muscle memory); poor for many-entity physics (replaying everyone is too expensive).

### Deep dives
1. **Client-side prediction + server reconciliation.** The mechanism that makes a networked game feel local: apply input immediately with a sequence number; when the authoritative snapshot arrives stamped with the last-processed sequence, snap to the server state and **replay** the inputs the server hasn't seen yet, so the local view stays both responsive *and* eventually-correct. This is structurally the **same rebase pattern** as `local-first-sync` (optimistic local op + replay-unacked-on-authoritative-state) — a cross-archetype connection worth naming. The hard part is smoothing the correction (interpolate the position delta rather than teleport).
2. **The three netcode families and when to pick each.** Lay out the decision: **RTS / huge object counts → lockstep** (inputs are tiny, state is enormous; accept most-lagged-player latency and pay the determinism cost). **FPS / many players → snapshot interpolation + lag compensation** (state is large and float-determinism infeasible across a big playerbase; accept 100ms interpolation delay and the lag-comp fairness tradeoff). **2-player fighting → rollback** (input precision is everything; predict + rollback a few frames hides latency with occasional visual snap-back). Quote tick rates (Source 66.6, CS:GO 64/128) and windows (interp 100ms, lag-comp 1s, rollback 1–7 frames). The Staff+ signal is matching the family to the game's state-size and latency-sensitivity, not declaring one "best."
3. **Lag compensation and its fairness paradox.** To make shooting feel right under latency, the server **rewinds** other players to where the shooter *saw* them (using the ~1s position history and the shooter's latency+interpolation offset), then validates the hit against that past state. The benefit: no need to lead your aim. The paradox: a victim can be **shot "after" they rounded a corner on their own screen**, because on the shooter's (delayed) screen they were still exposed. There's no free lunch — you pick whose timeline is authoritative for hit validation. Capping the rewind (Source ≤1s) bounds the unfairness. Naming this tradeoff explicitly is the depth marker.

## Known failure modes
1. **One laggy player stalls deterministic lockstep.** The turn can't simulate until all inputs arrive. Production answer: an input-delay buffer to absorb jitter, and eject/AI-substitute persistently lagged players; or switch to a model that doesn't gate on all-inputs.
2. **Misprediction storm exceeds the rollback budget.** Physics-heavy or many-entity games can't replay 7 frames within a 16ms budget. Production answer: keep the simulation deterministic and cheap, cache historical states, and prefer snapshot interpolation when entity count is high.
3. **Lag-compensation "shot behind cover" complaints.** Rewinding too far lets victims be hit after escaping on their own screen. Production answer: cap the rewind window (≤1s), and tune so the shooter's experience and victim fairness are balanced for the game's pace.

## (Spine note)
`multiplayer-game-sync` is the hard-real-time member of this archetype: lockstep is a degenerate CmRDT (ops = inputs, the deterministic simulation is the "merge"); client-prediction + reconciliation is the same rebase pattern as `local-first-sync`. UDP transport + reliability layering is shared with messaging — reference, don't re-derive.

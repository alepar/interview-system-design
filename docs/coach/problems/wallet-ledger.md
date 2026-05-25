---
slug: wallet-ledger
archetype: concurrent-resource
sources:
  double_spend_codetodeploy: medium.com/codetodeploy/solving-the-double-spend-system-design-patterns-for-bulletproof-fintech-ee5d73f33415
  db_concurrency_defects: ketanbhatt.com/p/db-concurrency-defects
  modern_treasury_occ: moderntreasury.com/journal/designing-ledgers-with-optimistic-locking
  pg_ssi: wiki.postgresql.org/wiki/SSI
  tigerbeetle: docs.tigerbeetle.com/coding/two-phase-transfers/
---

# Wallet / Ledger (concurrent debits, no double-spend)

## Bar anchors
- **Mid-level (L4/E4):** Reads balance, checks it's enough, writes balance − amount. Doesn't see the read-modify-write race (two concurrent debits both pass the check → negative balance).
- **Senior (L5/E5):** Conditional update (`SET balance = balance − amt WHERE balance >= amt`) or `SELECT FOR UPDATE`; idempotent transactions; knows the double-spend race. May not articulate the append-only ledger / derived balance, isolation-level subtleties, or cross-account transfer atomicity.
- **Staff+ (L6/E6+):** Drives proactively. Names the **read-modify-write double-spend race** (both debits read $500, both pass, commit −$300 and −$400 → −$200; READ COMMITTED doesn't stop it) and fixes it with **OCC** (`UPDATE … SET balance = balance − amt WHERE id=? AND balance >= amt`; 0 rows ⇒ reject — re-checks the invariant atomically at write time) or **pessimistic `SELECT FOR UPDATE`**, or **SERIALIZABLE/SSI** (aborts the conflicting committer → app retries). Makes the **immutable append-only double-entry ledger** the source of truth (every movement = balanced debit+credit rows; **balance is derived**, not a mutable column of record — prevents drift), enforces debits=credits at the DB layer, and makes transactions **idempotent** (transfer_id key). Handles **cross-account transfer** atomicity (debit+credit in one transaction, or a **saga** with compensation across services — noting the non-atomic window). References **TigerBeetle** (purpose-built double-entry OLTP, ~1M transfers/sec, two-phase pending/post/void reserved funds, linked all-or-nothing transfers).

## Canonical decomposition

### Requirements
**Functional:**
- Debit/credit an account balance; never allow a double-spend / negative balance
- Atomic transfers between accounts (debit one, credit another)
- Idempotent transactions (a retried transfer doesn't double-apply)
- Auditable, verifiable balance history

**Non-functional (with numbers):**
- Strong consistency on balances (financial correctness, non-negotiable)
- OCC throughput degrades under hot-account contention (e.g. ~159 vs ~434 req/sec, 2 vs 200 accounts)
- TigerBeetle: ~1M transfers/sec, up to 8,189 transfers/batch, no row locks
- Idempotent transfers (transfer_id) for exactly-once

### Core entities
- **Ledger entry:** immutable (account, amount, direction, transfer_id, ts) — debit or credit
- **Account:** derived balance (sum of entries) or a cached balance that reconciles to the log
- **Transfer:** a balanced pair (debit A, credit B) sharing a transfer_id
- **Pending transfer (two-phase):** reserved funds (debits_pending) posted or voided later

### API
- `POST /transfer {from, to, amount, transfer_id}` → atomic debit+credit; idempotent on transfer_id
- debit guard: `UPDATE accounts SET balance = balance − :amt WHERE id=:id AND balance >= :amt`
- balance: `SELECT SUM(...) FROM ledger WHERE account=:id` (derived) or reconciled cache
- two-phase: reserve (pending) → post (commit) | void (release)

### HLD
The hazard is the **read-modify-write race** on a balance: two concurrent debits both read $500, both pass their "enough funds?" check, then both commit (−$300 and −$400) → **−$200** (double-spend / overdraft). PostgreSQL's default READ COMMITTED does **not** prevent this (each transaction's read-then-write sails through). Three correct fixes: **OCC** — the conditional update `UPDATE accounts SET balance = balance − :amt WHERE id=:id AND balance >= :amt` re-checks the invariant **atomically at write time**, so the second debit affects 0 rows and is rejected (fast, no held lock, reads never blocked, but degrades under hot-account contention as conflicting txns retry); **pessimistic** `SELECT FOR UPDATE` — lock the row before modifying (correct, but serializes and queues under contention); or **SERIALIZABLE / SSI** — the DB detects the write-skew and aborts the later committer (app retries). Choose by contention: OCC/SSI for low-conflict, pessimistic for write-heavy hot accounts.

The deeper design makes an **immutable, append-only double-entry ledger** the source of truth: every money movement appends a **balanced pair** of rows (a debit and an equal credit), never edits a balance in place. The **balance is derived** (sum of entries, or a cached materialized value that must reconcile to the log) — so it can never drift from reality and can be replayed after a crash, and the invariant **debits == credits** is enforced at the DB transaction layer (no partial unbalanced entry). **Idempotency** (a `transfer_id` key, unique-constrained) makes a retried transfer a no-op (exactly-once). A **cross-account transfer** must be atomic: debit A and credit B in one transaction (single DB) — or, across services, a **saga** (debit then credit with a compensating reverse if the credit fails), explicitly noting the **eventual-consistency window** where balances look inconsistent between the two legs. **TigerBeetle** is the purpose-built reference: a double-entry OLTP database doing ~1M transfers/sec with no row locks, batching up to 8,189 transfers/request, **two-phase transfers** (a *pending* transfer reserves funds in `debits_pending`, later *posted* or *voided*, with an optional timeout auto-release), and **linked** transfers (a chain that all-succeeds-or-all-fails) for multi-leg atomicity.

### Deep dives
1. **The double-spend race + the three fixes.** The canonical concurrency defect: read-modify-write on balance under concurrency overdraws. Walk why READ COMMITTED fails (no lost-update protection on separate read+write) and the three remedies — **OCC** (`WHERE balance >= amt`, re-check at write, retry the loser), **pessimistic** (`SELECT FOR UPDATE`, lock-then-modify), **SERIALIZABLE/SSI** (detect-and-abort). The Staff+ nuance is the **contention tradeoff**: OCC is great at low conflict but *thrashes* under a hot account (a stress test showed ~159 req/sec on 2 hot accounts vs ~434 across 200) because conflicting transactions fail their version check and retry, burning CPU; pessimistic locking wins under sustained hot-account contention by queuing instead of retrying. Name the mechanism *and* the contention regime where each is right.
2. **Append-only double-entry ledger + derived balance.** Professional fintech doesn't store a mutable balance as the record of truth — it appends **immutable double-entry rows** (every transfer = a debit and an equal credit) and **derives** the balance (sum, or a cache that reconciles to the log). Why: an editable balance can drift (a missed update, a partial failure) with no audit trail, whereas an immutable journal is verifiable, replayable after a crash, and enforces **debits == credits** at the DB layer so no partial/unbalanced state exists. The balance is a *projection*, not the source. This is the architectural backbone that makes the concurrency control (above) safe and auditable — OCC/locks protect the *write*, the ledger guarantees the *truth*.
3. **Cross-account transfer atomicity + two-phase reservations.** A transfer is two effects (debit A, credit B) that must be **all-or-nothing**. In one DB, wrap them in a transaction (or, TigerBeetle-style, a **linked** chain that succeeds/fails together). Across services/ledgers, use a **saga**: debit A, then credit B, with a **compensating** credit-back to A if B fails — explicitly acknowledging the **window** between the committed debit and the credit where balances are temporarily inconsistent (eventual consistency, not atomic). For workflows that hold funds (escrow, auth-then-capture), **two-phase transfers** reserve funds in a *pending* state (`debits_pending`, unspendable) that is later *posted* or *voided*, with an optional timeout auto-release — the ledger analog of a reservation hold. The framing: transfers need atomicity (transaction/linked) or compensation (saga), plus a pending state for held funds, and idempotency (transfer_id) throughout.

## Known failure modes
1. **Double-spend / negative balance.** Concurrent debits both pass the funds check. Production answer: OCC (`WHERE balance >= amt`) / `SELECT FOR UPDATE` / SERIALIZABLE; never rely on READ COMMITTED read-then-write; immutable ledger as truth.
2. **Balance drift from a mutable balance column.** A missed/partial update desyncs the stored balance from reality. Production answer: append-only double-entry ledger as source of truth; balance derived (or a cache reconciled to the log); enforce debits==credits at the DB.
3. **Partial transfer (debit applied, credit lost).** A crash between the two legs leaves money missing. Production answer: single-transaction (or linked) atomicity in one ledger; saga with compensation across services (accepting the inconsistency window); idempotency on transfer_id so retries don't double-apply.

## (Delineation note)
`wallet-ledger` is the balance-integrity / no-double-spend concurrency variant. The full payment *processor* is infra-primitives `stripe-payments`; idempotency depth is `idempotent-payment`; the lock primitive is `distributed-lock` — reference, don't re-derive. Here it's OCC-vs-locks on balances + the append-only double-entry ledger + transfer atomicity.

---
slug: mls-group
archetype: interactive-messaging
sources:
  rfc_9420: datatracker.ietf.org/doc/rfc9420 ("The Messaging Layer Security (MLS) Protocol")
  rfc_9750: datatracker.ietf.org/doc/rfc9750 ("MLS Architecture")
  discord_dave: discord.com/blog/meet-dave-our-new-end-to-end-encryption-for-audio-video
---

# MLS group — RFC 9420 group E2E with TreeKEM at O(log N) update cost

## Bar anchors
- **Mid-level (L4/E4):** Treats group E2E as "encrypt N times" (pairwise). Doesn't recognize the O(N²) cost on member-change.
- **Senior (L5/E5):** Names Sender Keys (O(N) per member-remove). Knows FS + PCS as concepts. May or may not address MLS, TreeKEM, or the Delivery Service split.
- **Staff+ (L6/E6+):** Drives proactively. Cites **RFC 9420 (July 2023)** and its O(log N) member-removal cost via **TreeKEM** / RatchetTree. Articulates the **tree structure**: members are leaves of a binary tree; each internal node holds a key derived via HPKE from its children; only members on the path from a changed leaf to the root need updates. Names the **Commit / Welcome / Proposal flow**: any member proposes change; Commit batches proposals and broadcasts new tree state; Welcome delivers tree to newly-added members. Articulates the **Delivery Service** role (server orders Commits, cannot decrypt) vs **Authentication Service** (vouches for identity-to-key bindings). Quantifies the cost comparison: **for 10K-member group, Sender Keys ≈ 10K HKDF + 10K transports; MLS ≈ 14 transports** (log₂ 10K ≈ 14). Stretch (Sr Staff bar): articulates **deployments** (Discord DAVE for voice, Cisco Webex, RingCentral; Meta piloting for WhatsApp large groups); explains the **federated MLS gap** (RFC 9420 designed for centralized DS; ongoing IETF work for federation, e.g., MIMI WG).

## Canonical decomposition

### Requirements
**Functional:**
- Asynchronous group key establishment for 2 to ~50K members
- Forward secrecy (FS) and post-compromise security (PCS) for groups
- O(log N) update cost for add / remove / update
- Delivery Service that does not see plaintext (orders Commits, forwards ciphertext)
- Authentication Service binds KeyPackages (identity → key) — separable from DS

**Non-functional (with numbers):**
- Per RFC 9420 abstract: *"groups in size ranging from two to thousands"*
- Member-removal cost: O(log N) ciphertext + O(log N) tree nodes touched
- For 10K-member group: ~14 ciphertexts (vs ~10K for Sender Keys)
- Deployed: Discord DAVE (voice), Cisco Webex, RingCentral

### Core entities
- **Group:** group_id, current_epoch, tree_state, ratchet_state
- **KeyPackage:** per-member identity binding + leaf keys + ciphersuite; signed by user's identity key
- **RatchetTree:** binary tree of HPKE keypairs; leaves = members; internal nodes = derived from children
- **Proposal:** add | remove | update; submitted by any member
- **Commit:** batches proposals; advances epoch; new tree state
- **Welcome:** sent to newly-added member; carries tree state + initial keys

### API
- `POST /mls/groups/{id}/proposals` — member submits Add/Remove/Update proposal
- `POST /mls/groups/{id}/commit` — member submits Commit (batches proposals); DS total-orders Commits
- `GET /mls/groups/{id}/welcome` — newly-added member fetches Welcome message
- `POST /mls/messages` — encrypted group message; DS routes opaque ciphertext to all members

### HLD
**Delivery Service (DS)** orders Commits (provides total ordering across concurrent commits) and forwards opaque ciphertext to members; **cannot decrypt** (sees only authenticated metadata: group_id, epoch, sender_index). **Authentication Service (AS)** binds KeyPackages (per-member identity + leaf key) — verifies signatures, can be HSM-backed in regulated deployments. **Group lifecycle**: founder creates group, generates initial RatchetTree (just itself as a leaf); founder uses Welcome to invite members (one Welcome per new member with the tree state); subsequent member additions proceed via Commit batching proposals. **Per-message encryption**: sender computes their epoch's chain key (from the tree state at current epoch); encrypts message with derived message_key; sends opaque ciphertext to DS; DS routes to all members. **Member change** (add/remove/update): submitter generates Proposal(s); some member generates Commit (batches Proposals, advances tree, advances epoch); broadcasts Commit; all members apply Commit and derive new chain key for new epoch. **PCS**: every Commit rotates the epoch; even if device compromised, after next Commit attacker is locked out.

### Deep dives
1. **TreeKEM structure — O(log N) update cost.** Members are leaves of a binary tree of size 2^⌈log₂N⌉ (padded with blank leaves). Each internal node has an HPKE keypair derived from its children. To add a member: occupy a blank leaf or grow the tree; update the path from new leaf to root (only log N nodes change). To remove: blank the leaf; update path from blanked leaf to root. To update (key rotation): same — update path from your leaf to root. **Cost**: O(log N) ciphertext (each updated node's new public encrypted to each sibling subtree); O(log N) tree nodes touched. For 10K-member: ~14 nodes (vs Sender Keys O(N) = 10K). For 50K-member (Meta's WhatsApp target): ~16 nodes vs 50K — 3000× improvement. Trade: tree state is more complex than per-sender chains; client memory + Commit processing is more involved.

2. **Commit / Welcome / Proposal flow.** **Proposal**: any member submits Add(new_member_key_package) / Remove(member_index) / Update(self_new_leaf_key). DS orders proposals within epoch. **Commit**: some member (often the proposer, or a designated "committer") generates a Commit message that includes (a) list of proposals to apply, (b) updated path from committer's leaf to root, (c) new epoch number. Commit is broadcast; DS total-orders; all members apply (advance tree, advance epoch). **Welcome**: when a member is newly added, the Commit that added them includes a Welcome message specifically encrypted to their KeyPackage (carries the tree state + initial epoch keys). New member receives Welcome, initializes their state. **Concurrent commits**: DS imposes total ordering; if two members commit in the same epoch, DS picks one as the "winner" (typically first-received); the losing commit's proposals become proposals against the new (post-winning-commit) epoch and can be re-committed.

3. **Comparison vs Signal Sender Keys + deployment landscape.** **Sender Keys (Signal/WhatsApp)**: O(N) member-removal cost (every remaining member must receive a new sender chain). For 1024-member WhatsApp group: 1024 HKDF + 1024 transports. For 10K-member: 10K + 10K. **MLS**: O(log N). For 10K: 14. Why now? MLS RFC 9420 was published July 2023 with Meta-authored sections; production deployments came online 2023-2024: **Discord DAVE** for voice channels (per Discord blog), **Cisco Webex** (Cisco co-authored the RFC), **RingCentral**. Meta piloting MLS for WhatsApp's large groups (formerly capped because of Sender Key cost). Trade vs Sender Keys: MLS state is more complex (Commit ordering, tree maintenance, KeyPackage management); for very small groups (<10 members), Sender Keys is simpler with negligible cost difference.

## Known failure modes
1. **Concurrent commits in the same epoch.** Two members commit simultaneously; both broadcast. Production answer: DS total-orders Commits; one wins; losing commit's proposals are re-applied against the new epoch (or re-committed by the original submitter). MLS spec specifies this explicitly.

2. **Identity confusion** (attacker uploads KeyPackage claiming to be Alice). Production answer: external **Authentication Service** verifies KeyPackage signatures against identity certificates (or out-of-band verification via safety numbers); members reject KeyPackages with invalid signatures. AS can be HSM-backed for regulated deployments.

3. **Re-add after compromise.** Member's device compromised; they remove and re-add via new KeyPackage. Production answer: PCS guarantee from the next Commit — once committed, the attacker (without ongoing access) is locked out from subsequent messages. Trade: messages between compromise and Remove-Commit remain readable to attacker; user should rotate identity key + safety-number verify.

## Notes for the coach
- **Plausibly-asked at Staff+** at Meta, Discord (DAVE), Cisco. **Asked-confirmed at Discord** for DAVE-adjacent roles. RFC 9420 (July 2023) is primary; RFC 9750 covers MLS Architecture.
- **The "O(log N) vs O(N) member-removal" framing is the Staff+ unlock.** Candidates who can do the math (10K → 14 ciphertexts) demonstrate the value; candidates who say "MLS is better" without quantifying miss the depth.
- **The Commit/Welcome/Proposal flow is the protocol-design depth probe.** Candidates who name all three message types and the role of DS total ordering demonstrate RFC literacy.
- **Adversarial probe: "what if the Delivery Service colludes with an evicted member?"** Strong answer: PCS guarantee binds — once Commit applied, evicted member cannot derive new epoch keys; DS sees only opaque ciphertext; collusion gains nothing. Weak answer: "DS is trusted" — but MLS designed for untrusted DS.

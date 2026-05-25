---
slug: inbox-zero
archetype: fan-out
sources:
  gmail_priority: research.google/pubs/the-learning-behind-gmail-priority-inbox/
  rfc_5322: rfc-editor.org/rfc/rfc5322.html
  gmail_imap: developers.google.com/workspace/gmail/api/guides/pop_imap_settings
  outlook_ml: office365itpros.com/2023/03/09/machine-learning-in-outlook/
  spam_stack: maildiver.com/blog/how-do-email-spam-filters-work/
  superhuman: help.superhuman.com/hc/en-us/articles/38456456380051-Unified-Inbox
---

# Inbox-zero — Gmail Priority Inbox per-user logistic regression with online passive-aggressive PA-II + non-stationary noisy implicit labels + per-user higher regularization than global + cross-DC scoring without delaying mail delivery + RFC 5322 Message-ID + In-Reply-To + References threading + Outlook Conversation-ID + Gmail API + Cloud Pub/Sub push (lower latency than IMAP IDLE) + 7-layer spam stack + unified inbox via per-protocol sync to local SQLite/index + client-side merge

## Bar anchors
- **Mid-level (L4/E4):** Designs single inbox table with chronological sort; no priority, no threading.
- **Senior (L5/E5):** Names priority sort + threading by Subject. May or may not articulate PA-II online learning, RFC 5322 headers, sync protocol trade-offs, or 7-layer spam stack.
- **Staff+ (L6/E6+):** Names (a) **Gmail Priority Inbox** per-user logistic regression with online PA-II updates to combat noisy implicit labels; each mail updates global model + per-recipient model exactly once; per-user higher regularization than global; (b) scale: rate exceeds single machine; near-online updating of millions of per-user models/day; must score any user from any DC without delaying mail delivery; (c) **implicit labels** (open, reply, time-to-action, click); most users never explicitly mark importance; (d) **RFC 5322 threading**: Message-ID, In-Reply-To, References headers; Gmail conversation view prioritizes these; **Outlook layers proprietary Conversation-ID** for robustness; absence in forwarded mail breaks threading; (e) **sync protocol trade-off**: IMAP IDLE universal but Gmail's higher-latency than **Gmail API + Cloud Pub/Sub push channel** — delivers near-real-time without per-account TCP connections; (f) **Outlook Focused Inbox**: binary Focused vs Other classifier; bootstrapped from contact-list + sender-type signals; online updates on user moves; Privacy-Preserving ML; erase source data post-processing; (g) **7-layer spam stack**: IP blacklists (RBLs), rule engines (SpamAssassin), per-user Bayesian (PopFile), sender reputation (Ironport), decoy/honeypot, collaborative checksums (Cloudmark), ML ensemble; (h) **unified inbox vendors** (Spark, eM Client, Thunderbird, Missive) sync per-account via native protocol (Gmail API, Microsoft Graph, IMAP IDLE) into local SQLite/index, merge client-side; Superhuman skips to avoid IMAP complexity.

## Canonical decomposition

### Requirements
**Functional:**
- Unified inbox across Gmail + Outlook + IMAP accounts
- Threading (conversation view)
- Priority sorting (Important / Focused vs Other)
- Spam filtering
- Search

**Non-functional:**
- Per-user models updated near-online; millions of users
- Cross-DC scoring without delaying mail delivery
- IMAP IDLE 5min-30min latency on Gmail; Gmail API push <1s

### Core entities
- **Message:** message_id, account_id, thread_id, headers{message-id, in-reply-to, references, conversation-id}, raw_body
- **Thread:** thread_id, account_id, message_ids[]
- **PriorityModel:** per (user, account) — weights for logistic regression
- **SpamModel:** per-layer score outputs + ensemble

### API
- `GET /inbox?account=*&filter=focused` (unified view)
- `POST /sync` (per-account trigger)
- Push: Cloud Pub/Sub → /webhook for Gmail; webhook for Outlook Graph

### HLD
Per-account sync workers: Gmail → Gmail API + Cloud Pub/Sub push for low-latency; Outlook → Microsoft Graph webhook subscription; generic IMAP → IDLE long-poll. Each writes messages to local SQLite/index keyed by account_id.

Threading: parser extracts Message-ID + In-Reply-To + References + Outlook Conversation-ID; threads computed at index time. Subject heuristics ("Re:", "Fwd:") as fallback for forwarded mail without References.

Priority scoring: PA-II online logistic regression per (user, account); features include sender history, time-to-open, reply patterns, content topic. Cross-DC: model weights replicated; scoring local.

Spam: 7-layer stack as pipeline — RBL → rule engine → per-user Bayesian → sender-reputation → decoy → collaborative checksum → ML ensemble.

Unified UI: client-side merge of per-account indexes; consistent thread view across accounts.

### Deep dives
1. **Priority Inbox PA-II online learning.** Per-user logistic regression with PA-II regression variant — combats noisy implicit labels. Each mail updates global model + per-recipient model exactly once. Per-user higher regularization than global. **Cross-DC requirement**: must score any user from any DC without delaying mail delivery — model weights replicated.
2. **Threading + sync protocol trade-offs.** RFC 5322 Message-ID + In-Reply-To + References. Outlook Conversation-ID for robustness. **Gmail API + Cloud Pub/Sub push** lower latency than IMAP IDLE; minimal-trust architecture (no per-account TCP). IMAP IDLE universal but higher-latency on Gmail.
3. **7-layer spam stack + unified inbox client architecture.** RBL + rules + per-user Bayesian + reputation + decoy + collaborative checksums + ML ensemble. Per-user models learn each user's borderline-mail tolerance. **Unified inbox**: per-account sync to local SQLite/index + client-side merge.

## Known failure modes
1. *Threading break on forwarded mail* — missing References header. Production answer: Outlook Conversation-ID + heuristics on Subject prefix ("Re:", "Fwd:").
2. *Per-user model staleness for inactive users* — model trained on old behavior. Production answer: TTL on training data; refresh on resumption.
3. *Spam false-positive* on legitimate marketing mail. Production answer: per-user trust override; "Not Spam" → per-user signal.

## Notes for the coach
- **Asked-plausibly at Google (Gmail), Microsoft (Outlook), Apple (Mail).** Gmail Priority Inbox paper + RFC 5322 + Outlook PPML are public.
- **Cross-coverage** with messaging `whatsapp` (multi-device sync). With ML-in-loop (Priority Inbox is classical-ML).
- **The PA-II + per-user higher regularization + cross-DC scoring is the canonical Staff+ unlock.** Mid-senior candidates draw "global ML ranker"; Staff+ candidates name the per-user fine-tuning that makes priority adaptive.
- **Adversarial probe: "Unified inbox across 5 accounts. User searches for 'invoice.' Where does the query run?"** Strong answer: search runs against local SQLite/index (already synced via Gmail API push / Outlook Graph webhook / IMAP IDLE); merge results client-side ordered by relevance + recency; never proxy to per-account remote search (latency + auth-fanout cost). Counter: for very large mailboxes use periodic server-side index refresh + cached query results. Weak answer: "fan out a search to each provider" without the local-index argument.

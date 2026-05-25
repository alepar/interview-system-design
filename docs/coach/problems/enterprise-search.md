---
slug: enterprise-search
archetype: search-indexing
sources:
  glean_graph: glean.com/product/enterprise-graph
  glean_connectors: docs.glean.com/connectors/connectors-power-glean
  glean_identity: glean.com/blog/using-our-identity-schema-to-deliver-personalized-permissions-aware-results
  sinequa_acl: sinequa.com/resources/blog/data-access-security-management-the-enterprise-search-challenge/
  ms_connectors: learn.microsoft.com/en-us/microsoftsearch/connectors-overview
---

# Enterprise / Federated Search (permission-aware, 100+ SaaS sources)

## Bar anchors
- **Mid-level (L4/E4):** Proposes crawling company docs into one index and searching them. May mention permissions as a filter. Doesn't recognize that the ACL model is the hard part, or address identity mapping, staleness, or result leakage unprompted.
- **Senior (L5/E5):** Recognizes results must be **permission-trimmed per user** (never show a doc the user can't access) and that data comes from heterogeneous connectors (Slack, Drive, Jira, Salesforce). Proposes crawling content + permissions, and filtering results by the user's access. Knows freshness (re-crawl) matters. May not articulate **early- vs late-binding ACL**, cross-system identity mapping, the autocomplete-leak hazard, or tenant isolation.
- **Staff+ (L6/E6+):** Drives proactively. Frames **the ACL model as the entire problem** and trades **early binding** (index-time: encode each doc's allow-list of group IDs into the index — fast queries, but stale when membership changes) vs **late binding** (query-time: filter against current source ACLs — correct but slow and chatty), landing on the **hybrid** (index-time content + group allow-list, **query-time membership** resolution). Names **identity-graph stitching** (one human has different IDs in Slack vs Salesforce vs Jira → a unified identity schema). Flags the **autocomplete/suggestion leak** (a late-binding system can leak confidential doc titles via autosuggest/spell-correction even when bodies are filtered). Quantifies: Glean **100+ connectors**; identity-crawl optimization improved crawl time **up to 98%**; freshness **10–60 min** source-event→searchable. Treats **freshness-vs-ACL-staleness** as the single tradeoff axis and addresses per-tenant isolation.

## Canonical decomposition

### Requirements
**Functional:**
- Search across 100+ heterogeneous SaaS sources from one query box
- Permission-aware: a user only ever sees results they're authorized to access in the source
- Map one human's identities across systems to a unified user
- Keep content + permissions reasonably fresh as sources change
- Per-customer tenant isolation; data never leaves the tenant

**Non-functional (with numbers):**
- 100+ source connectors (Slack, Jira, Confluence, Salesforce, Drive, Gong, …)
- Freshness 10–60 min source-event → searchable (e.g. content/perms every 10 min, identity hourly)
- ACL correctness is a hard constraint (a single leak is a security incident)
- Identity-crawl cost is a major bottleneck (optimizations up to 98%)
- Query latency competitive with consumer search despite per-user trimming

### Core entities
- **Document:** source, doc_id, content, **allow_list** (group/user IDs that can access), updated_ts
- **Identity:** unified_user_id ← {per-source IDs}; group memberships
- **Connector:** per-source crawler for content + permissions + identities; sync or federated
- **Tenant:** per-customer isolation boundary (separate index, encrypted, never co-mingled)

### API
- `GET /search?q=...` (as user U) → results trimmed to docs U can access in their source
- Internal: connector.crawl() → content + per-doc ACL + identities, on a schedule
- Internal: `trim(results, U) → results ∩ access(U)` applied to hits **and** suggestions
- Internal: identity.resolve(per_source_id) → unified_user_id (+ current group memberships)

### HLD
**Connectors** pull from each source's API on a schedule, crawling three things together: **content**, **permissions** (the doc's ACL — which users/groups can access it), and **identities** (users, groups, memberships). Microsoft-style architectures distinguish **synced** connectors (data indexed into the search graph) from **federated** connectors (data stays in the source, fetched live at query time) — a freshness/cost trade per source. Crawled content is indexed; each document is stamped with an **allow-list** of group/user IDs.

The **identity graph** stitches one human's many per-source IDs (Slack user, Salesforce user, Jira account) into a **unified identity** with current group memberships — because a doc's ACL is expressed in source-specific groups, and trimming requires knowing which of those groups *this* unified user belongs to. Building and refreshing this graph is a major cost (Glean reports identity-crawl optimizations up to 98%).

The **ACL enforcement model** is the crux:
- **Early binding** indexes each doc with its allow-list of group IDs; a query AND's the user's group set against the index, so trimming is a fast index operation — but if a user is removed from a group, the index is stale until re-crawled (over-permissive: a security risk).
- **Late binding** stores no permissions in the index and checks each candidate against the *live* source ACL at query time — always correct, but slow, chatty (per-result source calls), and it breaks pagination/facet counts.
- **Hybrid (dominant):** index-time content + a doc's group allow-list, but resolve the **user's current group membership at query time** (membership is small and changes are what go stale fastest). This gets near-early-binding speed with near-late-binding correctness on the membership axis.

Critically, the **same per-user trim must apply to suggestions/autocomplete/spell-correction**, not just the main results — otherwise the system leaks confidential document titles or terms via suggestions even when bodies are correctly filtered. Each customer is a **tenant** with an isolated, encrypted index that never co-mingles with another customer's data.

### Deep dives
1. **Early vs late binding (the central tradeoff)** — Early binding pushes permissions into the index: fast queries (trimming is an index AND), but permission changes (a removed Slack channel member, a revoked share) are invisible until re-crawl, leaving a window where the index is *over-permissive* — the dangerous direction for security. Late binding checks live source ACLs per candidate at query time: always correct, but adds per-result network calls (slow), and post-filtering wrecks pagination consistency and facet counts (you can't know how many results a user can see without checking them all). The hybrid splits the difference along the axis that matters: index the relatively-stable content + doc allow-lists, but resolve the fast-changing **group membership** at query time. The Staff+ signal is recognizing that "freshness vs correctness" here is specifically about *which* facet (content vs ACL vs membership) you let go stale, and choosing the cheap-to-refresh one to bind late.
2. **Cross-system identity mapping** — A doc's ACL says "group sales-eng can read this," expressed in Salesforce's identity space; trimming a Slack-authenticated query requires knowing this user is the same human as that Salesforce user and is in `sales-eng`. So the system must stitch per-source IDs into a **unified identity** with resolved group memberships — non-trivial because display names collide, emails differ, and groups nest. Done wrong it either under-trims (leak: mapping two different people as one) or over-trims (user can't find their own docs). Conservative defaults (match on canonical email, require explicit action to merge ambiguous identities) bias toward *not leaking*. This identity crawl is also a top performance cost (optimizations up to 98%), because it touches every user × every source's group structure.
3. **The autocomplete/suggestion leak** — A subtle, common production bug: the main result path is correctly permission-trimmed, but the **suggestion services** (autocomplete, "did you mean", related-docs) are sourced from the full index and *not* trimmed — so they leak confidential document titles, project names, or terms to users who can't open the underlying doc. This is exactly the failure mode of naive late binding (post-filtering the body but not the metadata used for suggestions). Mitigation: apply the identical per-user ACL trim to *every* surface that reads the index — suggestions, facet counts, snippets, related-content — and treat any index-derived UI affordance as a potential disclosure channel. The interview lesson: in permission-aware search, the leak is usually in the side-channel, not the main result list.

## Known failure modes
1. **Stale ACL → over-permissive results** — A user is removed from a Slack channel / loses a share, but the early-bound index still lists them as authorized until the next crawl, so they keep seeing the doc — a security incident. Mitigation: hybrid binding with query-time membership resolution (membership changes bind late), short TTLs on cached membership, and opt-in full late-binding for the most sensitive sources where any staleness is unacceptable.
2. **Identity-mapping error → leak or lockout** — Mapping two different people to one unified identity leaks one's documents to the other; failing to map a user's identities locks them out of their own content. Mitigation: conservative matching (canonical email, explicit merge for ambiguous cases), bias toward under-merging (lockout is recoverable; leak is not), and audit logging of identity merges so mistakes are detectable and reversible.
3. **Source API rate-limits starve freshness** — Crawling content + permissions + identities across 100+ sources hits per-source API rate limits; if the crawler can't keep up, freshness degrades and ACLs go stale (looping back to failure 1). Mitigation: per-source adaptive backoff, prioritize high-change-rate and security-relevant sources (permission changes before low-value content), incremental/CDC crawling instead of full re-crawls, and surface per-source freshness so staleness is observable and the riskiest sources can be bound late.

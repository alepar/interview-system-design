---
slug: content-moderation-pipeline
archetype: ugc-pipeline
sources:
  photodna: en.wikipedia.org/wiki/PhotoDNA
  ncmec_hashlist: technologycoalition.org/knowledge-hub/update-on-voluntary-detection-of-csam
  cloudinary_moderation: cloudinary.com/guides/automations/ai-content-moderation
  tiktok_moderation: tiktok.com/safety/en/policies-and-engagement/content-moderation
  content_id: en.wikipedia.org/wiki/Content_ID
---

# Content Moderation Pipeline (scanning UGC in the processing pipeline)

## Bar anchors
- **Mid-level (L4/E4):** "Run an ML classifier on uploads." Doesn't address where the scan fits in the pipeline, hash-matching known-bad, the publish gate, or human escalation.
- **Senior (L5/E5):** Async scan after upload (hash-match + ML classifier), hold/flag violations, escalate uncertain cases to humans. Knows pre- vs post-moderation. May not articulate the confidence-tiered routing, the scan-before-distribution gate, copyright fingerprinting, or the human-review queue as a system.
- **Staff+ (L6/E6+):** Drives proactively. Frames moderation as a **pipeline integration**, not a model: the scan **hook fires after upload, before distribution** (the publish gate — scan the raw asset before transformations/CDN). Uses **hash-matching against known-bad first** (PhotoDNA: robust **1152-bit perceptual hash**, distance-threshold match; NCMEC's **5M+ vetted CSAM hash list**; >95% of CyberTipline reports come from hash-matching — cheap, exact, runs before any ML) then **ML classifiers** for novel nsfw/violence (the *model serving* is AI-infra `safety-moderation-pipeline` — reference; here it's the **pipeline**). Routes by **confidence tiers**: auto-approve (below threshold), auto-action (high-confidence block/blur), **soft-flag the mid-confidence "quarantine band" to human review** (biggest ROI), hard-escalate high-risk categories. Models **human review as a queueing network** (Facebook QUEST: jobs=content, reviewers=agents). Adds **copyright fingerprinting** (YouTube Content ID: audio/video fingerprint vs rights-holder DB → claim). Quotes TikTok (91% auto-removed, 96% before any views, scan-before-distribution gate). Chooses **pre- vs post-moderation** (hold-before-publish safest but slow vs publish-then-scan fast but risky → hybrid).

## Canonical decomposition

### Requirements
**Functional:**
- Scan uploaded UGC for policy violations (CSAM, nsfw, violence) and copyright before/at publish
- Match known-bad fast (hashes) + classify novel content (ML); route by confidence
- Escalate uncertain cases to human reviewers; quarantine/hold or block

**Non-functional (with numbers):**
- Hash-match known-bad: PhotoDNA 1152-bit hash, NCMEC 5M+ hashes, >95% of reports
- Confidence-tiered routing; mid-confidence → human review (quarantine band)
- Scan-before-distribution gate (TikTok: 96% removed before any views)
- Pre-moderation (safest, slow) vs post (fast, risky) → hybrid

### Core entities
- **Scan job:** an async task on the uploaded asset (hash-match → ML → decide)
- **Known-bad hash DB:** PhotoDNA/NCMEC perceptual-hash list (CSAM), Content ID fingerprints (copyright)
- **Confidence-tier router:** maps a score to approve/auto-action/quarantine/escalate
- **Human-review queue:** the queueing network for mid-confidence cases

### API
- upload → `enqueue scan` (before publish/distribution)
- scan: `hashMatch(asset, knownBadDB)` → if match, block/report; else `classify(asset)` → score
- route(score): approve | auto-action | soft-flag→human-review | hard-escalate
- publish gate: release to feed/CDN only after the scan clears (pre-moderation) or scan-after (post)

### HLD
Moderation is a **stage in the UGC pipeline**, hooked **after upload and before distribution** (the **publish gate**): the raw asset is analyzed before it's transformed, stored for serving, or pushed to the feed/CDN. The scan is **layered cheapest-first**. **Hash-matching against known-bad** runs first: **PhotoDNA** computes a robust **1152-bit perceptual hash** (grayscale + DCT, survives resize/crop/recompress) and matches by **distance threshold** against **NCMEC's 5M+ triple-vetted CSAM hash list** (and PhotoDNA-for-Video hashes frames) — this is cheap, exact-ish, and accounts for **>95% of CyberTipline reports**, so it catches known material before any expensive ML. Then **ML classifiers** score novel content (nsfw/violence) — but the **model serving** is the AI-infra `safety-moderation-pipeline` problem; *here* the focus is the **pipeline**: enqueue, scan, route, gate. **Copyright** uses **fingerprinting** (YouTube **Content ID**: an audio/video fingerprint matched against a rights-holder reference DB, robust to distortion → place a claim/monetize/block).

Decisions route by **confidence tier**: **auto-approve** below threshold, **auto-action** (block/blur/remove) on high-confidence violations, **soft-flag** the **mid-confidence "quarantine band" to human reviewers** (where human judgment delivers the most ROI — reduces both false positives and false negatives), and **hard-escalate** high-risk categories. The **human-review layer** is itself a system — modeled as a **queueing network** (Facebook's **QUEST**: incoming content = jobs, reviewers = agents) to size staffing/skills at billions-of-posts/day. The **pre- vs post-moderation** choice is fundamental: **pre-moderation** (hold before publish) nearly eliminates risk but slows publishing and discourages contribution; **post-moderation** (publish instantly, scan after) gives instant gratification but lets bad content reach users — so platforms run a **hybrid** (AI auto-filters at the gate; nuanced cases publish-then-review or hold). TikTok's published numbers show the gate working: **91% of violative content auto-removed, 96% before any views**.

### Deep dives
1. **The scan-before-distribution gate + hash-matching first.** The architectural decision is *where* the scan sits: hooking it **after upload, before transformation/CDN distribution** means violating content is caught before it's served (TikTok: 96% removed before any views). And the scan is **layered cheapest-first**: **hash-matching known-bad** (PhotoDNA 1152-bit perceptual hash vs NCMEC's 5M+ list) is cheap, deterministic, and catches the bulk (>95% of reports) *before* invoking expensive ML — only novel content reaches the classifier. This is the pipeline-design insight (vs "just run a model on everything"): gate at the right point, and run a cheap exact filter before the expensive fuzzy one. The Staff+ delineation: the hash DBs + fingerprinting + routing are *this* problem; the ML classifier's serving/training is AI-infra `safety-moderation-pipeline`.
2. **Confidence-tiered routing + the quarantine band.** A binary block/allow on a model score is wrong — scores are uncertain. The pipeline routes by **confidence**: auto-approve clear-safe, auto-action clear-violations, and **soft-flag the mid-confidence band to humans** (the "quarantine band" — where automated decisions are least reliable and human review most reduces both false positives and false negatives), with hard-escalation for high-risk categories (CSAM → report to NCMEC). Tuning the thresholds trades automation (cost/latency) against error rates. This graduated response — and explicitly designing the **human-review queue** as a capacity-planned **queueing network** (QUEST) rather than an afterthought — is the Staff+ depth: moderation at scale is a human+ML routing system, and the band sent to humans is the highest-leverage design lever.
3. **Pre- vs post-moderation + copyright fingerprinting.** **Pre-moderation** (hold-before-publish) is safest but adds latency and discourages contribution; **post-moderation** (publish-then-scan) is fast but exposes users to bad content briefly — so the **hybrid** is standard: hard known-bad (hash match) blocks at the gate (pre), while nuanced ML cases may publish-then-review for low-risk content or hold for high-risk. The choice depends on the harm profile (CSAM → always pre/hold + report; spam → post-review tolerable). **Copyright** is a parallel scan via **fingerprinting** (Content ID: fingerprint the audio/video, match against a rights-holder reference DB even under distortion, then claim/monetize/block) — structurally the same "fingerprint → match → action" shape as CSAM hashing but for IP. The framing: pick the pre/post posture per harm category, run hash/fingerprint matching at the gate, and reserve ML + humans for the uncertain middle.

## Known failure modes
1. **Bad content reaches users (post-moderation gap).** Publish-then-scan exposes viewers before review. Production answer: pre-moderation / hold-before-publish for high-risk categories; hash-match known-bad at the gate (caught before any views); hybrid posture by harm profile.
2. **Human-review queue overload.** Mid-confidence volume swamps reviewers. Production answer: model the review queue as a queueing network (QUEST) for staffing; tune confidence thresholds to size the quarantine band; prioritize high-harm; auto-action the clear cases.
3. **Evasion of hash/fingerprint matching.** Adversaries perturb known-bad media to dodge exact hashes. Production answer: robust perceptual hashes (PhotoDNA survives resize/crop/recompress) + ML for novel/perturbed content; frame-hashing for video; continuously update the known-bad DB.

## (Delineation note)
`content-moderation-pipeline` is the **pipeline integration** of moderation (gate placement, hash/fingerprint matching, confidence routing, human-review queue) — distinct from AI-infra `safety-moderation-pipeline`, which owns the **LLM/ML classifier serving**. The object store is infra-primitives `s3`; sandboxed scanning of untrusted media borders `document-preview`. Reference the classifier, don't re-derive it.

---
slug: email-digest-pipeline
archetype: fan-out
sources:
  sendgrid_scale: sendgrid.com/en-us/marketing/email-brand-signup-sendgrid-vs-mailchimp
  rfc_8058: datatracker.ietf.org/doc/html/rfc8058
  valimail_one_click: valimail.com/blog/one-click-unsubscribe/
  bounces: smtp2go.com/blog/understanding-hard-bounces-soft-bounces-and-rejected-emails/
  sto: theseventhsense.com/blog/the-five-levels-of-send-time-optimization
  suprsend: docs.suprsend.com/docs/digest
---

# Email digest pipeline — SendGrid 183B+/month (>75B peak weeks) at 99.99% uptime + timezone-aware delivery via signup-derived segment + per-local-time bucket stage-release + RFC 8058 one-click unsubscribe (mandatory since June 2024 for senders >5K msgs/day) + SMTP 5xx hard bounce → immediate suppression / 4xx soft bounce → 3-5 retries over 24-72h with geometric backoff + <2% bounce-rate ceiling + per-recipient send-time optimization (5-15% open-rate lift, 5-7% conversion)

## Bar anchors
- **Mid-level (L4/E4):** Sends all emails at midnight UTC; no bounce handling; no unsubscribe pipeline.
- **Senior (L5/E5):** Names timezone segmentation + bounce categorization. May or may not articulate RFC 8058, DKIM-signed unsubscribe headers, geometric backoff, or per-recipient STO.
- **Staff+ (L6/E6+):** Names (a) **SendGrid scale**: 183B+ emails/month at 99.99% uptime; >75B during peak weeks (Cyber Week); 99.99% inbox delivery; (b) **timezone-aware delivery** segments by signup-derived TZ + stage-releases per local bucket; STO operates in recipient's local time and must normalize DST shifts; (c) **RFC 8058 one-click unsubscribe** mandatory since June 2024 for senders >5K msgs/day to mailbox provider; headers `List-Unsubscribe: <https://...>` + `List-Unsubscribe-Post: List-Unsubscribe=One-Click`; **DKIM-signed** covering those headers; POST endpoint MUST NOT redirect or rely on cookies; URI encodes opaque (recipient, list) token; (d) **bounce handling**: SMTP 5xx (550 user-not-found, 553 relay-denied) = hard bounce → suppression list immediately, never retry; 4xx (450 mailbox full, 421 service unavailable) = soft bounce → 3-5 retries over 24-72h with geometric backoff (1m/10m/1h/4h); **<2% best-practice ceiling** for sender reputation; configurable sunset auto-promotes addresses to suppression after consecutive soft bounces; (e) **per-recipient send-time optimization**: 5-15% open-rate lift; 5-7% conversion lift; AI splits A/B holdout vs optimized to measure incremental impact.

## Canonical decomposition

### Requirements
**Functional:**
- Send digest to N million users daily/weekly
- Timezone-aware delivery (e.g., 8am local)
- Per-recipient STO
- One-click unsubscribe (RFC 8058)
- Bounce/complaint handling
- Suppression list management

**Non-functional:**
- 183B+/month average; >75B peak weeks; 99.99% uptime
- Median delivery <1s after dispatch
- One-click unsubscribe mandatory >5K msgs/day to provider
- <2% bounce rate for sender reputation
- STO: 5-15% open-rate, 5-7% conversion lift

### Core entities
- **Recipient:** email, timezone, opt_in, suppression_reason
- **DigestRun:** run_id, list_id, scheduled_at, content_snapshot
- **DeliveryRecord:** recipient, digest_id, smtp_status, retry_count, bounced_at
- **UnsubscribeToken:** opaque, (recipient_id, list_id)

### API
- `POST /digest/schedule` body={list_id, content, send_window}
- `POST /unsubscribe/:token` (RFC 8058 one-click endpoint)
- SMTP: outbound queues per provider

### HLD
Generation pipeline: nightly cron triggers per-list batch job → fetches recipients from list store → per-recipient content selection (linked to ranker upstream e.g. `medium-following-feed`) → renders MJML/HTML.

Scheduling: timezone segmenter → per-(TZ, local-hour) buckets; STO model adjusts per-recipient within bucket; results land on dispatch queue ordered by `scheduled_at_utc`.

Dispatch: per-provider SMTP worker pool; respects per-domain warmup rate-limit; signs DKIM (including List-Unsubscribe headers per RFC 8058 requirement).

Bounce/complaint feedback: SMTP response → categorize (5xx hard / 4xx soft); hard → suppression list; soft → retry queue with geometric backoff (1m/10m/1h/4h) up to 3-5 attempts; sunset policy promotes consecutive-soft to suppression. ARF complaint feedback loop from major providers → instant suppression.

Unsubscribe: POST endpoint validates opaque token → looks up (recipient, list) → adds suppression row → returns 200 within 48h SLA.

### Deep dives
1. **Throughput + uptime + timezone-aware delivery.** 183B+/month = ~70K/sec average. 99.99% uptime; median <1s. Timezone segmentation derived from signup IP / explicit setting; 8am-local bucket. STO in recipient's local time; DST normalization required.
2. **RFC 8058 one-click unsubscribe.** Mandatory since June 2024 for senders >5K msgs/day. Headers: `List-Unsubscribe` + `List-Unsubscribe-Post: List-Unsubscribe=One-Click`. **DKIM signature** MUST cover those headers. POST endpoint MUST NOT redirect or rely on cookies. URI encodes opaque (recipient_id, list_id) token. **48-hour honoring** required.
3. **Bounce handling + sender reputation.** 5xx hard → immediate suppression, never retry. 4xx soft → 3-5 retries over 24-72h with geometric backoff (1m/10m/1h/4h). <2% bounce rate ceiling. Sunset policy auto-promotes consecutive-soft. Per-recipient STO: 5-15% open-rate / 5-7% conversion lift.

## Known failure modes
1. *Sender reputation drop from bounce-rate spike* — purchased list with high invalid rate. Production answer: pre-flight verification; per-domain warmup rate-limit.
2. *Unsubscribe non-compliance penalty* — Gmail/Yahoo throttle or block; 48h SLA cited. Production answer: real-time suppression on one-click; audit log per unsubscribe.
3. *Email-tracking signal degradation* — Apple Mail Privacy Protection auto-opens images. Production answer: rely on click-through over open-rate; in-app engagement signals.

## Notes for the coach
- **Plausibly-asked at SendGrid, Mailchimp, Twilio, Postmark, AWS SES.** Vendor docs + RFC 8058 are public.
- **Cross-coverage** with messaging `push-notification` (delivery channel parallel). With `medium-following-feed` (digest content selection).
- **The RFC 8058 one-click unsubscribe with DKIM-covered headers is the canonical Staff+ unlock.** Mid-senior candidates draw an unsubscribe link; Staff+ candidates name the specific RFC requirements + 48h SLA.
- **Adversarial probe: "Gmail just throttled us. What do we audit first?"** Strong answer: bounce rate must be <2% (check last 7 days per-domain); unsubscribe SLA must be <48h with one-click (check RFC 8058 header presence + DKIM signature); spam-complaint rate via ARF feedback loop; sender reputation via Google Postmaster Tools. Counter-actions: pause sending to that domain; warm up new IP; one-click compliance audit. Weak answer: "scale down" without the audit checklist.

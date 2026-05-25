---
slug: image-derivatives
archetype: ugc-pipeline
sources:
  aws_ondemand_resize: aws.amazon.com/blogs/networking-and-content-delivery/image-optimization-using-amazon-cloudfront-and-aws-lambda/
  cloudinary_optimize: cloudinary.com/documentation/image_optimization
  thumbor: github.com/thumbor/thumbor
  wikimedia_thumbor: diff.wikimedia.org/2017/12/09/thumbor-journey-thumbnailing-architecture/
  avif_webp: theimagecdn.com/docs/webp-vs-avif-vs-jpeg
---

# Image Derivatives (thumbnail/resize/format generation at scale)

## Bar anchors
- **Mid-level (L4/E4):** Generates a couple of fixed thumbnail sizes at upload. Doesn't address on-demand vs precompute, format negotiation, CDN caching of variants, or storage cost.
- **Senior (L5/E5):** Generates multiple sizes, serves via CDN, picks WebP/AVIF by browser. Knows on-the-fly resizing exists. May not articulate the on-demand-vs-precompute tradeoff quantitatively, the Vary:Accept caching rule, the resize-service architecture, or DPR/responsive handling.
- **Staff+ (L6/E6+):** Drives proactively. Frames the central tradeoff: **on-demand/on-the-fly resizing** (transform at request via an image service + CDN cache, keyed by URL params — pay compute on first miss, store only requested variants) **vs precompute** (generate all sizes at upload — fast serve, but store thousands of variants, most unused). Reasons it from the **long-tail of unused variants** (precompute stores everything whether accessed or not; on-demand only materializes what's requested). Describes the **CloudFront+Lambda+Sharp pattern** (CloudFront Function reads `format=auto` + Accept header → rewrites URL → on cache miss, Lambda resizes and writes the derivative back to S3, keyed by a normalized transform suffix, 1yr cache + 90-day lifecycle delete of cold variants). Handles **format negotiation** (serve AVIF ~50% / WebP ~25–34% smaller than JPEG by Accept header) with **`Vary: Accept`** so the CDN caches a separate derivative per format. Names the **Thumbor**-style service (HMAC-signed URLs, smart-crop) and Wikimedia's **Varnish+Swift two-tier** on-demand thumbnailing. Adds **DPR/responsive** (srcset, round width to nearest 100px) and targets 90%+ CDN hit.

## Canonical decomposition

### Requirements
**Functional:**
- Serve images in the right size, crop, and format for each device/surface
- Generate variants efficiently (compute vs storage vs latency)
- Negotiate modern formats (WebP/AVIF) and DPR/responsive sizes
- Cache derivatives at the edge

**Non-functional (with numbers):**
- AVIF ~50% / WebP ~25–34% smaller than JPEG (bandwidth win)
- On-demand: derivative cached 1yr, cold variants lifecycle-deleted ~90 days
- CDN hit ratio target 90%+ (each cached variant ⇒ zero origin bandwidth)
- DPR-aware: round width to nearest 100px; Vary: Accept for per-format caching

### Core entities
- **Original:** the source image (object storage)
- **Derivative:** a (size, crop, format, quality) variant, CDN-cached, keyed by transform params
- **Transform request:** URL-encoded params (width, format=auto, crop) → identifies the derivative
- **Image service:** the resize worker (Lambda/Thumbor) generating derivatives on miss

### API
- `GET /img/{id}?w=640&format=auto` (or path params `/{id}/w=640,format=webp`) → derivative
- on miss: image service fetches original, resizes/encodes (Sharp), writes derivative back, returns it
- `Vary: Accept` + long `Cache-Control` (immutable) so CDN caches per-format and serves cheaply

### HLD
The core decision is **on-demand vs precompute**. **Precompute (eager)**: at upload, generate every needed size/crop/format and store them — fast at serve time, but you **store thousands of variants whether or not they're ever requested** (and adding a new size means re-processing the whole corpus). **On-demand (lazy)**: serve via an **image service** that transforms at request time, parameterized by URL (width, crop, `format=auto`), and **caches the result** at the CDN — you pay resize compute on the **first miss** only, and store only variants actually requested (the long tail of unused sizes never materializes). On-demand scales better for large catalogs with unpredictable size/device demand; precompute wins for a small fixed variant set on hot content.

The canonical on-demand architecture (AWS): a **CloudFront Function** inspects `format=auto` + the **Accept header** to choose JPEG/WebP/AVIF and rewrites the request to a normalized derivative key (e.g. `/cat.jpg/format=webp,width=640`); on a **cache miss**, the origin fails over to a **Lambda** that fetches the original from S3, resizes/encodes with **Sharp**, writes the derivative **back to S3**, and returns it with a long (1-year, immutable) cache header — so subsequent requests hit the CDN/S3, and a **lifecycle policy deletes cold variants** (~90 days) to cap storage. **Format negotiation** serves **AVIF (~50% smaller than JPEG)** or **WebP (~25–34%)** based on the browser's Accept header, and the response sets **`Vary: Accept`** so the CDN caches a *separate* derivative per format (and never serves a WebP to a JPEG-only client). **DPR/responsive**: `srcset`/`sizes` and rounding the requested width to the nearest 100px bound the variant explosion. Thumbor (HMAC-signed URLs to prevent abuse, smart face/feature-detection crop) and Wikimedia's **Varnish+Swift two-tier** thumbnailing (Varnish hot cache over Swift originals; on miss, generate from the original) are reference implementations. Target **90%+ CDN hit** — each cached derivative costs zero origin bandwidth thereafter.

### Deep dives
1. **On-demand vs precompute (the core tradeoff).** Precompute pays storage for *every* variant up front (most never requested — the long tail) and forces a full re-process to add a size; on-demand pays *compute* per variant but only on first miss, storing only what's actually requested, with the CDN absorbing repeats. The economics: on-demand + cache is cheaper for large/unpredictable catalogs (AWS example: ~$7.84/mo for 100K originals / 1M requests / 95% hit — storage ~$2/mo + transform ~$1.3/mo), while precompute is simpler/faster for a small fixed set on hot content. The hybrid is common: precompute a few hot sizes, generate the rest on demand. This is the exact analog of `vod-delivery`'s JIT-vs-pre-packaging — name the parallel. The Staff+ point: choose by catalog size × variant unpredictability × hotness, and let the CDN make on-demand's first-miss cost amortize away.
2. **Format negotiation + the Vary:Accept caching rule.** Modern formats are big wins (AVIF ~50%, WebP ~25–34% smaller than JPEG), but you must serve the right one per browser. **Content negotiation** reads the `Accept` header (or `format=auto`) and serves AVIF→WebP→JPEG by support. The crucial correctness detail is **`Vary: Accept`**: without it, a CDN could cache a WebP and serve it to a client that only accepts JPEG (broken image), so the CDN must cache a **separate derivative per format** — which interacts with cache-key design (deep-dive 1) and slightly fragments the cache (more variants). Combining responsive sizing (srcset) with format negotiation yields 80–90% byte savings for mobile. The framing: format/size negotiation lives at the delivery edge, and `Vary: Accept` is the rule that keeps per-format caching correct.
3. **The resize-service architecture + abuse/cost control.** The on-demand generator (Lambda/Sharp, or a Thumbor service) is a stateless worker: fetch original → transform → write derivative → return, fronted by the CDN. Two production concerns: **abuse** (an open resize endpoint lets attackers request infinite distinct sizes to blow up compute/storage — Thumbor signs URLs with an **HMAC** so only valid transform requests are honored; you can also whitelist allowed sizes) and **storage/compute caps** (write derivatives back to object storage with long cache headers so compute runs once, and **lifecycle-delete cold variants** ~90 days so the long tail doesn't accumulate forever). Wikimedia's two-tier (Varnish hot thumbnails over Swift originals, generate-on-miss) shows the same shape at scale. The Staff+ point: an on-demand image service must be secured (signed URLs / size whitelist) and bounded (cache + lifecycle) or it becomes a compute/storage DoS vector.

## Known failure modes
1. **Variant explosion / storage blowup.** Precomputing every size×format, or an unbounded on-demand endpoint, accumulates millions of mostly-unused derivatives. Production answer: on-demand generation + CDN cache + lifecycle-delete of cold variants; round/whitelist sizes; precompute only hot variants.
2. **Wrong format served from cache.** A CDN serves a WebP/AVIF to a client that can't decode it. Production answer: `Vary: Accept` so the CDN caches a separate derivative per format; negotiate by Accept header / format=auto.
3. **Resize endpoint abused as a compute/storage DoS.** Attackers request infinite distinct transforms. Production answer: HMAC-signed URLs (Thumbor) or a size whitelist; rate-limit; cache + lifecycle so repeated/cold variants don't cost compute/storage indefinitely.

## (Delineation note)
`image-derivatives` is the **derivative-generation + delivery** stage (on-demand vs precompute, format negotiation). The full upload pipeline is `instagram-upload`/`google-photos`; generic CDN/edge mechanics are caching `cdn-edge-cache`; the object store is infra-primitives `s3`. The VOD analog is `vod-delivery` (JIT packaging). Reference, don't re-derive.

---
slug: document-preview
archetype: ugc-pipeline
sources:
  dropbox_riviera: dropbox.tech/machine-learning/bringing-ai-powered-answers-and-summaries-to-file-previews-on-the-web
  dropbox_cannes: dropbox.tech/machine-learning/cannes--how-ml-saves-us--1-7m-a-year-on-document-previews
  libreoffice_headless: oneuptime.com/blog/post/2026-02-08-how-to-run-libreoffice-in-docker-for-document-conversion/view
  ghostscript_pages: victordibia.com/blog/pdf-img/
  gvisor_dangerzone: gvisor.dev/blog/2024/09/23/safe-ride-into-the-dangerzone/
---

# Document Preview (upload → convert/render preview)

## Bar anchors
- **Mid-level (L4/E4):** Opens the doc in the browser. Doesn't address converting arbitrary formats, async rendering, caching previews, or sandboxing untrusted files.
- **Senior (L5/E5):** Async conversion pipeline (Office→PDF→image), worker pool + queue, cache rendered previews, headless renderer. Knows large docs render page-by-page. May not articulate the conversion graph/chaining, on-demand-vs-precompute previews, sandboxing untrusted files, or single-threaded-renderer scaling.
- **Staff+ (L6/E6+):** Drives proactively. Designs an **async conversion pipeline** (upload → queue → worker pool → render → cache), modeling conversions as a **graph** chained into multi-step pipelines (Dropbox **Riviera**: ~300 file types, ~2.5B requests/~1EB per day, each plugin in an **isolated jail**, intermediate-state caching). Renders **on-demand** (not precompute) in multiple resolutions and **caches** results (Dropbox: 30 days) — and uses an **ML predictor** to pre-warm only likely-viewed files (Dropbox **Cannes**: $1.7M/yr saved vs $9K operating cost). Uses **headless renderers** (LibreOffice `--headless --convert-to pdf`; Ghostscript PDF→image, `-dFirstPage/-dLastPage` for page-by-page on large docs); knows LibreOffice is **single-threaded per instance** → scale via multiple containers/queue. Treats **security as first-class**: rendering untrusted files is the attack surface, so it runs renderers in **sandboxes** (containers + gVisor — assume LibreOffice has exploitable bugs; prevent host escape even after a document exploit). Generates a **thumbnail ladder** (Slack: 80/360/480/720/960/1024).

## Canonical decomposition

### Requirements
**Functional:**
- Convert/render uploaded documents (Office/PDF/etc.) into viewable previews + thumbnails
- Support many formats; render large docs page-by-page; cache previews
- Safely render untrusted, potentially-malicious files

**Non-functional (with numbers):**
- Dropbox Riviera: ~300 file types, ~2.5B conversions/day (~1EB)
- Previews generated on-demand, cached ~30 days; ML pre-warm (Cannes $1.7M/yr saved)
- LibreOffice single-threaded/instance → multi-container scaling
- Thumbnail ladder (e.g. 80/360/480/720/960/1024)

### Core entities
- **Conversion plugin:** a single format-to-format step, run in an isolated jail
- **Conversion graph:** the DAG of possible conversions; chained into pipelines
- **Preview/thumbnail:** the rendered output (multiple resolutions), cached
- **Sandbox:** the isolation boundary for untrusted-file rendering

### API
- `POST /preview {file}` → enqueue conversion job → async render → cached preview URL
- internal: route file through chained plugins (e.g. .docx → .pdf → page images), each in a jail
- `GET /preview/:id?page=N&size=360` → cached page preview (rendered on-demand on miss)
- ML pre-warm: predict likely-viewed files → pre-generate previews

### HLD
Previews are produced by an **async conversion pipeline**: upload → enqueue → a **worker pool** renders → cache the result → serve. The conversions form a **graph** (Dropbox's **Riviera**: ~300 file types, a graph of possible conversions chained into multi-step pipelines — e.g. `.docx → .pdf → page-image`, or `video → audio → transcript`), processing ~2.5B requests/~1EB per day. Each conversion step runs as a **plugin in an isolated jail** (a container), both for dependency isolation and **security** (see below). Expensive **intermediate states** (e.g. the PDF rendered from a .docx) are **cached and reused** across requests.

Previews are generated **on-demand** rather than pre-computed for every file, in multiple resolutions, and **cached** (Dropbox: 30 days) — striking the storage-vs-compute balance (most files are never previewed). To capture the benefit of pre-warming *without* pre-rendering everything, Dropbox's **Cannes** ML classifier predicts whether a file's preview will be viewed (features: file extension, account type, 30-day activity) and pre-generates only likely-viewed previews — **$1.7M/yr saved** vs a **$9K/yr** operating cost. The renderers are **headless** tools: **LibreOffice** (`--headless --convert-to pdf`) for Office→PDF, **Ghostscript** for PDF→image (with `-dFirstPage/-dLastPage` to render **specific pages** of a large doc rather than the whole thing). A key scaling constraint: **LibreOffice is single-threaded per instance**, so concurrency comes from running **many containers** behind a load balancer / task queue, not threads.

**Security is first-class** because the system renders **untrusted, attacker-controlled files**: the threat model assumes a determined attacker will find a vulnerability in the renderer (LibreOffice, image parsers), so rendering runs in **sandboxes** — containers plus **gVisor** (a second isolation layer; its Sentry reimplements ~200 syscalls in Go and uses only ~70 restricted host syscalls, so an attacker must compromise the Sentry *and* escape it to reach the host). Output is a **thumbnail ladder** (Slack: 80/360/480/720/960/1024) sized for different surfaces, cached and CDN-served.

### Deep dives
1. **Conversion graph + chained plugins.** A preview often needs multiple steps (Office → PDF → page images), and supporting ~300 formats means you don't write N² converters — you model conversions as a **graph** and find a **path** (chain plugins) from the source format to the target preview, reusing shared intermediate steps. Dropbox Riviera does exactly this (graph of conversions, multi-step pipelines, ~2.5B/day), with **intermediate-state caching** so an expensive step (the rendered PDF) is computed once and reused for thumbnails/page images. The Staff+ point: a format-explosion problem becomes tractable as graph traversal + plugin chaining + intermediate caching, rather than bespoke per-format converters.
2. **On-demand rendering + ML pre-warm (the cost optimization).** Pre-rendering previews for every uploaded file wastes compute/storage (most files are never previewed), so previews are generated **on-demand** and cached (30 days). But pure on-demand has a first-view latency cost, so Dropbox adds **Cannes** — a gradient-boosted classifier predicting whether a file *will* be previewed (from cheap features) and pre-warming only those — saving $1.7M/yr at a $9K/yr operating cost. This is the same on-demand-vs-precompute tension as `image-derivatives`/`vod-delivery`, resolved with an **ML-driven hybrid** (predict the hot set, pre-warm it, generate the rest lazily). Naming the ML-pre-warm optimization and its lopsided ROI is the depth signal.
3. **Sandboxing untrusted-file rendering (security).** This is the distinctive risk: the system feeds **attacker-controlled files** into complex parsers (LibreOffice, PDF/image libraries) that *will* have memory-safety bugs — a malicious document can pop the renderer. So the design assumes compromise and contains it: each conversion runs in an **isolated jail/container**, hardened with **gVisor** (a user-space kernel — the Sentry reimplements ~200 Linux syscalls and exposes only ~70 restricted host syscalls, so escaping requires compromising the Sentry *then* breaking out, two layers). The Dangerzone model (nested containers + gVisor, render-to-pixels) is the reference. The Staff+ framing: untrusted-document rendering is a security problem first — sandbox the renderer, assume it'll be exploited, and prevent host escape — not just a conversion problem. (Scaling note: single-threaded renderers ⇒ horizontal containers + queue.)

## Known failure modes
1. **Malicious file exploits the renderer.** A crafted document pops LibreOffice/an image parser. Production answer: run renderers in sandboxes (containers + gVisor); assume the renderer is exploitable and prevent host escape; render-to-pixels, strip active content.
2. **Conversion backlog / slow large-doc render.** Many uploads or huge docs overwhelm the (single-threaded) renderers. Production answer: queue + autoscaled worker containers (LibreOffice is single-threaded per instance); page-by-page rendering (Ghostscript -dFirstPage/-dLastPage); prioritize, dead-letter poison files.
3. **Wasted pre-render compute/storage.** Pre-generating previews for files no one views. Production answer: on-demand generation + cache (30 days) + ML pre-warm of only likely-viewed files (Cannes); lifecycle-expire cold previews.

## (Delineation note)
`document-preview` is the **document conversion/preview** stage of the UGC pipeline (graph-chained conversion + sandboxed rendering + on-demand+ML-prewarm caching). Image-specific derivatives are `image-derivatives`; the object store is infra-primitives `s3`; the ML model serving is AI-infra; sandboxed execution of untrusted code borders AI-infra `sandboxed-agent-execution`. Reference, don't re-derive.

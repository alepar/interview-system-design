---
slug: google-places
archetype: geo-proximity
sources:
  places_product: mapsplatform.google.com/maps-products/places/
  place_id: developers.google.com/maps/documentation/places/web-service/place-id
  places_overview: developers.google.com/maps/documentation/places/web-service/op-overview
  session_pricing: developers.google.com/maps/documentation/places/web-service/session-pricing
  insights_validation: developers.google.com/maps/architecture/validate-places-insights-data
  issue_tracker: issuetracker.google.com/issues/355478592
---

# Google Places API — 200M+ places across 250+ countries with ~100M data updates/day + 300+ place types + 70+ attributes per place + Place ID as opaque variable-length string acting as stable cross-API key (Places, Geocoding, Maps JS, Maps Embed, Roads) + Place IDs NOT permanently stable (refresh older than 12 months) + duplicate Place IDs for same physical location is documented data-model failure + 5 services (Place Details / Photos / Nearby / Text / Autocomplete) + session tokens (UUIDv4) bundle Autocomplete keystrokes with Place Details for billing + two-pathway pattern (Places Insights bulk + Place Details ground-truth) + no SLA-published latency

## Bar anchors
- **Mid-level (L4/E4):** Designs naive lat/lon lookup; no stable identifier; no session-token billing model.
- **Senior (L5/E5):** Names Place ID + Autocomplete. May or may not articulate session-token billing, Place ID instability, duplicate IDs, or two-pathway pattern.
- **Staff+ (L6/E6+):** Names (a) **scale**: 200M+ places worldwide / 250+ countries / ~100M updates/day / 300+ place types / 70+ attributes; (b) **Place ID as opaque variable-length string** acting as stable cross-API key across Places / Geocoding / Maps JS / Maps Embed / Roads; examples short like `ChIJgUbEo8cfqokR5lP9_Wh_DaM` to 500+ chars for inferred ranges; exempt from caching restrictions for persistent storage; (c) **Place IDs NOT permanently stable**: Google recommends refreshing >12 months old at no charge via Place Details call with only ID field specified; stale → NOT_FOUND; malformed → INVALID_REQUEST; inferred ranges / route segments / intersections / subpremises particularly prone to churn; (d) **Duplicate Place IDs for same physical location** is documented data-model failure — clients must handle multiple-IDs-per-place; (e) **Places API (New) has 5 services**: Place Details, Place Photos, Nearby Search, Text Search, Autocomplete; AI summaries synthesize reviews/neighborhood; (f) **Session tokens (UUIDv4)** for Places Autocomplete bundle multiple keystroke queries with terminating Place Details call for billing; without tokens each keystroke billed individually; (g) **session token billing tiers** vary by termination: Place Details Essentials first 12 Autocomplete billed (13+ free); Enterprise + Atmosphere all Autocomplete free; (h) **stale/closed-place handling** delegated to clients via NOT_FOUND error codes — Google does NOT push invalidations; (i) **two-pathway pattern**: Places Insights for bulk/analytical + Place Details for targeted ground-truth verification; (j) **no SLA-published latency** for Autocomplete; documented elevated-latency incidents.

## Canonical decomposition

### Requirements
**Functional:**
- Place Details (by Place ID)
- Place Photos
- Nearby Search (lat/lng + radius + types)
- Text Search (free-form query)
- Autocomplete (as-you-type)

**Non-functional:**
- 200M+ places, 250+ countries
- ~100M data updates/day
- 300+ place types; 70+ attributes per place
- Session-token billing model
- No published SLA on latency

### Core entities
- **Place:** Place ID (opaque), name, lat/lng, types[], attributes (rating, hours, ...)
- **PlaceID:** variable-length opaque string; stable cross-API key
- **AutocompleteSession:** UUIDv4 + bundled keystroke queries + terminating Place Details
- **PlaceInsightsQuery:** bulk analytical pathway

### API
- `GET /place/details?place_id=`
- `GET /place/photo?photo_reference=`
- `GET /place/nearbysearch?location=&radius=&type=`
- `GET /place/textsearch?query=`
- `GET /place/autocomplete?input=&sessiontoken=`

### HLD
Place ID lookup: client passes Place ID → Place Details Service → returns canonical place metadata. Place ID is opaque variable-length; encodes type + location + version info but format not exposed publicly. **Place IDs not permanently stable**: Google recommends refresh >12 months via Place Details call with only ID field.

Autocomplete: client opens session token (UUIDv4) → POSTs Autocomplete query per keystroke with same session token → on user selection, POSTs Place Details with same session token (terminating call). Billing: all Autocomplete + final Details billed as single session (or tier-specific free-tier).

Nearby/Text Search: geo-bounded queries → return candidate list (Place IDs + summary fields). Client subsequently fetches Place Details for selected.

Places Insights: bulk analytical pathway for ML/data-science consumers; Place Details for targeted ground-truth verification.

### Deep dives
1. **Place ID as stable cross-API foreign key (with caveats).** Opaque variable-length. Stable across Places / Geocoding / Maps JS / Maps Embed / Roads. Exempt from caching restrictions. **NOT permanently stable**: refresh >12 months. Stale → NOT_FOUND; malformed → INVALID_REQUEST. Inferred ranges / route segments / intersections / subpremises particularly prone to churn.
2. **Session tokens for Autocomplete billing.** UUIDv4 bundles keystroke queries + terminating Place Details. Without tokens each keystroke billed individually. Tier-specific: Place Details Essentials first 12 Autocomplete free, 13+ billed; Enterprise + Atmosphere all Autocomplete free. Expired/incomplete sessions revert to per-request pricing.
3. **Two-pathway + AI summaries + stale-handling delegation.** Places Insights for bulk/analytical; Place Details for targeted ground-truth. AI summaries synthesize reviews/neighborhood. Stale/closed places delegated to clients via NOT_FOUND — Google does NOT push invalidations. Clients implement reactive refresh on error.

## Known failure modes
1. *Stale Place ID after 12 months*. Production answer: scheduled refresh job + reactive refresh on NOT_FOUND.
2. *Duplicate Place IDs for same physical location* — Google docs admit it. Production answer: customer-side dedup logic (Placekey as cross-vendor standard).
3. *No published latency SLA + documented elevated-latency incidents*. Production answer: client-side timeout + fallback to cached snapshot.

## Notes for the coach
- **Asked-plausibly at Google Maps Platform.** Google docs are canon. Engineering-blog depth limited.
- **Cross-coverage** with `yelp-search` + `foursquare-checkin` (this archetype; competing place-search platforms). With frontend `airbnb-search-map` (consumer of Google Places).
- **The opaque Place ID with 12-month refresh + session-token billing model is the canonical Staff+ unlock.** Mid-senior candidates assume keys are immutable; Staff+ candidates name the explicit refresh discipline + billing-driven session semantics.
- **Adversarial probe: "Your app stored 10M Place IDs over 5 years. What's your data-quality migration plan?"** Strong answer: batched refresh jobs — Place Details calls with only ID field (free per Google docs) for IDs >12 months old; handle NOT_FOUND by retrying via Nearby Search at last known location to find current Place ID; for duplicate-ID cases use Placekey cross-vendor identifier to deduplicate; budget for ~5-10% ID churn over 5 years on inferred ranges / intersections / subpremises. Weak answer: "Place IDs are stable" without naming the 12-month refresh requirement.

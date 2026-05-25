---
slug: stripe-checkout-flow
archetype: frontend
sources:
  stripe_pci_guide: stripe.com/guides/pci-compliance
  stripe_payment_intents: docs.stripe.com/payments/payment-intents
  stripe_3ds_auth: docs.stripe.com/payments/3d-secure/authentication-flow
  stripe_elements: docs.stripe.com/payments/elements
  stripe_address_element: docs.stripe.com/elements/address-element
---

# Stripe checkout flow — iframe-sandboxed card collection (PCI-DSS SAQ A scope) + tokenization + 3DS handling + postMessage protocol + multi-step

## Bar anchors
- **Mid-level (L4/E4):** Builds form with `<input type="text">` for card number. PCI-DSS scope explodes; merchant never gets to launch.
- **Senior (L5/E5):** Names Stripe Elements + tokenization. May or may not articulate iframe-sandbox + postMessage protocol, 3DS frictionless vs challenge, or multi-step state preservation.
- **Staff+ (L6/E6+):** Drives the **RADIO framework**. Security-conscious end of frontend. **Card data must never touch your server** — Stripe Elements iframes card input so PCI scope stays with Stripe. Per Stripe verbatim: "When called, stripe.confirmPayment attempts to complete any required actions, such as authenticating your customers by displaying a 3DS dialog or redirecting them to a bank authorization page." Bar: (a) **iframe-based card collection** — form contains iframe owned by Stripe; merchant receives only token (PaymentMethod ID); **PCI-DSS scope reduces from SAQ D-Merchant (~329 questions) to SAQ A (~14 questions) = ~90% fewer compliance controls**; (b) **multi-step state machine** — address → payment → review → confirmed; back-button preservation; (c) **3DS challenge handling** — confirm returns `requires_action`; client displays Stripe's 3DS UI (modal iframe or redirect); on return re-confirm via PaymentIntent's client_secret; **frictionless 3DS** (issuer trusts data) skips modal — handle both visible and invisible outcomes; (d) **address autocomplete** via Google Places API or Stripe's own Address Element; (e) **error states** — declined / fraud-flagged / 3DS-failed paths; (f) **idempotency** — client-generated key on PaymentIntent confirm prevents double-charge on accidental double-submit.

## Canonical decomposition

### Requirements (R)
**Functional:**
- Multi-step checkout: address → payment → review → confirmation
- Saved-cards UX with explicit "use saved" + "add new"
- 3DS challenge handling (both visible modal + frictionless)
- Address autocomplete
- Apple Pay / Google Pay alternative methods
- Error states for declined / fraud-flagged / 3DS-failed

**Non-functional:**
- Stripe processes payments at trillions-of-dollars annual scale
- Per-checkout: 4-6 distinct form fields beyond card; submission INP ≤200ms
- 3DS redirect adds 5-15s to flow
- PCI-DSS scope: **SAQ A (Stripe Elements) vs SAQ D-Merchant (raw card form) = ~90% fewer compliance controls**
- Address autocomplete: 100-200ms response, same patterns as `autocomplete-typeahead`

### Architecture (A)
**Layers**: Parent page (merchant DOM) ↔ postMessage ↔ Stripe-hosted iframe (Elements). Multi-step state in React; sensitive state (PaymentIntent ID) in memory only.

### Data model (D)
- **PaymentIntent**: server-created; returns `client_secret` to client
- **Step state**: `{step: 'address'|'payment'|'review'|'confirmed', addressData, savedPaymentMethodId, errorState}`
- **Idempotency key**: client-generated UUIDv4 per submit attempt

### Interface (I)
- Parent → iframe: `stripe.elements({clientSecret})` + `elements.create('card')` + `card.mount()`
- iframe → parent: `card.on('change', ...)` events (validity flags + brand metadata; NEVER raw PAN)
- Parent → Stripe API: `stripe.confirmCardPayment(client_secret, {payment_method: ...})`

### Optimization (O)
**Stripe Elements iframe-based card collection**: card-input fields injected into iframes hosted on Stripe's PCI-DSS-validated origin; card data never enters merchant's DOM/JS context. Per Stripe verbatim: "When you use Stripe Elements to create input fields for card details, it embeds these fields within iframes that are hosted by Stripe's servers and not by your web server... If you use Stripe Elements (embedded fields that send data directly to Stripe), you qualify for SAQ A."

**Tokenization flow**: (1) server creates PaymentIntent → returns ONLY `client_secret` to browser; (2) Stripe.js inside iframe sends card data directly to Stripe with that client_secret via `stripe.confirmCardPayment()`; (3) returns PaymentMethod token to parent; **parent + merchant server never see PAN**.

**3DS challenge**: auto-rendered by Stripe.js as modal/popup when `confirmCardPayment` detects required authentication; client only inspects resulting `PaymentIntent.status`. **Frictionless 3DS** (issuer trusts data) skips modal entirely — client must handle both visible and invisible 3DS outcomes.

**Multi-step support**: Elements are independent — call `element.getValue()` to capture address data between steps; `defaultValues` prop to repopulate on back-nav; state lives in app state, NOT in Element instance.

**postMessage protocol**: parent calls JS methods on Element handle which SDK relays over postMessage to cross-origin iframe; events like 'change'/'blur'/'focus' bubble back same way, never carrying raw PAN — only validity flags and brand metadata.

**Idempotency**: client-generated key on `confirmCardPayment` prevents double-charge on accidental double-submit; server validates against key.

**Step state preservation**: URL (`/checkout/payment`) so back/forward works; sensitive state (PaymentIntent ID) in memory only; non-sensitive state in sessionStorage.

**Form validation**: client-side as you-type; server-side authoritative; PaymentIntent's `last_payment_error` surfaces failure reasons.

**Accessibility**: multi-step forms require clear step-progress, focus management on step transition, error-message announcement via aria-live.

**Performance**: defer Stripe.js script load until user reaches payment step (avoid 100 KB+ on cart page).

## Known failure modes
1. **Double-charge from accidental double-submit**. Production answer: idempotency key on confirm call.
2. **Form data lost on browser back**. Production answer: preserve in sessionStorage; restore on mount.
3. **3DS challenge blocked by popup blocker**. Production answer: full-page redirect fallback when popup blocked.
4. **XSS from third-party scripts on checkout page**. Production answer: strict CSP, no third-party JS on payment step.
5. **Card-element fails to mount when CSP blocks Stripe's frame-src**. Production answer: explicitly allow `https://js.stripe.com` in `frame-src` directive.

## Notes for the coach
- **Asked-confirmed at Stripe** (canonical interview problem variant). Plausibly Shopify, Square, Adyen, Braintree, Checkout.com.
- **The PCI-DSS scope reduction (SAQ A vs SAQ D-Merchant) is the canonical Staff+ unlock.** ~90% fewer compliance controls justifies the iframe architectural choice.
- **The frictionless-vs-challenge 3DS handling is the depth probe.** Mid-senior candidates only handle modal case; Staff+ candidates handle both visible challenge AND silent frictionless outcomes.
- **Adversarial probe: "merchant wants raw card form instead of Elements iframe — what's the cost?"** Strong answer: PCI-DSS scope explodes from SAQ A (~14 questions) to SAQ D-Merchant (~329 questions); annual compliance burden + breach liability; merchant likely cannot legally accept cards without quarterly ASV scans. Production answer: refuse; insist on Elements. Weak answer: "it's less secure" without the SAQ-A-vs-SAQ-D specifics.

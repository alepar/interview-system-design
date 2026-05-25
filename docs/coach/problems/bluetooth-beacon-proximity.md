---
slug: bluetooth-beacon-proximity
archetype: geo-proximity
sources:
  kontakt: kontakt.io/blog/beacon-id-strategy-guide-quick-deployment/
  beaconzone: beaconzone.co.uk/ibeaconadvertisinginterval
  eddystone_spec: github.com/google/eddystone/blob/master/protocol-specification.md
  eddystone_eid: developers.googleblog.com/en/growing-eddystone-with-ephemeral-identifiers-a-privacy-aware-secure-open-beacon-format/
  apple_findmy: support.apple.com/guide/security/find-my-security-sec6cbc80fd0/web
  uwb: amaldev.blog/uwb-the-tech-behind-apple-airtags/
---

# BLE proximity beacons at retail scale — iBeacon advertising packet 30 bytes (16-byte UUID + 2-byte major + 2-byte minor + 1-byte TxPower; distance inferred client-side from observed RSSI vs TxPower) + battery vs latency trade (100ms iBeacon interval = 1-3 months coin cell, 900ms = 2-3 years) + Eddystone 4 frame types on BLE service UUID 0xFEAA (UID/URL/TLM/EID) + Eddystone-EID rotates AES-encrypted 8-byte ID on configurable 2^K-second period (1s to ~9hr) with ECDH-exchanged key (solves iBeacon ID-spoofing) + UWB (Apple U1/U2) cm-level distance via time-of-flight + Apple Find My inverts beacon model (lost device advertises rotating P-224 public key, finders encrypt + upload) + retail deployment pattern (single org-wide UUID, major = store/floor, minor = fixture/shelf)

## Bar anchors
- **Mid-level (L4/E4):** Static beacon broadcasts ID; client picks up; no battery/spoofing discussion.
- **Senior (L5/E5):** Names iBeacon UUID + RSSI distance. May or may not articulate Eddystone-EID, battery trade, UWB time-of-flight, or Find My inverse-beacon.
- **Staff+ (L6/E6+):** Names (a) **iBeacon packet 30 bytes**: 16-byte UUID (org-level) + 2-byte major (group, floor) + 2-byte minor (instance) + 1-byte TxPower (calibrated RSSI @ 1m); distance inferred client-side from observed RSSI vs TxPower; (b) **Battery vs latency**: 100ms iBeacon interval (Apple-recommended) = 1-3 months coin cell; 900ms = 2-3 years; (c) **Eddystone** defines 4 frame types multiplexed on BLE service UUID 0xFEAA: UID (16-byte ID = 10-byte namespace + 6-byte instance), URL (compressed URL push), TLM (battery/temp telemetry), EID (ephemeral encrypted); (d) **iBeacon spoofing**: static IDs trivially clonable. **Eddystone-EID** solves via AES-encrypted 8-byte ID rotating pseudo-randomly on configurable 2^K-second period (1 second to ~9 hours); ECDH-exchanged key at provisioning so only resolver service can de-anonymize; (e) **Apple Find My inverse-beacon**: lost device advertises rotating P-224 public key; nearby Apple devices sniff + encrypt their location to that key + upload anonymously. Apple cannot read locations or identify finder/owner; (f) **Public key rotates ~15 min via derivation counter** — prevents persistent-identifier tracking; finder upload contains no auth so Apple has no finder identity; (g) **UWB (Apple U1/U2)** uses time-of-flight of radio pulses for cm-level distance + direction — replaces RSSI-based proximity (noisy at 1-10m granularity) once peers in UWB range; (h) **Retail deployment pattern** (multi-floor stores): single org-wide UUID, major = store/floor, minor = fixture/shelf — keeps client-side region monitoring scoped to one UUID while distinguishing thousands of beacons.

## Canonical decomposition

### Requirements
**Functional:**
- BLE beacons broadcast proximity-detectable ID
- Client-side detection (iBeacon region monitoring / Eddystone scanning)
- Server resolves beacon → context (retailer, fixture, action)
- Anti-spoof protection

**Non-functional:**
- 100ms interval = 1-3 months coin cell; 900ms = 2-3 years
- BLE RSSI 1-10m granularity (UWB cm-level)
- Eddystone-EID rotates 1s-9hr

### Core entities
- **Beacon:** beacon_id (UUID + major + minor), location, TxPower
- **EdystoneFrame:** {type ∈ {UID, URL, TLM, EID}, payload}
- **ResolverService:** EID → owner identity (ECDH-decrypted)
- **DetectionEvent:** {client_id, beacon_id, rssi, distance_estimate, ts}

### API
- Client: iOS Core Location region monitoring OR Android beacon scanning library
- Server: `POST /beacon_event` body={beacon_id, rssi, ts}
- EID resolver: `POST /resolve_eid` body={eid_payload, ts} (authenticated, ECDH-key access)

### HLD
Beacon broadcasts BLE advertisements per interval. Client scans (iOS region monitoring or Android BLE scanning). On detect, client estimates distance from RSSI vs TxPower (~1m calibrated). Client posts detection to server.

Server: maps (beacon_id) → (retailer, fixture, action) context. For Eddystone-EID, ECDH-key resolver decrypts EID payload → owner identity.

Retail multi-floor store: single org UUID + major (floor) + minor (fixture) — iOS region monitoring on UUID; per-beacon distinction via received major/minor.

Find My inverse-beacon: lost device IS the beacon (advertises rotating P-224 public key); any nearby Apple device IS the scanner + encrypts own GPS to advertised key + uploads. Apple servers index by SHA-256(public_key) — opaque buckets.

UWB Precision Finding (Apple): when peers in U1/U2 range, time-of-flight radio pulses give cm-level distance + direction; falls back to BLE RSSI + AR + haptic at greater range.

### Deep dives
1. **iBeacon packet + battery trade.** 30 bytes: UUID + major + minor + TxPower. Distance client-side inferred from RSSI vs TxPower. 100ms interval = 1-3 months coin cell; 900ms = 2-3 years. Retail tunes per zone.
2. **Eddystone 4 frames + EID spoofing fix.** UID/URL/TLM/EID multiplexed on 0xFEAA. Static iBeacon trivially clonable. EID rotates AES-encrypted 8-byte ID on 2^K-second period (1s-9hr); ECDH key exchange at provisioning; only resolver can de-anonymize.
3. **Find My inverse-beacon + UWB.** Lost device broadcasts rotating P-224 public key (~15 min rotation). Finders sniff + encrypt location to that key + upload anonymously. Apple cannot read or identify. UWB time-of-flight for cm-level distance vs BLE RSSI's 1-10m granularity.

## Known failure modes
1. *iBeacon ID spoofing* — static IDs clonable. Production answer: Eddystone-EID rotation.
2. *RSSI proximity noise* at 1-10m granularity. Production answer: UWB for cm-level when both peers support U1/U2.
3. *Beacon battery exhaustion* — fleet replacement cost. Production answer: 900ms interval for non-critical beacons (2-3 year life).

## Notes for the coach
- **Plausibly-asked at Apple, Google, retail-tech vendors (Kontakt, Estimote, Radius Networks).** iBeacon + Eddystone specs + Find My security guide + UWB analysis are public.
- **Cross-coverage** with `find-my-friends` (this archetype; inverse-beacon pattern). With `geofence-notifications` (this archetype; iBeacon region-monitoring on iOS uses same Core Location primitives).
- **The Eddystone-EID rotation + ECDH key exchange solving iBeacon spoofing is the canonical Staff+ unlock.** Mid-senior candidates assume static IDs are fine; Staff+ candidates name the cloning attack + the EID rotation as cryptographic mitigation.
- **Adversarial probe: "Your retail beacon network is being spoofed — competitor injecting fake iBeacons in their stores. How do you stop it?"** Strong answer: migrate from iBeacon (static UUID + major + minor, trivially clonable) to Eddystone-EID; ECDH key exchange at beacon provisioning (key never leaves resolver service); rotating 8-byte ID on 2^K-second period; only your resolver can decode → competitor-injected beacons fail to resolve. Battery cost: EID rotation requires beacon to have onboard AES — slightly higher power than static iBeacon. Weak answer: "secure the UUIDs" without naming the spoofing-mitigation cryptography.

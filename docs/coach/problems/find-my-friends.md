---
slug: find-my-friends
archetype: geo-proximity
sources:
  apple_security: support.apple.com/guide/security/find-my-security-sec6cbc80fd0/web
  arxiv_verification: arxiv.org/pdf/2510.14589
  openhaystack: github.com/seemoo-lab/openhaystack
  airtag_research: cc-sw.com/find-my-and-find-hub-network-research/
  airtag_product: apple.com/airtag/
  apple_unwanted_tracking: apple.com/newsroom/2022/02/an-update-on-airtag-and-unwanted-tracking/
  northeastern: news.northeastern.edu/2023/10/23/apple-airtag-stalking-alert/
  send_my: positive.security/blog/send-my
  share_location: support.apple.com/guide/iphone/share-your-location-iph01954dc44/ios
---

# Apple Find My + Find My Network — P-224 elliptic-curve key pairs generated entirely on-device + private key + 256-bit seed SK0 never leave devices + sync only via E2E-encrypted iCloud Keychain + advertised public key rotates ~15 min via recursive KDF chain (SK_i = KDF(SK_{i-1}, update)) + P-224 chosen because public-key fits in single BLE advertisement payload + server-side encrypted reports indexed by SHA-256(P-224 public key) (Apple sees only opaque hash buckets, cannot link reports to accounts) + "hundreds of millions" of in-use iPhones/iPads/Macs as anonymous finder fleet + AirTag emits rotating signed BLE every 0.5-2s + Precision Finding via Apple U1 UWB ~10cm time-of-flight + anti-stalking Apple/Google cross-platform spec

## Bar anchors
- **Mid-level (L4/E4):** Designs as server-side location upload from device; no E2E encryption; no key rotation.
- **Senior (L5/E5):** Names BLE + E2E encryption. May or may not articulate P-224 + opaque SHA-256 buckets, recursive KDF rotation, AirTag inverse-beacon model, or anti-stalking spec.
- **Staff+ (L6/E6+):** Names (a) **P-224 EC key pair generated on-device**; private key + 256-bit seed SK0 NEVER leave devices; sync only via E2E-encrypted iCloud Keychain; (b) **Advertised public key rotates ~15 min via recursive KDF chain** `SK_i = KDF(SK_{i-1}, update)` — prevents persistent-identifier tracking; (c) **P-224 specifically chosen** because public-key encoding fits in single BLE advertisement payload — ultra-low-power beacon broadcast; (d) **Server-side encrypted reports indexed by SHA-256(P-224 public key)** — Apple's relay servers see only opaque hash buckets; cannot link reports to accounts/devices; (e) **Crowdsourced fleet**: "hundreds of millions" of in-use iPhones/iPads/Macs as anonymous finder devices — global Bluetooth coverage without dedicated infrastructure; (f) **AirTag** emits cryptographically signed rotating BLE ID every 0.5-2s; finder iPhone fetches own GPS + encrypts with advertised public key + uploads anonymously; (g) **Precision Finding via Apple U1 UWB**: ~10cm accuracy via time-of-flight; falls back to BLE/AR/haptic; 2nd-gen UWB extends range 50%; (h) **Anti-stalking via Apple/Google cross-platform spec**: phones detect unknown rotating-key beacons traveling with them + emit notifications + audible chirps; (i) **Unknown-tracker alerts** have 30-min-to-9-hour delay; researchers demonstrated key-rotation reconfiguration attacks that bypass; (j) **Find My Network exploitable as covert exfiltration channel** ("Send My") — broadcasts bits as fake BLE beacons uploaded by nearby Apple devices; (k) **Share My Location** (friend-sharing primitive distinct from offline finding) supports time-bounded sharing 1hr / EOD / indefinite.

## Canonical decomposition

### Requirements
**Functional:**
- Find lost device (own / family member's) via crowdsourced fleet
- Share Location with friends/family (time-bounded)
- AirTag asset tracking
- Precision Finding (UWB)
- Anti-stalking notifications

**Non-functional:**
- "Hundreds of millions" Apple devices as anonymous finder fleet
- P-224 public key rotates ~15 min
- AirTag BLE beacon 0.5-2s; coin cell ~1yr life
- UWB ~10cm accuracy via time-of-flight

### Core entities
- **OwnerDevice:** Apple ID + private key + SK0 seed (E2E synced via iCloud Keychain)
- **LostDevice:** broadcasting current P-224 public key (rotates ~15 min)
- **FinderDevice:** any nearby Apple device (anonymous)
- **EncryptedReport:** {SHA-256(public_key), encrypted_location_payload}

### API
- BLE: rotating-public-key advertisement (~30 bytes)
- Server: `POST /finder_report` body={hash, encrypted_payload} (no auth required for upload)
- Server: `GET /owner_query?hashes[]=` (authenticated; owner downloads encrypted reports for expected hashes)

### HLD
Owner setup: device generates P-224 EC key pair + 256-bit seed SK0 on-device. Private key + SK0 sync to user's other Apple devices via E2E-encrypted iCloud Keychain. Apple servers never see private key or SK0.

Lost device path: device begins broadcasting rotating P-224 public key (`SK_i = KDF(SK_{i-1}, counter)`); changes every ~15 min. Public key fits in single BLE advertisement payload (P-224 chosen specifically for this).

Finder path: nearby Apple device sniffs BLE → fetches own GPS → encrypts {lat, lon, timestamp} with the advertised public key → uploads to Apple's relay servers with server index = SHA-256(public key). Finder upload contains no auth info; Apple has no finder identity.

Owner query path: owner device computes expected SHA-256(public_key_i) for each rotation window in lookup period; uploads hash list to Apple. Apple returns encrypted reports for matching hash buckets. Owner decrypts using private key.

Precision Finding (AirTag in range): U1 UWB time-of-flight for ~10cm accuracy + direction; falls back to BLE RSSI + AR + haptic guidance when out of UWB range.

Anti-stalking: nearby phones detect unknown rotating-key beacons traveling with them → notify + emit audible chirps. Cross-platform spec with Google.

### Deep dives
1. **P-224 + rotating keys + opaque hash buckets.** P-224 EC on-device. Private key + SK0 never leave. Public key rotates ~15 min via recursive KDF chain. P-224 specifically chosen for BLE-payload fit. Server indexes reports by SHA-256(public_key) — Apple sees only opaque buckets; cannot link to accounts.
2. **Crowdsourced finder fleet + AirTag + UWB Precision Finding.** "Hundreds of millions" Apple devices as anonymous finder fleet. AirTag emits rotating signed BLE every 0.5-2s. Finder iPhone fetches own GPS + encrypts with advertised key + uploads. Precision Finding via U1 UWB time-of-flight ~10cm. Falls back to BLE+AR+haptic.
3. **Anti-stalking spec + Send My exploit + Share My Location.** Cross-platform Apple/Google spec for unknown-tracker alerts. 30min-9hr alert delay + reconfiguration-attack bypass = real failure mode. "Send My" arbitrary data exfiltration via fake BLE beacons. Share My Location separate primitive: time-bounded 1hr/EOD/indefinite.

## Known failure modes
1. *Unknown-tracker alert delay 30min-9hr* + reconfiguration bypass. Production answer: shortened delay + audible chirps; ongoing Apple/Google spec iteration.
2. *Send My covert exfiltration channel* — Find My Network exploitable as data channel. Production answer: rate-limit beacon uploads + require account auth for owner lookups + rotate keys faster.
3. *iOS low-power mode throttles background BLE* → finder devices stop uploading. Accepted trade for battery.

## Notes for the coach
- **Asked-plausibly at Apple, Google.** Apple security guide + symbolic-verification arXiv + OpenHaystack reverse-engineering are canon.
- **Cross-coverage** with `bluetooth-beacon-proximity` (this archetype; beacon primitives). With `snap-map` + `life360` (this archetype; competing location-sharing models).
- **The P-224 rotating-key + opaque SHA-256 bucket architecture is the canonical Staff+ unlock.** Mid-senior candidates assume Apple sees locations; Staff+ candidates name the explicit cryptographic protocol that prevents this.
- **Adversarial probe: "Apple claims they can't read locations. Prove it."** Strong answer: P-224 private key generated on-device + synced only via E2E-encrypted iCloud Keychain (Apple can't decrypt the keychain); public key rotates ~15 min preventing persistent ID; server indexes reports by SHA-256(public key) so Apple sees only opaque hash buckets without identity; finder upload contains no auth info (Apple doesn't know who found); encrypted location payloads decrypted only by owner devices with private key; symbolic-verification paper (arXiv 2510.14589) formalizes. Counterpoint: anti-stalking system relies on Apple correlating beacon-with-user (privacy trade); "Send My" exploit shows the channel is exploitable. Weak answer: "they say they can't" without the protocol details.

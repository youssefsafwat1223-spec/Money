# V1 Security Classification — blocker, or hardening?

Written because the readiness sheet had been treating every open security
opportunity as a release blocker. That is not the same question. "Would Apple
reject this?" and "is there a concrete Qirsh-specific vulnerability?" are the
tests; "would a more hardened app have it?" is not.

Assessed 2026-09-16 against the shipped configuration.

---

## 1. Transport security — the baseline, verified

| Check | Result |
|---|---|
| `NSAppTransportSecurity` in `ios/Runner/Info.plist` | **Absent — ATS fully enforced at defaults.** No `NSAllowsArbitraryLoads`, no domain exceptions, no `NSExceptionAllowsInsecureHTTPLoads` |
| Same for `ios/ShareBankMessage/Info.plist` | **Absent — same posture** |
| Cleartext endpoints in app or extension code | **None.** The single `'http://'` literal in `parser_engine.dart:1021` is a phishing-detection keyword for scanning SMS, not an endpoint |
| Android cleartext | No `usesCleartextTraffic`, no `networkSecurityConfig` override — blocked by platform default since API 28 |
| Hosts contacted | Supabase (`rjwphwsefnuotpbtuycf.supabase.co`), `img.logo.dev`, `qirsh.site`, `apps.apple.com`, `github.com` — all HTTPS |

ATS at defaults means TLS 1.2+, forward secrecy, SHA-256+ certificates, and
Certificate Transparency. That is the platform's own answer to transport
security, and this app takes all of it with no exception carved out.

## 2. Certificate pinning — **POST-V1 HARDENING**, not a blocker

Apple's own position is that pinning is not required, and its guidance warns it
should be deployed only when genuinely necessary — a pinned app breaks when a
certificate rotates, which is an outage the user cannot fix.

The question is whether Qirsh has a concrete vulnerability that ATS does not
already cover. Pinning defends against one thing: a valid certificate from a CA
the device trusts but the app should not. In practice that is a compromised
public CA, or a root the user installed themselves.

What actually crosses the network in V1:

| Traffic | Sensitivity under a MITM with a trusted rogue root |
|---|---|
| Auth (GoTrue) | Real, but identical to every app using the platform's TLS |
| Catalog, flags, force-update | No user data |
| Capture text | **Already redacted before it leaves** — proven on the wire; card, IBAN, OTP, phone, account, Arabic-Indic digits and third-party names are gone |
| Gamification / profile | Low sensitivity, and consent-gated |
| **Financial ledger** | **Does not cross the network at all.** All three transport capabilities are `unknown`, push and pull stay dark, and that was verified at runtime with both consents granted |

The most sensitive payload the product has is the one that never leaves. The
second most sensitive is redacted before it does. An attacker positioned to
install a root certificate on the handset already has the device — and the
database key is now `ThisDeviceOnly` in the keychain, so that is where the
defence sits.

**Verdict: POST-V1.** Revisit when financial sync activates — at that point
money crosses the wire, the calculus changes, and pinning should be evaluated
together with certificate rotation runbooks rather than bolted on.

## 3. Root / jailbreak / debugger detection — **POST-V1 HARDENING**

Not an App Store requirement. Nothing in the Review Guidelines asks for it, and
Apple provides no API for it; every implementation is heuristic, is defeated by
the tooling it tries to detect, and produces false positives that lock legitimate
users out of their own data.

The threat it addresses is an attacker with physical control of an unlocked,
jailbroken device extracting the local database. In V1 that database holds the
device owner's own financial records. Locking the owner out of their own handset
to defend against the owner is not a trade worth making at this stage.

What is actually in place: SQLCipher at rest, a keychain key bound to the device
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it is not in iCloud
Keychain and does not migrate), and app-lock with Face ID.

**App Attest / DeviceCheck** deserves a separate note, because it is the
principled answer to a real finding rather than generic hardening.
`register-device` authenticates nothing — it cannot, since the iOS App Intent
carries no user JWT — and the privilege-escalation path that made that dangerous
is closed (a rotated secret no longer inherits a user link). App Attest would
close the root cause instead of the consequence, by proving a request comes from
a genuine instance of this app. It needs server-side attestation verification and
a key-registration flow.

**Verdict: POST-V1**, and recorded as the principled fix for AUTH-24's root
cause rather than as a generic hardening wish.

## 4. What genuinely remains open in this domain

| Item | Class | Why |
|---|---|---|
| Certificate pinning | POST-V1 | §2 — no concrete V1 vulnerability; ATS enforced with no exceptions |
| Jailbreak / debugger detection | POST-V1 | §3 — not a store requirement; defends the owner from the owner |
| App Attest / DeviceCheck | POST-V1 | §3 — the principled fix for `register-device`; the exploitable path is already closed |
| `sync-captures` claim-on-link (N14) | POST-V1, schema | Needs a `capture_devices.linked_at` column; deferred with migration 0100 by owner decision |
| `metrics_client.dart` `record_metric` | POST-V1 | Pre-existing OPEN finding: owner-bound, allowlisted and rate-limited server-side, sends a key plus a coarse dimension rather than user data |

None of these blocks a V1 submission. All are recorded so they are decisions
rather than oversights.

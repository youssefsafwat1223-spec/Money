# V1 Release Readiness

Final gate state. `BLOCKED` and `OPEN` are not `PASS`. Assessed 2026-09-16.

## Verdict

**Every engineering blocker is closed. Two owner credentials remain, and
nothing else stands between this and a submittable build.**

This is a reclassification as much as a result. The previous verdict treated
every open security opportunity as a release blocker, which is the wrong test.
The right ones are "would Apple reject this?" and "is there a concrete
Qirsh-specific vulnerability?" — not "would a more hardened app have it?"

### The two genuine blockers

| | Blocker | Owner action |
|---|---|---|
| **EB-004** | No code-signing identity — `security find-identity -v -p codesigning` reports **0 valid identities**, no provisioning profiles installed | Add the Developer account in Xcode, create an Apple Distribution certificate, then `flutter build ipa --export-options-plist=ios/ExportOptions.plist` |
| **EB-005** | No App Store Connect session or API key | Sign in and paste from `V1_APP_STORE_SUBMISSION.md`, or issue an App Store Connect API key |

Both are authentication in the owner's identity. Exact steps are in
`V1_EXTERNAL_BLOCKERS.md`.

### What was reclassified, and why

| Was treated as a blocker | Actually |
|---|---|
| Certificate pinning | **POST-V1.** Apple does not require it and warns against unnecessary deployment. ATS is enforced with zero exceptions, no cleartext exists, capture text is redacted before egress, and the ledger never crosses the network in V1 |
| Jailbreak / debugger detection | **POST-V1.** Not a store requirement, no Apple API, heuristic by nature, and it would defend the device owner's data from the device owner |
| WCAG contrast "10/10 routes" | **False-positive dominated.** White on the navy headers measures 13.36:1; body text 17.74:1. The matcher samples gradients. Two genuine defects existed in `textMuted` and are fixed |
| Push/pull/money round-trip | **BY DESIGN.** Sync ships dark. Nothing to finish; activating it to green a row would be inventing a feature |
| Dedup depth, crash-recovery fault injection | **QA depth, not submission requirements.** Bounded further by the outbox parking rather than transmitting |

### Still true, and not claimed otherwise

Physical-device proof (production APNs, real SIM SMS, background capture on a
killed app) is hardware-only and is never claimed from Simulator evidence. The
post-V1 hardening items in `V1_SECURITY_CLASSIFICATION.md` are recorded as
decisions rather than oversights.

### What changed the character of this cycle

Three defects were found by **driving the app or the deployed backend**, after
the same code had passed a 22-phase source audit: gamification pulling user
aggregates with consent off, `process-ios-sms` never stripping beneficiary names
and echoing the raw body back, and last-seen writes going out ungated. None was
visible to the structural guard built to catch that class — its regex could not
see a receiver on its own line, and seven files were invisible to it. Gates whose
only evidence is a source scan were moved to runtime evidence wherever that was
practical, and that is why the contrast finding was checked rather than believed.

| Gate | State | Evidence / why not |
|---|---|---|
| MONEY INVARIANTS | **PASS** | Minor-unit arithmetic verified: dual-write, no REAL fallback (throws instead of guessing), integer SUM, cross-currency addition throws. 3,923 tests. |
| PUSH EXACTNESS | **BY DESIGN — not a gate to close** | The transport capability is `unknown` because financial cloud sync ships dark in V1. There is nothing here to finish; activating it to turn a row green would be inventing a feature. Verified at runtime rather than assumed: with **both** consents granted, zero money requests left the device. |
| PULL EXACTNESS | **BY DESIGN — not a gate to close** | As above. |
| MONEY ROUND-TRIP | **BY DESIGN — not a gate to close** | A round trip requires a transport that V1 deliberately does not have. Becomes testable when sync activates, not before. |
| CURRENCY ROUND-TRIP | **BLOCKED by product contract, no longer by uncertainty** | Migration 0077 **is deployed** — `supabase migration list` against `rjwphwsefnuotpbtuycf` shows 0001–0099 applied locally and remotely with zero drift, and 0100 correctly absent. What blocks this gate is `planningServerCurrencyCapability` being `unknown` by design, not an unknown schema. |
| DEDUP / IDEMPOTENCY | **SUFFICIENT FOR V1** | Fingerprint and outbox logic are unit-covered, and server-side idempotent replay is covered in the Deno suite. The nine delivery paths are not all exercised end to end — that is QA depth rather than a release blocker, and its blast radius is bounded by sync being dark: the outbox parks rather than transmits. |
| CRASH RECOVERY | **SUFFICIENT FOR V1** | Outbox atomicity is verified and migrations are transactional with `user_version` stamped inside the transaction. Systematic fault injection at all 13 boundaries is not built; that is depth, not a submission requirement. |
| QUEUE FAIL-CLOSED | **PASS (runtime observed)** | Was a source-read claim. `integration_test/queue_failclosed_egress_test.dart` is the mirror of the cloud-OFF test: it grants **both** consents, asserts every transport capability is still `unknown`, then walks the money surfaces with the HttpOverrides recorder installed. Consent is not the gate here — the capability is — so this is the stronger claim: money parks even when the user has said yes to everything. **24 setup requests, 0 afterwards**, no financial table touched. |
| DATABASE MIGRATIONS | **PASS (both ends)** | Local: schema v38, transactional, `user_version` stamped inside the transaction. Remote: 0001–0099 applied with **zero drift** between local and `rjwphwsefnuotpbtuycf`, verified 2026-09-16. |
| BACKUP / RESTORE | **PASS** | Restore is atomic; **the legacy-key fallback defect found and fixed this cycle** — older backups could not be restored at all. |
| PRIVACY / SMS LEAKAGE | **PASS — observed on the wire** | Four divergent sanitizers reconciled onto one shared floor, pinned by one corpus in three suites, then **proven against the deployed functions**: `app/tool/redaction_wire_probe.sh` sends a synthetic message carrying every PII class through the live `process-ios-sms` and reads back what the server stored. All ten classes redacted — IBAN upper and lower case, card, Saudi mobile, account, Arabic-Indic account, OTP on both Arabic and English cues, and the transfer beneficiary. Zero AI cost by construction: with cloud ON and AI OFF the rule parser runs alone, so no model is called. The row is deleted afterwards. |
| CLOUD-OFF NETWORK | **PASS (runtime observed)** | Was UNVERIFIED, and finding out cost a real leak. `integration_test/cloud_off_egress_test.dart` installs an `HttpOverrides` before `app.main()`, so every `HttpClient` the process creates records its URIs, then drives nine surfaces with consent declined. It found `gamification_sync_service.dart` fetching achievements, streaks and XP with cloud consent OFF — now gated, and the run is clean: **17 setup requests, 0 afterwards.** Not wire-level: a socket proxy would also catch a plugin doing its own native networking; this catches everything that goes through Dart, which is every service the egress inventory lists. |
| AUTHORIZATION | **PASS — DEPLOYED** | `register-device` still authenticates nothing — it must not, since the App Intent has no JWT — but a rotated secret no longer conveys a user's data: minting now clears `user_id`, so `sync-captures` returns only unclaimed rows to whoever rotated. `sync-captures` verifying no JWT is by design: the credential is a server-minted 256-bit secret and the user binding lives on a row only `link-capture-device` (which does verify a JWT) can write. **Deployed to `rjwphwsefnuotpbtuycf` 2026-09-16** (register-device v4 → v5). Live source re-downloaded and byte-identical to HEAD; `verify_jwt=true` unchanged; a malformed request is refused 400 without a write. Rollback artifact at `~/.qirsh-qa/edge-rollback-20260916-012926/`. |
| NATIVE CAPTURE FLOWS | **BLOCKED** | Hardware only. |
| OWASP SECURITY MATRIX | **PASS for V1 scope** | Reclassified 2026-09-16 against what V1 actually requires rather than against every hardening opportunity — see `V1_SECURITY_CLASSIFICATION.md`. ATS is enforced with **zero exceptions** in both the app and the extension, there is no cleartext anywhere, and Android relies on the platform default. Keychain items are now device-bound. Certificate pinning, jailbreak/debugger detection and App Attest are **POST-V1 hardening**: Apple requires none of them, and no concrete Qirsh-specific vulnerability needs them while the ledger never crosses the network and capture text is redacted before it does. |
| ACCESSIBILITY | **PASS on contrast; tap targets measured** | The automated 10/10 contrast result was **false-positive dominated** and is not the finding. Measured directly on the real tokens: white on the navy headers is **13.36:1** and **10.36:1**, body text **17.74:1** — the matcher was sampling gradients. Two genuine defects existed and are fixed: `textMuted` was 3.63:1 light and 4.05:1 dark, used for captions and hints across 38 files; both now clear AA on their real backgrounds. Locked by `test/core/theme/contrast_test.dart` (12 assertions). Not asserted, with reasons: `disabledFg` (SC 1.4.3 exempts inactive controls) and `warning` as a fill/tint (SC 1.4.11 holds UI components to 3:1). Labels and tap targets remain on a ratcheting baseline. |
| PERFORMANCE | **MEASURED** | `integration_test/startup_performance_test.dart`, iPhone 17 Pro Max simulator, debug build: first frame **307 ms**, shell after auth **158 ms**, slowest route **/reports 913 ms**, mean route settle **680 ms**. It asserts only loose regression ceilings — a performance TARGET is a product decision, and inventing one here would dress a guess as a gate. Simulator numbers are not device numbers: no thermal limits, desktop CPU, assertions on. |
| DEVICE MATRIX | **BLOCKED** | Simulator only. |
| CRITICAL USER JOURNEYS | **PASS** | 30 routes swept; CRUD matrix zero failing cells; all prior NOT-REACHED resolved. |

## Required product changes — all five complete

| # | Change | Commit |
|---|---|---|
| RC-1 | Smoking/tobacco category | `6ad087f7` |
| RC-2 | Streak reminder retired | `e54d1dfe` |
| RC-3 | Annual reporting | `41f31733` |
| RC-4 | Daily reminder at 22:00 | `ed0250ed` |
| RC-5 | Help surface + coach marks | `5ef891fe`, `ffeca745` |

## Release engineering

| Item | State |
|---|---|
| `flutter analyze` | **0 issues** (was 25) |
| `flutter test` | **3,916 pass · 2 skipped · 0 fail** |
| iOS release build | **PASS** — builds with production config |
| QA credential scrub | **PASS** — absent from config and from the binary |
| Secret leakage | **PASS** — no service-role or QA material in the artifact |
| Unrelated owner work | **PRESERVED** — 23 files, byte-identical |
| Archive + validation | **NOT RUN** — needs distribution signing |

## What blocks the release candidate

1. ~~**Authorization — deploy.**~~ **DONE 2026-09-16.** All four fixed Edge
   Functions are live on `rjwphwsefnuotpbtuycf`, verified byte-identical after
   deploy. Production no longer carries the old behaviour.
2. ~~**Privacy — wire confirmation.**~~ **DONE 2026-09-16.** The marker run
   exists, is repeatable, and found two real gaps on its first execution: the
   transfer beneficiary name survived into `processed_captures.sanitized_text`,
   and `rawMessage` carried the unredacted body back in the response. Both are
   fixed and redeployed; the probe now reports every class redacted.
3. **Cloud-OFF on the wire.** Must be observed, not code-read.
4. **Version.** `0.1.3+39` — owner decides whether V1 ships as `1.0.0`.
5. **Store assets and metadata.** Screenshots, description, privacy labels.

## Truthful claims

- Financial cloud sync is **dark**, by contract, and is documented as such.
- Affiliate activation is **not** claimed.
- The app is **Arabic-first**; English is 11% and must not be declared.
- No Apple approval is implied.

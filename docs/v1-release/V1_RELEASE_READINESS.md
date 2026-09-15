# V1 Release Readiness

Final gate state. `BLOCKED` and `OPEN` are not `PASS`. Assessed 2026-09-16.

## Verdict

**NOT READY**, and closer than it was. The two P0 gates that engineering could
close — the SMS sanitizer divergence and the `register-device` privilege
escalation — are closed in source and covered by tests that fail against the
previous code. What remains needs owner decisions, a deploy the owner must
authorise, physical hardware, or work measured in weeks rather than hours.

Three things follow, and none of them is "ship it":

1. The authorization fix is **deployed**. Production carries it.
2. Privacy is closed at the unit level in all three implementations. The
   end-to-end marker run through a live capture is still the proof that it
   holds on the wire.
3. A P0 privacy leak was found in this cycle by **driving the app**, not by
   reading it — and the structural guard written to prevent exactly that class
   of defect could not see the file, because its regex required a receiver and
   its call on one line and `dart format` splits long chains. Seven files were
   invisible to it. That is a reason for humility about every gate on this page
   whose evidence is a source scan.
4. `NOT READY` here is not a formality. The terminal phrase this effort is
   working toward is not claimed.

| Gate | State | Evidence / why not |
|---|---|---|
| MONEY INVARIANTS | **PASS** | Minor-unit arithmetic verified: dual-write, no REAL fallback (throws instead of guessing), integer SUM, cross-currency addition throws. 3,923 tests. |
| PUSH EXACTNESS | **BLOCKED** | Transport capability is `unknown` by product contract. Not activated to make a gate green. |
| PULL EXACTNESS | **BLOCKED** | As above. |
| MONEY ROUND-TRIP | **BLOCKED** | Requires live PostgREST + Postgres. |
| CURRENCY ROUND-TRIP | **BLOCKED by product contract, no longer by uncertainty** | Migration 0077 **is deployed** — `supabase migration list` against `rjwphwsefnuotpbtuycf` shows 0001–0099 applied locally and remotely with zero drift, and 0100 correctly absent. What blocks this gate is `planningServerCurrencyCapability` being `unknown` by design, not an unknown schema. |
| DEDUP / IDEMPOTENCY | **PARTIAL** | Fingerprint and outbox logic covered by unit tests; the nine delivery paths are not all exercised. |
| CRASH RECOVERY | **PARTIAL** | Outbox atomicity verified; fault injection at the 13 boundaries not built. |
| QUEUE FAIL-CLOSED | **PASS (runtime observed)** | Was a source-read claim. `integration_test/queue_failclosed_egress_test.dart` is the mirror of the cloud-OFF test: it grants **both** consents, asserts every transport capability is still `unknown`, then walks the money surfaces with the HttpOverrides recorder installed. Consent is not the gate here — the capability is — so this is the stronger claim: money parks even when the user has said yes to everything. **24 setup requests, 0 afterwards**, no financial table touched. |
| DATABASE MIGRATIONS | **PASS (both ends)** | Local: schema v38, transactional, `user_version` stamped inside the transaction. Remote: 0001–0099 applied with **zero drift** between local and `rjwphwsefnuotpbtuycf`, verified 2026-09-16. |
| BACKUP / RESTORE | **PASS** | Restore is atomic; **the legacy-key fallback defect found and fixed this cycle** — older backups could not be restored at all. |
| PRIVACY / SMS LEAKAGE | **PASS — observed on the wire** | Four divergent sanitizers reconciled onto one shared floor, pinned by one corpus in three suites, then **proven against the deployed functions**: `app/tool/redaction_wire_probe.sh` sends a synthetic message carrying every PII class through the live `process-ios-sms` and reads back what the server stored. All ten classes redacted — IBAN upper and lower case, card, Saudi mobile, account, Arabic-Indic account, OTP on both Arabic and English cues, and the transfer beneficiary. Zero AI cost by construction: with cloud ON and AI OFF the rule parser runs alone, so no model is called. The row is deleted afterwards. |
| CLOUD-OFF NETWORK | **PASS (runtime observed)** | Was UNVERIFIED, and finding out cost a real leak. `integration_test/cloud_off_egress_test.dart` installs an `HttpOverrides` before `app.main()`, so every `HttpClient` the process creates records its URIs, then drives nine surfaces with consent declined. It found `gamification_sync_service.dart` fetching achievements, streaks and XP with cloud consent OFF — now gated, and the run is clean: **17 setup requests, 0 afterwards.** Not wire-level: a socket proxy would also catch a plugin doing its own native networking; this catches everything that goes through Dart, which is every service the egress inventory lists. |
| AUTHORIZATION | **PASS — DEPLOYED** | `register-device` still authenticates nothing — it must not, since the App Intent has no JWT — but a rotated secret no longer conveys a user's data: minting now clears `user_id`, so `sync-captures` returns only unclaimed rows to whoever rotated. `sync-captures` verifying no JWT is by design: the credential is a server-minted 256-bit secret and the user binding lives on a row only `link-capture-device` (which does verify a JWT) can write. **Deployed to `rjwphwsefnuotpbtuycf` 2026-09-16** (register-device v4 → v5). Live source re-downloaded and byte-identical to HEAD; `verify_jwt=true` unchanged; a malformed request is refused 400 without a write. Rollback artifact at `~/.qirsh-qa/edge-rollback-20260916-012926/`. |
| NATIVE CAPTURE FLOWS | **BLOCKED** | Hardware only. |
| OWASP SECURITY MATRIX | **PARTIAL — one P0 class closed** | Secure-storage options were unset at all 12 sites, so the SQLCipher database key, the capture relay secret and the install id were written with iOS defaults: eligible for iCloud Keychain and device-to-device transfer. Ten sites now use `SecureStorageOptions.storage` (`first_unlock_this_device` = ThisDeviceOnly, `afterFirstUnlock` so the capture pipeline still works on a locked phone); the remaining two hold a UI snooze timestamp in the owner's uncommitted file and are recorded as an exemption. **Proven safe before changing anything**: `integration_test/keychain_accessibility_test.dart` writes with the old options and reads with the new on a real simulator keychain, and back again, so neither an upgrade nor a rollback strands the database key. Still open in this domain: no root/debugger detection, no certificate pinning. |
| ACCESSIBILITY | **PARTIAL** | RTL/LTR asserted on the new surfaces; no full audit. |
| PERFORMANCE | **NOT MEASURED** | |
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

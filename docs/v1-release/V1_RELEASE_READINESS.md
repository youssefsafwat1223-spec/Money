# V1 Release Readiness

Final gate state. `BLOCKED` and `OPEN` are not `PASS`. Assessed 2026-09-16.

## Verdict

**NOT READY**, and closer than it was. The two P0 gates that engineering could
close — the SMS sanitizer divergence and the `register-device` privilege
escalation — are closed in source and covered by tests that fail against the
previous code. What remains needs owner decisions, a deploy the owner must
authorise, physical hardware, or work measured in weeks rather than hours.

Three things follow, and none of them is "ship it":

1. The authorization fix exists only in this repository. **Production still
   carries the old behaviour** until the edge functions are deployed.
2. Privacy is closed at the unit level in all three implementations. The
   end-to-end marker run through a live capture is still the proof that it
   holds on the wire.
3. `NOT READY` here is not a formality. The terminal phrase this effort is
   working toward is not claimed.

| Gate | State | Evidence / why not |
|---|---|---|
| MONEY INVARIANTS | **PASS** | Minor-unit arithmetic verified: dual-write, no REAL fallback (throws instead of guessing), integer SUM, cross-currency addition throws. 3,923 tests. |
| PUSH EXACTNESS | **BLOCKED** | Transport capability is `unknown` by product contract. Not activated to make a gate green. |
| PULL EXACTNESS | **BLOCKED** | As above. |
| MONEY ROUND-TRIP | **BLOCKED** | Requires live PostgREST + Postgres. |
| CURRENCY ROUND-TRIP | **BLOCKED** | Requires migration 0077, whose deployment state is UNVERIFIED. |
| DEDUP / IDEMPOTENCY | **PARTIAL** | Fingerprint and outbox logic covered by unit tests; the nine delivery paths are not all exercised. |
| CRASH RECOVERY | **PARTIAL** | Outbox atomicity verified; fault injection at the 13 boundaries not built. |
| QUEUE FAIL-CLOSED | **PASS** | With capability `unknown`, money writes park and nothing is transmitted. |
| DATABASE MIGRATIONS | **PASS** | Schema v38, transactional, `user_version` stamped inside the transaction. |
| BACKUP / RESTORE | **PASS** | Restore is atomic; **the legacy-key fallback defect found and fixed this cycle** — older backups could not be restored at all. |
| PRIVACY / SMS LEAKAGE | **PASS (unit)** | Four divergent sanitizers reconciled: the server copies share one floor, the Swift copy is verified against the shipped source, and one corpus is pinned in all three suites. IBAN, cue-anchored OTP, Arabic-Indic digits and lower-case IBANs now redact everywhere; the Swift copy fails closed on a rule that will not compile. The end-to-end wire marker run is still outstanding. |
| CLOUD-OFF NETWORK | **UNVERIFIED** | Enforcement is code-read, never observed on the wire. |
| AUTHORIZATION | **PASS (unit), pending deploy** | `register-device` still authenticates nothing — it must not, since the App Intent has no JWT — but a rotated secret no longer conveys a user's data: minting now clears `user_id`, so `sync-captures` returns only unclaimed rows to whoever rotated. `sync-captures` verifying no JWT is by design: the credential is a server-minted 256-bit secret and the user binding lives on a row only `link-capture-device` (which does verify a JWT) can write. **The change is in source only — the edge functions are not deployed.** |
| NATIVE CAPTURE FLOWS | **BLOCKED** | Hardware only. |
| OWASP SECURITY MATRIX | **OPEN** | 23 P0s in that domain; no root/debugger detection, no pinning; secure-storage options unset at all 12 sites. |
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

1. **Authorization — deploy.** The privilege-escalation path is fixed in
   source and covered by a test that fails against the previous code
   (`supabase/functions/register-device/handler_test.ts`). It is **not
   deployed**: deploying edge functions to the production project is an
   owner action, and nothing in this cycle has touched it. Until it is
   deployed, production still carries the old behaviour.
2. **Privacy — wire confirmation.** The sanitizer divergence itself is closed
   (`c826d14b` + follow-up) and pinned by one corpus in three suites. What is
   not done is observing it on the wire: the §3 marker run in
   `docs/qa/QA_SECURITY_MATRIX.md` remains the end-to-end proof, and until it
   runs, the claim rests on unit evidence.
3. **Cloud-OFF on the wire.** Must be observed, not code-read.
4. **Version.** `0.1.3+39` — owner decides whether V1 ships as `1.0.0`.
5. **Store assets and metadata.** Screenshots, description, privacy labels.

## Truthful claims

- Financial cloud sync is **dark**, by contract, and is documented as such.
- Affiliate activation is **not** claimed.
- The app is **Arabic-first**; English is 11% and must not be declared.
- No Apple approval is implied.

# V1 Release Readiness

Final gate state. `BLOCKED` and `OPEN` are not `PASS`. Assessed 2026-09-16.

## Verdict

**NOT READY.** Five gates are genuinely open. Everything that can be closed by
engineering inside this window has been closed; what remains needs either owner
decisions, physical hardware, or work measured in weeks rather than hours.

| Gate | State | Evidence / why not |
|---|---|---|
| MONEY INVARIANTS | **PASS** | Minor-unit arithmetic verified: dual-write, no REAL fallback (throws instead of guessing), integer SUM, cross-currency addition throws. 3,916 tests. |
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
| AUTHORIZATION | **OPEN** | `register-device` mints a device secret from the public anon key; `sync-captures` performs no JWT verification. Both stand. |
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

1. **Authorization (P0).** `register-device` and `sync-captures` need fixing or
   an explicit accepted-risk decision. Server-side change.
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

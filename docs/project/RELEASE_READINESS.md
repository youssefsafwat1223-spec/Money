# Qirsh — release readiness

**Classification as of 2026-09-02: ENGINEERING COMPLETE.**

Not BETA READY. Not a Release Candidate. Not Production Ready.

> **Re-evaluated after Android emulator QA (2026-09-03).** Still
> ENGINEERING COMPLETE — and the label is now better earned than it was, because
> a defect that would have made it false was found and fixed: **the Android app
> did not compile**, and had not since 2026-09-01, while every gate reported
> green. Emulator QA proved the built app installs, boots, opens its encrypted
> database, captures a real inbound SMS end to end with the app not running,
> drops non-financial messages, and keeps merchant URLs out of the financial
> queue. None of that is physical-device evidence, so BETA READY is unchanged.
> A new CRITICAL, RB-7, records that nothing in CI compiles Android.
>
> **Re-evaluated after the migration ledger was verified (2026-09-02).**
> The classification **does not change**, and it is worth being precise about
> why. Closing RB-4 removed a *production* blocker and the product's worst
> unknown — whether account deletion actually erases server-side. It removed
> nothing from the BETA READY bar, which is device QA, and **no physical device
> has been used**.
>
> What genuinely improved: this label is no longer qualified by "…and we cannot
> tell what the backend is running". Production is verified applied through
> 0092. Open production blockers went from three to two, and both remaining ones
> are external — hardware and Google's review queue.
>
> Promoting the label on the strength of a document correction would be exactly
> the inflation this file exists to prevent.

## What the label means here

| Label | Met? | Why |
|---|---|---|
| NOT READY | passed | No known executable engineering blocker remains. The one that did — Android SMS capture being unreachable — is fixed. |
| **ENGINEERING COMPLETE** | **current** | Code and integration are complete; canonical CI is green; every remaining item needs hardware, an external account, or a production database this machine cannot read. |
| BETA READY | **no** | Requires **device** QA. RB-5 is **PENDING — HARDWARE CURRENTLY UNAVAILABLE**; the 2026-09-03 emulator pass (22 PASS) is banked and must not be repeated. |
| RELEASE CANDIDATE | **no** | Additionally requires the Play restricted-permission approval. *(The production migration ledger requirement is now **met** — verified applied through 0092 on 2026-09-02.)* |
| PRODUCTION READY | **no** | Additionally requires deployed migrations, deployed Edge Functions, configured AdMob units, and store approval. |

## The honest boundary

**ENGINEERING COMPLETE ≠ VALIDATED.** Specifically:

- Affiliate fixture tests are **not** real network validation — no network is contracted.
- Zero simulator runs are **not** simulator validation.
- Migration source is **not** a deployed migration. Verified state: applied through **0092**; **0093–0098 are source-only** and must not be assumed deployed.
- Edge Function tests are **not** deployed Edge Functions; four affiliate functions have never executed against the live project.
- An AdMob component is **not** a configured AdMob account; no production ad unit exists.
- A written device QA plan is **not** device QA.

## What has actually been verified

**Canonical CI on 2026-09-03: 12 mandatory gates passed, 0 failed.** Flutter
**3518 passed / 1 skipped / 0 failed** (bulk) plus **24 passed** (serialized
crypto). The baseline at the start of this finalization was 8 passed / 4
failed.

```
mandatory gates passed : 12
mandatory gates failed : 0
tools unavailable      : 0
caller-skipped tests   : 0
artifact-dependent     : 1   (iOS packaging — needs a built Runner.app)
node tests skipped     : 89  (credentials absent, all manifest-declared)
skip/ignore manifest   : satisfied
```

Deno 215. Node contract 317 / 228 pass / 0 fail. Admin 140 / 140, lint clean,
`npm run build` succeeds.

**Android build verified 2026-09-03**: `✓ Built app-debug.apk` (201 MB, exit 0)
— the first time the Android artifact has been confirmed to compile. See RB-7:
no CI gate does this.

Canonical CI (`tools/ci_gates.sh`, the repository's own authority — 12 gates,
with a truthfulness contract that forbids counting a skip as a pass):
migration lint, Deno tests + lint, `flutter analyze`, the full Flutter suite in
two stages, Node contract tests, skip-manifest enforcement, admin authorization
tests, l10n freshness, the MALI-034 architecture guard, and the dependency
policy. The iOS packaging gate is artifact-dependent and defers to a post-build
check.

Static and architectural guarantees are strong: 430 test files, egress
inventory with every network call classified, backup/wipe/restore coverage
guards, forward-only schema enforcement, and a new reachability guard that fails
if a permission-gated feature loses its last production caller.

## Runtime evidence — what was actually run, and what it proves

There is **no iOS simulator, no Android emulator, no `adb`, and no AVD** on this
machine (`flutter devices` reports only macOS desktop and Chrome). The only
runtime surface available is the macOS desktop target, which is **not a shipping
platform**. It was used anyway, because zero runtime evidence is worse than
partial runtime evidence honestly labelled.

**What ran, 2026-09-02:**

```
flutter build macos --debug   →  ✓ Built money_companion.app   (exit 0)
```

The entire Dart tree and every native plugin compile and link. That is the first
build evidence in this project's record.

The binary was then launched and observed:

```
[SupabaseConfig] env=production configured=false
[Bootstrap] session_restore ok (579ms)
[Bootstrap] notifications_init ok (185ms)
[Bootstrap] [id] ok (4197ms)
[Bootstrap] database_open failed after 50ms: PlatformException
```

**Two real findings from that:**

1. The app **boots, runs its bootstrap chain, and survives a database-open
   failure without crashing.** That is the fail-open behaviour the design claims,
   observed rather than asserted.
2. `database_open` fails on macOS because `macos/Runner/*.entitlements` carries
   no keychain entitlement, so `flutter_secure_storage` cannot hold the SQLCipher
   key under the sandbox. **This is a macOS-target gap, not an iOS/Android
   defect.**

An attempt to close (2) by adding `keychain-access-groups` was **reverted**: on
an ad-hoc-signed local build `$(AppIdentifierPrefix)` expands to nothing, the
resulting group is invalid, and the app was killed at launch. Making macOS a
usable QA surface needs a real signing identity. Recorded as deferred debt in
`MASTER_ROADMAP.md` rather than left half-done.

**What this evidence is not.** It is not mobile runtime QA. It exercises no SMS
receipt, no share extension, no App Group, no push, no platform-view banner, and
no real database. Every mobile-specific behaviour remains unverified.

## What has never been verified

Everything that needs hardware or a counterparty. See `RELEASE_BLOCKERS.md`
RB-4, RB-5 and RB-6 for the three that gate a production claim, and
`EXTERNAL_REQUIREMENTS.md` for the full dependency list.

## Path to the next label

1. **→ BETA READY:** reconnect the Xiaomi 2201117TG and run **only** the
   physical-device-only matrix (§5 of `ANDROID_EMULATOR_QA.md`) via
   `device_qa_plan.md` and `MANUAL_BANNER_QA_CHECKLIST.md`. ~~Resolve the migration ledger.~~ ✅ done
   2026-09-02 — production verified applied through 0092.
2. **→ RELEASE CANDIDATE:** reconcile the three SMS disclosure documents, submit
   the Play permissions declaration and Data Safety form, obtain approval.
   Restore Apple portal access and complete iOS device QA.
3. **→ PRODUCTION READY:** deploy the verified migration set and the Edge
   Functions, configure AdMob units and `app-ads.txt`, then enable flags
   deliberately and one at a time.

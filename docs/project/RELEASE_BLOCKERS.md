# Qirsh — release blockers

**As of 2026-09-03.** A blocker is something that makes a release *indefensible*,
not merely imperfect. Everything else is in `MASTER_ROADMAP.md` as debt.

Policy: **zero unresolved RELEASE BLOCKER and zero unresolved CRITICAL** before
claiming Release Candidate or higher.

---

## RESOLVED on 2026-09-02

### RB-1 — Android automatic SMS capture was unreachable ✅ FIXED

The build declared `RECEIVE_SMS` and registered a live `SMS_RECEIVED` receiver
for a feature no user could switch on. Google Play requires a declared
restricted permission to enable core functionality a reviewer can exercise; the
privacy policy was already live saying the app captures bank SMS; and Settings
told users it does not.

Fixed by wiring the Settings toggle, correcting the copy, and adding a
reachability guard. See `CURRENT_STATE.md`.

### RB-2 — Four canonical CI gates failing ✅ FIXED

`tools/ci_gates.sh` is this repository's CI authority and it reported
`mandatory gates failed: 4`. All four are now honest: the arch guard's schema
pin (stale at 31 through four approved bumps), `app/CLAUDE.md` (said 33), 19
node skips with no stated reason, and a signing guard that scanned the
filesystem while claiming to check what was committed.

### RB-3 — a false privacy claim in a Play submission draft ✅ FIXED

`data_safety_draft.md` stated the egress inventory had "0 open" findings. It has
three. That document is destined for a regulatory submission.

### RB-4 — the production migration ledger was unknowable · ✅ **CLOSED 2026-09-02**

**Resolved by owner verification.** A read-only query against
`supabase_migrations.schema_migrations` on the production project
(`rjwphwsefnuotpbtuycf`) confirmed the ledger is **continuous through 0092**,
with 0084–0092 each explicitly present.

The `SOURCE-ONLY / NOT APPLIED` headers on 0084, 0085 and 0086 were stale: they
named an earlier production project that is no longer the deployment target.
Corrected in place; deployment state now lives in one file,
`MIGRATION_LEDGER.md`.

**What this closes:** the worst open unknown in the product — `0084` is a
data-erasure repair, so "possibly unapplied" meant "account deletion may not
fully erase and we cannot tell". It is applied. Deletion completeness is
server-side verified.

**What it does not close:** 0093–0098 remain source-only and must not be
assumed deployed. Every feature depending on them is behind an OFF flag, so
nothing is broken by their absence.

---

## OPEN — blocking PRODUCTION, not blocking further engineering

### RB-5 — Android physical-device QA · **PENDING — HARDWARE CURRENTLY UNAVAILABLE** · EXTERNAL RELEASE GATE

**Status is not "in progress". It is parked on hardware.** This stays an
external release gate and cannot be closed by any amount of further emulator,
simulator or static work.

**Already banked, do NOT repeat.** The Android emulator pass of 2026-09-03
(Android 13 / API 33 / x86_64, against the real 201 MB debug APK) is complete
and recorded in `ANDROID_EMULATOR_QA.md`: 22 PASS, 2 blocked on authentication,
2 not run. It proved the two-key lock against genuinely delivered SMS, capture
with the app not running, multipart reassembly, the privacy prefilter,
durable-queue survival across a device restart, Force Stop suppression, and
merchant-URL isolation from the financial queue.

**When hardware returns, resume ONLY the physical-device-only matrix.** Do not
re-run the emulator suite — it adds no new evidence and costs hours.

Run exactly:
- `Qirsh Production/18_Android_SMS_Capture/device_qa_plan.md`
- `docs/MANUAL_BANNER_QA_CHECKLIST.md`

scoped to §5 of `ANDROID_EMULATOR_QA.md`, which is the authoritative list of
what an emulator structurally cannot answer: real carrier/bank SMS formats,
Xiaomi/MIUI autostart and background-kill behaviour, doze and app-standby, real
APNs delivery, dual-SIM routing, permission revocation through the real Settings
app, lock-screen notification rendering, AdMob rendering including the
platform-view-over-sheet bleed check, release-build cold-start timing (which
determines whether the observed low-RAM broadcast-timeout risk is real in the
field), and the v33→v34→v35 migration on a populated real database.

**Target hardware on file:** Xiaomi 2201117TG (Redmi Note 11S), Android 13,
locale ar-EG, dual live Orange EG SIM — profiled 2026-09-02, currently
disconnected.

### RB-6 — Google Play restricted-permission approval · **RELEASE BLOCKER** · EXTERNAL APPROVAL

`RECEIVE_SMS` requires an approved permissions declaration under the SMS-based
money management exception. The draft is ready and **not submitted**; the Data
Safety form likewise.

**Before submitting**, reconcile three documents that currently do not agree:
the declaration draft says no SMS text reaches an AI provider; the Data Safety
draft records an optional sanitized-text path that the backend retains; the live
privacy policy describes an optional cloud/AI path. All three must say the same
thing, and the true statement is the third one — the path exists, is
consent-gated and is off by default.

### RB-7 — nothing in CI compiles the Android app · **CRITICAL** · OWNED

**Evidence.** The Android app was unbuildable from `564f1327` until
`7161ad04` — a wrong package declaration on two Kotlin files — and **every gate
stayed green the whole time**: 12/12 canonical CI, 3537 Flutter tests, Deno,
Node, admin, migration lint, all architecture guards. It was caught only by
physically building for a device.

**Partially mitigated.** `android_source_integrity_test.dart` now catches this
specific class statically in ~1s (one package across all Kotlin sources, package
== `applicationId`, `MainActivity` references resolvable, manifest components
exist). Proven non-vacuous.

**Not resolved.** A static guard is not a compiler. Any Kotlin error it does not
model still ships green. `flutter build apk` takes ~38 minutes cold, which is why
it is not in the inner loop — but a release pipeline that never compiles the
artifact it releases is a real gap.

**Recommended.** Add an Android compile step to the release workflow (not the
inner loop), e.g. `assembleDebug` on CI hardware with a warm Gradle cache.

---

## NOT blockers — recorded debt

| Item | Severity | Why it does not block |
|---|---|---|
| Proof-Carrying engine unwired | CLEANUP | Zero production callers, so zero runtime effect. Dart AOT strips unreferenced code. Both reviewers: ship dormant, recorded. Activation is an integration change, not a flag flip. |
| Affiliate click gateway unwired | CLEANUP | Coupons work; the CTA opens the plain merchant URL. No network is contracted, so wiring a gated egress path now adds accidental-activation risk for no benefit. |
| `SupabaseEngagementRecorder` unwired | LOW | Nothing reaches the network. Recorded as an OPEN egress finding so the consent obligation is visible before a caller appears. |
| `record_metric` has no client consent gate | MEDIUM | Server-side owner-bound, allowlisted, rate-limited; carries a key and a coarse dimension, never user data. Tracked, not hidden. |
| ~~`set_default_account` gates on transport, not consent~~ | ✅ FIXED | Closed 2026-09-02. One consent gate at the `StartupSyncReconcileService` entry now covers every backfill it drives, defaults to DENY, and refusal is its own outcome. |
| No JVM test source set for Android | LOW | Kotlin is covered by structural assertions over source rather than execution. Weaker, and recorded as such. |
| iOS share extension still named «إضافة رسالة بنك» | LOW | Now inaccurate for a URL share. A product naming decision, deliberately left to the owner. |
| `app/android/key.properties` on disk | LOW | Gitignored, never committed, and now asserted so by the corrected guard. Consider relocating outside the repo anyway. |

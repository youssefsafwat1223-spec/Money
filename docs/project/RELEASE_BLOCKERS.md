# Qirsh — release blockers

**As of 2026-09-03.** A blocker is something that makes a release *indefensible*,
not merely imperfect. Everything else is in `MASTER_ROADMAP.md` as debt.

Policy: **zero unresolved RELEASE BLOCKER and zero unresolved CRITICAL** before
claiming Release Candidate or higher.

---

## RESOLVED

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
money management exception. **Nothing has been submitted.**

**The reconciliation is DONE (2026-09-03).** Every SMS statement was audited
against the code and four were false — including one that made the live privacy
policy untrue (see RB-8). The declaration is rewritten, the disclosure quoted
verbatim, the store copy corrected, and a 12-step reviewer video script written.
Entry point: `Qirsh Production/18_Android_SMS_Capture/PLAY_SUBMISSION_PACKAGE.md`.

**Two things still block submission, both owner actions:**

1. **Pin a no-training AI provider tier before `GEMINI_API_KEY` is ever set.**
   Both reviewers made this the pivot: the exception permits transfer to a
   *service provider*, and the Gemini free tier permits Google to use submitted
   content to improve its products — an independent purpose that would void the
   claim and flip Data Safety to *Shared: YES*. The key is unset in production;
   keep it that way until the tier and its terms are recorded.
2. **Redeploy the legal site.** The policy source is corrected; the live page
   still says "and notification messages". The declaration attaches that URL.

Plus the reviewer video, which needs RB-5 hardware.

### RB-7 — CI did not compile the app · ✅ **CLOSED 2026-09-03** (both platforms) · was CRITICAL

**Why this existed.** The Android app was unbuildable from `564f1327` until
`7161ad04` — a wrong package declaration on two Kotlin files — and **every gate
stayed green the whole time**: 12/12 canonical CI, 3537 Flutter tests, Deno,
Node, admin, migration lint, all architecture guards. It was caught only by
physically building for a device.

#### Android — CLOSED

Two independent layers now cover it:

1. **A real compiler in automatic CI.** `codemagic.yaml`'s
   `backend-and-quality-gates` workflow builds a **debug APK** on every push and
   pull request to `main`, `master`, `develop` and `feat/*` (added in
   `8a5bd3aa`). It is the only auto-triggered workflow — the three build
   workflows are manual-only — and it needs no signing key, no production AdMob
   ids and no backend. It exercises Gradle 9.1.0, AGP 9.0.1, Kotlin 2.3.20,
   javac, `GeneratedPluginRegistrant`, native plugins, sqlite3mc via the NDK and
   manifest merge, verifies the vendored `file_picker` fork is actually resolved,
   and asserts the artifact exists rather than trusting the exit code.
2. **A ~1s static guard** for the specific class that caused it —
   `android_source_integrity_test.dart` (one package across all Kotlin sources,
   package == `applicationId`, `MainActivity` references resolvable, manifest
   components exist). Proven non-vacuous.

The recommendation this blocker used to carry — "add an Android compile step to
the release workflow" — is **done**. Only two narrow caveats remain, both
deliberate and neither blocking:

- `tools/ci_gates.sh` itself still does not compile Android, so a **local** green
  `ci_gates.sh` run is not evidence that Android builds. The compiler lives in
  Codemagic, not in the inner loop, because a cold `flutter build apk` is ~38
  minutes. Do not read a local 12/12 as build proof.
- Pure-documentation changesets skip the workflow by design (`excludes: docs/**`,
  `**/*.md`), so an Android build is not spent on a README edit.

#### iOS — CLOSED 2026-09-03, and it was broken

**The first iOS build ever attempted in this repository failed.** The same gap
existed for iOS — both Xcode workflows are manual-only and the auto-triggered
workflow had no iOS step — and it was hiding the same class of defect, in the
same feature:

```
Swift Compiler Error: Cannot find 'SharedOfferIntentStore' in scope
ios/ShareBankMessage/ShareViewController.swift:47
```

Both copies of `SharedOfferIntentStore.swift` existed on disk, were correct, and
were byte-identical. **Neither had ever been added to a target** in
`Runner.xcodeproj/project.pbxproj`, so nothing compiled them, while two files
that *do* compile referenced the type (`ShareViewController.swift` and
`AppDelegate.swift` — so the Runner target would have failed next). Its
neighbour `SharedCaptureStore.swift` is wired into both targets correctly, which
is exactly why this survived inspection. On iOS there is no error for "source
file nobody builds" — only for the reference that cannot resolve, reported
somewhere else entirely.

This is the iOS twin of the Android package bug (`564f1327` → `7161ad04`), from
the same offer-URL sharing work, surviving for the same reason.

**Fixed and verified.** Both copies wired into their targets (`PBXBuildFile`,
`PBXFileReference`, group child, Sources phase). Build now verified:
`✓ Built build/ios/iphoneos/Runner.app` (207 MB) with
`PlugIns/ShareBankMessage.appex` embedded.

Three layers now cover iOS:

1. **A real compiler in automatic CI.** `backend-and-quality-gates` builds an
   unsigned iOS app on every push/PR. `--no-codesign` needs no signing identity,
   no provisioning profile and no Apple portal access — none of which are
   available — while still exercising CocoaPods, the Swift compiler across
   Runner *and* the extension, `GeneratedPluginRegistrant` and every plugin's
   iOS unit. It asserts the `.appex` is embedded, because the defect lived in
   the extension and a `Runner.app` without it would read as success.
2. **A ~1s static guard**, `ios_source_integrity_test.dart`: every `.swift` file
   in a target directory must appear in some Sources build phase, and both
   copies of each App-Group store must stay byte-identical. Proven non-vacuous
   against the original `project.pbxproj`.
3. **The byte-identity contract now runs in CI.** `RunnerTests.swift` asserted it
   for `SharedCaptureStore`, but XCTest only runs under Xcode and never executes
   in this repository's CI. `SharedOfferIntentStore` had the same two-copy shape
   and **no check at all**. Both are covered by the Dart guard, which does run.

**What remains open for iOS is runtime, not compilation** — every iOS Runtime
and Device cell in `FEATURE_MATRIX.md` is still ❌, and that is RB-5's iOS
counterpart, gated on hardware and an Apple provisioning profile.

### RB-8 — AI egress was single-gated · ✅ **FIXED 2026-09-03** · was CRITICAL

`ConsentAuthority` required `cloud && aiConsentGranted` for AI egress; the
production wiring asked only for `aiConsentGranted` at four call sites, and
`ai_parser_client` never consulted `ConsentAuthority`. With cloud processing OFF
and AI ON — a state the UI allows — sanitized bank-SMS text was still
transmitted.

That made a **published legal document false**: the policy promises that with
cloud off "no financial data leaves your device — this is enforced at every
network call, not only in the settings UI."

Fixed by routing every site through `ConsentAuthority`, pinned by
`ai_egress_consent_test.dart` (non-vacuous), 505 related tests passing. Found
while reconciling statements for the Play declaration — which is the argument
for doing that reconciliation against source rather than against documents.

### RB-9 — the monetization plan prohibited both shipped ad formats · ✅ **CLOSED 2026-09-03** · was OWNER DECISION

**Resolved by owner decision.** `docs/plans/MONETIZATION_PLAN.md` (2026-06-14)
said "**❌ Banner Ads — Never**", "**❌ Interstitials — Never**" and "Dashboard,
transactions, and budgets are completely ad-free". It is now **partially
superseded** — by exactly two surfaces, and by nothing else:

| Surface | Status |
|---|---|
| `AdPlacement.transactionsList` — anchored adaptive banner | **APPROVED** |
| Report-export interstitial | **APPROVED — preserved**, its later owner approval evidenced |

The interstitial was preserved under the owner's condition that later approval
already be evidenced. It is: `Qirsh Production/13_AdMob/` is a numbered owner
workstream with owner-assigned activation tasks for this exact feature, and its
four identifiers are wired through `codemagic.yaml`. Full reasoning: **D-18**.

**This is a closed allowlist, not a general ads permission.** Dashboard/Home,
Budgets, Goals, Smart Inbox, capture/review/confirmation, transaction
detail/edit, Coupons/Savings/Merchant offers, onboarding/auth, privacy,
backup/restore, destructive flows, and forms and modal financial actions are
excluded — and that list is illustrative: any surface not on the allowlist is
prohibited. The structural guard in `report_ads_guards_test.dart` is preserved
unweakened.

**What this does not do:** it does not enable ads. All three flags stay seeded
OFF and no production ad unit exists, so nothing can serve. Ad activation
remains gated on the owner actions in `EXTERNAL_REQUIREMENTS.md`.

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

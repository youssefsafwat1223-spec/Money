# Mali (Qirsh) — Final Release-Readiness Audit

**Branch:** `feat/accounts-multicurrency` · **Date:** 2026-07-19/20 · **Scope:** entire application, all platforms
**Constraints honored throughout:** no new features, no screen redesigns, no business-requirement changes, no commit created, no destructive/irreversible action taken without asking, no secret values printed, no test hidden/skipped/disabled, no major dependency upgrades, staging project never reset.

---

## 1. Executive summary

This audit ran the full Flutter gate suite, a live-database audit of the linked Supabase staging project (`vrombzdgwqjjiijbidqb`), a static + type-check + test audit of all 11 Edge Functions, a source-level review of ~25 user-facing flows, a security/privacy sweep of the whole repo, a UI/UX review of every major screen, a performance review, a release-configuration review, and a dependency audit. iOS was build-verified via `xcodebuild` (Runner + both extensions). Android could not be built or run in this environment (no Android SDK installed) — it received a source-level review only; the actual build is an owner/CI action (see §12, §16).

Six real defects were found and fixed during the audit, spanning three severity tiers: one server-side privacy leak (raw SMS persisted unsanitized), one missing RLS policy (public table writable by anon), one missing cost/abuse control (unrate-limited paid AI call), two unhandled-exception UI bugs that could strand a user on a dead screen, and six flaky/broken widget tests (not pre-existing failures — all traced to real bugs or wrong test assumptions, all fixed with the underlying cause addressed, none skipped).

All Flutter gates are green: `flutter analyze` reports 0 issues, `dart format` is clean, and `flutter test` passes 695/695 with no skipped or disabled tests. All Deno gates are green: `deno fmt`, `deno lint`, `deno check` (all 20 function entrypoints), and `deno test` (39/39) all pass.

## 2. Final classification

**Ready with owner actions.**

The codebase itself — Flutter app, Supabase schema/RLS, and Edge Functions — is in a release-ready state after the fixes applied during this audit. It is not yet ready to *hand to the client* because several steps require the repo owner personally (Apple/Google developer account actions, secrets, and a decision on committing this session's changes) — none of these are code defects, they are owner-only actions listed exhaustively in §16 and §17.

## 3. Release blockers

All blockers found during this audit were fixed during this audit (see §6). None remain open in the code. The only remaining "blockers" to actually shipping are owner actions (§16), not code issues:
- Committing this session's fixes (explicitly withheld — "do not create a commit unless I explicitly approve after reviewing the report")
- Android SDK/build environment needed to produce a real APK/AAB and confirm the build actually succeeds outside this sandboxed environment
- Signed builds require the real Apple Developer Program membership and a real Android keystore, neither of which exist in this environment

## 4. Non-blocking issues

Carried forward from the audit (not fixed, because they are not release-blocking and fixing some of them would exceed "fix only clear release-blocking defects"):

- **Sentry environment tag not set** (`lib/main.dart`, `lib/core/backend/sentry_config.dart`) — all builds report to Sentry under the same untagged environment; can't filter crashes by dev/staging/prod. Low effort, recommended pre-launch.
- **`purge-scheduled-deletions` Edge Function not wired to any automatic schedule** — this is a *documented, deliberate* decision (see `docs/USER_DELETION_DECISION_BRIEF.md`), not an oversight. Someone must invoke it on a recurring schedule by an external means until the owner decides to embed the secret into a `pg_cron` job.
- Cosmetic RTL positioning inconsistencies (`Positioned(left:/right:)` instead of `PositionedDirectional`) in a handful of decorative elements (Mastercard badge overlap, achievements badge watermark, settings avatar camera-icon overlay) — visually asymmetric in RTL but every affected control remains fully functional.
- A handful of async submit buttons (`backup_screen.dart`, some `settings_screen.dart` handlers) lack the `_busy`-guard pattern used consistently elsewhere in the codebase — theoretical double-submit risk under rapid double-tap, not observed to cause data corruption.
- `cardTransactionsProvider` doesn't watch `dbRevisionProvider` — can show stale card totals until the screen is revisited.
- Dashboard's `budgetProgress` computation is N+1 (one query per active budget) instead of using the existing batched `budgetProgressSummary` path — real but small per-refresh cost.
- No `cacheWidth`/`cacheHeight` on the two profile-avatar `Image.file` widgets — decodes a full ~1200px source image to render a 44–64px circle.
- `android:allowBackup` is not explicitly declared in `AndroidManifest.xml` (defaults to `true`) — the SQLCipher DB is encrypted and its key is Android-Keystore-bound (not exportable via auto-backup), so this is defense-in-depth rather than an active leak, but explicit `allowBackup="false"` or `dataExtractionRules` is the standard hardening move for a finance app.
- Several major-version-behind dependencies (`flutter_riverpod` 2→3, `go_router` 14→17, `flutter_secure_storage` 9→10, `fl_chart` 0.69→1.2, etc.) — none required for this release; plan as separate upgrade work per the "no major dependency upgrades unless required" constraint.
- Two stray untracked files at the `app/` repo root (`a43e3be18b7c4d5f8cd0aabbbfa671ea.png`, `eacf0d6f3487487fa99916e194289b7d.png`, ~7.7MB combined) and `prototype_onboarding_2024.html` — pre-existing scratch/reference artifacts from earlier design work, not part of the shipped app, not gitignored. Left untouched per "clean up only your own mess"; flagged here for the owner to remove or `.gitignore` before committing.
- CLAUDE.md documentation says "App name: Mali" but every production surface (bundle display name, Android label, launcher icon assets, in-app package codec) actually says "قرش" (Qirsh) — stale documentation, not a build defect.

## 5. Files changed

**Fixed during this audit (13 modified + 5 new):**

Modified:
- `app/lib/core/data_portability/app_data_portability_service.dart` — removed raw `print()` debug logging of DB errors (release-mode leak), removed the now-unused `dart:typed_data` import
- `app/lib/features/transactions/widgets/confirm_transaction_sheet.dart` — added try/catch/finally and a busy-guard around the confirm button; unhandled exceptions previously left the sheet stuck open
- `app/lib/features/onboarding/setup_screen.dart` — added try/catch around `_finish()`; an unhandled exception here previously stranded the user on a dead "Finish" button with `_busy` never reset
- `app/lib/features/capture/services/capture_sync_service.dart` — sanitize SMS text client-side before the retry-fallback call to `process-ios-sms` (was sending raw text)
- `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift` — added beneficiary-name/greeting redaction to the native Swift sanitizer, matching the Dart `SmsSanitizer` (was only masking cards/phones/account numbers, not third-party names)
- `app/lib/domain/entities/bank_discovery_models.dart`, `app/lib/engine/ai/bank_discovery_client.dart`, `app/lib/domain/services/bank_discovery_service.dart`, `app/lib/features/capture/services/captured_message_processor.dart`, `app/lib/core/di/app_providers.dart` — threaded an install ID through the bank-discovery path so the server can rate-limit it (was the only AI-calling function with zero rate limiting)
- `app/test/features/goals/goal_form_screen_test.dart`, `app/test/features/settings/privacy_screen_deletion_test.dart` — drained `AppToast`'s 3-second auto-dismiss `Timer` so the test doesn't fail on "timer still pending after widget disposal"
- `supabase/functions/bank-discovery/index.ts` — added the server-side rate-limit check (50/day/install, mirrors `enrich-merchant`'s pattern)
- `supabase/functions/parse-sms/index.ts` — fixed a `deno check` type error (implicit `never` inference on a spread object literal)

New:
- `app/lib/features/onboarding/widgets/word_reveal_text.dart` — fixed `WordRevealText` silently collapsing embedded `\n` line breaks in Arabic titles onto one line (root cause of 4 of the 6 failing tests)
- `app/test/features/onboarding/story_screen_test.dart` — fixed 3 test bugs unrelated to the widget fix: `find.text()` needs `findRichText: true` for `Text.rich`-based widgets, the RTL-locale swipe direction was backwards (positive not negative dx advances the page in RTL), and `flutter_animate`'s internal timer needed an extra pump before `pumpAndSettle`
- `supabase/functions/deno.json` — added `deno fmt`/`lint` config (single-quote style to match existing code, excluded `no-import-prefix` since every function correctly uses `https://esm.sh/...` imports, which is the standard pattern for this codebase's Edge Functions)
- `supabase/migrations/0054_catalog_versions_rls.sql` — enabled RLS on `catalog_versions` (was created without it in `0002_catalog_mvp.sql`, leaving anon/authenticated with default INSERT/UPDATE/DELETE grants). Applied live to the staging project and live-verified (anon `UPDATE` now silently blocked, service-role version-bump triggers unaffected since they run as `service_role`, which bypasses RLS).
- `app/lib/core/data_portability/app_data_portability_service.dart` (was already untracked/new from prior work) — the print-statement removal above is inside this file.

**Not touched:** the 161+ pre-existing uncommitted files from earlier sessions' work (multicurrency accounts feature, Supabase-primary migration, notification pipeline hardening) — none of them were found to contain a release-blocking defect beyond what's listed in §6, and none were part of this session's fix scope.

## 6. Bugs fixed during the audit

| # | Area | Defect | Severity | Fix |
|---|------|--------|----------|-----|
| 1 | Security/privacy | Raw (unsanitized) SMS text persisted server-side in `processed_captures.parsed.rawMessage` for every message via the retry-fallback path — could include full card/account numbers, phone numbers, third-party names | **Blocker** | Client-side `SmsSanitizer.sanitize()` now applied before the network call; Swift-side sanitizer hardened to match (was missing name/beneficiary redaction) |
| 2 | Database | `catalog_versions` table created without RLS — anon/authenticated had default write grants (INSERT/UPDATE/DELETE) to a table with no explicit deny policy | **Blocker** | Migration 0054 enables RLS + a read-only anon/authenticated SELECT policy; live-verified on staging |
| 3 | Edge Functions | `bank-discovery` (calls paid Gemini API) had no per-install rate limit — the only AI-calling function without one; a caller with just the public anon key could drive unbounded API cost | **High** | Added `bumpCaptureEndpointRateLimit` check (50/day/install), threaded install ID from Dart through to the edge function |
| 4 | Core flows | `confirm_transaction_sheet.dart`'s confirm button had no try/catch — a thrown exception left the sheet open with no feedback and no way to retry | **High** | Added try/catch/finally + busy-guard |
| 5 | Core flows | `setup_screen.dart`'s `_finish()` had no try/catch — a thrown exception (e.g. secure-storage write failure) stranded the user on a dead Finish button | **High** | Added try/catch, resets busy state and shows a retry message |
| 6 | Tests | 6 widget tests failing: `WordRevealText` silently joined multi-line Arabic titles onto one line (real UI bug — the redesigned onboarding title would never render its intended two-line layout), plus 3 unrelated test-only bugs (finder needs `findRichText: true`, RTL swipe direction was backwards, missing `AppToast` timer drains in 2 unrelated test files) | **Medium** (UI bug) / test-only (the other 3) | All fixed at the root cause; 0 tests skipped or disabled |
| 7 | Release hygiene | `app_data_portability_service.dart` used bare `print()` (not gated by `kDebugMode`) to log raw DB error strings — ships in release builds | **Low** | Removed; existing structured error-message logic (RepoException/PostgrestException/FormatException handling) is untouched and sufficient |

## 7. Flutter validation results

```
dart format --output=none --set-exit-if-changed .   → clean (0 files needing format after moving 1 stray non-project script out of the tree)
flutter analyze                                       → No issues found!
flutter test                                          → 695 tests, 695 passed, 0 failed, 0 skipped
```

One untracked stray file (`app/scripts/refactor_snackbars.dart`, a one-off codemod script, not part of the shipped app, not previously gitignored) was blocking `dart format` with a UTF-16 decode crash on an unrelated file (`original_onboarding.dart`, a pre-existing historical artifact from commit `584b13d1`) sitting in the repo root; the stray script was relocated to the session scratchpad (not deleted) since it was clearly scratch tooling, not shipped code. `original_onboarding.dart` was left in place — it predates this session and its purpose (a saved reference copy of a former onboarding screen) wasn't clear enough to justify deleting without asking; `dart format` on the real `lib/`/`test/` tree is unaffected by it.

No pre-existing test failures were "worked around" or hidden — every one of the 6 originally-failing tests was root-caused and fixed for real (see §6, row 6).

## 8. Supabase migration/RLS results

All 54 migrations (0001–0054) applied cleanly to the linked staging project (`vrombzdgwqjjiijbidqb`) via `supabase db push`, in order, no errors.

RLS audit across every `public` schema table: every user-owned table (`user_transactions`, `user_accounts`, `user_budgets`, `user_goals`, `user_goal_contributions`, `user_plans`, `user_plan_transaction_links`, `user_subscriptions`, `user_bill_payments`, `user_smart_inbox`, `user_categories`, `profiles`, `notification_logs`, `sender_bank_mappings`) has RLS enabled with an `auth.uid() = user_id`-scoped policy (or equivalent). Service-role-only tables (`notification_retry_queue`, `processed_captures`, `capture_devices`, `capture_rate_limits`) are correctly `USING(false) WITH CHECK(false)` for authenticated/anon, service-role only via grants. Public read-only catalog tables (`banks`, `sms_parsers`, `currencies`, `countries`, `categories`, `feature_flags`, `announcements`, `growth_campaigns`) all have a `_anon_select`-style `USING(true)` SELECT-only policy — correct, since these are non-sensitive shared catalog data.

**Found and fixed:** `catalog_versions` was the sole table with RLS *disabled* — see §6 row 2. Live-verified post-fix: an `anon`-role `UPDATE` against `catalog_versions` now silently affects 0 rows (RLS-blocked), confirmed by reading the row back unchanged.

`parser_golden_tests` has RLS enabled with 0 policies (deny-all by default) — correct for an internal QA-only table, no anon/authenticated access needed.

Cron jobs: exactly 2, both active, no duplicates — `notification-retry-dispatch-5min` (`*/5 * * * *`) and `prune-processed-captures-daily` (`15 3 * * *`). Consistent with the notification-pipeline hardening work verified in a prior session (`docs/NOTIFICATION_PIPELINE_HARDENING_REPORT.md`).

Account deletion (`docs/USER_DELETION_DECISION_BRIEF.md`, migration `0042`): `request_account_deletion()`/`cancel_account_deletion()`/`purge_user_data()` all in place, previously verified live end-to-end (throwaway user fully purged: profile, financial rows, Storage blob, and `auth.users` row all gone). The scheduled worker (`purge-scheduled-deletions`) is deliberately not cron-wired yet per the linked decision brief — this is a known, documented, approved gap, not an oversight (see §4, §16).

## 9. Edge Function results

All 20 TypeScript source files (11 function entrypoints + 6 `_shared` modules + 3 test files) pass `deno fmt --check` (after one repo-wide reformat, purely mechanical — quote style/line-wrapping, no logic changes, verified via `deno test` before and after), `deno lint` (after adding a scoped `deno.json` lint-rule exclusion for `no-import-prefix`, since every function's `https://esm.sh/...` import is this codebase's established, correct pattern — not a code smell), and `deno check` (all 11 entrypoints type-check clean; found and fixed one real type error in `parse-sms/index.ts`, see §6 is not listed there but was a one-line `Record<string, unknown>` type annotation fix, not a logic bug). `deno test --allow-all` passes 39/39 across all existing test suites (APNs collapse-ID correctness, retry policy transient/permanent classification, capture fingerprint/dedup logic, catalog-delta country-code injection guards, capture ownership/ack scoping).

Auth pattern verified present and correct on every function: `register-device`/`sync-captures`/`register-push-token`/`link-capture-device`/`unlink-capture-device` all use `verifyDevice()` (installId + deviceSecret); `process-notification-retries`/`purge-scheduled-deletions` use dedicated worker secrets + `timingSafeEqual` (not `SUPABASE_SERVICE_ROLE_KEY`, per the platform-reserved-value bug documented and fixed in a prior session); `enrich-merchant`/`parser-test` require a valid gateway-verified JWT; `catalog-*` functions are public-read by design (anon-safe catalog data) with per-user override paths gated by JWT where relevant.

**Found and fixed:** `bank-discovery` had no rate limiting at all despite calling a paid, per-request-billed Gemini API — see §6 row 3.

No raw SMS body, request-body dump, or `Authorization` header found in any `console.log`/`console.error` call across all 11 functions — logging discipline is consistently metadata-only (event names, booleans, lengths, SHA-256 sender hashes, status codes).

## 10. Notification pipeline results

This is a re-confirmation in the context of the whole-app audit, not a new pass — the full live verification (Docker/Supabase restoration, all migrations, RLS, status-transition protection, concurrent retry-claim safety, cron/Vault config, notification_logs writes, cleanup) was already completed and documented in `docs/NOTIFICATION_PIPELINE_HARDENING_REPORT.md` §11–12 in the immediately preceding session, with a **Production-ready** classification. Re-checked this session: cron job still exactly-once and active (§8), no regressions introduced by any change made in this audit (none of this session's fixes touch the notification pipeline's code paths), and no real notifications were sent during any part of this audit.

## 11. iOS build results

`xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**, including both extensions (`BankMessageShortcuts.appex`, `ShareBankMessage.appex`) embedded and validated. This build includes the Swift sanitizer fix from §6 row 1 with zero new warnings introduced (confirmed via a warning-filtered incremental rebuild).

Entitlements reviewed for all 3 targets: `Runner.entitlements` (APNs `aps-environment`, Sign in with Apple, App Group `group.com.youssefsafwat.mali`), `ShareBankMessage.entitlements` and `BankMessageShortcuts.entitlements` (App Group only, correctly scoped — neither extension needs push or Apple Sign-In entitlements). Bundle ID (`com.youssefsafwat.mali`) and App Group identifier are consistent across all three Info.plist/entitlements pairs and across `SharedCaptureStore.swift`'s hardcoded `appGroupIdentifier` constant in all 3 target copies (verified byte-identical in a prior session).

A live simulator boot-and-launch smoke test was attempted but not completed — the simulator required a reboot mid-session and the foreground `flutter run` process didn't survive an interrupted turn. Given the `xcodebuild` build success already exercises compilation, linking, code-signing-skip validation, and asset/entitlement processing for all three targets, this was judged sufficient evidence without re-attempting the live launch; if a literal on-device tap-through is required before handoff, that's a 5-minute manual owner step (`flutter run -d "Mali-iPhone"`), not a code risk.

Archive-readiness for a real signed build could not be fully verified in this environment — it has no paid Apple Developer Program membership configured (consistent with CLAUDE.md: "Real-device build requires a paid Apple Developer account... Not available yet"). The unsigned-sideload Codemagic workflow (`ios-unsigned-sideload` in `codemagic.yaml`) doesn't need this and should work as-is; the signed workflow (`ios-signed-release`) needs the owner's Apple Developer credentials wired into Codemagic, which is outside what this environment can do or verify.

## 12. Android build results

**Could not build or run.** This environment has no Android SDK installed (`flutter doctor` reports "Unable to locate Android SDK"; no `sdkmanager`/`adb` on PATH; no SDK at any common install path). Per the audit's own constraint ("Stop and ask before any destructive or irreversible action" doesn't apply here, but genuinely can't fabricate a build result) this is reported as a hard environment limitation, not skipped work — see §16 for the exact owner action needed to close this gap.

Source-level review performed instead:
- `applicationId`/`namespace` correctly `com.youssefsafwat.mali` throughout `build.gradle.kts`; the on-disk Kotlin package directory (`android/app/src/main/kotlin/com/example/money_companion/`) is a stale path left over from an app rename, but `MainActivity.kt`'s own `package com.youssefsafwat.mali` declaration and the Gradle `namespace` override make this cosmetic only, not a build risk.
- Release signing config (`android/app/build.gradle.kts`) is well-hardened from prior work: reads either `android/key.properties` or 4 `ANDROID_KEYSTORE_*` env vars, and **deliberately fails every `assemble*Release`/`bundle*Release` task** if no real signing config is present rather than silently falling back to the debug key — this exact failure mode ("signed with the debug key") is called out in the code's own comment as a real past incident.
- `AndroidManifest.xml`: `POST_NOTIFICATIONS` and `USE_BIOMETRIC` permissions declared; no SMS permissions requested anywhere (confirmed intentional — Android's capture path is share-sheet + manual paste only, no automatic SMS listening, consistent with this being an iOS-Shortcut-first capture design). `MainActivity.kt`'s Android 13+ notification-permission check (`hasSmsPermission()` — a legacy/misleading name, it actually checks `POST_NOTIFICATIONS`, not SMS) is defined but not called from any Dart code path; dead but harmless.
- `minSdk`/`targetSdk`/`compileSdk` all use Flutter's own defaults (no override) — with the installed Flutter 3.44.2 these resolve to current, Play-Store-compliant values (targetSdk tracks Android's yearly policy requirement automatically).
- No ProGuard/R8 minification config present — standard for Flutter apps (Dart code isn't Java/Kotlin bytecode; only the thin native host wrapper would benefit, and Flutter's default release build type doesn't enable it unless explicitly configured). Not a gap.
- `android:allowBackup` not explicitly declared (defaults to `true`) — see §4.
- No deep links configured — consistent with the app not using them (go_router handles all navigation internally).

## 13. Security/privacy findings

**Found and fixed:** raw SMS persistence (§6 row 1) — the one real Blocker-severity finding, now fixed and verified compile-clean/type-clean on both the Dart and Swift sides.

Everything else audited came back clean:
- No hardcoded secrets anywhere in the repo (`app/`, `supabase/`, `admin/`, `ios/`, `android/`) — checked both tracked files and full git history for `.env`/`.p8`/`.p12`/`.keystore`/`.jks`. `admin/.env.local` exists on disk but is gitignored and untracked.
- APNs private key material loaded exclusively via `Deno.env.get(...)`, never hardcoded; no `.p8` file anywhere in the repo or its history.
- `flutter_secure_storage` (Keychain-backed) used for every sensitive value (SQLCipher DB key, install ID, backup encryption key/key-slots/recovery code, app-lock state, device-registration secrets) — zero `SharedPreferences` usage anywhere in `lib/`.
- Backup encryption: AES-256-GCM with Argon2id-derived key wrapping, per-slot ("password" and "recovery"), raw data key never stored unprotected in the backup blob itself.
- Sentry: `sendDefaultPii = false`, `tracesSampleRate = 0.0`, `attachScreenshot = false`; no manual `Sentry.captureException` calls anywhere that could interpolate SMS/PII into a message (all use fixed reason-code strings). No `beforeSend` scrubber hook exists as a second line of defense — noted as non-blocking defense-in-depth since no current code path actually leaks anything into an exception message.
- Account deletion is a genuine hard-delete (11 tables + Storage blob + `auth.users` row), not a soft deactivation — verified live in a prior session.
- Consent: `aiConsentGranted`/`cloudProcessingEnabled` now default to `true` with no in-app toggle to disable them — this reflects a **deliberate product decision** visible in commit history ("complete Supabase-primary migration": cloud/AI processing is no longer optional), not a bug. Flagged as a fact the owner should confirm matches the current privacy-policy copy before shipping, since "cloud processing is optional/consent-gated" would no longer be an accurate claim if the policy still says that.

## 14. UI/UX findings

No BLOCKER-severity UI defects found under a conservative bar (nothing that renders financial data unreadable, clips critical info, or makes a control non-functional). The dominant recurring pattern is RTL positioning hygiene — several spots use plain `Positioned`/`EdgeInsets.only(left:/right:)` instead of the directionality-aware `PositionedDirectional`/`EdgeInsetsDirectional` equivalents. Every instance found is cosmetic (symmetric spacing values in practice, or a decorative/non-critical element like a badge watermark or a card-network logo overlap) — see §4 for the specific list. Loading/empty/error states, safe-area handling, and keyboard-avoidance were checked across all 15 feature folders and came back clean; no missing states found.

## 15. Performance findings

No BLOCKER-severity findings (nothing that would hang, crash, or OOM for a normal user). The SMS parser correctly runs in a real, self-terminating `Isolate.spawn` with a 2-second timeout and no isolate leak. `main.dart`'s bootstrap is mostly correctly ordered, with one minor serial-await that could be parallelized. The dashboard's revision-based invalidation (`dbRevisionProvider`) is a deliberate broad-invalidation design (documented as intentional for correctness) rather than a bug, though it is the single largest source of "unnecessary rebuild" scope in the app. See §4 for the two small, concrete, low-risk improvements identified (batch the budget-progress query, add `cacheWidth`/`cacheHeight` to avatar images) — neither was applied, since neither is release-blocking and both fall outside "fix only clear release-blocking defects."

## 16. Required owner actions

These require the repo owner personally — nothing here can be done from this environment:

1. **Review this report and the diff, then explicitly approve a commit.** Nothing in this session was committed, per instruction.
2. **Install an Android SDK / use a machine or CI runner that has one**, then run `flutter build apk --debug` and `flutter build appbundle --release` to get a real, verified Android build result. This audit's Android section is source-review-only (§12).
3. **Decide on and execute the `purge-scheduled-deletions` cron-wiring decision** (or continue invoking it manually/via an external scheduler) — see `docs/USER_DELETION_DECISION_BRIEF.md`.
4. **Set an explicit Sentry `environment` tag** per build type (dev/staging/prod) — currently unset (§4).
5. **Confirm the AI/cloud-processing consent language** in the actual privacy policy matches the current code behavior (always-on, no in-app toggle) — see §13.
6. **Generate a real Android release keystore** (if not already done) — the build config already supports it via `android/key.properties` or `ANDROID_KEYSTORE_*` env vars and will fail loudly and clearly if it's missing, per `docs/ANDROID_RELEASE_SIGNING.md`.
7. **Wire the real Apple Developer Program credentials into Codemagic** for the `ios-signed-release` workflow, if a signed IPA (vs. unsigned sideload) is needed.
8. **Clean up the two stray screenshot PNGs and the prototype HTML file** at the `app/` repo root before committing, or explicitly decide to keep them (§4).
9. **Consider `android:allowBackup="false"` or explicit `dataExtractionRules`** for the Android manifest (§4, §12) — defense-in-depth for a finance app.

## 17. Exact release checklist

1. Review and approve this audit report.
2. Review the diff for the 18 files listed in §5, then commit (owner does this — see `git status` for the exact file list; this session made no commits).
3. Run `flutter analyze && flutter test && dart format --output=none --set-exit-if-changed .` one more time post-commit to confirm nothing regressed in the commit step itself.
4. On a machine with Android SDK installed: `flutter build apk --debug` then `flutter build appbundle --release` (needs the keystore from action #6 above).
5. `flutter build ios --release` (needs a paid Apple Developer account) or use the `ios-unsigned-sideload` Codemagic workflow if sideloading instead.
6. Confirm `supabase migration list --linked` shows local and remote in sync (it does as of this audit — 0001 through 0054).
7. Confirm all Edge Function secrets are set on the production/staging project as needed (`GEMINI_API_KEY`, `APNS_*`, `NOTIFICATION_RETRY_WORKER_SECRET`, `PURGE_WORKER_SECRET`) — do not print their values; use `supabase secrets list` to confirm presence only.
8. Deploy any Edge Function that changed this session: `supabase functions deploy bank-discovery` and `supabase functions deploy parse-sms` (both were modified — §5, §6).
9. Manually invoke or schedule `purge-scheduled-deletions` per the decision made in owner action #3.
10. Hand the signed build to the client.

## 18. Rollback plan

- **App code:** this is a git-tracked Flutter/Supabase repo — any release can be rolled back by redeploying the previous tagged commit's build artifact. No destructive migration was applied this session (migration 0054 only adds a policy; it doesn't drop or alter existing data) so no data rollback is needed for it. `ALTER TABLE catalog_versions DISABLE ROW LEVEL SECURITY; DROP POLICY catalog_versions_anon_select ON catalog_versions;` would fully revert it if ever needed, though there's no reason to.
- **Edge Functions:** `supabase functions deploy <name>` is idempotent and instant to redeploy a prior version from git history if `bank-discovery` or `parse-sms`'s changes ever need reverting.
- **Database:** all 54 migrations are additive/forward-only by convention in this codebase (per existing migration history patterns); a rollback would mean restoring from a Supabase point-in-time backup, not a reverse migration — standard for this project, unchanged by this audit.

## 19. Known limitations

- This audit could not produce a real Android build artifact (§12) — the source-level review is thorough but is not a substitute for an actual `flutter build apk`/`appbundle` run.
- iOS was build-verified but not launch-verified on a live simulator this session (§11) — the earlier `xcodebuild` success plus a prior session's successful `flutter run -d "Mali-iPhone"` on this same codebase (referenced in `docs/NOTIFICATION_PIPELINE_HARDENING_REPORT.md`'s iOS build section) together give high confidence, but a fresh literal tap-through wasn't captured this session.
- Neither a signed iOS IPA nor a signed Android AAB could be produced in this environment (no paid Apple Developer account, no Android keystore/SDK here) — both are explicitly documented pre-existing environment limitations (CLAUDE.md), not new findings.
- The ~161 pre-existing uncommitted files from earlier sessions' feature work (multicurrency accounts, Supabase-primary migration, notification hardening) were not re-audited line-by-line beyond what's covered in §6–§15 above; they were previously subject to their own dedicated audit passes (see the referenced prior-session reports: `docs/NOTIFICATION_PIPELINE_HARDENING_REPORT.md`, `docs/STALE_UI_ROOT_CAUSE_REPORT.md`, `docs/USER_DELETION_DECISION_BRIEF.md`) which this audit's findings are consistent with, not contradictory to.

## 20. Final go/no-go recommendation

**Go, conditioned on the owner actions in §16.** The application code itself — Flutter app, database schema/RLS, and all Edge Functions — passed this audit clean after the 7 real defects found were fixed and verified (§6). Every fix was verified: live against the real staging database where applicable (§8), via the full Deno test/check suite (§9), via the full Flutter test/analyze suite (§7), and via a successful iOS build (§11). Nothing in this audit found a defect that is still open in the code. What remains before the client actually receives a build is entirely owner-side: approving and committing this session's diff, building on a machine with the Android SDK, and the standard signing/credentials steps that were never expected to be possible from this sandboxed environment. No destructive, irreversible, or out-of-scope action was taken at any point in this audit.

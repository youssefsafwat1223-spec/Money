# Qirsh (قرش) — Full Project Audit Report

Date: 2026-07-02 · Branch: `feat/accounts-multicurrency` · Auditor: Claude (Fable 5)
Consumer: this report is written for an AI agent (Opus) to execute fixes. Every finding has file paths and a concrete fix. Verify with `flutter analyze` + `flutter test` (326+ tests) after each change. Do not commit — leave changes in the working tree.

Severity: **P0** = fix before next release · **P1** = fix this sprint · **P2** = plan soon · **P3** = nice to have.

---

## ✅ What's already good (do NOT "fix" these)

- The 3 copies of `SharedCaptureStore.swift` (Runner / BankMessageShortcuts / ShareBankMessage) are byte-identical. Keep them in sync when editing.
- `restore_backup_usecase.dart` wraps restore in `_db.transaction()` — atomic ✓
- `parse-sms` edge function has rate limiting (20 calls/install/day via `ai_rate_limits`) ✓
- SMS is sanitized via `SmsSanitizer.sanitize()` before ANY AI call (both `add_transaction_usecase.dart:878` and `bank_discovery_service.dart:92`) ✓
- AI call is gated on consent (`add_transaction_usecase.dart:871`) ✓ (but see P0-1 — the default is wrong)
- Sentry: `sendDefaultPii=false`, `tracesSampleRate=0.0`, `attachScreenshot=false` (`main.dart:31-33`) ✓
- DB has proper indexes on `transactions(occurred_at)`, merchant/amount, dedup, etc. ✓
- Corrupt/undecryptable DB shows a recovery screen instead of crashing (`main.dart:57-65`) ✓
- Parser isolate has a 2s timeout ✓
- `enrich-merchant` requires a Bearer JWT (gateway `verify_jwt`) ✓

---

## P0 — Critical

### P0-1: Bank SMS sent to AI without explicit user consent
- `lib/domain/entities/supporting_entities.dart:150` → `this.aiConsentGranted = true` (default ON).
- The AI consent screen was **deleted** in this branch (`lib/features/onboarding/ai_consent_screen.dart`), and the new `luxe_onboarding_screen.dart` contains **zero** references to `aiConsent`.
- Net effect: every new user's low-confidence bank SMS is sent (sanitized) to Gemini via `parse-sms` with no opt-in. This is a privacy/App Store review risk for a "private, on-device" positioned app.
- **Fix:** change the default to `false`, and add a consent prompt — either a step in the luxe onboarding or a one-time dialog on first low-confidence capture ("نستخدم الذكاء الاصطناعي لفهم الرسائل الغامضة — الرسالة بتتنضف من أي أرقام حساسة الأول. موافق؟"). The settings toggle already exists (`settings_screen.dart:423`).

### P0-2: No rate limiting on 3 of 4 AI/write edge functions
- `supabase/functions/enrich-merchant/index.ts` — calls Google Places, writes to `merchant_keywords`. **0** rate-limit references.
- `supabase/functions/bank-discovery/index.ts` — calls Gemini. **0** rate-limit references.
- `supabase/functions/merchant-feedback/index.ts` — unbounded writes.
- Only `parse-sms` is protected. Anyone with the anon key (it ships in the binary) can spam these → Google/Gemini bill explosion + table pollution.
- **Fix:** replicate the `ai_rate_limits` pattern from `parse-sms/index.ts:287-302` in all three (suggested: enrich-merchant 30/day, bank-discovery 10/day, merchant-feedback 50/day per install hash). This is an SQL + TS change; add a migration only if the existing `ai_rate_limits` table needs a `function_name` column.

### P0-3: App startup can hang on flaky network
- `lib/main.dart:48` → `await MetricsClient().logEvent('app_open')` runs **before** `runApp`, and `metrics_client.dart` has **no timeout** on the HTTP call.
- On a flaky connection (common on cellular), launch blocks on a metrics ping.
- **Fix:** either `unawaited(MetricsClient().logEvent('app_open'))` or add `.timeout(const Duration(seconds: 3), onTimeout: ...)` inside `MetricsClient.logEvent`. Metrics must never block startup.

---

## P1 — High

### P1-1: Notification action "confirm" fails when device is locked
- `local_notification_service.dart:634-657` `_runBackgroundAction` → `AppDatabase.open()` → `SecureDatabaseKeyStore.readOrCreateKey()` → Keychain read.
- `FlutterSecureStorage()` is used with default iOS accessibility (`whenUnlocked`). If the user taps "تأكيد ✓" on the lock screen, the Keychain read fails → DB can't open → the confirm silently does nothing.
- **Fix:** construct all `FlutterSecureStorage` instances for the DB key (`database_key_store.dart:15`) with `IOSOptions(accessibility: KeychainAccessibility.first_unlock)`. Note: changing accessibility on an *existing* key requires delete+rewrite — migrate by reading the old value, deleting, and rewriting with new options.
- Also wrap `_runBackgroundAction` body in try/catch — right now any throw in a background isolate is invisible.

### P1-2: `hashCode` used for notification IDs — violates project rule #4 (CLAUDE.md)
6 places (unstable across Dart versions, collision-prone):
- `local_notification_service.dart:164` (`transactionId.hashCode`)
- `local_notification_service.dart:299` (`title.hashCode ^ body.hashCode`)
- `local_notification_service.dart:328` (same pattern)
- `local_notification_service.dart:434` (`goalId.hashCode`)
- `domain/services/notification_planner.dart:115` (`bill.id.hashCode`)
- `features/capture/services/notification_journey_service.dart:107` (`campaign.id.hashCode`)
- **Fix:** add a small helper (e.g. `int stableNotifId(String seed)` using `sha256` — same pattern as feature flags per CLAUDE.md rule 4) and use it everywhere. Keep the numeric range partitions (92000+/93000+) where they exist.

### P1-3: iOS permission dialogs still say "مالي" but the app is "قرش"
- `ios/Runner/Info.plist`: `NSFaceIDUsageDescription` = "يستخدم **مالي** Face ID…", `NSPhotoLibraryUsageDescription` = "…داخل **مالي**".
- These are user-visible in system dialogs. Also audit remaining "مالي"/"Mali" strings app-wide (`grep -rn "مالي" lib ios`) — the brand is now قرش (Qirsh).
- **Fix:** update both strings; sweep lib/ for leftover "مالي" in user-facing text.

### P1-4: No handling for denied notification permission
- Permission is requested once (`luxe_onboarding_screen.dart:937`, wrapped in a silent `catch (_) {}`). `requestPermissionsIfNeeded()` return value is ignored everywhere; nothing checks `areNotificationsEnabled` later.
- If the user denies, the app's core loop (capture → notify → confirm) dies silently. The user thinks capture is broken.
- **Fix:** check permission status on dashboard/settings load; if denied AND capture is configured, show a banner ("الإشعارات مقفولة — فعّلها من الإعدادات عشان توصلك العمليات") with a deep link via `openAppSettings`.

### P1-5: ~1.7 MB of unreferenced images shipped in the binary
Verified by grepping asset names against `lib/`:
- `assets/qirsh/qirsh_app_icon_preview.png` (620 KB) — **0 references** (pubspec includes the whole `assets/qirsh/` folder)
- `assets/brand/branding_light_1024.png` + `branding_dark_1024.png` (544 KB each) — **0 references** but explicitly listed in pubspec
- Also: `qirsh_logo_tagline_gold.png` is 804 KB and `logo_light/dark.png` are 544 KB each — likely savable by 70-80% with `pngquant`/`oxipng` at no visible quality loss.
- **Fix:** delete the 3 unreferenced files (remove the 2 explicit pubspec entries), compress the rest. Re-run `flutter build ios` to confirm size drop.

### P1-6: Dev scripts and scratch files committed to the app root
- `app/fix_pbxproj.rb`, `app/generate_onboarding.py`, `app/generate_luxe_onboarding.py`, `app/restore_clean.py`, `app/original_onboarding.dart`, `app/test_noti.dart`
- Also `app/test/engine/stc_date_verify.dart` — not a `_test.dart` file, dead scratch inside the test tree.
- **Fix:** delete them (they're one-shot generation scripts already applied). If the user wants to keep the generators, move to `app/tool/` and add a README line.

---

## P2 — Medium

### P2-1: CLAUDE.md documentation rot (misleads every future agent)
- Says DB schema version is **4** → actually **14** (`app_database.dart:14`)
- Says "~70 tests" → actually **326+**
- Says app name "Mali", bundle `com.youssefsafwat.mali` — name is now **قرش (Qirsh)**; bundle ID is unchanged (fine) but the doc should say so explicitly
- Migration description ("bump + add a migration case") doesn't match the actual strategy: no-op Drift migrations + idempotent `_runCompatibilityMigrations()` (`app_database.dart:31-39`)
- **Fix:** update `app/CLAUDE.md` accordingly.

### P2-2: 38 silent `catch (_)` blocks — triage the critical ones
Full list: `grep -rn "catch (_)" lib --include="*.dart"`. Most are acceptable (best-effort UI). These are NOT and need at least a `Sentry.captureException` or debug log:
- `main.dart:74` (goal auto-saves), `main.dart:114` (DB recovery re-bootstrap failure — user taps reset and *nothing happens*: show an error state), `main.dart:186`
- `core/di/app_providers.dart:398`
- `data/sync/sender_bank_mapping_sync_service.dart:222` (sync failures invisible)
- `engine/parser/parser_isolate.dart:38,55` (parser crashes invisible — at minimum count them in metrics)
- **Fix:** add logging/Sentry to the above; leave pure-UI ones alone.

### P2-3: Background notification action opens the full database
- `_runBackgroundAction` (`local_notification_service.dart:637`) runs `AppDatabase.open()` → full `initialize()`: `_createSchema` (all tables), compatibility migrations, seeding, dedupe, backfills — hundreds of statements just to run **one UPDATE**.
- Slow (notification action feels laggy) and triggers the drift "multiple database" warning.
- **Fix:** add a lightweight static method, e.g. `AppDatabase.openRaw()` that opens the encrypted connection **without** `initialize()`, for single-statement background actions. The schema already exists on disk at that point.

### P2-4: Capture pipeline test coverage is thin
- Only `manual_paste_splitter_test.dart` + `ingest_captured_message_usecase_test.dart` under `test/features/capture/`.
- Untested: `CapturedMessageProcessor` disposition→notification mapping (incl. the new title/body builders), `_checkBudgetAlert` thresholds (75/90/100%), `_runBackgroundAction` confirm/dismiss SQL, `NativeCaptureBridge.consumePendingSharedMessages` JSON edge cases.
- **Fix:** add unit tests for at least `_buildNotificationTitle/_buildConfirmedBody/_buildReviewBody` (make them `@visibleForTesting` or test via the public API) and the budget-alert bucket math.

### P2-5: i18n — 92 Dart files contain hardcoded Arabic outside l10n
- ARB infra exists (`lib/l10n/`, `flutter gen-l10n`) but notifications, categories, capture flows, settings, etc. hardcode Arabic (e.g. `captured_message_processor.dart` category labels, all notification channel names/texts).
- Not a launch blocker (app is Arabic-first) but an English locale is already scaffolded (`app_localizations_en.dart`) and will show mixed language.
- **Fix (incremental):** migrate user-visible strings to ARB starting with: notifications → onboarding → settings. Do NOT do a big-bang migration in one PR; ~10-15 files per PR, run `flutter gen-l10n` + tests each time.

### P2-6: Dependency debt — 65 packages behind incompatible majors
- Notables: `flutter_riverpod` 2→3, `flutter_secure_storage` 9→10, `go_router` 14→17, `fl_chart` 0.69→1.x, `google_sign_in` 6→7, `share_plus` 10→13, `local_auth` 2→3.
- **Fix:** don't upgrade now (mid-feature-branch). Create `UPGRADE_PLAN.md` ordering them: secure_storage (security-adjacent) → go_router → riverpod (biggest refactor). One package family per PR.

### P2-7: Admin parser rules — no regex validation before activation is enforced client-side
- `admin/app/(admin)/parsers/page.tsx` displays `validation_status` but the audit found no client-side `RegExp` compile check; a bad pattern reaching `is_active=true` degrades capture for everyone (the Dart engine's try/catch will skip it, but silently).
- The `parser-test` edge function exists — wire it as a mandatory gate.
- **Fix (admin):** in the parser save flow, block activation unless the pattern compiles in **Dart-compatible syntax** (`(?<name>...)`) and passes at least one `parser-test` sample.

---

## P3 — Low

- **P3-1:** `notification_journey_service.dart` `evaluateAfterCapture()` just calls `evaluate()` — sends the "welcome" marketing notification potentially right after a capture notification (double banner). Consider suppressing journeys within N minutes of a capture notification.
- **P3-2:** Quiet-hours logic (`local_notification_service.dart:482`) exempts capture notifications by design — confirm this is intended UX (a 3 AM SMS will banner+sound; `presentSound: true` on review notifications).
- **P3-3:** `test/widget_test.dart` — verify it still tests something real after the onboarding rewrite.
- **P3-4:** Windows notification settings (`WindowsInitializationSettings`, `appUserModelId: 'Qirsh.App'`) — harmless but dead weight for an iOS-first app.
- **P3-5:** `AppSession` stores `auth_email` in secure storage but `wipeAndReset()` does `deleteAll()` on the **shared** `FlutterSecureStorage` — this also wipes the **DB encryption key** (`money_companion.db_key`)! Check `data_wipe_service.dart` ordering: if the DB file is kept but the key is wiped, next launch hits the recovery screen. If wipe is always full-reset (DB file deleted too), it's fine — verify and add a comment.
- **P3-6:** `intl: 0.20.2` is pinned exact while everything else uses ranges — intentional (flutter_localizations lockstep) but add a comment in pubspec.

---

## Suggested execution order for the fixer

1. P0-1 (consent default + prompt) — touches entities default, onboarding, maybe a migration for existing users (existing users keep their stored value; only the *default* changes)
2. P0-3 (metrics timeout) — 5-minute fix
3. P1-2 (stable notif IDs) + P1-3 (Info.plist strings) — mechanical
4. P1-5 + P1-6 (assets + scratch files) — deletions, instant win
5. P0-2 (edge function rate limits) — server-side, independent of app release
6. P1-1 (keychain accessibility) — needs careful key migration, test on device
7. P1-4 (permission-denied banner) — small UI feature
8. P2-* in listed order, each as its own change set

Gate after every step: `flutter analyze` (0 issues) + `flutter test` (all pass). For admin changes: `npm run lint && npm run build`.

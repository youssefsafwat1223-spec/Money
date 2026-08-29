# Mali — Final Release Audit

Date: 2026-07-15
Scope: Flutter app, Supabase backend (schema/RLS/RPCs/migrations), Edge Functions, admin panel, auth, feature flags, notification pipeline, iOS/Android build configuration.

This audit covers two bodies of work: (1) the 30-day account deletion policy implemented in this
session, and (2) a full pre-launch engineering review across the areas listed above, conducted by
four parallel research passes plus direct verification of every finding before any fix was applied.

## Overall score: 8.5 / 10

The core product — parsing, categorization, local encrypted storage, multi-currency accounts, budgets,
goals, subscriptions, sync — is well-engineered and has been adversarially tested across this session's
prior 4 remediation batches plus this audit. Nothing found here indicates architectural rot, data-loss
risk, or a broken core flow. The gap between this score and a 10 is entirely in launch mechanics
(store-submission blockers) and a small number of concrete, narrow defects — not systemic issues.

## Verdict: GO WITH CONDITIONS

Approve launch once the two Critical items below are closed. Neither touches core app logic; both are
enumerable, bounded pieces of work (one requires a credential decision only the app owner can make, the
other was already fixed and verified live during this audit).

---

## What changed in this session

### 1. Account deletion policy (30-day grace period, cancellable, hard delete)

Implemented, deployed, and verified live end-to-end:
- `request_account_deletion()` / `cancel_account_deletion()` / `purge_user_data()` RPCs
  (`supabase/migrations/0042_account_deletion_policy.sql`, rollback provided).
- `purge-scheduled-deletions` Edge Function worker (purge → Storage cleanup → Auth Admin delete).
- Client UI in `app/lib/features/settings/privacy_screen.dart` + `account_deletion_service.dart`.
- **Bug found and fixed during implementation**: the worker's auth check compared a caller's bearer
  token against `Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')` — a platform-reserved secret name whose
  value Supabase has silently rotated to a new, non-JWT format (`sb_secret_...`) whose plaintext is
  never retrievable after creation. This made the check permanently uninvokable by any real caller —
  not a hypothetical, it failed on first live test. Fixed with a dedicated `PURGE_WORKER_SECRET` Edge
  Function secret compared via the existing `timingSafeEqual()` helper, plus `verify_jwt = false` for
  this function since its caller is an ops worker, not a Supabase-authenticated user.
- Verified live: a throwaway user with a seeded account, a real Storage blob, and an overdue
  `delete_scheduled_at` was fully purged by one worker invocation — profile, account, backup row,
  Storage object, and `auth.users` row all confirmed gone. All QA/diagnostic artifacts cleaned up.
- 5 new widget tests + 4 new live Node integration tests, all passing. `docs/USER_DELETION_DECISION_BRIEF.md`
  updated to reflect implementation status.

### 2. Fixes applied from this audit (Critical/High severity only, per instruction)

| Fix | File(s) | Why |
|---|---|---|
| iOS privacy manifest added | `app/ios/Runner/PrivacyInfo.xcprivacy` (+ wired into `project.pbxproj`) | App Store static scan rejects apps with required-reason API usage (file timestamps, via Drift/sqlite3/path_provider) and no manifest. Verified bundled into the built `.app` after a full `flutter build ios --release --no-codesign`. |
| Rate limit added to `enrich-merchant` Edge Function | `supabase/functions/enrich-merchant/index.ts`, 2 call sites in `app/lib` | Any valid project token — including the public anon key shipped in the app binary — could trigger unlimited Google Places API calls and writes into the shared, all-devices-trust `merchant_keywords` catalog. Every sibling AI-calling function in this codebase rate-limits; this one didn't. Fixed by reusing the existing `bumpCaptureEndpointRateLimit` mechanism (200/install/day), verified live. |
| Admin flag-toggle confirmation | `admin/app/(admin)/flags/page.tsx` | A one-click toggle-on shipped a flag at whatever `rollout_percent` was already stored, with zero confirmation. Not hypothetical — migrations `0023`/`0028` exist specifically because this exact pattern (flag inert only via `is_active=false`, `rollout_percent` left at 100) previously caused an unintended 100%-rollout risk. Added a confirmation prompt when activating a flag with `rollout_percent > 0`. |
| Sentry DSN wired into CI builds | `codemagic.yaml` (both workflows) | Neither Codemagic workflow passed `--dart-define=SENTRY_DSN`, so every CI-built release (TestFlight/App Store included) shipped with crash reporting silently disabled. Fixed the build commands; **the `SENTRY_DSN` secret itself must still be added to the `supabase` variable group in the Codemagic dashboard** — that's a dashboard action, not something fixable from the repo. |
| Wrong currency label in budget-alert notifications | `app/lib/features/app/app_shell.dart`, `app/lib/features/capture/services/captured_message_processor.dart` | Non-SAR-account users received push notifications with a raw ISO code ("...150 USD") instead of the app's Arabic currency label used everywhere else. Fixed by routing through the existing `Currency.arabicLabel`/`moneyInt` helpers. |

All fixes verified: `flutter analyze` clean, 582/582 Dart tests pass, admin panel lints and builds clean,
`enrich-merchant` rate limit live-smoke-tested (with cleanup), full unsigned iOS release build succeeds
with the privacy manifest correctly bundled, `git diff --check` clean, all 42 migrations in sync
local/remote, all Edge Functions ACTIVE.

---

## Remaining blockers

### Critical

**1. Android release builds sign with the debug keystore.**
`app/android/app/build.gradle.kts:29-33` — still Flutter's default template
(`signingConfig = signingConfigs.getByName("debug")` with a `// TODO: Add your own signing config`
comment). Play Console will reject any upload signed this way. **Not fixed in this session** — generating
and safely custody-ing a production signing key is a decision only the app owner should make (losing
this key means losing the ability to ever update the app on Play Store again). Action needed: generate
a release keystore, store it somewhere durable and backed up, create `android/key.properties`
(already gitignored), and wire a `signingConfigs.create("release")` block. Estimated effort: under an
hour once the keystore exists.

### High (fixed, listed for visibility)

All four High-severity items found in this audit were fixed this session (see table above): the
`enrich-merchant` rate-limit gap, the admin flag-toggle confirmation gap, the missing Sentry DSN in CI,
and the currency-label bug. No further action needed on these.

### Medium

- **Google Sign-In "skip nonce checks" dashboard setting unverifiable from the repo.** Native Google
  sign-in silently fails if this isn't enabled on the production Supabase project's Auth → Providers →
  Google page. Add to the pre-launch checklist; confirm in the dashboard before submission.
- **iOS extension provisioning profiles unverifiable from the repo.** `codemagic.yaml`'s signed workflow
  only names the Runner bundle identifier; the two share-extension targets need their own profiles
  configured in Codemagic/App Store Connect. Confirm before running the signed workflow.
- **Display name mismatch**: iOS `CFBundleDisplayName` and Android `android:label` both read "قرش"
  (Qirsh) while the product is called "Mali" everywhere else (CLAUDE.md, docs, this report). Confirm
  which is the intended store-listing name before submission — not fixed here since it's plausibly an
  intentional in-progress rebrand, not a defect.
- `parse-sms`'s rate limit is keyed on a client-supplied `install_id` with no device-secret proof (unlike
  the capture endpoints), so it's bypassable by rotating the id. `bank-discovery` has no rate limit at
  all. Both bound cost/abuse, not data integrity; propose binding both to the existing
  `capture_devices`/device-secret mechanism as a fast follow-up, not a blocker.
- `merchant-feedback` Edge Function is a no-op stub with no auth and an unfinished TODO; not a security
  hole (writes nothing today) but should be finished or taken out of the client's call path.
- Backup restore shows "wrong password" instead of "corrupt file" on a malformed-but-decryptable backup
  (`encrypted_backup_service.dart` / `restore_backup_usecase.dart`) — confirmed non-crashing, just an
  inaccurate error message.
- A `TextEditingController` in the dashboard's quick-budget sheet isn't disposed (bounded, one-per-open
  leak) — `dashboard_screen.dart:994-999`.

### Low (acceptable to ship as-is; listed for completeness, not blockers)

- Unused RPC `goal_progress_summary` (no caller yet — goal progress is computed client-side).
- `catalog_versions` table has no RLS (non-sensitive counters, low-value target).
- Migrations 0001–0019 lack rollback scripts (0020+ all have them — a convention gap, not a live risk).
- `catalog-*` read-only Edge Functions don't enforce `GET`-only (cosmetic; they ignore the body anyway).
- Two dead files (`bento_card.dart`, `android_sms_capture_service.dart`) and two dead providers
  (`installIdProvider`, `saveLanguageUseCaseProvider`) — left in place per project convention
  ("don't remove pre-existing dead code unless asked").
- A handful of N+1 query patterns in Drift repositories — correctness-safe, low real-world impact at
  expected per-user row counts.
- Silent, unlogged failure in `bank_discovery_client.dart`'s catch-all (falls back to local heuristic
  parser safely, but produces no telemetry on why). Not fixed — the codebase has no existing manual
  Sentry-capture pattern anywhere, so adding one here would be a new architectural habit, not a
  same-shape fix; worth a deliberate follow-up rather than a rushed one-off.
- Sign-in cancel and genuine auth failure show the same error message (minor UX confusion, not a bug).

---

## Areas reviewed and found acceptable (no changes needed)

- **RLS coverage**: all 30 tables covered except the one Low item above; `admin_users` is notably
  well-hardened (fail-closed self-check policy, all grants revoked except service_role).
- **Race conditions**: every financial RPC reviewed (`delete_user_account_safely`,
  `add_goal_contribution`, `record_bill_payment`, `set_default_account`, etc.) uses correct locking or
  idempotent-by-construction design. The one previously-fixed race (subscription payment `paid_count`,
  migrations 0040/0041) is confirmed still correct.
- **Indexes**: no missing index found against any real query pattern in the repository layer.
- **Migration/remote drift**: none — all 42 migrations in sync, local and remote.
- **Edge Function auth patterns**: all capture-flow functions correctly use device-secret + timing-safe
  comparison; no recurrence of the `purge-scheduled-deletions`-class bug found anywhere else. Admin-only
  functions correctly use `auth.getUser()` + an `admin_users` allowlist, not client-claimed roles.
  Secrets handling is clean — no hardcoded or echoed secrets in any of the 17 functions.
  User-id trust is correct everywhere — no function accepts a client-supplied `user_id` for a
  non-admin write.
- **Feature flag bucketing**: SHA-256(`installId:flagKey`) is correctly implemented and independent per
  flag — changing one flag's rollout cannot affect another flag's bucket assignment.
  Per-user overrides are correctly RLS-scoped.
- **Auth/session handling**: Apple "Hide My Email" relay works with no special-casing needed;
  session/token-refresh reconciliation (`app_session.dart`) correctly distinguishes expired-session
  from never-onboarded, and explicitly patches the "signed into Supabase but stale local state" gap.
  No credentials logged anywhere.
- **Biometric lock**: fail-closed throughout, no bypass path, correctly wraps the router root.
- **Parser isolate**: enforces its 2-second timeout and fails closed to `null` on any error — no crash
  risk from adversarial SMS input.
- **Offline degradation**: `SupabaseConfig.isConfigured` gating is consistent across providers and
  services; no code path crashes or hangs when the backend is unreachable or unconfigured.
- **Android manifest**: only `POST_NOTIFICATIONS`/`USE_BIOMETRIC` requested — capture uses share-sheet
  intents, not SMS permissions, avoiding Play's restricted-permissions review entirely.
- **App Groups entitlement**: `group.com.youssefsafwat.mali` matches exactly across Runner,
  BankMessageShortcuts, and ShareBankMessage targets.
- **iOS Info.plist**: usage-description strings match actual plugin usage, app icon set complete,
  `ITSAppUsesNonExemptEncryption` correctly set, bundle ID correct, no `com.example` placeholder.
- **No hardcoded secrets** found anywhere in `app/lib/` or the 17 Edge Functions.

---

## Manual QA remaining before launch

1. Confirm the Google Sign-In "skip nonce checks" setting on the **production** Supabase project.
2. Confirm the two extension provisioning profiles are configured in Codemagic/App Store Connect before
   running `ios-signed-release`.
3. Add `SENTRY_DSN` to the `supabase` variable group in the Codemagic dashboard (code side is now wired).
4. Confirm the intended store display name ("Mali" vs "قرش") and update whichever is stale.
5. Generate the Android release keystore and wire `signingConfigs.create("release")`.
6. A device-level regression pass on the notification pipeline, capture flow, and account deletion UI
   (schedule → cancel → re-schedule) on a real iPhone, per the manual QA checklist already produced
   earlier this session.

## Deployment / store readiness

- **Deployment (Supabase)**: ready. All migrations applied and in sync; all Edge Functions deployed and
  active; the account-deletion worker is live-verified but intentionally not on an automatic schedule
  yet (documented decision — wiring it to `pg_cron` requires embedding its secret into cron SQL text,
  a separate operational choice for the app owner to make).
- **App Store readiness**: ready pending the two Medium checklist items above (nonce-check setting,
  extension provisioning profiles) — the Critical privacy-manifest blocker is fixed and verified.
- **Play Store readiness**: blocked on the Android release-signing Critical item. Everything else
  (manifest permissions, SDK versions) checked out clean.
- **Soft-launch readiness**: ready for iOS sideload/TestFlight track today; Play Store track blocked
  until signing is resolved.
- **Production readiness**: the backend, data model, and app logic are production-ready. The remaining
  gaps are launch mechanics (signing, CI secrets, dashboard settings), not defects in the product itself.

## Would you approve launching Mali to real users today?

**GO WITH CONDITIONS.** The engineering is sound — RLS, race conditions, auth, offline behavior, and
the notification/capture pipeline all held up under this audit and the prior remediation batches this
session. Ship once: (1) the Android keystore is generated and wired, and (2) the three dashboard/CI
confirmations above are done. None of these touch app logic; all are bounded, well-understood pieces of
launch housekeeping, not open engineering questions.

> **STATUS: HISTORICAL / SUPERSEDED**
> **Current source of truth:** `Qirsh Production/QIRSH_PRODUCTION_RELEASE_RUNBOOK.md`
>
> Retained for traceability. It reflects what was believed during
> release preparation and is NOT accurate about the current plan —
> most importantly, production now uses a NEW Supabase project.

# QIRSH — RELEASE RUNBOOK

**Prepared against HEAD `40034663`.** Every command below is written to be
copy-pasted. Nothing in this file has been executed against production or
evidence staging; the local verification results quoted are from a disposable
container and this working machine.

**Production project:** `vrombzdgwqjjiijbidqb` — ZERO contact to date.
**Evidence staging:** `dpdukyozedajelflkeix` — ZERO contact to date.

---

## ⚠️ 0. READ FIRST — THE LINKED-PROJECT HAZARD

`supabase/.temp/project-ref` on this machine contains:

```
bdhqjijscwdzqwqanygv        # organization iyfzfynifrmwcjbcyfwv, name "Nbjg"
```

That is **neither production nor evidence staging.** It is gitignored, so it is
local state and not a repository leak — but it means **any `supabase db push`
or `supabase functions deploy` run from this directory right now goes to a
project nobody intends to deploy to.**

Worse than deploying to the wrong place: it would look like it worked.

**Before any deploy command:**

```bash
supabase projects list                      # confirm which refs you can see
supabase link --project-ref vrombzdgwqjjiijbidqb
cat supabase/.temp/project-ref              # MUST now print the production ref
```

Re-run that `cat` after every `link`. Treat a mismatch as a full stop.

---

## 1. MIGRATIONS — exact production execution order

Eight migrations are written, reviewed, rollback-covered and **unapplied
anywhere**: `0084` … `0091`. Apply them in **strict numeric order**. Each is
transactional or idempotent; none may be skipped or reordered.

| # | File | What it changes | Reversible? |
|---|---|---|---|
| 0084 | `purge_user_data_restore.sql` | replaces `purge_user_data()`; restores deletion completeness, de-identifies referral audit | via re-running 0083 |
| 0085 | `concurrency_absent_row_locking.sql` | replaces 3 functions; closes H-10/H-11/H-12 absent-row races | via re-running 0074 then 0083 |
| 0086 | `backups_owner_liveness.sql` | new `backups_owner_is_live()`; adds liveness to 2 storage write policies | **yes**, exact |
| 0087 | `parser_validation_evidence.sql` | resets evidence-free `passed` parsers; adds CHECK constraint | **yes**, exact (pre-image journal) |
| 0088 | `explicit_owner_table_grants.sql` | declares grants on 17 owner tables | see rollback file — revoking BREAKS the app |
| 0089 | `force_update_arming_authority.sql` | new audit table, guard trigger, `arm_force_update()` | **yes**, exact |
| 0090 | `budget_category_key_reconciliation.sql` | one read-only diagnostic view | **yes**, trivial |
| 0091 | `catalog_amount_decimal_scale.sql` | widens parser decimal cap `{1,2}`→`{1,3}` | yes, but see warning |

### Local verification already performed

```
supabase/tools/dryrun_migrations.sh
  → all 91 migrations apply cleanly in filename order, on a fresh database
  → 0084-0091 re-apply after rollback (roll-back → fix → roll-forward works)
  → rollbacks 0086/0087/0089/0090/0091 execute
```

Run against a throwaway `postgres:17` container started with `--network none`;
the script refuses to run if the container has a network at all, and the
Supabase CLI is never invoked, so the linked-project ref cannot be involved.

**What that proves:** every statement parses, every object exists before it is
referenced, and the numeric order is a valid apply order.
**What it does not prove:** behaviour. `pg_cron`, `pg_net` and `vault` are
stubs, and RLS policies compile without being exercised.

### Apply

```bash
# Confirm the link FIRST (see §0).
cat supabase/.temp/project-ref

# Recommended: one file at a time, checking between each.
for n in 0084 0085 0086 0087 0088 0089 0090 0091; do
  f=$(ls supabase/migrations/${n}_*.sql)
  echo "── applying $f"
  psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || break
done
```

`supabase db push` also works, but applies everything unapplied in one pass —
prefer the loop so a failure stops at a known file.

### Migration-specific notes

* **0087** prints how many parsers it demoted. Expect a non-zero count; that is
  the defect being fixed, not an error. `catalog-delta` serves only `passed`
  parsers, so **some banks stop parsing until their rules get golden-test
  evidence.** Plan for that — it is user-visible.
* **0091** raises a `WARNING` listing any rule still carrying a `{1,2}` cap.
  Not fatal. Review those in the admin Parser Lab.
* **0089** installs a trigger that blocks arming a force-update outside
  `arm_force_update()`. After this, the admin panel's force-update path must go
  through that function.

---

## 2. EDGE FUNCTIONS — deployment

24 functions. All pass `deno test` and `deno lint` locally (gate stage 2).

```bash
cat supabase/.temp/project-ref     # §0 again — deploy targets the linked project

cd supabase
for fn in catalog-delta catalog-announcements catalog-flags catalog-versions \
          catalog-campaigns catalog-coupons parser-test bank-discovery \
          parse-sms process-ios-sms enrich-merchant merchant-feedback \
          evaluate-budgets evaluate-goals evaluate-gamification \
          cron-daily-reminders link-capture-device unlink-capture-device \
          register-device register-push-token set-device-consent \
          sync-captures purge-scheduled-deletions process-notification-retries; do
  echo "── $fn"
  supabase functions deploy "$fn" || break
done
```

### Two functions deploy with JWT verification OFF — this is deliberate

`supabase/config.toml` sets `verify_jwt = false` for
`purge-scheduled-deletions` and `process-notification-retries`. Both are
workers invoked by `pg_cron` or an operator, never by a client, and each gates
itself on a dedicated shared secret instead of a Supabase JWT.

**Both fail closed on a missing secret** — verified in source:

* `bearerSecretAuthorized()` opens with `if (!configuredSecret) return false;`
  (`_shared/capture_auth.ts:124`), covered by `_shared/purge_worker_auth_test.ts`.
* `process-notification-retries` checks `if (!workerSecret || !timingSafeEqual(...))`.

So if you deploy these **before** setting their secrets, they reject every
request rather than running unauthenticated. Deploy order is therefore safe
either way, but set the secrets first to avoid a window of failing cron runs.

### Fail-closed posture of the AI functions

| function | missing key behaviour |
|---|---|
| `parse-sms`, `bank-discovery`, `process-ios-sms` | return `upstream_unavailable` (retryable); never proceed, never leak |
| `enrich-merchant` | **soft-degrades by design** to `bestEffortCategoryForMerchant()`; enrichment is an enhancement, not a correctness path |

---

## 3. SECRETS & CONFIG INVENTORY

### 3a. Supabase Edge Function secrets

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are
injected by the platform — do **not** set them manually.

| secret | needed by | consequence if unset |
|---|---|---|
| `GEMINI_API_KEY` | `parse-sms`, `bank-discovery`, `process-ios-sms` | AI capture returns `upstream_unavailable`; deterministic parser unaffected |
| `GEMINI_MODEL` | same three | falls back to the in-code default |
| `GOOGLE_MAPS_API_KEY` | `enrich-merchant` | merchant enrichment degrades to local heuristics |
| `PURGE_WORKER_SECRET` | `purge-scheduled-deletions` | **worker rejects everything (403)** — scheduled deletions stop running |
| `NOTIFICATION_RETRY_WORKER_SECRET` | `process-notification-retries` | **worker rejects everything (401)** — push retries stop |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` | `_shared` (push delivery) | iOS pushes cannot be signed |

```bash
supabase secrets set GEMINI_API_KEY=...
supabase secrets set PURGE_WORKER_SECRET="$(openssl rand -base64 32)"
supabase secrets set NOTIFICATION_RETRY_WORKER_SECRET="$(openssl rand -base64 32)"
# APNS_PRIVATE_KEY is the .p8 contents including the BEGIN/END lines:
supabase secrets set APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
supabase secrets list        # verify names only; values are never echoed
```

The two worker secrets should be **freshly generated and unique**, not the
service-role key — that separation is the point of the design.

### 3b. App build-time `--dart-define`

| define | required | purpose |
|---|---|---|
| `SUPABASE_URL` | for cloud features | project URL |
| `SUPABASE_ANON_KEY` | for cloud features | anon key |
| `SENTRY_DSN` | optional | crash reporting; absent = disabled, no crash |
| `LEGAL_BASE_URL` | **yes, for store submission** | host serving `/privacy` and `/terms` |

Without `LEGAL_BASE_URL` the build falls back to `https://mali.youssefsafwat.com`,
which does not resolve. `legalUrlsArePlaceholder` is asserted `true` by
`legal_urls_test.dart` today; when a real host is configured that assertion
flips and must be deleted.

### 3c. Android

| variable | purpose |
|---|---|
| `ANDROID_KEYSTORE_PATH` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` | release signing (or `android/key.properties`) |
| `ADMOB_APP_ID_ANDROID` | optional; absent ⇒ warns and ships with ads off |

### 3d. iOS

| setting | purpose |
|---|---|
| `APS_ENVIRONMENT` | `development` or `production`, from the entitlements build setting |
| `ADMOB_APP_ID_IOS` | optional, feeds `$(ADMOB_APP_ID)` |
| `AppIdentifierPrefix` | expanded by Xcode; used for the shared Keychain group |

---

## 4. CAPABILITY ACTIVATION — PUSH, verify, then PULL

### ⚠️ 4a. This is a CODE change, not a dashboard toggle

`app/lib/data/sync/exact_transport_capability.dart` hardcodes all three
capability providers:

```dart
final exactPushTransportCapabilityProvider = Provider(...)  => unknown;
final exactPullTransportCapabilityProvider = Provider(...)  => unknown;
final planningServerCurrencyCapabilityProvider = Provider(...) => unknown;
```

They are **not wired to `FeatureFlagService`**. No Supabase flag, admin toggle
or remote config can change them. Activation requires editing this file,
rebuilding, and shipping — which is why it is a reviewed release decision
rather than an operational switch.

The gate is **positive proof only**: both `unknown` and `unsupported` block.
Financial cloud sync is therefore fully off in the current build, by design.

### 4b. Order — PUSH before PULL, and why

Push proves the server accepts an exact decimal string into `NUMERIC` without
a float round-trip. Pull proves the server returns `NUMERIC::text` unchanged.
Proving one says nothing about the other, which is why they are separate
providers.

Push first, because a push failure is contained — the outbox parks the write
durably with `exact_money_transport_unverified` and nothing is lost. A pull
failure under an unverified transport would mean **wrong money values entering
the local canonical store**, which is not contained and not automatically
repairable.

### 4c. Procedure

**Step 1 — verify PUSH against a real project (not production).**
Write a known exact value through the real PostgREST path, read it back at full
precision, and confirm byte equality — e.g. `12.345` for a 3-decimal currency
and a value beyond 2^53 for magnitude.

**Step 2 — activate PUSH only.**
```dart
final exactPushTransportCapabilityProvider =
    Provider<ExactTransportCapability>((ref) {
  return ExactTransportCapability.verifiedExact;  // verified <date>, evidence <link>
});
// pull and planning-currency stay `unknown`
```
Ship. Watch parked-write counts fall to zero.

**Step 3 — verify PULL** the same way, in the opposite direction.

**Step 4 — activate PULL.** Same file, `exactPullTransportCapabilityProvider`.

**Step 5 — planning currency (budgets/goals) needs BOTH.**
`planningServerCurrencyCapabilityProvider` requires migration **0077** deployed.
`weakerCapability()` means budgets/goals stay parked unless the planning
capability *and* that direction's transport are both `verifiedExact` — never
one alone.

### 4d. Kill switch / rollback

| layer | mechanism | reach |
|---|---|---|
| capability | set the provider back to `unknown`, ship | needs a release — **slow** |
| feature flag | `ledger_push_sync` / `ledger_pull_sync` / `planning_*_sync` → off | remote, immediate |
| consent | user's own financial-sync consent | per user |

**The fast kill switch is the feature flags, not the capabilities.** Flags are
remote and take effect on next flag fetch; capabilities are compiled in. If
something goes wrong after activation, flip the flag first and treat the
capability revert as the follow-up release.

`FeatureFlagService` defaults every sync flag to `false`, and `getBool` returns
`false` for unknown keys — so a flag that fails to fetch fails closed.

---

## 5. PHYSICAL-DEVICE QA

Simulators cannot exercise the parts most likely to break. These need real
hardware.

### 5a. iPhone

| # | Check | Why a simulator cannot |
|---|---|---|
| 1 | Face ID unlock, and cancel/fallback | Simulator Face ID is synthetic |
| 2 | Share-sheet extension `ShareBankMessage` from Messages | needs a real share host |
| 3 | Shortcut `BankMessageShortcuts` end-to-end (H-19) | App Intents need a device |
| 4 | Shared Keychain group across app + extension (MALI-031) | keychain groups need a real prefix |
| 5 | APNs receipt in foreground, background, and terminated | simulator push differs |
| 6 | Notification actions «تأكيد ✓» / «تجاهل» from the lock screen | lock screen not simulated |
| 7 | App Group container handoff `group.com.youssefsafwat.mali` | entitlement is device-real |
| 8 | Biometric lock after backgrounding, with a real timer | |
| 9 | Dynamic Island / notch clearance on a Pro device | `useSafeAreaTop` uses the real inset |
| 10 | Dynamic Type at max size on the money surfaces | |

### 5b. Android

| # | Check |
|---|---|
| 1 | Notification-listener permission grant, revoke, and re-grant |
| 2 | Real bank SMS/notification capture end-to-end |
| 3 | Background capture with the app swiped away |
| 4 | Battery optimisation exemption prompt and behaviour when denied |
| 5 | Biometric prompt across vendor skins (Samsung/Xiaomi differ) |
| 6 | SQLCipher open on a low-RAM device |
| 7 | Locale switch ar ⇄ en with RTL relayout |
| 8 | Play Protect / install-from-bundle sanity on a signed AAB |

### 5c. Both — the money surfaces

Every screen changed in Phase J, at default and maximum font scale, in both
themes and both locales: Home hero · Accounts · Budgets cards and sheet ·
Reports (refund breakdown, weekly chart) · Goals pacing · Plans · Subscriptions
· Transactions detail (account/card rows) · notification bodies.

---

## 6. UX-035 — device reproduction

The one Phase J finding whose original repro was never captured. **Capture this
before deciding whether the fix is right.**

**Report:** very large values on the cards UI collapse into a zero-like,
unreadable result («0 0 0»).

**What shipped:** exactness fixed (values are now formatted from exact minor
units, correct past 2^53); legibility given a floor via `heroAmountFontSize()`,
which picks a size from the formatted length so a long value starts legible
instead of shrinking continuously inside `FittedBox(scaleDown)`.

### Reproduction

1. Real device, not a simulator. Note model, OS version, locale, and **text
   size setting** (iOS: Settings → Display → Text Size; Android: Font size).
2. Create an account and add transactions producing balances of increasing
   magnitude: `9,999.99` → `999,999.99` → `99,999,999.99` → `9,999,999,999.99`.
3. Visit, and screenshot each: **Home hero**, **Accounts** rows, **Budgets**
   card tiles, **Cards** page flow figures.
4. Repeat at maximum text size, and in both ar and en.
5. For each screenshot record: is every digit legible? is any digit missing or
   truncated? does the value match what was entered?

### How to read the result

* **Digits wrong or missing** → a formatting defect. Report it; the exactness
  fix did not cover that path.
* **Digits correct but too small to read** → the legibility floor needs
  lowering. Tune the thresholds in `hero_amount_size.dart`.
* **Cannot reproduce at any magnitude** → the fix holds; close UX-035 and note
  the repro attempt in the closure matrix.

`hero_amount_size.dart` states this openly: if the captured repro shows a
different cause, the shipped fix is the *wrong* fix rather than an incomplete
one.

---

## 7. iOS RELEASE CONFIGURATION — audit

**Verified present in the repo:**

* Bundle id `com.youssefsafwat.mali`; display name `قرش`.
* `ITSAppUsesNonExemptEncryption = false` — set, so no export-compliance prompt.
  *This is a legal declaration.* The app uses SQLCipher; the exemption for
  standard encryption protecting the user's own data normally applies, but
  **confirm it against Apple's current criteria before submitting.**
* Entitlements: `aps-environment` (build-setting driven), Sign in with Apple,
  App Group `group.com.youssefsafwat.mali`, two Keychain groups with the app's
  own group **first** (required — `flutter_secure_storage` uses the default
  group and must keep reading the existing SQLCipher key).
* Purpose strings present and in Arabic: Camera, Face ID, Photo Library.
* `SKAdNetworkItems` present; no IDFA/ATT requested in V1.
* Google Sign-In URL scheme registered.
* `NSLocationWhenInUseUsageDescription` deliberately **absent** — the location
  permission was removed in Phase-7 Batch-4.

**Owner must confirm in App Store Connect / the developer portal:**

* App ID has App Groups, Sign in with Apple, and Push Notifications enabled.
* An APNs key (`.p8`) exists; its Key ID / Team ID match the Edge secrets.
* Provisioning profiles exist for the app **and both extensions**
  (`BankMessageShortcuts`, `ShareBankMessage`) — a missing extension profile
  fails `ios-signed-release` late.
* App Privacy answers match `docs/legal/PRIVACY_POLICY.md`.
* Privacy policy URL is reachable **before** submitting.

---

## 8. ANDROID RELEASE CONFIGURATION — audit

**Verified in `android/app/build.gradle.kts`:**

* `applicationId = com.youssefsafwat.mali`, namespace matches.
* **Release never falls back to the debug key.** If no signing config is
  present, `signingConfig` stays null and every `assemble*Release` /
  `bundle*Release` / `package*Release` task fails with a named error. This is
  the guard that a previous debug-signed upload rejection produced.
* Signing reads `android/key.properties` **or** four `ANDROID_KEYSTORE_*`
  environment variables, so CI need not commit the file.
* AdMob app id is shape-validated against `^ca-app-pub-[0-9]{16}~[0-9]{10}$` —
  the exact regex the SDK applies in `MobileAdsInitProvider` at *process start*,
  where no Dart guard could catch a typo. A malformed value **fails the build**;
  an absent value warns and ships with ads off.
* Setting the id to Google's test publisher in a release build is a hard error.
* Java/Kotlin 17, core library desugaring on.

**Owner must do:**

* Generate the keystore, store it in 2+ independent locations, and put both
  passwords in a password manager. **A lost keystore cannot be recovered and
  cannot be replaced without publishing a new listing.**
  ```bash
  keytool -genkeypair -v -keystore mali-release.jks \
    -keyalg RSA -keysize 2048 -validity 10000 -alias mali
  cp android/key.properties.example android/key.properties   # then fill in
  ```
* Confirm `git status` shows nothing new afterwards (both are gitignored).
* Play Console: data-safety form matching the privacy policy; declare the
  notification-listener usage and justify it — this is the most common
  rejection reason for this app category.

---

## 9. RELEASE BUILD COMMANDS

```bash
# Android
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_ANON_KEY=... \
  --dart-define=SENTRY_DSN=... \
  --dart-define=LEGAL_BASE_URL=https://<host>

keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab
# → SHA-256 must match: keytool -list -v -keystore mali-release.jks -alias mali

# iOS (Codemagic workflow `ios-signed-release`, or locally with signing set up)
flutter build ipa --release --dart-define=...   # same defines
```

---

## 10. BETA ROLLOUT

### TestFlight
1. Upload via Codemagic `ios-signed-release` or Xcode Organizer.
2. Export-compliance answer must match `ITSAppUsesNonExemptEncryption`.
3. Internal testers first — verify the §5a device list on a real iPhone.
4. External testing needs Beta App Review; supply the privacy URL and a
   demo account.
5. Keep capabilities `unknown` for the first build. Cloud financial sync stays
   off; that is intended and should be stated in the tester notes.

### Google Play internal testing
1. Upload the signed AAB to the internal track.
2. Complete the data-safety form and the notification-listener declaration.
3. Confirm Play App Signing enrolment and record the upload-key fingerprint.
4. Internal track → closed track only after the §5b list passes on real hardware.

### Both
- Ship with sync flags **off**. Turn them on per §4 only after push is verified.
- Have the force-update path ready (`arm_force_update()`, 0089) before wide
  rollout — it is the only client-side kill switch that reaches installed apps.

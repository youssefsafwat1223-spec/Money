# FINAL RELEASE READINESS — Qirsh / قِرش

**Phase R7 output. This is a readiness package, not a rollout.**
Nothing in this document has been executed against production.

| | |
|---|---|
| Prepared at | 2026-08-22 |
| Branch | `feat/phase1-data-integrity` |
| Source baseline audited | `12048943` |
| HEAD (after R7 closures) | `d5e64aa7` — `6667dcc7` GATE-1 test fixes · `e1662e2b` gate record · `d5e64aa7` iOS signing (I1/I2) |
| Working tree | clean |
| Local commits ahead of upstream | 324 (**NOT PUSHED**) |
| Production project ref | `vrombzdgwqjjiijbidqb` — **ZERO contact in R7** |
| Validation staging ref | `bdhqjijscwdzqwqanygv` — read-only entitlement/flag verification only |
| Evidence staging ref | `dpdukyozedajelflkeix` — **ZERO contact in R7** |

> **Operator runbook:** `docs/PRODUCTION_ROLLOUT_OPERATOR_PACKAGE.md` — the executable PROD-1..4 package,
> prepared with zero production contact. Nothing in it has been run.

> **Scope rule.** R7 answers "is every prerequisite identified and ready?" — it does not deploy,
> migrate, flip flags, publish, or push. Every item below is either VERIFIED (with evidence),
> or an explicit prerequisite for an operator.

---

## 1. Source baseline (verified, not assumed)

| Item | Expected | Actual | Verdict |
|---|---|---|---|
| Bundle / package id | `com.youssefsafwat.mali` | iOS `com.youssefsafwat.mali` (+ `.ShareBankMessage`, `.RunnerTests`); Android `applicationId = com.youssefsafwat.mali` | **PASS** |
| Drift schema | v31 | `_targetSchemaVersion = 31` (`app/lib/data/db/app_database.dart:21`) | **PASS** |
| `google_mobile_ads` | exactly 9.0.0 | `google_mobile_ads: 9.0.0` (no caret) | **PASS** |
| `liquid_glass_renderer` | exactly 0.2.0-dev.4 | `liquid_glass_renderer: 0.2.0-dev.4` | **PASS** |
| Migration ceiling | 0083 | 83 files, `0001…0083`, dense and gapless | **PASS** |
| CAS | false | `kServerRevisionCas = false` (`app/lib/core/sync/sync_capabilities.dart:27`) | **PASS** |
| Financial capabilities | unknown unless activated | `exactPush`/`exactPull`/`planningServerCurrency` all return `ExactTransportCapability.unknown` | **PASS** |
| Feature flag source defaults | all false | `enable_referrals:false`, `enable_report_ads:false`, `enable_coupons:false` | **PASS** |

**No DRIFT detected against the expected baseline.**

---

### 1.1 Canonical gate result (`tools/ci_gates.sh`, current)

```
mandatory gates passed : 12
mandatory gates failed : 0
tools unavailable      : 1
node tests skipped     : 69  (credentials absent — manifest-matched)
deno tests ignored     : 2   (live-Postgres — manifest-matched)
skip/ignore manifest   : satisfied
ALL RUN GATES PASSED (1 unavailable — see notes)
```

Node contract surface: **243 tests · 174 pass · 0 fail · 69 skipped**.

**UNAVAILABLE — `iOS packaging inventory`** (the only unavailable item): the built `Runner.app` has no
provenance sidecar (`tools/stamp_ios_provenance.sh`), so the stage reports UNAVAILABLE rather than
passing. This is the designed behaviour for an unstamped artifact. **It is NOT a pass** — closing it
requires a fresh build plus a provenance stamp, or external evidence.

#### GATE-1 — **CLOSED** (commit `6667dcc7`, test-side only)

R7 originally found this stage failing. It turned out to be **three** stale test-side items in the same
stage — fixing the first exposed the next. No production code was changed to satisfy any of them.

| # | Item | Resolution |
|---|---|---|
| 1 | `remote_backup_contract_test.mjs:88` pinned the exact one-line spelling `if (_busy) return null`; the UI merge (`900012a6`, via `be7fd84d`) reformatted the same guard to braces | Assertion rewritten to check the **semantic** invariant, scoped to the `_run` coordinator: a busy guard returning null, ordered **before** `_busy = true`, and a `finally` that always releases the flag. Verified it still fails if the guard is removed, if the race is reintroduced, or if the flag is never released — and accepts either formatting. Scoping was required: a whole-file check was vacuous because `refresh()` carries its own earlier `if (_busy)`. |
| 2 | `referral_rewards_contract_test.mjs:669` read `report_config_sheet.dart`, renamed to `report_config_page.dart` when the report configuration step became a full-screen route | Path updated. The invariant (report-configuration UI carries no entitlement/ad logic) is unchanged and still verified. |
| 3 | `referral_r5_live_harness.mjs` called `process.exit(2)` when staging credentials were absent — which `node --test` counts as a failing test file, so the stage was red on any machine without credentials | Converted to the same credential-gate idiom as every other live test here (**skip, not fail**), with cleanup moved into a `finally`. The ref guards stay **HARD** and still abort: aiming the harness at production or evidence staging is a safety failure, not a config gap. |

**Behavioural impact of GATE-1 in all three cases: NONE.** These were stale assertions and a mis-shaped
credential gate, never product regressions.

> **Scope note.** A green canonical gate means the code and contract surfaces verify locally. It does
> **not** mean the product is releasable — release readiness remains **BLOCKED** by the production,
> signing, Android and configuration prerequisites in §21/§23, none of which are affected by GATE-1.

---

## 2. Production migration plan (prepared — DO NOT APPLY in R7)

### 2.1 Ordering

Apply `0001 → 0083` in numeric order. Numbering is dense and gapless; no `0084` exists and none may be
introduced by this release.

### 2.2 Hard prerequisite — pgcrypto schema

`0083` calls pgcrypto **schema-qualified** at exactly three sites:

| Line | Call |
|---|---|
| `0083:447` | `extensions.gen_random_bytes(16)` — in `generate_referral_code()` |
| `0083:556` | `extensions.digest(...)` — in `apply_entitlement_mutation()` |
| `0083:1071` | `extensions.digest(...)` — in `referral_admin_fingerprint()` |

This is load-bearing: all 21 functions in `0083` pin `SET search_path = pg_catalog, public, pg_temp`,
which **does not include `extensions`**. This is the exact defect that failed on real Postgres in R5 and
was fixed by schema-qualification.

**Pre-apply check (must pass before applying 0083):**

```sql
SELECT e.extname, n.nspname AS installed_schema
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname IN ('pgcrypto','pg_net','pg_cron');
-- REQUIRED: pgcrypto -> extensions
```

If pgcrypto resolves anywhere other than `extensions`, **stop** — 0083's RPCs will fail at runtime.
Note `0083:30` issues an *unqualified* `CREATE EXTENSION IF NOT EXISTS pgcrypto`; on a stock Supabase
project this is a harmless no-op because pgcrypto ships pre-installed in `extensions`.

### 2.3 Other extension dependencies

| Extension | Expected schema | Used by |
|---|---|---|
| `pgcrypto` | `extensions` | 0002, 0083 |
| `pg_cron` | `cron` | 0033, 0052, 0057, 0065 |
| `pg_net` | `extensions` / `net` | 0052, 0053, 0057, 0065 |

### 2.4 What 0083 creates

- **8 tables**: `referral_codes`, `referral_reward_rules`, `referrals`, `referral_reward_progress`,
  `user_entitlement_state`, `entitlement_events`, `referral_reward_grants`, `referral_admin_audit`
- **22 functions** in three tiers:
  - **10 internal-only** — revoked from PUBLIC, anon, authenticated *and* service_role
  - **4 authenticated self-RPCs** — `apply_referral_code`, `request_referral_qualification`,
    `get_referral_summary`, `get_entitlement_decision`
  - **7 service-role admin RPCs** — `admin_mutate_entitlement`, `admin_reject_referral`,
    `admin_reverse_referral`, `admin_adjust_referral_progress`, `admin_rotate_referral_code`,
    `admin_publish_reward_rule`, `admin_deactivate_reward_rule`
- **RLS enabled on all 8 tables with ZERO policies**, plus explicit `REVOKE ALL ON TABLE … FROM anon, authenticated`
  (defence in depth — denial does not rest on policy absence alone)
- **1 replaced function**: `purge_user_data(uuid)` gains a referral-domain block (CREATE OR REPLACE of the 0065 function)
- **2 flag seeds**: `enable_referrals=false/0%`, `enable_report_ads=false/0%` (both `ON CONFLICT DO NOTHING`)

### 2.5 Post-apply smoke queries

Run as service_role/postgres. Full query set is in §2.5 of the audit evidence; the minimum gate is:

```sql
-- 1. 13 tables exist, RLS enabled on all
SELECT c.relname, c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN (
 'coupons','coupon_categories','coupon_tags','coupon_tag_links','coupon_metrics_daily',
 'referral_codes','referral_reward_rules','referrals','referral_reward_progress',
 'user_entitlement_state','entitlement_events','referral_reward_grants','referral_admin_audit');
-- EXPECT 13 rows, relrowsecurity = true for all

-- 2. Referral tables must have ZERO policies
SELECT tablename, count(*) FROM pg_policies WHERE schemaname='public'
  AND tablename LIKE 'referral%' OR tablename IN ('user_entitlement_state','entitlement_events')
GROUP BY 1;
-- EXPECT: no rows. ANY row here is a FAILURE.

-- 3. No anon EXECUTE anywhere in the referral domain (the 0080 bug class)
SELECT has_function_privilege('anon','public.get_entitlement_decision(text)','EXECUTE') AS anon_bad;
-- EXPECT false

-- 4. Flags ship OFF
SELECT key, value, rollout_percent, is_active FROM public.feature_flags
WHERE key IN ('enable_coupons','enable_referrals','enable_report_ads');
-- EXPECT all value='false', rollout_percent=0
```

### 2.6 Rollback / recovery

**There are no rollback scripts for 0081, 0082 or 0083** — `supabase/rollback/` stops at `0062`.
Reversal strategy for this release is therefore **roll-forward hotfix only**, never a downgrade.
Containment for the referral/ads domain is the feature flags (see §9), not a schema revert.

**Do not re-run `0030`, `0032`, or `0039` after any flag activation** — they use
`ON CONFLICT DO UPDATE` and will silently force 8 flags back to OFF.

---

## 3. Edge Function deployment manifest

Reconciled from the current source tree (24 function directories + `_shared/`).

### REQUIRED_FOR_RELEASE (14)

| Function | Why required |
|---|---|
| `register-device` | Bootstrap for the entire capture pipeline |
| `register-push-token` | No push delivery without it |
| `sync-captures` | Sole drain path for relay captures |
| `link-capture-device` | Post-sign-in device ownership |
| `unlink-capture-device` | Sign-out path |
| `set-device-consent` | `0071` makes all AI endpoints fail closed without it |
| `process-ios-sms` | Core capture path; the only natively-invoked function (iOS App Intent) |
| `parse-sms` | In-app AI parse |
| `catalog-versions` | **Hard gate** — awaited first in `syncAll`; a throw skips flags, announcements, campaigns and coupons too |
| `catalog-delta` | Parser/bank catalog source |
| `catalog-flags` | Rollout / kill-switch authority — required for any flag control |
| `evaluate-gamification` | Awards XP via RPC (not merely a notification path) |
| `process-notification-retries` | Only durable APNs retry path (cron-driven) |
| `purge-scheduled-deletions` | Sole executor of the 30-day deletion commitment (cron-driven) |

### OPTIONAL (7)
`bank-discovery`, `enrich-merchant`, `catalog-announcements`, `catalog-campaigns`, `catalog-coupons`,
`parser-test` (admin tooling), `evaluate-budgets`, `evaluate-goals` (notification-only).

### OBSOLETE (2)
- `cron-daily-reminders` — retired stub returning `{status:'retired'}`; its pg_cron job still fires daily.
- `merchant-feedback` — returns 410; its Dart client is never constructed.

**Deployment note:** the historical 5-function list in `docs/STAGING_GUIDE.md` and `app/CLAUDE.md` is
**stale and must not be used** — it omits every capture, AI and worker function.

---

## 4. Cron / background jobs

| Job | Schedule | Target | Required |
|---|---|---|---|
| `prune-processed-captures-daily` | `15 3 * * *` | SQL RPC (no pg_net) | **Yes** |
| `notification-retry-dispatch-5min` | `*/5 * * * *` | Edge `process-notification-retries` | **Yes** |
| `purge-scheduled-deletions-job` | `30 3 * * *` | Edge `purge-scheduled-deletions` | **Yes** |
| `cron-daily-reminders-job` | `0 0 * * *` | retired stub | **No** — consider removing |

Plus **3 DB triggers** on `user_transactions`/`user_goals` firing `evaluate-budgets`,
`evaluate-gamification`, `evaluate-goals` via pg_net + Vault.

**Vault secrets required by the SQL dispatchers** (separate from Edge env):
`project_url`, `service_role_key`, `notification_retry_worker_secret`, `purge_worker_secret`.
Every dispatcher **no-ops silently when these are NULL** — absence looks like success.

---

## 5. Production secret manifest (NAMES ONLY — never values)

| Secret name | Owner/system | Required by | Staging-proven? | Production status |
|---|---|---|---|---|
| `APNS_KEY_ID` | Apple Developer | `_shared/apns.ts` → 5 functions | partial | **MISSING** |
| `APNS_TEAM_ID` | Apple Developer | same | partial | **MISSING** |
| `APNS_BUNDLE_ID` | Apple Developer | same (used verbatim as `apns-topic`) | partial | **MISSING** |
| `APNS_PRIVATE_KEY` | Apple Developer | same | partial | **MISSING** |
| `GEMINI_API_KEY` | Google AI | `process-ios-sms`, `parse-sms`, `bank-discovery` | yes | **MISSING** |
| `GEMINI_MODEL` | config | same | yes | **MISSING** |
| `GOOGLE_MAPS_API_KEY` | Google Cloud | `enrich-merchant` | unclear | **MISSING — and absent from the existing release checklist** |
| `NOTIFICATION_RETRY_WORKER_SECRET` | self-issued | `process-notification-retries` + its cron dispatcher | yes | **MISSING** |
| `PURGE_WORKER_SECRET` | self-issued | `purge-scheduled-deletions` + its cron dispatcher | yes | **MISSING** |
| Vault `project_url` | Supabase | all pg_net dispatchers | yes | **MISSING** |
| Vault `service_role_key` | Supabase | engagement webhook dispatchers | yes | **MISSING** |
| Vault `notification_retry_worker_secret` | self-issued | retry cron | yes | **MISSING** |
| Vault `purge_worker_secret` | self-issued | purge cron | yes | **MISSING** |

**Known auth-value hazard.** `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals` and
`cron-daily-reminders` authorize by comparing the caller bearer to their own
`SUPABASE_SERVICE_ROLE_KEY` env value, while their dispatchers send the **Vault** `service_role_key`.
`process-notification-retries` documents that the platform-reserved env value is Supabase-managed and
**confirmed to differ** from the project's real service-role JWT — which is why that function was moved
to a dedicated worker secret. **The other three were not migrated.** If the values differ in production,
all engagement webhooks return 403 and silently stop. Verify before relying on gamification XP.

---

## 6. iOS release readiness

### Verified present
- Targets: `Runner`, `ShareBankMessage` (app-extension), `RunnerTests`
- App Group `group.com.youssefsafwat.mali` on **both** Runner and the extension
- Push Notifications (`aps-environment`), Sign in with Apple, shared keychain groups
- `IPHONEOS_DEPLOYMENT_TARGET = 16.0`
- AppIntent (`PostBankStatusIntent` + `AppShortcutsProvider`) compiles **into Runner** — correct;
  there is no separate AppIntent extension target and none is needed
- `ITSAppUsesNonExemptEncryption = false`
- Usage descriptions: Camera, FaceID, PhotoLibrary. **No `NSUserTrackingUsageDescription`** — correct for
  a no-IDFA/no-ATT V1

### iOS blockers (must fix before a distribution build)

| # | Blocker | Evidence | Severity |
|---|---|---|---|
| ~~I1~~ | ~~Release/Profile pin a development identity while the pipeline requests `distribution_type: app_store`~~ — **CLOSED** in `d5e64aa7`: no identity is pinned for Release any more (automatic signing / CI profiles resolve it); explicit `Apple Development` remains only on the development-signed configs. Verified by a real `flutter build ipa --release`: **ARCHIVE PASS**, conflict error gone. | `d5e64aa7` | **CLOSED** |
| ~~I2~~ | ~~`APS_ENVIRONMENT = production` on a development-signed Profile config~~ — **CLOSED** in `d5e64aa7`: Profile is now `development` (it is what `flutter run --profile` uses on device), Debug `development`, Release `production`. The entitlement stays variable-driven (`$(APS_ENVIRONMENT)`) so provisioning owns the final value — confirmed in the archive, where automatic signing resolved a development profile and reconciled `aps-environment` to `development`. | `d5e64aa7` | **CLOSED** |
| ~~I3~~ | ~~AdMob app id hardcoded as Google's TEST id with no override path~~ — **CLOSED (configuration)**: `Info.plist` now reads `$(ADMOB_APP_ID)`; the build setting is the TEST id on Debug/Profile and `$(ADMOB_APP_ID_IOS)` on Release. Proven end-to-end — a fresh build resolves the value through the new mechanism and the tracked plist contains **zero** ad-id literals. Production **values** remain MANUAL. | `f-config` | **CLOSED (config)** |
| ~~I4~~ | ~~No `ADMOB_INTERSTITIAL_IOS` dart-define in any CI workflow~~ — **CLOSED**: the release workflows now pass all four AdMob inputs (names only, values from the environment) and materialise the native iOS app id via a gitignored `AdMob.xcconfig`. | `codemagic.yaml` | **CLOSED** |
| ~~I5~~ | ~~`DEVELOPMENT_TEAM` mismatch: project-level `965NY7W824` vs target-level `5TWARK8A23`~~ — **CLOSED** in `d5e64aa7` (unified to `5TWARK8A23` at project level while fixing I1). | `d5e64aa7` | **CLOSED** |
| I6 | `GoogleService-Info.plist` `REVERSED_CLIENT_ID` does not match the `CFBundleURLSchemes` entry. Sign-In works only because an explicit `clientId` is passed in code. | `Info.plist:41` vs bundled plist | **P2** |
| I7 | `SKAdNetworkItems` has only 1 entry (Google's own). Minimal attribution coverage if ads are enabled. | `Info.plist:100-106` | **P2** |
| I8 | `Podfile` `platform :ios, '14.0'` vs project deployment target 16.0. | `Podfile:1` | **P2** |
| I9 | Orphan `TargetAttributes` block for a target that no longer exists. | `project.pbxproj:325-332` | **P2** |

---

## 7. Android release readiness

### ANDROID PHYSICAL GATE — **BLOCKED_BY_ENVIRONMENT** (confirmed, not assumed)

Local tooling audit: **no JDK** (`java -version` fails), **no Android SDK** (`ANDROID_HOME`/`ANDROID_SDK_ROOT`
empty, `~/Library/Android` absent), **no `adb`**, **no Android Studio**, **no `gradlew`** in `app/android/`,
**no keystore and no `key.properties`** (only `key.properties.example`).
`flutter doctor` reports `[✗] Android toolchain`.

A release-signed Android build is **not possible on this machine**. By design the build fails fast rather
than falling back to the debug key.

### Correction to a standing assumption — Android capture is NOT merely device-blocked

Automatic Android SMS capture is **manifest-disabled in source**: `RECEIVE_SMS` and the
`SmsCaptureReceiver` declaration are both inside comment blocks, pending a **Google Play Permissions
Declaration** for SMS money-management plus prominent in-app disclosure. There is also **no UI** to enable
it, and `CapturedMessageSource` has no `androidSms` value. Kotlin capture code exists and is complete,
but in the shipping build it is dead code.

The only live Android capture path is **share-to-app**.

There is also **no NotificationListenerService anywhere in the repo** — `app/CLAUDE.md`'s "SMS notification
listener" description and parts of `MALI_MASTER_QA/14_SMS_CAPTURE_PIPELINE.md` are **stale and contradict
the code**.

**Implication:** even with an SDK + device + keystore, Android automatic capture would still not work.
Closing it requires a Play policy decision, not just hardware.

### Android blockers

| # | Blocker | Severity |
|---|---|---|
| A1 | No JDK / Android SDK locally → no local Android build or verification. (The `gradlew` part of the earlier report was wrong: `gradlew`/`gradlew.bat`/`gradle-wrapper.jar` are gitignored **by the standard Flutter template** and regenerated by the Flutter tool; only `gradle-wrapper.properties` is tracked, pinning Gradle 9.1.0. Nothing is missing from the repository.) | **ENV** |
| ~~A2~~ | ~~Release signing had no keystore-materialisation step in CI~~ — **CLOSED (pipeline)**: `codemagic.yaml` now decodes `ANDROID_KEYSTORE_BASE64` into the ephemeral `$CM_BUILD_DIR`, exports `ANDROID_KEYSTORE_PATH` for Gradle, and shreds it afterwards; missing inputs fail the step. Gradle already required explicit inputs and never fell back to the debug key. The real **upload key** remains a MANUAL_PREREQUISITE. | **CLOSED (pipeline)** |
| ~~A3~~ | ~~AdMob test application id hardcoded in `AndroidManifest.xml`~~ — **CLOSED (configuration)**: the manifest now uses the `${admobAppId}` placeholder, resolved by Gradle from `ADMOB_APP_ID_ANDROID` (env or property) for release and the TEST id for debug. Static/config verified; **compile BLOCKED_BY_ENVIRONMENT** (no Android toolchain — A1/A2). | **CLOSED (config)** |
| ~~A4~~ | ~~No Android build/compile in any gate — Kotlin never compiled~~ — **CLOSED (local)**: the Android toolchain now exists and debug + release APK/AAB all build (§20.2). Adding an Android compile to CI remains a follow-up. | **CLOSED (local)** |
| A5 | Automatic SMS capture manifest-disabled + no enable UI + Play declaration required | **P1 / MANUAL** |
| A6 | `minSdk`/`targetSdk`/`compileSdk`/NDK inherited from the Flutter SDK, not pinned in-repo | **P2** |

---

## 8. Store readiness

### 8.1 App Store Connect (all MANUAL prerequisites)

- [ ] Apple Developer Program membership active (paid team `5TWARK8A23` in use for signing)
- [ ] App ID `com.youssefsafwat.mali` with capabilities: Push Notifications, App Groups, Sign in with Apple
- [ ] App Group `group.com.youssefsafwat.mali` registered
- [ ] **Distribution** certificate + App Store provisioning profiles (Runner **and** ShareBankMessage) — see blocker I1/I2
- [ ] App Store Connect app record created
- [ ] App name / subtitle (brand: **Qirsh / قِرش**)
- [ ] Privacy policy URL (**required** — app collects financial data)
- [ ] Support URL
- [ ] Screenshots for all required device sizes
- [ ] Description + keywords (Arabic-first)
- [ ] Age rating questionnaire
- [ ] **App Privacy disclosures** — must declare financial data, identifiers if ads are enabled
- [ ] Sign in with Apple present ⇒ Apple's equal-prominence requirement satisfied
- [ ] Export compliance — `ITSAppUsesNonExemptEncryption=false` already set; confirm it matches the
      Argon2id/AES-GCM backup encryption story before submitting
- [ ] Review notes + demo account (reviewers cannot receive real bank SMS — supply a manual-paste walkthrough)

### 8.2 Google Play Console (all MANUAL prerequisites)

- [ ] Play Developer account
- [ ] Application record for `com.youssefsafwat.mali`
- [ ] Play App Signing enrolment (Play holds the **app signing key**)
- [ ] **Upload key** generated, escrowed, and stored in the CI secret store as
      `ANDROID_KEYSTORE_BASE64` + `ANDROID_KEYSTORE_PASSWORD` + `ANDROID_KEY_ALIAS` + `ANDROID_KEY_PASSWORD`
      (pipeline already consumes these — see `docs/ANDROID_RELEASE_SIGNING.md` §4)
- [ ] Register the upload **and** Play App Signing certificate SHA-1/SHA-256 wherever Google Sign-In needs
      them (fingerprints do not exist until the real keys do)
- [ ] Internal testing track before any wider track
- [ ] Store listing, screenshots, privacy policy URL
- [ ] **Data Safety** form (financial data, no IDFA/ads-id unless ads enabled)
- [ ] Content rating questionnaire
- [ ] **Ads declaration** — must say "contains ads" if `enable_report_ads` will ever be on
- [ ] Financial-features declaration if applicable
- [ ] **Account deletion URL** (Play requirement) — backed by `purge-scheduled-deletions`
- [ ] Test access instructions
- [ ] **SMS Permissions Declaration** — only if/when automatic SMS capture is enabled (see A5)

---

## 9. AdMob production readiness (test IDs remain in place)

Current state is correct for pre-release: **Google TEST IDs only**, both platforms.

Required before enabling `enable_report_ads` in production:

**iOS** — AdMob app record · production App ID · report-export **standard Interstitial** unit ID
**Android** — AdMob app record · production App ID · report-export **standard Interstitial** unit ID

Invariants to preserve (all currently verified in code + physical test):
- **Standard interstitial only** — no Rewarded, no RewardedInterstitial
- UMP remains the sole ad-consent authority
- Production IDs are **build/deployment configuration**, never business DB config

**Configuration plumbing — CLOSED (R7 I3/A3).** All four inputs are now build-time injectable and the
repository contains no production identifier:

| Input | Reaches Dart via | Reaches native via |
|---|---|---|
| `ADMOB_APP_ID_IOS` | dart-define | `ADMOB_APP_ID` build setting → `Info.plist` (CI writes `ios/Flutter/AdMob.xcconfig`, gitignored) |
| `ADMOB_INTERSTITIAL_IOS` | dart-define | n/a (Dart supplies the unit id to the SDK) |
| `ADMOB_APP_ID_ANDROID` | dart-define | Gradle `manifestPlaceholders["admobAppId"]` → `AndroidManifest.xml` |
| `ADMOB_INTERSTITIAL_ANDROID` | dart-define | n/a |

Fail-closed contract: a release with any half missing, malformed (app id vs unit id confusion), or set to
Google's TEST publisher resolves to **ads unavailable** — no ad request, no crash, and report export still
completes (fail-open). Debug/profile keep the TEST identifiers, so QA and R6's physical evidence are
unaffected.

**Still MANUAL — production AdMob values** (deliberately NOT obtained in R7): create the iOS and Android
AdMob app records, obtain both production App IDs and both report-export Interstitial unit IDs, complete
Privacy & Messaging, then inject all four at release time.

---

## 10. UMP / privacy readiness

Current evidence (accurate, not upgraded):

| Item | Status |
|---|---|
| Physical iPhone UMP runtime execution | **VERIFIED** (`<UMP SDK>` log from device) |
| Simulator UMP visual flow | **PASS** (consent form + privacy-options entry + Google privacy form) |
| Physical UMP visual rendering | **BLOCKED_BY_ENVIRONMENT** (iOS 26.5 redacts the test-device id; all profile paths rejected) |
| Physical iOS interstitial gate | **PASS** with Google test ad |

Production checklist:
- [ ] AdMob **Privacy & Messaging** — create the GDPR/EEA-UK consent message
- [ ] Configure the consent provider/vendor list
- [ ] Confirm privacy-options entry appears for EEA users (Settings → «خيارات خصوصية الإعلانات»)
- [ ] Align the app privacy policy with the UMP vendor disclosures
- [ ] **Do not add ATT** unless a personalization/IDFA strategy is explicitly adopted

---

## 11. Auth provider readiness

R6 proved that a fresh Supabase project ships with **providers disabled** — production will need explicit
configuration.

| Requirement | Note |
|---|---|
| Google provider enabled | Production project |
| iOS client ID registered | Native Google Sign-In uses an explicit `clientId` in code |
| **Skip nonce checks = ON** | The native SDK hashes its own nonce and never exposes the raw value; without this, sign-in fails |
| Apple provider enabled | Client ID `com.youssefsafwat.mali` |
| Apple key/secret | Rotates (~6 months) — needs a renewal owner and calendar reminder |
| Android Google Sign-In | Requires the release SHA-1/SHA-256 from the Play/upload key (blocked by A2) |
| Redirect URLs | Only if a web/PKCE flow is used |

**No production auth settings were read or changed in R7.**

---

## 12. Feature flag release model

Source defaults verified: `enable_referrals=false`, `enable_report_ads=false`, `enable_coupons=false`.
SQL seeds match (`value='false'`, `rollout_percent=0`).

### Activation order (deploy dark, then prove, then enable)

1. Apply migrations through 0083 · deploy required Edge Functions · set secrets — **all flags OFF**
2. Ship the app build with all flags OFF
3. Prove production smoke: auth, capture, catalog sync, report generation (no ads)
4. Verify `get_entitlement_decision` on a real production account
5. **Referrals**: enable to an internal cohort → small % → wider (referral has no ad dependency)
6. **Report ads**: only after AdMob production IDs (§9) and UMP messaging (§10) are in place

Percentages are deliberately **not** fixed here — no production evidence exists yet to justify a number.

### Kill-switch behaviour (verified)
`syncCatalog` re-runs `FeatureFlagService.init()` on cold start **and on resume**, then invalidates
`reportAdsEnabledProvider` — so turning a flag OFF takes effect **in the same session**, without a restart.
Client defaults fail closed if the flag row is missing.

### Known flag hazards
- `0030`/`0032`/`0039` re-runs **force 8 flags back to OFF** (`ON CONFLICT DO UPDATE`)
- `0015`/`0016`/`0017`/`0020` seed `rollout_percent=100` with `is_active=false` — flipping `is_active`
  jumps straight to **100% of users** with no ramp
- **Coupons have no SQL-side flag gate.** `enable_coupons` is enforced only in app code; the RLS policies
  expose live coupon rows to `anon`/`authenticated` regardless. If the flag is meant to gate *data
  exposure* rather than *UI visibility*, that gap is real.

---

## 13. Financial capability activation (kept separate from product flags)

| Capability | Current | Activation rule |
|---|---|---|
| `exactPush` | `unknown` | Requires positive live verification that PostgREST accepts exact-decimal strings into NUMERIC |
| `exactPull` | `unknown` | Requires positive live verification of NUMERIC::text pull |
| `planningServerCurrency` | `unknown` | Requires 0077 applied **and** verified in the target project |
| `kServerRevisionCas` | `false` | Requires 0068 applied + the 9M/9N live conflict evidence re-proven in the target project |

These must **never** be activated by ordinary percentage rollout. Each requires positive server
verification semantics; `unknown` must continue to fail closed rather than be assumed available.
**R7 did not activate any of them.**

---

## 14. Backup / restore baseline (unchanged in R7)

| Concern | Value |
|---|---|
| Business snapshot schema | **4** |
| Crypto envelope | **3** (AES-256-GCM, Argon2id 64 MiB/3/2, magic `MALIBAK`) |
| Accepted ranges | envelope 1–3, snapshot 1–4 (forward-compat rejected before any DB touch) |
| Destructive-restore preflight | 4-layer chain — structural validation → preparation → planning-currency preflight → mutation guards (journal replay, ownership revalidation, file lease, typed rollback) |
| Exact-money round-trip | covered by dedicated tests |
| Test coverage | 34 dedicated backup/restore test files |

No backup schema change is part of this release.

---

## 15. Capture readiness

| Platform | Code | Device verification |
|---|---|---|
| **iOS** | **CODE_READY** — ShareBankMessage extension, AppIntent in Runner, encrypted App-Group FIFO with peek-then-ack lease, Darwin notification wake-up | **DEVICE_VERIFIED** (Shortcuts path previously exercised on hardware) |
| **Android — share-to-app** | **CODE_READY** | **BLOCKED_BY_ENVIRONMENT** (no device/SDK) |
| **Android — automatic SMS** | **NOT_ACTIVE** — code complete but manifest-disabled, no enable UI, missing `androidSms` source enum | **BLOCKED_BY_POLICY + ENVIRONMENT** — needs a Play Permissions Declaration, not just hardware |

---

## 16. CI / reproducibility

| Item | State |
|---|---|
| Codemagic workflows | 4 — `ios-unsigned-sideload`, `ios-signed-release`, `android-release`, `backend-and-quality-gates` |
| GitHub Actions | 1 job running `tools/ci_gates.sh` on ubuntu |
| Flutter pin | **3.44.2 on Codemagic; UNPINNED on GitHub Actions** (`channel: stable`) — the two CI systems can diverge |
| Secret injection | Codemagic variable groups `supabase`, `google_play`, ASC key integration. GitHub Actions injects **no** secrets |
| Machine-local paths | **None found** in build config — no `/Users/youssef` hardcoding |
| Local-only gate stage | iOS packaging inventory needs a macOS build + provenance sidecar → permanently UNAVAILABLE on Linux CI |

**CI gaps**
1. **Codemagic build workflows bypass `ci_gates.sh`** and run a bare `flutter test`, which is exposed to the
   documented Argon2id 10 s per-segment timeout flake that the canonical gate specifically avoids by
   serializing the `crypto-prod` stage.
2. **No Android build/compile in any gate.**
3. Flutter unpinned on GitHub Actions.
4. `flutter create .` in CI regenerates gitignored platform scaffolding, so the CI tree differs from a dev tree.

---

## 17. Release build configuration (values must come from CI/secrets, never the repo)

| dart-define / setting | Source | Status |
|---|---|---|
| `SUPABASE_URL` | Codemagic `supabase` group | wired |
| `SUPABASE_ANON_KEY` | Codemagic `supabase` group | wired |
| `SENTRY_DSN` | Codemagic `supabase` group | wired |
| `ADMOB_INTERSTITIAL_IOS` | **not wired in CI** | **GAP (I4)** |
| `ADMOB_INTERSTITIAL_ANDROID` | **not wired in CI** | **GAP** |
| AdMob **App ID** (iOS) | hardcoded test literal in Info.plist | **GAP (I3)** |
| AdMob **App ID** (Android) | hardcoded test literal in AndroidManifest | **GAP (A3)** |
| `REPORT_ADS_TEST_OVERRIDE` | QA only; **must never be passed** to a release build | release-inert by construction |
| Android keystore vars | Codemagic `google_play` group + an uploaded keystore file | **file step missing (A2)** |

**No secret values appear in this repository or in this document.**

---

## 18. Rollback / containment plan (prepared — not executed)

Ordered by cost, cheapest first:

1. **Flag kill switch (seconds)** — set `enable_report_ads` and/or `enable_referrals` to `false`/0%.
   Takes effect same-session on cold start *and* resume. This is the primary containment.
2. **Coupons** — `enable_coupons=false` hides the UI. Note it does **not** revoke anon read access to
   live coupon rows (§12 hazard).
3. **Edge function containment** — redeploy the previous function version, or revoke the worker secret to
   halt cron-driven traffic.
4. **Database** — **roll forward only.** There are no rollback scripts for 0081–0083; never attempt a
   schema downgrade against live user data.
5. **App distribution** — halt the App Store phased release; on Play, halt the staged rollout percentage.
6. **Artifact revert** — re-submit the previous build; treat as slow (review latency) and never rely on it
   as the primary rollback.

---

## 19. First-hour / first-day monitoring checklist

| Signal | Where | What "bad" looks like |
|---|---|---|
| Auth failures | Supabase Auth logs | sign-in error spike (the R6 provider-misconfiguration signature) |
| Capture failures | `process-ios-sms` logs, `processed_captures` | ingest errors, dedupe anomalies |
| Edge errors | Function logs | 4xx/5xx spikes, especially `catalog-versions` (blocks all catalog sync) |
| Referral RPC errors | Postgres logs | `apply_referral_code` / `request_referral_qualification` failures |
| Entitlement errors | Postgres logs | `get_entitlement_decision` failures → clients fall to UNKNOWN (no ad; correct but hides breakage) |
| Report-ad load/show | app analytics events | `report_ad_load_failed` / `report_ad_show_failed` rates |
| Report generation | app analytics | `report_export_requested` vs `report_export_completed` divergence |
| Crash rate | Sentry | any regression vs baseline |
| Sync/CAS | app logs | conflict/`PGRST116` anomalies (CAS stays OFF this release) |
| Cron/purge | `notification_retry_queue`, purge audit | queue growth, purge not running (silent NULL-secret no-op) |

No new analytics system is required — all of the above already emit.

---

## 20. Operator checklist (condensed execution order)

1. Confirm pgcrypto is installed in `extensions` (§2.2)
2. Apply migrations `0001 → 0083`; run the §2.5 smoke queries
3. Set all production secrets (§5) **including** the four Vault secrets and `GOOGLE_MAPS_API_KEY`
4. Verify the service-role-vs-Vault auth hazard for the three engagement webhooks (§5)
5. Deploy the 15 REQUIRED Edge Functions (§3); decide on the OPTIONAL set; skip OBSOLETE
6. Create the 3 required cron jobs; drop or ignore the retired reminders job (§4)
7. Configure Auth providers, including **skip nonce checks** for Google (§11)
8. ~~Fix iOS signing blockers I1/I2~~ (done, `d5e64aa7`) — obtain an iOS **Distribution** certificate + App Store profiles, then produce and export a distribution archive (CI or a Mac signed into the paid team)
9. Complete App Store / Play prerequisites (§8)
10. Ship the app with **all flags OFF**; run production smoke
11. Only then: AdMob production IDs (§9) + UMP messaging (§10), then staged flag activation (§12)

---

### 20.1 Authorized Android release sequence (prepared — NOT executed)

1. Create the Google Play Console application for `com.youssefsafwat.mali`
2. Enable **Play App Signing** (Play holds the app signing key)
3. Create the **upload key** (`docs/ANDROID_RELEASE_SIGNING.md` §1) and escrow it
4. Store upload key + credentials in the CI secret store as `ANDROID_KEYSTORE_BASE64`,
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`
5. CI materialises the keystore ephemerally (already implemented — no code change needed)
6. Inject production build configuration (Supabase + the four AdMob inputs, all optional for ads)
7. Build the signed AAB
8. Inspect the artifact's signature and certificate fingerprint before uploading
9. Upload to **internal testing only**, and only when explicitly authorized

Steps 1–9 are deliberately **not** performed by R7.

---

### 20.2 Android build chain — R8 / R8A / R8B evidence

The Android toolchain had never existed on this machine, so the Android build had
never actually run — locally **or in CI**. Standing it up surfaced a real defect that
static review could not have found.

**Toolchain installed (R8)** — JDK 17.0.20.1 · Android SDK platform-36 · build-tools 36.0.0 ·
platform-tools/adb 37.0.1 · NDK 28.2.13676358 · CMake 3.22.1. `flutter doctor`: **Android
toolchain ✓**. Versions were derived from the project (JDK 17 from `VERSION_17`/`JVM_17`;
SDK 36 from Flutter 3.44.2) — **no toolchain was changed to suit a dependency**.

**The defect** — every Android build failed at `:app:compileDebugJavaWithJavac`:

```
GeneratedPluginRegistrant.java:24: error: cannot find symbol
  new com.mr.flutter.plugin.filepicker.FilePickerPlugin()
```

**Root cause** — `file_picker` 11.x asks only "is AGP ≥ 9?" and then skips applying the
Kotlin plugin, assuming AGP 9's *built-in Kotlin*. Built-in Kotlin is gated on the
`android.builtInKotlin` property, and the Flutter template sets it to **false**
(`app/android/gradle.properties:6`). Property false + plugin skipped ⇒ `FilePickerPlugin.kt`
is never compiled.

**Candidates evaluated (each by real build, none assumed)**

| Candidate | Result |
|---|---|
| `file_picker` 11.0.2 (shipped) | ❌ the failure |
| `file_picker` 11.0.3 | ❌ **byte-identical failure** — "numerically closer" was not the fix |
| `file_picker` 12.0.0 | ✅ fixes it — but drags `win32 ^6` → `share_plus` **13** (removes `Share.*`, used by report sharing) → `flutter_secure_storage` **10** (the SQLCipher key store) |
| `dependency_overrides: win32 ^6` | ❌ **non-viable**: `flutter_secure_storage_windows 3.1.2` fails against win32 6.4.0 with 10+ errors, and Dart's `kernel_snapshot` compiles the whole graph — so it breaks the **Android** build too. "Windows isn't shipped" does not save it |

**Adopted (R8B)** — a vendored fork of upstream **11.0.3** carrying **one** backported fix
(`third_party/file_picker/`, provenance in `QIRSH_FORK.md`). It is not an official upstream
release. Base 11.0.3 is newer than the shipped 11.0.2, so the path-traversal fix is retained.
`share_plus` 10.1.4, `flutter_secure_storage` 9.2.4 and `win32` 5.15.0 are all **unchanged**,
and **zero product code** was touched — the 11.x API is API-compatible with the single Qirsh
call site. A drift guard byte-compares the fork against the pristine archive.

**Build evidence (local, QA-signed — not a Play release)**

| Artifact | Result |
|---|---|
| Debug APK | ✅ `app-debug.apk` **200,919,372 B**; NDK/CMake native path (sqlite3mc) compiled |
| Release APK | ✅ `app-release.apk` **102,758,292 B** (102.8 MB) |
| Release AAB | ✅ `app-release.aab` **99,544,519 B** (99.5 MB) — the Play artifact path |
| Signer | `CN=QIRSH QA SIGNING ONLY - NOT PLAY UPLOAD KEY`, SHA-256 `8c3f8438…` |
| Debug-certificate matches | **0** — not debug-signed |
| Package | `com.youssefsafwat.mali`, APK Signature Scheme **v2** |

**A2 upgraded to EXECUTION_VERIFIED** — the full CI chain was executed for real: base64 secret
→ ephemeral materialisation into `$CM_BUILD_DIR` → `ANDROID_KEYSTORE_PATH` → Gradle release
signing → signed APK **and** AAB → signer inspection. The QA keystore was destroyed afterwards;
a leak scan confirms no key material in the repository or scratch. **The real Play upload key
was never created or used.**

**Still open:** ANDROID PHYSICAL remains **BLOCKED_BY_ENVIRONMENT** (no device attached, no
emulator image); automatic SMS remains a **Play policy** prerequisite; the real upload key and
Play Console setup remain **MANUAL_PREREQUISITE**.

---

## 21. Blocker register (severity)

| ID | Blocker | Severity |
|---|---|---|
| ~~I1~~ | ~~iOS Release/Profile pinned to a development signing identity~~ — **CLOSED** (`d5e64aa7`); release ARCHIVE verified | **CLOSED** |
| ~~I2~~ | ~~`APS_ENVIRONMENT=production` with a development identity~~ — **CLOSED** (`d5e64aa7`); provisioning now owns the final APS value | **CLOSED** |
| ~~I3/A3~~ | ~~AdMob test app IDs hardcoded on both platforms, no override path~~ — **CLOSED as a code/config blocker** (`ADMOB_APP_ID_*` plumbing, iOS build-verified, Android static-verified). Production **values** remain **MANUAL_PREREQUISITE** | **CLOSED (config)** |
| ~~A2~~ | ~~Android release signing has no keystore-materialisation step in CI~~ — **CLOSED (pipeline)**; real upload key + Play enrolment remain MANUAL | **CLOSED (pipeline)** |
| PROD-1 | All production secrets unset (§5) — **OPERATOR_PACKAGE_READY / EXECUTION_NOT_AUTHORIZED** (package §5, §6) | **P0 / MANUAL** |
| PROD-2 | Production migrations 0001–0083 not applied — **OPERATOR_PACKAGE_READY / EXECUTION_NOT_AUTHORIZED** (package §2, §3) | **P0 / MANUAL** |
| PROD-3 | Production Edge Functions not deployed; cron not created — **OPERATOR_PACKAGE_READY / EXECUTION_NOT_AUTHORIZED** (package §4, §7) | **P0 / MANUAL** |
| PROD-4 | Production Auth providers unconfigured (R6 precedent) — **OPERATOR_PACKAGE_READY / EXECUTION_NOT_AUTHORIZED** (package §8) | **P0 / MANUAL** |
| STORE-1 | App Store Connect record + assets + privacy disclosures | **MANUAL** |
| STORE-2 | Play Console record, Data Safety, ads declaration, deletion URL | **MANUAL** |
| ~~I4~~ | ~~`ADMOB_INTERSTITIAL_*` not wired into CI~~ — **CLOSED** (all four inputs wired, names only) | **CLOSED** |
| C1 | Codemagic build workflows bypass `ci_gates.sh` (Argon2 flake exposure) | **P1** |
| A4 | No Android compile in any gate — Kotlin never compiled | **P1** |
| A5 | Android automatic SMS capture disabled pending Play declaration | **P1 / MANUAL** |
| SEC-1 | 3 engagement webhooks may 403 on service-role value mismatch | **P1** |
| DB-1 | No rollback scripts for 0081/0082/0083 (forward-fix only) | **P1 (accepted)** |
| DB-2 | Coupons have no SQL-side flag gate — anon reads live coupons regardless | **P1** |
| DB-3 | `coupon_categories` has no seed; coupon catalog unusable until seeded | **P2** |
| I5–I9 | Team mismatch, stale GoogleService plist, 1-entry SKAdNetwork, Podfile/target mismatch, orphan target attrs | **P2** |
| A6 | Android SDK levels not pinned in-repo | **P2** |
| ENV-1 | Android toolchain/device absent locally | **ENV** |
| ENV-2 | Physical UMP visual rendering unobtainable on iOS 26.5 | **ENV** |
| ~~GATE-1~~ | ~~`node contract` stage fails on stale test-side assertions~~ — **CLOSED** in `6667dcc7` (test-only); canonical gate now 12/0/1 | **CLOSED** |
| DOC-1 | Stale docs contradicting code (Android capture, iOS shortcuts, CLAUDE.md, old checklists) | **P2** |

---

## 22. GO / NO-GO matrix

| Domain | Status |
|---|---|
| CODE | **READY_FLAG_OFF** |
| IOS | **MANUAL_PREREQUISITE** — signing model fixed (I1/I2 CLOSED, `d5e64aa7`): BUILD PASS, ARCHIVE PASS. **EXPORT BLOCKED locally** — no `iOS Distribution` certificate and no Xcode account on this Mac, so App Store export/upload remains a manual/CI step. Test AdMob app id (I3) still open and tracked separately |
| ANDROID | **READY_FLAG_OFF (build)** — toolchain installed, debug + release APK/AAB build, and the A2 signing pipeline is now **EXECUTION_VERIFIED** with a QA key (§20.2). **PHYSICAL remains BLOCKED_BY_ENVIRONMENT** (no device). Automatic SMS still blocked by Play policy; real upload key still MANUAL |
| SERVER | **READY_FLAG_OFF** (0083 verified on staging; not applied to production) |
| STAGING | **READY** |
| PRODUCTION_CONFIG | **MANUAL_PREREQUISITE** (secrets, migrations, functions, cron all unset) |
| AUTH | **MANUAL_PREREQUISITE** |
| APNS | **MANUAL_PREREQUISITE** |
| ADMOB | **MANUAL_PREREQUISITE** — configuration plumbing CLOSED (I3/A3); what remains is obtaining and injecting the four production values, plus Privacy & Messaging. Report ads stay **flag-off** regardless |
| UMP | **READY_FLAG_OFF** (physical visual = BLOCKED_BY_ENVIRONMENT) |
| REFERRALS | **READY_FLAG_OFF** |
| REPORT_ADS | **READY_FLAG_OFF** |
| CAPTURE | iOS **READY** · Android share **READY_FLAG_OFF** · Android SMS **BLOCKED** (policy + env) |
| BACKUP | **READY** |
| CI | **READY_FLAG_OFF** — canonical gate **12 passed / 0 failed / 1 unavailable** (iOS packaging provenance only, not a pass). Residual, non-blocking for a flags-OFF release: Codemagic build workflows still bypass the gate (C1) and no Android compile exists in any gate (A4) |
| APP_STORE | **MANUAL_PREREQUISITE** |
| PLAY_STORE | **MANUAL_PREREQUISITE** — Play Console app, Play App Signing enrolment, upload key creation + CI secret storage, listing/Data Safety/ads declaration |
| OBSERVABILITY | **READY** |
| ROLLBACK | **READY** (flag-first; DB forward-fix only) |

---

## 23. Classification

**R7 FINAL RELEASE READINESS — BLOCKED**

Local verification is green — the canonical gate is **12 passed / 0 failed / 1 unavailable** (§1.1) and
GATE-1 is closed. That verdict covers code and contract surfaces only; **it does not move this
classification**. The codebase is release-quality and safe to ship dark (all flags OFF), but production
cannot be entered until these are closed:

**P0 — cannot ship**
1. ~~**I1 + I2**~~ — **CLOSED** (`d5e64aa7`). The signing model is now distribution-capable and a real
   release ARCHIVE succeeds locally. What remains is not a code defect: **App Store EXPORT requires an
   iOS Distribution certificate and an Xcode/ASC account**, neither of which exists on this Mac — a
   MANUAL/CI prerequisite (see §8.1).
2. **PROD-1..4** — production has no migrations, no Edge Functions, no secrets, no cron, no auth providers
   (all deliberately untouched). These are now **OPERATOR_PACKAGE_READY / EXECUTION_NOT_AUTHORIZED**: the
   exact executable runbook is `docs/PRODUCTION_ROLLOUT_OPERATOR_PACKAGE.md`, built with **zero**
   production contact. Preparation is not deployment evidence — they stay P0 until an authorized
   operator actually executes them.
3. ~~**I3/A3**~~ — **CLOSED** as a code/configuration blocker: both platforms now take their AdMob app id
   from build configuration and fail closed for ads when it is absent. Obtaining and injecting the four
   production values (and Privacy & Messaging) is a **MANUAL_PREREQUISITE**, not a code defect.
4. ~~**A2**~~ — **CLOSED** as a pipeline blocker: the release workflow materialises the upload keystore
   from an encrypted secret, fails closed without it, and never signs with the debug key. Creating the
   real **upload key** and enrolling in Play App Signing remain **MANUAL_PREREQUISITE**, and the Android
   **build** itself is still **BLOCKED_BY_ENVIRONMENT** (no JDK/SDK here).

**Not blocking a flags-OFF release:** everything classified P1/P2/ENV above, provided
`enable_report_ads`, `enable_referrals` and `enable_coupons` all remain false.

**Android** remains separately **BLOCKED_BY_ENVIRONMENT**, and its automatic-capture story is additionally
blocked by Google Play policy — not by hardware alone.

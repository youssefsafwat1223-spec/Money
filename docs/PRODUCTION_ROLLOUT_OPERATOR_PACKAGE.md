# PRODUCTION ROLLOUT — OPERATOR PACKAGE

**Status: PREPARED, NOT EXECUTED.** Every command in this document is labelled
**FUTURE COMMAND — DO NOT RUN DURING R7**. Nothing here has been run against production.

This package is written to be executable later by a competent operator **without** any memory of the
session that produced it. It was built entirely from repository source, migration files, and evidence
already proven on validation staging — **with zero production contact**.

| | |
|---|---|
| Prepared at | 2026-08-22 |
| Source baseline | branch `feat/phase1-data-integrity`, R7 closures through `933ae0aa` |
| Canonical gate at preparation time | 12 passed · 0 failed · 1 unavailable (iOS packaging provenance) |
| Companion document | `docs/FINAL_RELEASE_READINESS.md` (readiness verdict + blocker register) |
| External prerequisites | `docs/MANUAL_RELEASE_PREREQUISITES.md` (accounts, keys, store metadata, privacy) |

---

## 0. PRODUCTION IDENTITY GUARD — read before anything else

| Role | Project ref | Rule |
|---|---|---|
| **PRODUCTION** | `vrombzdgwqjjiijbidqb` | Target only under explicit, current authorization |
| **Validation staging** | `bdhqjijscwdzqwqanygv` | Where 0083 + the referral/entitlement E2E were proven |
| **Evidence staging** | `dpdukyozedajelflkeix` | Do not touch |

**Guard every command.** Paste this ahead of any production session and abort if it prints anything but
the production ref:

```bash
# FUTURE COMMAND — DO NOT RUN DURING R7
REF="vrombzdgwqjjiijbidqb"
case "$REF" in
  bdhqjijscwdzqwqanygv|dpdukyozedajelflkeix)
    echo "ABORT: this is a staging ref, not production"; exit 2;;
esac
echo "target = $REF"
```

Never print, echo, log, or commit a service-role key, OAuth secret, APNs key, or keystore password.

---

## 1. PROD-1..4 — exact definitions

Canonical grouping, preserved from `docs/FINAL_RELEASE_READINESS.md` §21:

| ID | Exact definition | Covers |
|---|---|---|
| **PROD-1** | Production **secrets** are unset | Edge Function env secrets + the four SQL **Vault** secrets |
| **PROD-2** | Production **migrations** `0001…0083` not applied | Schema, RLS, GRANTs, RPCs, storage bucket |
| **PROD-3** | Production **Edge Functions** not deployed; **cron** not created | 24 functions in source + 4 pg_cron jobs |
| **PROD-4** | Production **Auth providers** unconfigured | Google + Apple (the R6 staging precedent) |

All four are **MANUAL / operator-executed**. None is a code defect; the code side is closed.

---

## 2. PREFLIGHT — future authorized production read-only

Run these **first**, in a session explicitly authorized for production. They mutate nothing.
Anything they cannot answer stays `REQUIRES_AUTHORIZED_PRODUCTION_INSPECTION` — never guessed.

```sql
-- FUTURE COMMAND — DO NOT RUN DURING R7
-- P1. Migration ceiling actually applied in production
SELECT version FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 10;
-- Compare against the repository's 83 files, 0001…0083 dense and gapless.

-- P2. Extensions and, critically, WHICH SCHEMA pgcrypto lives in
SELECT e.extname, n.nspname AS installed_schema
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname IN ('pgcrypto','pg_net','pg_cron');
-- REQUIRED: pgcrypto -> extensions   (see §3.2 — this is a hard gate)

-- P3. Conflicting objects that would make 0081/0082/0083 fail mid-way
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN (
 'coupons','coupon_categories','coupon_tags','coupon_tag_links','coupon_metrics_daily',
 'referral_codes','referral_reward_rules','referrals','referral_reward_progress',
 'user_entitlement_state','entitlement_events','referral_reward_grants','referral_admin_audit');
-- EXPECT: no rows before applying. Any row ⇒ STOP and reconcile.

-- P4. Policy / grant drift on tables this release depends on
SELECT schemaname, tablename, count(*) AS policies
FROM pg_policies WHERE schemaname='public' GROUP BY 1,2 ORDER BY 3 DESC LIMIT 20;

-- P5. Existing cron jobs (so §7 does not duplicate them)
SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;

-- P6. Vault secret NAMES present (names only — never select the values)
SELECT name FROM vault.secrets ORDER BY name;
```

```bash
# FUTURE COMMAND — DO NOT RUN DURING R7
# P7. Which functions are already deployed
supabase functions list --project-ref "$REF"
```

**STOP conditions from preflight**
- pgcrypto not in `extensions` → **STOP**, do not apply 0083 (§3.2)
- migration ceiling ahead of / diverged from the repository → **STOP**
- any table from P3 already present → **STOP**, reconcile before applying
- unexpected policies on referral tables → **STOP** (the design is zero-policy)

---

## 3. PROD-2 — migration operator plan

### 3.1 Sequence
Apply `0001 → 0083` in numeric order. 83 files, dense and gapless. **No `0084` exists and none is
required for this release.**

### 3.2 Hard precondition — pgcrypto schema qualification
`0083` calls pgcrypto **schema-qualified** at exactly three sites:

| Line | Call |
|---|---|
| `0083:447` | `extensions.gen_random_bytes(16)` — `generate_referral_code()` |
| `0083:556` | `extensions.digest(…)` — `apply_entitlement_mutation()` |
| `0083:1071` | `extensions.digest(…)` — `referral_admin_fingerprint()` |

All 21 functions in 0083 pin `SET search_path = pg_catalog, public, pg_temp`, which **excludes**
`extensions`. This is the exact defect that failed on real Postgres during R5 and was fixed by
qualification. If preflight P2 shows pgcrypto anywhere else, the RPCs will fail at runtime → **STOP**.

Note `0083:30` issues an *unqualified* `CREATE EXTENSION IF NOT EXISTS pgcrypto`; on a stock Supabase
project this is a harmless no-op because pgcrypto ships pre-installed in `extensions`.

### 3.3 Other extension requirements
`pg_cron` → schema `cron` (0033/0052/0057/0065) · `pg_net` → `extensions`/`net` (0052/0053/0057/0065).

### 3.4 Transaction expectations
Supabase applies each migration file in its own transaction. A failure aborts **that file** — earlier
files stay applied. There is therefore no all-or-nothing guarantee across the set: on failure, record the
last successful version from P1 and resume forward.

### 3.5 What 0081 / 0082 / 0083 create

| Migration | Objects |
|---|---|
| `0081_coupons` | 4 tables (`coupon_categories`, `coupon_tags`, `coupons`, `coupon_tag_links`), `coupon_is_live()`, a deactivate-guard trigger, RLS + 8 read policies, **storage bucket `coupon-assets`** (public read, 512 KiB, 3 MIME types) |
| `0082_coupon_metrics` | `coupon_metrics_daily`, `record_coupon_event()` (authenticated), RLS with **zero** policies |
| `0083_referral_rewards` | **8 tables**, **22 functions** (10 internal-only · 4 authenticated self-RPCs · 7 service-role admin RPCs), RLS on all 8 with **zero policies** + `REVOKE ALL … FROM anon, authenticated`, replaces `purge_user_data()`, seeds `enable_referrals`/`enable_report_ads` OFF |

### 3.6 Apply

```bash
# FUTURE COMMAND — DO NOT RUN DURING R7
supabase link --project-ref "$REF"
supabase db push          # applies 0001..0083 in order
```

### 3.7 Post-apply validation (the gate before anything else proceeds)

```sql
-- FUTURE COMMAND — DO NOT RUN DURING R7
-- V1. 13 tables exist and RLS is ON for every one
SELECT c.relname, c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN (
 'coupons','coupon_categories','coupon_tags','coupon_tag_links','coupon_metrics_daily',
 'referral_codes','referral_reward_rules','referrals','referral_reward_progress',
 'user_entitlement_state','entitlement_events','referral_reward_grants','referral_admin_audit');
-- EXPECT 13 rows, relrowsecurity = true for ALL.

-- V2. Referral domain carries ZERO policies (by design)
SELECT tablename, count(*) FROM pg_policies WHERE schemaname='public'
  AND tablename IN ('referral_codes','referral_reward_rules','referrals',
                    'referral_reward_progress','user_entitlement_state',
                    'entitlement_events','referral_reward_grants','referral_admin_audit')
GROUP BY 1;
-- EXPECT: no rows. ANY row is a FAILURE.

-- V3. anon/authenticated hold SELECT only on the coupon catalog, nothing else
SELECT table_name, grantee, string_agg(privilege_type,',' ORDER BY privilege_type) AS privs
FROM information_schema.role_table_grants
WHERE table_schema='public' AND grantee IN ('anon','authenticated')
  AND table_name IN ('coupons','coupon_categories','coupon_tags','coupon_tag_links',
                     'coupon_metrics_daily','referral_codes','referrals','user_entitlement_state')
GROUP BY 1,2 ORDER BY 1,2;
-- EXPECT exactly 8 rows (4 coupon tables × 2 roles), all privs = 'SELECT'.
-- Any referral/metrics row, or any INSERT/UPDATE/DELETE/TRUNCATE, is a FAILURE.

-- V4. EXECUTE grant matrix — no anon anywhere (the 0080 bug class)
SELECT has_function_privilege('anon','public.get_entitlement_decision(text)','EXECUTE')  AS anon_decision,
       has_function_privilege('authenticated','public.get_entitlement_decision(text)','EXECUTE') AS auth_decision,
       has_function_privilege('anon','public.record_coupon_event(uuid,text)','EXECUTE')  AS anon_coupon,
       has_function_privilege('authenticated','public.record_coupon_event(uuid,text)','EXECUTE') AS auth_coupon,
       has_function_privilege('service_role','public.admin_mutate_entitlement(text,uuid,uuid,text,text,text,integer)','EXECUTE') AS svc_admin,
       has_function_privilege('authenticated','public.admin_mutate_entitlement(text,uuid,uuid,text,text,text,integer)','EXECUTE') AS auth_admin;
-- EXPECT: anon_* = false, auth_decision = true, auth_coupon = true,
--         svc_admin = true, auth_admin = false.

-- V5. SECURITY DEFINER functions pin a tight search_path
SELECT p.proname, p.prosecdef, p.proconfig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prosecdef AND p.proname LIKE '%referral%';
-- EXPECT every row: proconfig contains 'search_path=pg_catalog, public, pg_temp'.

-- V6. purge_user_data replaced, not duplicated
SELECT count(*) AS overloads, bool_or(prosrc LIKE '%referral%') AS covers_referrals
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='purge_user_data';
-- EXPECT overloads = 1, covers_referrals = true.

-- V7. Storage bucket
SELECT id, public, file_size_limit FROM storage.buckets WHERE id='coupon-assets';
-- EXPECT public=true, file_size_limit=524288.

-- V8. Flags shipped OFF
SELECT key, value, rollout_percent, is_active FROM public.feature_flags
WHERE key IN ('enable_coupons','enable_referrals','enable_report_ads');
-- EXPECT all value='false', rollout_percent=0.
```

**STOP on any V-query mismatch. Do not proceed to function deployment.**

### 3.8 Failure handling / forward-fix posture
See §14. There are **no rollback scripts for 0081/0082/0083** — forward-fix only.

---

## 4. PROD-3a — Edge Function deployment manifest

24 functions in `supabase/functions/` (verified against current source, not a historical list).
Shared helpers live in `_shared/` and deploy with their callers.

### REQUIRED_FOR_FIRST_RELEASE (14)

| # | Function | Auth model | Secrets | Depends on |
|---|---|---|---|---|
| 1 | `catalog-versions` | anon key | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | — |
| 2 | `catalog-delta` | anon key | same | `catalog-versions` |
| 3 | `catalog-flags` | anon key | same | `catalog-versions` |
| 4 | `register-device` | device bootstrap | service role | migrations 0012/0033/0036 |
| 5 | `register-push-token` | device secret | service role + APNs (indirect) | `register-device` |
| 6 | `link-capture-device` | device secret **+** user JWT | service role, `SUPABASE_ANON_KEY` | `register-device`, PROD-4 |
| 7 | `unlink-capture-device` | device secret | service role | `register-device` |
| 8 | `set-device-consent` | device secret | service role | `register-device`; **0071 fails AI closed without it** |
| 9 | `sync-captures` | device secret | service role | `register-device` |
| 10 | `process-ios-sms` | device secret | service role, `GEMINI_API_KEY`, `GEMINI_MODEL`, `APNS_*` | 4,5,8 |
| 11 | `parse-sms` | user JWT + consent | service role, `GEMINI_*` | 8 |
| 12 | `process-notification-retries` | `NOTIFICATION_RETRY_WORKER_SECRET` | that + `APNS_*` | cron job 2 |
| 13 | `purge-scheduled-deletions` | `PURGE_WORKER_SECRET` | that + service role | cron job 3, `purge_user_data()` |
| 14 | `evaluate-gamification` | service-role bearer | service role, `APNS_*` | 0057 trigger, 0073/0074 |

> **`catalog-versions` is a hard gate.** `CatalogSyncService.syncAll` awaits it first
> (`catalog_sync_service.dart:31`) inside a `try` whose `catch` (line 48) abandons the whole sync — so if
> it fails, **flags, announcements, campaigns and coupons are all skipped too**. Deploy and smoke it first.

### OPTIONAL / DEFERRED (8)

| Function | Classification | Why |
|---|---|---|
| `bank-discovery` | **OPTIONAL_FLAGGED** | Client provider is nullable; unknown senders degrade gracefully |
| `enrich-merchant` | **OPTIONAL** | Categorisation falls back locally. Needs `GOOGLE_MAPS_API_KEY` |
| `catalog-announcements` | **OPTIONAL** | Content surface; failure swallowed |
| `catalog-campaigns` | **OPTIONAL** | Banner content only |
| `catalog-coupons` | **OPTIONAL** | Coupons ship flag-OFF (§9) |
| `parser-test` | **OPTIONAL** | Admin tooling; no client dependency |
| `evaluate-budgets` | **OPTIONAL** | Notification-only; local-primary model |
| `evaluate-goals` | **OPTIONAL** | Notification-only |

### OBSOLETE — do not deploy (2)
`cron-daily-reminders` (retired stub returning `{status:'retired'}`) · `merchant-feedback` (returns 410;
its Dart client is never constructed).

### Deployment order
1. `catalog-versions` → smoke → 2. `catalog-delta`, `catalog-flags`
3. `register-device` → `register-push-token`, `link-capture-device`, `unlink-capture-device`, `set-device-consent`, `sync-captures`
4. `process-ios-sms`, `parse-sms` (need Gemini + APNs secrets first)
5. `process-notification-retries`, `purge-scheduled-deletions` (worker secrets first, then cron §7)
6. `evaluate-gamification`

```bash
# FUTURE COMMAND — DO NOT RUN DURING R7
supabase functions deploy catalog-versions --project-ref "$REF"
# …repeat per function, in the order above
```

### Post-deploy smoke (per group)

```bash
# FUTURE COMMAND — DO NOT RUN DURING R7
# Catalog reachable and returns a version map
curl -s -H "apikey: $ANON" "https://$REF.supabase.co/functions/v1/catalog-versions" | head -c 300
# Flags reachable and report the three release flags as OFF
curl -s -H "apikey: $ANON" "https://$REF.supabase.co/functions/v1/catalog-flags" | grep -o 'enable_[a-z_]*'
```

---

## 5. PROD-1 — secret-name manifest (NAMES ONLY)

Re-derived from current function source. **No values appear in this document, ever.**

### Edge Function environment secrets

| Name | Required by | Mandatory? | Staging evidence | Production |
|---|---|---|---|---|
| `SUPABASE_URL` | most functions | **Yes** (platform-provided) | proven | auto |
| `SUPABASE_ANON_KEY` | catalog fns, `link-capture-device` | **Yes** (platform-provided) | proven | auto |
| `SUPABASE_SERVICE_ROLE_KEY` | 16 call sites | **Yes** (platform-provided) | proven | auto |
| `APNS_KEY_ID` | `_shared/apns.ts` → 5 functions | **Yes** for push | partial | **MANUAL_PREREQUISITE** |
| `APNS_TEAM_ID` | same | **Yes** for push | partial | **MANUAL_PREREQUISITE** |
| `APNS_BUNDLE_ID` | same (used verbatim as `apns-topic`) | **Yes** for push | partial | **MANUAL_PREREQUISITE** |
| `APNS_PRIVATE_KEY` | same | **Yes** for push | partial | **MANUAL_PREREQUISITE** |
| `GEMINI_API_KEY` | `process-ios-sms`, `parse-sms`, `bank-discovery` | **Yes** for AI capture | proven | **MANUAL_PREREQUISITE** |
| `GEMINI_MODEL` | same | **Yes** (config) | proven | **MANUAL_PREREQUISITE** |
| `NOTIFICATION_RETRY_WORKER_SECRET` | `process-notification-retries` | **Yes** | proven | **MANUAL_PREREQUISITE** |
| `PURGE_WORKER_SECRET` | `purge-scheduled-deletions` | **Yes** | proven | **MANUAL_PREREQUISITE** |
| `GOOGLE_MAPS_API_KEY` | `enrich-merchant` | Optional | unclear | **MANUAL_PREREQUISITE** |

### SQL Vault secrets (separate from Edge env — easy to miss)

| Vault name | Used by | Mandatory? |
|---|---|---|
| `project_url` | every pg_net dispatcher | **Yes** |
| `service_role_key` | engagement webhook dispatchers (0057) | **Yes** if engagement ships |
| `notification_retry_worker_secret` | retry cron dispatcher (0052/0053) | **Yes** |
| `purge_worker_secret` | purge cron dispatcher (0065) | **Yes** |

> **Silent-failure hazard.** Every dispatcher **no-ops when its Vault secret is NULL** — absence looks
> exactly like success. Verify with preflight P6 (names only) and with the §12 health queries.

> **Known auth-value hazard (verify before trusting gamification).** `evaluate-budgets`,
> `evaluate-gamification`, `evaluate-goals` and `cron-daily-reminders` authorise by comparing the caller's
> bearer against their own `SUPABASE_SERVICE_ROLE_KEY`, while their dispatchers send the **Vault**
> `service_role_key`. `process-notification-retries` documents that the platform-reserved env value is
> Supabase-managed and **confirmed to differ** from the project's real service-role JWT — which is why
> that function was migrated to a dedicated worker secret. The other three were not. If the two values
> differ in production, all engagement webhooks return 403 and stop **silently**.
> Classification: `REQUIRES_AUTHORIZED_PRODUCTION_INSPECTION`.

---

## 6. PROD-1b — APNs production package

Operator steps (none performed):

1. Apple Developer → **Keys** → create an **APNs Auth Key** (`.p8`). Record the **Key ID**; the file
   downloads **once** — escrow it immediately.
2. Record the **Team ID** (`5TWARK8A23`).
3. `APNS_BUNDLE_ID` must be exactly **`com.youssefsafwat.mali`** — it is sent verbatim as `apns-topic`.
4. Confirm the **Push Notifications** capability on the App ID (already in the shipping entitlements).
5. Set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` as Edge secrets. Never echo them.
6. Environment routing is automatic: `_shared/apns.ts` selects `api.sandbox.push.apple.com` vs
   `api.push.apple.com` per message, and the app registers `sandbox` in DEBUG / `production` otherwise
   (`AppDelegate.swift:264-269`). A **production** build therefore registers production tokens — do not
   test a production build against sandbox and conclude push is broken.
7. Smoke: sign in on a production build → confirm a row in the device table with an APNs token →
   trigger a capture → observe delivery. Then verify retry: force one failure and confirm
   `notification_retry_queue` drains within ~5 minutes (cron job 2).
8. If all four secrets are absent, `sendCapturePush()` returns `apns_not_configured` and the pipeline
   still functions **without** push — degraded, not broken.

---

## 7. PROD-3b — cron / background job manifest

Created by migrations (§3), so they exist **after** `db push`. Verify rather than create.

| # | Job | Schedule | Target | Secret | Class |
|---|---|---|---|---|---|
| 1 | `prune-processed-captures-daily` | `15 3 * * *` | SQL RPC `run_prune_processed_captures()` | none (pure SQL) | **REQUIRED** |
| 2 | `notification-retry-dispatch-5min` | `*/5 * * * *` | Edge `process-notification-retries` | Vault `project_url` + `notification_retry_worker_secret` | **REQUIRED** |
| 3 | `purge-scheduled-deletions-job` | `30 3 * * *` | Edge `purge-scheduled-deletions` | Vault `project_url` + `purge_worker_secret` | **REQUIRED** |
| 4 | `cron-daily-reminders-job` | `0 0 * * *` | Edge `cron-daily-reminders` (retired stub) | Vault `project_url` + `service_role_key` | **RETIRED/INERT** — consider unscheduling |

Plus **3 DB triggers** on `user_transactions` / `user_goals` firing `evaluate-budgets`,
`evaluate-gamification`, `evaluate-goals` via pg_net (0057).

**Idempotency:** `cron.schedule` upserts by job name, so re-running those migrations is safe.

```sql
-- FUTURE COMMAND — DO NOT RUN DURING R7
SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;          -- expect the 4 above
SELECT count(*) AS pending FROM public.notification_retry_queue;          -- should not grow unboundedly
-- Disable one job (containment, not deletion):
-- SELECT cron.unschedule('cron-daily-reminders-job');
```

---

## 8. PROD-4 — Auth provider package

Separate what is already in the repository from what only the production account can supply.

| Item | Status |
|---|---|
| Native Google Sign-In wiring, explicit iOS client id in code | **REPOSITORY_CONFIGURED** |
| `CFBundleURLSchemes` reversed-client-id entry | **REPOSITORY_CONFIGURED** |
| Sign in with Apple entitlement + capability | **REPOSITORY_CONFIGURED** |
| Google provider enabled on the production project | **PRODUCTION_ACCOUNT_CONFIGURATION_REQUIRED** |
| **Skip nonce checks = ON** for Google | **PRODUCTION_ACCOUNT_CONFIGURATION_REQUIRED** |
| Apple provider enabled + Services ID `com.youssefsafwat.mali` | **PRODUCTION_ACCOUNT_CONFIGURATION_REQUIRED** |
| Apple client secret (JWT from the `.p8`, ~6-month lifetime) | **PRODUCTION_ACCOUNT_CONFIGURATION_REQUIRED** |
| Android Google identity: upload **and** Play App Signing SHA-1/SHA-256 | **PRODUCTION_ACCOUNT_CONFIGURATION_REQUIRED** (fingerprints do not exist until the keys do) |

**Why "skip nonce checks" is mandatory:** the native iOS Google SDK generates and hashes its own nonce
inside the `id_token` and never exposes the raw value, so Supabase's nonce comparison fails without it.
This is exactly the R6 failure mode — on staging both providers were simply **disabled**, and sign-in
failed with a generic Arabic error. Expect the same symptom in production if this step is skipped.

**Apple secret lifecycle:** the client secret is a JWT that expires (max ~6 months). Assign an owner and
a calendar reminder; expiry presents as sudden Apple-only sign-in failure.

Smoke: sign in with Google on a production build; sign in with Apple; confirm `auth.users` rows appear
and `link-capture-device` succeeds.

---

## 9. Catalog / coupons dependency status

| Concern | State |
|---|---|
| `catalog-versions` | **REQUIRED first** — its failure abandons the whole catalog sync (§4) |
| `catalog-flags` | **REQUIRED** — the kill-switch/rollout authority |
| `catalog-delta` | **REQUIRED** — parser/bank catalog |
| Announcements / campaigns | OPTIONAL |
| **Coupons** | **Code present, ships FLAG OFF.** 0081/0082 apply as part of the migration set; `catalog-coupons` is OPTIONAL; the `coupon-assets` bucket is created by 0081; `enable_coupons` defaults **false** in both client and SQL seed |

> **Known gap, deliberately not changed here:** coupons have **no SQL-side flag gate** — `enable_coupons`
> gates only the client UI, while 0081's RLS policies expose *live* coupon rows to `anon`/`authenticated`
> regardless. If the flag is meant to gate data exposure rather than UI visibility, treat that as a
> follow-up. Note also that `coupon_categories` has **no seed data** anywhere in SQL, and
> `coupons.display_category_key` is a NOT NULL FK to it — so the catalog is not insertable until
> categories are seeded out of band.

---

## 10. Referral / entitlement production smoke (0083)

Run **after** §3.7 passes, in this order. Read-only except where noted.

```sql
-- FUTURE COMMAND — DO NOT RUN DURING R7
-- S1. Structure: 8 tables, RLS on, zero policies              (see V1/V2)
-- S2. Grants: 4 authenticated RPCs, 7 service-role admin RPCs (see V4)
-- S3. Entitlement decision for a real signed-in user id
SELECT set_config('request.jwt.claims','{"sub":"<USER_UUID>","role":"authenticated"}',true);
SET LOCAL ROLE authenticated;
SELECT public.get_entitlement_decision('report_export_ad_free');
-- EXPECT {"active":false,"status":"none",…} with a server_now timestamp
--   → the client maps this to VERIFIED_INACTIVE (an authoritative "no"),
--     NOT to UNKNOWN_OR_STALE.

-- S4. Referral summary for the same user (must not leak the counterpart's uuid)
SELECT public.get_referral_summary();

-- S5. Direct table read must return NOTHING even for an authenticated user
SELECT * FROM public.referrals LIMIT 1;      -- EXPECT: 0 rows or a permission error
```

Mobile-path smoke (real client, not SQL): sign in → open Settings → the referral tile is **absent**
while `enable_referrals` is OFF (that is the correct, expected state at launch).

---

## 11. Report-ads production configuration

Build inputs are now supported by the app (R7 I3/A3). **No values in this document.**

| Input | Purpose |
|---|---|
| `ADMOB_APP_ID_IOS` | iOS AdMob application id → `Info.plist` via `ADMOB_APP_ID` **and** dart-define |
| `ADMOB_INTERSTITIAL_IOS` | iOS report-export interstitial unit |
| `ADMOB_APP_ID_ANDROID` | Android application id → manifest placeholder **and** dart-define |
| `ADMOB_INTERSTITIAL_ANDROID` | Android report-export interstitial unit |

Operator prerequisites (all **MANUAL_PREREQUISITE**, none obtained):
create the iOS AdMob app record · obtain the iOS App ID · obtain the iOS Interstitial unit ID ·
create the Android AdMob app record · obtain the Android App ID · obtain the Android Interstitial unit ID ·
complete **Privacy & Messaging** (UMP consent message for EEA/UK).

**Fail-closed contract already enforced:** any half missing, malformed (`~` vs `/` confusion), or set to
Google's TEST publisher ⇒ **ads unavailable** ⇒ no ad request, no crash, report export still completes.
`enable_report_ads` stays **OFF** regardless; ads are enabled only after §13.

---

## 12. Feature flags — initial production state

Deploy **all risky features OFF**. Verified defaults (client `feature_flag_service.dart` + SQL seeds):

| Flag | Initial | Notes |
|---|---|---|
| `enable_report_ads` | **false / 0%** | Seeded by 0083 |
| `enable_referrals` | **false / 0%** | Seeded by 0083 |
| `enable_coupons` | **false / 0%** | Seeded by 0003 |
| `enable_goals`, `enable_announcements` | true | Pre-existing product surfaces |
| `ledger_*`, `planning_*_sync`, `smart_inbox_pull_sync`, `capture_direct_ledger_write` | false / inactive | Sync-authority flags — leave alone |

```sql
-- FUTURE COMMAND — DO NOT RUN DURING R7 — proves OFF state after deployment
SELECT key, value, rollout_percent, is_active FROM public.feature_flags
WHERE key IN ('enable_report_ads','enable_referrals','enable_coupons') ORDER BY key;
-- EXPECT all value='false', rollout_percent=0.
```

**Rollout hazards**
- Re-running `0030` / `0032` / `0039` force-resets 8 flags to OFF via `ON CONFLICT DO UPDATE`. Never
  re-run them after any activation.
- `0015`/`0016`/`0017`/`0020` seed `rollout_percent=100` with `is_active=false` — flipping `is_active`
  jumps straight to **100 %** with no ramp.
- **Kill switch works same-session:** `syncCatalog` re-runs flag init on cold start *and* resume, then
  invalidates the ads provider — turning a flag OFF takes effect without a restart.

No rollout percentages are prescribed here: there is no production evidence yet to justify a number.

---

## 13. Financial capabilities — must stay non-authoritative

Kept deliberately separate from ordinary product flags.

| Capability | Initial state | Activation rule |
|---|---|---|
| `exactPush` | `unknown` | Positive live proof that PostgREST accepts exact-decimal strings into NUMERIC |
| `exactPull` | `unknown` | Positive live proof of NUMERIC::text pull |
| `planningServerCurrency` | `unknown` | 0077 applied **and** verified in the target project |
| `kServerRevisionCas` | `false` | 0068 applied + the 9M/9N live conflict evidence re-proven |

These are **compile-time providers**, not remote flags — no production action can enable them, and none
should be attempted during rollout. `unknown` must continue to fail closed.

---

## 14. Stop conditions, rollback and forward-fix posture

| Step | PASS | STOP | Containment |
|---|---|---|---|
| Preflight | pgcrypto in `extensions`, no conflicting tables, ceiling matches | anything else | Do not apply migrations |
| Migrations | §3.7 V1–V8 all match | any mismatch | Do not deploy functions; forward-fix |
| Secrets | all mandatory names set | any missing | Do not deploy the dependent function |
| Functions | smoke returns 2xx | `catalog-versions` failing | **Do not ship the client build** — the whole catalog sync depends on it |
| Cron | 4 jobs listed, queue drains | queue grows | Unschedule the job; investigate Vault secrets |
| Auth | Google **and** Apple sign-in succeed | either fails | **Do not release capture/cloud**; re-check "skip nonce checks" |
| AdMob/UMP | production ids + consent message in place | incomplete | Report ads stay **OFF** — everything else may still ship |
| Store | distribution export succeeds | signing/account gap | Halt the release; not a code defect |

**Database posture — forward-fix only.** There are **no rollback scripts for 0081/0082/0083**
(`supabase/rollback/` stops at 0062). On a post-apply problem: stop the rollout → disable the relevant
feature flags → isolate the affected function → apply a reviewed forward hotfix. **Do not** write
destructive rollback SQL against live user data merely to have a rollback section, and never attempt a
schema downgrade.

**Ordered containment, cheapest first**
1. Flags OFF (`enable_report_ads` / `enable_referrals` / `enable_coupons`) — takes effect same session
2. Unschedule a misbehaving cron job
3. Redeploy the previous version of a single function, or revoke its worker secret to halt traffic
4. Halt the App Store phased release / Play staged rollout
5. Re-submit the previous build (slow — review latency; never the primary plan)

---

## 15. Monitoring — first 15 minutes / 1 hour / 24 hours

**First 15 minutes** — auth success vs failure (the R6 provider-misconfiguration signature) ·
Edge 4xx/5xx, especially `catalog-versions` · crash rate vs baseline · first capture ingested end-to-end.

**First hour**

```sql
-- FUTURE COMMAND — DO NOT RUN DURING R7
SELECT count(*) FROM auth.users WHERE created_at > now() - interval '1 hour';
SELECT count(*) AS pending FROM public.notification_retry_queue;               -- must not climb
SELECT key, value, rollout_percent FROM public.feature_flags
 WHERE key IN ('enable_report_ads','enable_referrals','enable_coupons');       -- must still be OFF
SELECT count(*) FROM public.user_entitlement_state;                            -- expect 0 at launch
```

**First 24 hours** — cron: confirm `prune-processed-captures-daily` (03:15) and
`purge-scheduled-deletions-job` (03:30) actually ran · APNs delivery vs retry ratio · report generation
success vs `report_export_requested`/`report_export_completed` divergence · referral RPC error rate
(should be ~zero while flag-off) · report-ad load/show failures (should be **zero** while flag-off — any
signal means the flag or config leaked) · sync/CAS anomalies (CAS is OFF this release) · no financial
capability reporting anything other than `unknown`.

No new monitoring vendor is required — all of the above already emit.

---

## 16. Release build input matrix

| Class | Input | Where from |
|---|---|---|
| **Public identifier** | `ADMOB_APP_ID_IOS`, `ADMOB_INTERSTITIAL_IOS`, `ADMOB_APP_ID_ANDROID`, `ADMOB_INTERSTITIAL_ANDROID` | AdMob console → CI env |
| **Public identifier** | `SUPABASE_URL` | Production project |
| **Secret value** | `SUPABASE_ANON_KEY`, `SENTRY_DSN` | CI secret group `supabase` |
| **Secret value** | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | CI secret group `google_play` |
| **Store-side config** | App Store Connect record, distribution cert/profiles; Play Console record, Play App Signing | Apple / Google consoles |
| **Server config** | Everything in §5, §7, §8 | Supabase project |

**Never** pass `REPORT_ADS_TEST_OVERRIDE`, `UMP_DEBUG_FORCE_EEA` or `UMP_DEBUG_TEST_DEVICE` to a release
build (all three are structurally inert in release, but do not supply them).

---

## 17. Manual prerequisites carried forward

**iOS** — Apple Developer membership · **iOS Distribution certificate** + App Store profiles (Runner and
ShareBankMessage) · App Store Connect record, privacy policy URL, support URL, screenshots, description,
age rating, App Privacy disclosures, export compliance, review notes + a demo path (reviewers cannot
receive bank SMS) · production AdMob identifiers · production Auth provider configuration · APNs secrets.
None of these is a code blocker — the signing model itself is closed (R7 I1/I2) and a release **archive**
already succeeds locally; only **export** needs the distribution certificate.

**Android** — JDK · Android SDK · `adb` + a device or emulator · the real **upload key** · Play App
Signing enrolment · Play Console app record · production AdMob identifiers · upload **and** Play App
Signing SHA-1/SHA-256 for Google Sign-In · and, **only if automatic SMS capture is ever to ship**, a
Google Play Permissions Declaration plus prominent in-app disclosure. The signing **pipeline** is closed
(R7 A2); the **build** is `BLOCKED_BY_ENVIRONMENT`.

---

## 18. Future authorized order of operations

1. Authorized production read-only preflight (§2)
2. Verify backup/recovery posture (PITR window, snapshot) before any schema change
3. Apply migrations `0001…0083` (§3.6)
4. Verify DB + security (§3.7 V1–V8) — **gate**
5. Configure secrets: Edge env **and** the four Vault secrets (§5)
6. Deploy the 14 required Edge Functions in dependency order (§4)
7. Verify cron jobs exist and drain (§7)
8. Configure Auth providers, including **skip nonce checks** (§8)
9. Server smoke: catalog, entitlement RPC, referral RPCs, capture path, push (§4, §6, §10)
10. Build production-configured signed apps (§16) — iOS export needs the distribution cert
11. Internal testing / TestFlight validation only
12. Keep `enable_report_ads`, `enable_referrals`, `enable_coupons` **OFF**
13. Controlled activation later, each behind its own evidence gate; financial capabilities stay `unknown`

**None of steps 1–13 has been performed.**

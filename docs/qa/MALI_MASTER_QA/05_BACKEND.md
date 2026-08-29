# 05 — Backend (Supabase)

Related: [03_ARCHITECTURE.md](03_ARCHITECTURE.md), [04_DATABASE.md](04_DATABASE.md), [07_SECURITY.md](07_SECURITY.md), [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md), [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md).

## 1. Supabase project components in use

| Component | Used for |
|---|---|
| Postgres | All catalog + financial + capture-relay data |
| PostgREST (auto-REST over Postgres) | Direct client reads/writes to RLS-scoped `user_*` tables when a Supabase-primary flag is on |
| GoTrue (Auth) | Google Sign-In, Sign in with Apple; issues the JWT used by both PostgREST (RLS) and Edge Functions |
| Edge Functions (Deno) | All capture-pipeline logic, catalog delta sync, admin-panel-facing operations, anything needing a service-role key or third-party API call (Gemini, APNs, Google Places) |
| Storage | `backups` bucket (private), user-initiated encrypted export/import |
| pg_cron | Scheduled maintenance (currently: `processed_captures`/`capture_fingerprints` retention pruning) |

## 2. Edge Functions inventory

| Function | Auth | Purpose |
|---|---|---|
| `process-ios-sms` | Device secret (custom, not a Supabase JWT) | Core iOS capture relay: verify device → idempotency check → rate limit → deterministic parse (+ optional Gemini AI parse) → duplicate fingerprint → store `processed_captures` row → optional direct write to `user_transactions` (flag-gated) → APNs push |
| `sync-captures` | Device secret | Drains unacked `processed_captures` rows for a device (oldest 50), and deletes acked ones |
| `parse-sms` | Supabase JWT (anon or user) | AI-assisted parse used by the in-app (Android/manual-paste) ingest path, distinct from the iOS relay's own AI call |
| `enrich-merchant` | Supabase JWT | Resolves an unknown merchant name to a category via Google Places, writes the result into `merchant_keywords` for future syncs |
| `bank-discovery` | Supabase JWT | Detects a plausible new bank sender pattern and proposes a bank profile |
| `register-device` | anon key | First-run: registers a new `capture_devices` row, issues a device secret |
| `register-push-token` | Device secret | Updates a device's APNs token/environment |
| `link-capture-device` | Device secret + Supabase JWT | Associates an already-registered device with the now-signed-in user (`capture_devices.user_id`) |
| `catalog-delta`, `catalog-announcements`, `catalog-flags`, `catalog-versions` | anon key | Catalog sync surface consumed by `CatalogSyncService`/`FeatureFlagService` |
| `parser-test` | Admin-panel session | Validates a parser regex rule against sample text before publishing it to the catalog |

Shared modules (`_shared/`): `capture_auth.ts` (device verification, constant-time secret compare, CORS/JSON helpers), `apns.ts` (JWT-signed APNs push client, bounded timeout, collapse-id), `ledger.ts` (direct-write path to `user_transactions`, idempotent insert-then-recover-on-23505), `capture_fingerprint.ts` (time-bucketed fingerprint key generation), `feature_flags.ts` (server-side flag/override resolution used to gate direct-write).

## 3. Authentication model

Two independent auth mechanisms coexist by design:

1. **Supabase JWT** (GoTrue) — for the main app's authenticated user, gates RLS on all `user_*` tables and any Edge Function that needs to know "which user."
2. **Device secret** (custom, capture-pipeline-only) — a per-install shared secret issued by `register-device`, hashed and stored in `capture_devices.device_secret_hash`, verified via constant-time compare in `verifyDevice()`. This exists because the iOS App Extension that calls `process-ios-sms` runs **without** a signed-in Supabase session (it must work before the user ever opens the main app, and must keep working even for a guest/unauthenticated capture flow). `capture_devices.user_id` is populated later, once the user signs in and `link-capture-device` is called — this is what enables the direct-write path (§4) to know whose `user_transactions` row to write.

**Never** confuse the two: a device secret is not a substitute for a JWT and grants access only to the four deny-all-RLS capture tables, exclusively through Edge Functions using the service-role key server-side.

## 4. RLS model

- Catalog tables: readable by `anon`, writable only by service role (admin panel goes through a session with elevated claims, not raw anon).
- `user_*` financial tables: `USING (auth.uid() = user_id)` (or equivalent) — a user can only ever see/write their own rows via PostgREST. All access from Flutter to these tables uses the user's own JWT (`supabase.auth.currentSession`), never the service-role key.
- Capture tables: `USING (false) WITH CHECK (false)` — reachable **only** from Edge Functions running with `SUPABASE_SERVICE_ROLE_KEY`, never from any client, authenticated or not. This is intentional defense-in-depth: even a compromised anon/JWT credential cannot read another device's relay data because there is no RLS policy that would ever allow it, for anyone.

## 5. RPCs (Postgres functions)

| RPC | Security | Purpose |
|---|---|---|
| `set_default_account(p_account_id uuid)` | SECURITY INVOKER | Atomically clears the previous default and sets a new one; INVOKER is correct here because RLS already scopes the caller to their own accounts — DEFINER would be an unnecessary privilege escalation |
| `get_user_stats()` | — | Admin-panel-facing aggregate stats (total users, MAU, new-this-month) |
| `bump_capture_rate_limit(p_install_id_hash, p_limit)` | SECURITY DEFINER | Atomic increment-and-check for the 300/day capture rate limit; revoked from `anon`/`authenticated`, service-role only |
| `run_prune_processed_captures()` | SECURITY DEFINER | Scheduled retention job body; revoked from `anon`/`authenticated` |
| `prune_processed_captures()` | SECURITY DEFINER | Legacy retention function (pre-`0033`); superseded by the logging wrapper above but left in place for compatibility |

## 6. Deployment mechanics

```bash
cd supabase
supabase functions deploy <function-name>
# or, to redeploy every function (avoid unless truly necessary):
for fn in catalog-delta catalog-announcements catalog-flags catalog-versions parser-test \
          process-ios-sms sync-captures register-device register-push-token link-capture-device \
          parse-sms enrich-merchant bank-discovery; do
  supabase functions deploy "$fn"
done
```

**Only deploy functions actually affected by a change.** Determine the affected set by searching for imports of any changed shared module:

```bash
grep -rl "_shared/<changed-module>" supabase/functions --include="*.ts"
```

Deploying an unrelated function wastes a deploy slot and widens the verification surface unnecessarily — see [27_DEPLOYMENT_GUIDE.md](27_DEPLOYMENT_GUIDE.md).

## 7. Local verification without a running app

Because there is no separate staging Supabase project, backend logic is verified by:

1. `deno check <file>` — type-check a function/shared module before deploying.
2. `deno test <file>` — run any Deno unit tests for pure logic (e.g. fingerprint bucketing) with zero live dependency.
3. Direct REST calls against the **live** project using a dedicated QA device/user (registered via `register-device`, signed in via a real or QA-provisioned account) — this is the primary way to validate RLS, RPC behavior, idempotency, and pagination authentically without needing a running Flutter app. See [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) for the exact playbooks.
4. Direct SQL via the Supabase Management API's `database/query` endpoint (service-role-equivalent access) for schema/constraint/row-count verification — never used to touch real user data, only for schema-shape checks and QA-row cleanup.

## 8. Admin panel (`admin/`)

Next.js 14 app, port 3001, authenticated via Supabase email/password (no self-serve sign-up — accounts are created manually in the Supabase dashboard). Manages: user stats dashboard, bank/parser catalog, categories, feature flags (including global rollout percentage — see the escalation rule in [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md)), announcements. Not covered further in this handbook beyond this summary; it is a distinct, smaller codebase from the Flutter app.

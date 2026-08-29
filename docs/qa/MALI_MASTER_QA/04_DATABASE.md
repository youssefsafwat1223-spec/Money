# 04 — Database

Related: [03_ARCHITECTURE.md](03_ARCHITECTURE.md), [05_BACKEND.md](05_BACKEND.md), [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md).

> **Source of truth**: `app/lib/data/db/app_database.dart` (Drift) and `supabase/migrations/*.sql` in numeric order (Postgres). This document explains structure and intent; always confirm exact column lists/constraints against those files before writing a migration or a query that depends on them.

## 1. Two databases, two roles

| | Drift (on-device) | Postgres (Supabase) |
|---|---|---|
| Engine | SQLite via SQLCipher (`sqlite3mc`) | PostgreSQL |
| Encryption | At-rest, key in Keychain/Keystore | At-rest (Supabase-managed) + RLS |
| Scope | One user, one device | All users, one project |
| Role today | Authoritative for financial data **unless** the relevant `*_supabase_primary` flag is on for that user | Authoritative for catalog data always; authoritative for financial data **when** the flag is on for that user |
| Migration mechanism | `_targetSchemaVersion` bump + `onUpgrade` migration case in `app_database.dart` | Ordered numbered files in `supabase/migrations/`, applied via `supabase db push` or direct SQL, tracked in `supabase_migrations.schema_migrations` |

## 2. Drift schema (on-device)

Key tables (see `app_database.dart` `_createSchema()` for exact DDL):

- `accounts` — multi-currency accounts (`AccountEntity`): name, currency, type (bank/cash/card), initial/current balance, `is_default`, `sort_order`.
- `transactions` — the core ledger row: amount, currency, `account_id` FK, type (payment/withdrawal/transfer/refund/income/unknown), source (bank/manual/ai_parsed), status (pending/confirmed), category FK (local UUID), `raw_message`, `raw_merchant`, `card_last4`, direction (debit/credit/unknown), `comparison_timestamp` + `comparison_timestamp_source` (sms_body vs received_at — see [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md)), duplicate status/reason, `server_id` (mirrors the Supabase row id once synced).
- `budgets` — per-category or all-expenses budgets, monthly period, `is_active`.
- `goals` / goal contributions — savings goals with target amount and progress.
- `bills`/subscriptions — recurring payment tracking with due dates and reminder scheduling.
- `plans` and plan-transaction links — the budgeting/planning feature's own entities.
- `smart_inbox` — items requiring user review (low-confidence parses, suspicious duplicates).
- `categories` (catalog cache), `banks`/`sms_parsers` (catalog cache), `feature_flags`/`feature_flag_overrides` (catalog cache).
- `dedup_hashes` — capture/duplicate-detection marker store. **Not** a financial table; see [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) for its `capture_payload:` marker namespace and the pruning rule that must exclude it (see the notification-hardening changelog referenced in [18_REGRESSION.md](18_REGRESSION.md)).
- `financial_cache_health` — one row per Supabase-primary-eligible entity type (`accounts`, `transactions`, `budgets`, `goals`, `subscriptions`, `plans`, `smart_inbox`), tracking `dirty`/`last_error`/`marked_at`/`repaired_at` for the rollback-cache-mirror mechanism (see [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §4).
- `sender_bank_mappings` — learned/confirmed mapping from an SMS sender ID to a bank profile, used to resolve which parser rules apply to an unrecognized sender.

Schema versioning: `_targetSchemaVersion` in `app_database.dart` (bump on every schema change; add a corresponding case in the migration `onUpgrade` callback). **Never** skip a version or reuse one.

## 3. Postgres schema (Supabase)

### 3.1 Catalog tables (global, non-user-scoped)

| Table | Purpose |
|---|---|
| `banks` | Bank profiles (name, country, sender IDs) |
| `sms_parsers` | Regex-based parser rules per bank |
| `currencies`, `countries` | Reference data |
| `categories` | Stable category keys + Arabic/English labels |
| `catalog_versions` | Version counters per catalog type, bumped by triggers, used for delta sync |
| `feature_flags` | `key`, `is_active`, `rollout_percent`, description |
| `feature_flag_overrides` | `user_id`, `key`, `enabled` — per-user QA overrides, always wins over rollout bucket |
| `announcements` | In-app announcement banners |
| `profiles` | User profile extension over `auth.users` |
| `backups` | Metadata for user-initiated encrypted backups (Storage bucket `backups`, private) |
| `metrics` | Lightweight app usage metrics |

### 3.2 Financial tables (per-user, RLS-scoped)

Naming convention: `user_<entity>`, one row per user's copy of that entity. Common columns across all of them (confirm exact set per table in its migration file):

- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE`
- `local_id` and/or `client_request_id` — idempotency keys for backfill (`local_id`, preserved exactly from the Drift row) vs normal user-writes (`client_request_id`, a fresh UUID per write attempt)
- `created_at`, `updated_at TIMESTAMPTZ`
- `deleted_at TIMESTAMPTZ NULL` — soft delete; a NULL value means "live row." Financial data is **never** hard-deleted server-side by application code.

Known tables: `user_accounts`, `user_transactions`, `user_budgets`, `user_goals`, `user_goal_contributions`, `user_subscriptions`/`user_bill_payments`, `user_plans`, `user_plan_transaction_links`, `user_smart_inbox`.

`user_transactions` specifics (hardened in migration `0022_ledger_hardening.sql` and `0027`/`0033` bugfixes):

- `source_payload_id TEXT NULL` — correlates with the capture relay (`processed_captures.payload_id`); unique per `(user_id, source_payload_id)`.
- `client_request_id TEXT NULL` — unique per `(user_id, client_request_id)`; the idempotency key for direct UI writes.
- `direction TEXT CHECK (direction IN ('debit','credit','unknown'))`, `transaction_type TEXT CHECK (transaction_type IN ('income','expense','transfer','refund','adjustment','unknown'))` — kept as two separate columns deliberately; see [09_DATA_FLOW.md](09_DATA_FLOW.md) §"Transfer accounting" for why direction and accounting classification are not the same axis.
- `category_id TEXT` — the **stable category key** (e.g. `'restaurants'`), not a UUID (see [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 6).
- `local_account_id TEXT NULL`, `server_account_id UUID REFERENCES user_accounts(id)` — dual reference during the accounts migration window.
- `comparison_timestamp TIMESTAMPTZ`, `comparison_timestamp_source TEXT CHECK (... IN ('sms_body','received_at'))` — see [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) for how this drives duplicate-detection tolerance.
- `balance_after NUMERIC NULL` — additive column (migration `0026`), optional.
- `chk_user_transactions_amount_positive CHECK (amount > 0)`, `chk_user_transactions_currency_format CHECK (currency ~ '^[A-Z]{3}$')`.

`user_accounts` specifics: `set_default_account(p_account_id uuid)` RPC (SECURITY INVOKER — RLS already scopes it correctly, so DEFINER is unnecessary and would be a privilege-escalation smell) atomically clears any existing default and sets the new one in a single transaction, backed by a partial unique index enforcing "at most one default account per user."

### 3.3 Capture pipeline tables (deny-all RLS, service-role-only)

Defined in `0012_ios_capture_pipeline.sql`, hardened in `0033_capture_pipeline_hardening.sql`. **Not** a financial ledger — a short-lived relay. See [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) for full lifecycle.

| Table | Key columns | Notes |
|---|---|---|
| `capture_devices` | `install_id_hash TEXT PRIMARY KEY`, `device_secret_hash`, `platform`, `user_id NULL`, `last_seen_at` | Deny-all RLS; only service-role Edge Functions touch it |
| `processed_captures` | `install_id_hash + payload_id` **composite PRIMARY KEY** (changed from a global `payload_id` PK in migration `0033` — see [18_REGRESSION.md](18_REGRESSION.md)), `status CHECK (IN ('processed','needs_review','duplicate','rejected'))`, `parsed JSONB`, `notification JSONB`, `sanitized_text NULL`, `apns_push_sent_at`, `apns_push_error` | Relay row; deleted on client ack via `sync-captures`, and pruned after 30 days by the scheduled `run_prune_processed_captures()` job (migration `0033`) for anything never acked |
| `capture_fingerprints` | `(install_id_hash, fingerprint)` composite PK, `payload_id` | Duplicate-detection index; fingerprint is time-bucketed for `received_at`-sourced timestamps (10-minute buckets, current+previous) and exact for `sms_body`-sourced ones — see [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md). Pruned after 7 days |
| `capture_rate_limits` | `(install_id_hash, date)` composite PK, `call_count` | Atomic increment via `bump_capture_rate_limit()` RPC (migration `0033`); capped at 300 calls/device/day |

All four tables have `ENABLE ROW LEVEL SECURITY` + a `USING (false) WITH CHECK (false)` deny-all policy — they are reachable **only** via service-role Edge Functions, never directly from the Flutter client.

## 4. Known cross-database gotchas

### 4.1 Category identity mismatch

Supabase stores `category_id` as the **stable string key**; Drift stores it as a **local UUID** foreign-keying `categories.id`. Any Supabase-sourced row displayed in the UI must be translated key → local UUID before use (all UI resolves categories via `catalog.byId()` only). This translation lives in `SupabaseTransactionRepository._fromServerRow` / `_localCategoryIdForKey`. **A bug class to watch for**: any new read path added to a Supabase repository that skips this translation will silently show "غير مصنّف" (Uncategorized) for every transaction — this exact bug was found and fixed once already (see [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) for the pattern of how it was diagnosed).

### 4.2 Partial index / upsert incompatibility

PostgREST's `.upsert(onConflict:)` generates a plain `ON CONFLICT (columns) DO UPDATE` with no `WHERE` clause. Postgres will only infer a **partial** unique index (`CREATE UNIQUE INDEX ... WHERE col IS NOT NULL`) as the conflict target when the `ON CONFLICT` clause's predicate matches the index predicate exactly — which PostgREST cannot express. Any unique index intended as an upsert target **must be a full (non-partial) unique index**; a plain non-partial unique index still treats `NULL` as distinct from `NULL` by Postgres default, so nullable idempotency columns remain correctly unconstrained against each other. This exact bug (error `42P10`) was found live during the accounts/transactions Supabase-primary QA and fixed in migration `0027`.

### 4.3 Half-open date ranges only

Every date-range query against `occurred_at`/`comparison_timestamp` must use `>= from` and `< to`, never `<= to`. See [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 5 and [11_TEST_MATRIX.md](11_TEST_MATRIX.md) for the month-boundary/timezone test scenarios that specifically guard against regressions here.

### 4.4 `dedup_hashes` marker namespace vs pruning

`app_database.dart`'s `pruneOldDedupHashes()` deletes rows by `occurred_at` age. Capture-import markers are stored with a **fixed epoch-0 `occurred_at`** as a namespace signal (`hash LIKE 'capture_payload:%'`), not a real timestamp — they must be excluded from age-based pruning or every prune cycle silently deletes the "already imported" registry, re-opening a duplicate-import window. This was found and fixed as part of the notification/capture pipeline hardening — see [18_REGRESSION.md](18_REGRESSION.md) for the regression test that guards it.

## 5. Migration workflow

See [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 8 and [27_DEPLOYMENT_GUIDE.md](27_DEPLOYMENT_GUIDE.md) for the full apply/rollback/verification procedure. Summary:

1. Write `supabase/migrations/NNNN_description.sql` (next sequential number — check `supabase migration list` and the highest existing file, they must agree).
2. Write the matching `supabase/rollback/NNNN_description_rollback.sql`.
3. Verify against **live row counts and shapes** before applying anything that changes a constraint (see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md)).
4. Apply via `supabase db push` when migration history is in sync, or direct SQL via the Management API/SQL editor when it's a hotfix applied out-of-band — in the latter case, immediately run `supabase migration repair --status applied NNNN` so history stays synchronized (a desynced history is a recurring failure mode — see [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md)).
5. Verify post-apply: constraint shape, row counts unchanged (for additive changes) or explicitly accounted for (for destructive ones), new functions/RPCs exist, RLS unchanged unless intended.

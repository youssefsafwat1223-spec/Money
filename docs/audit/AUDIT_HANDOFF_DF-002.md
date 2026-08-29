<!-- PROVENANCE: copied from `demo-docker/AUDIT_HANDOFF_DF-002.md`, which is an untracked local
     demo/working directory. Audit handoff for DF-002 (owner-table grants), which became migration 0088.
     Tracked here so the authoritative artifact survives loss of that
     directory. The original is left in place; this copy is the one of
     record. -->

# AUDIT HANDOFF — NEW HIGH FINDING (DF-002)

**From:** Demo Crowd (local demo QA session, 2026-08-25)
**To:** Audit/Main session
**Class:** PRODUCT DEFECT — provisioning / disaster recovery
**Proposed severity:** **HIGH**
**Status:** recorded only. **Not fixed.** The audit worktree was not mutated.

---

## 1. Finding statement

> Fresh Supabase provisioning from migrations `0001..0086` is **not
> self-sufficient** for authenticated direct-table access, because the required
> DML grants are absent. Any project created today from these migrations alone
> comes up with a working schema and correct RLS, but with `authenticated`
> lacking `SELECT`/`INSERT`/`UPDATE`/`DELETE` on the tables the app reads and
> writes directly. The existing hosted projects are unaffected only because they
> predate a Supabase default change and carry legacy auto-exposure grants.

The local demo environment only functions because of a **demo compatibility
workaround** (`auto_expose_new_tables = true`), applied solely in
`demo-docker/supabase/config.toml`. That workaround is not a fix and was
deliberately not applied to the audit tree.

---

## 2. Exact missing GRANT model

### 2.1 What the migrations actually grant

58 `GRANT` statements exist across `0001..0086`:

| Kind | Count |
|---|---|
| `GRANT EXECUTE` on functions | **54** |
| `GRANT SELECT` on tables | **4 statements** |
| `GRANT INSERT / UPDATE / DELETE` on tables | **0** |

The only table grants in the entire migration set:

```sql
grant select on table public.admin_users            to authenticated;   -- 0035
grant select on table public.user_xp_levels         to authenticated;   -- 0073
grant select on table public.user_engagement_events to authenticated;   -- 0070
GRANT SELECT ON TABLE coupons, coupon_categories,
                      coupon_tags, coupon_tag_links ...                 -- 0081
```

There is **no `REVOKE`** on any of the affected tables, so the absence is an
omission, not deliberate hardening.

> Note: the presence of those four statements is evidence *for* the finding, not
> against it. The authors knew explicit table grants are required, issued them
> for four cases, and never issued write privileges anywhere.

### 2.2 Observed privilege state on a fresh stack

With default config (`auto_expose_new_tables` unset), on a freshly reset local DB:

```sql
select grantee, string_agg(privilege_type,',')
  from information_schema.role_table_grants
 where table_schema='public' and table_name='user_transactions'
 group by grantee;
```
```
anon          : TRUNCATE,REFERENCES,TRIGGER
authenticated : TRUNCATE,REFERENCES,TRIGGER      <-- no SELECT/INSERT/UPDATE/DELETE
service_role  : TRUNCATE,REFERENCES,TRIGGER
postgres      : TRIGGER,INSERT,SELECT,UPDATE,DELETE,TRUNCATE,REFERENCES
```

Runtime symptom:

```
{"code":"42501",
 "message":"permission denied for table user_transactions",
 "hint":"Grant the required privileges to the current role with:
         GRANT SELECT ON public.user_transactions TO authenticated;"}
```

RLS is **not** the cause and is correctly configured — 60 of 60 public tables
have RLS enabled, and anon correctly reads 0 rows once grants exist.

---

## 3. Affected direct `.from()` call inventory

**52 direct PostgREST table calls across 18 files in `app/lib`**, executed as the
`authenticated` user.

### 3.1 By table

| Table | Calls | Granted by migrations? |
|---|---:|---|
| `user_transactions` | 14 | ❌ none |
| `user_accounts` | 14 | ❌ none |
| `user_plan_transaction_links` | 6 | ❌ none (incl. `.update()`) |
| `notification_logs` | 5 | ❌ none (all 5 are `.upsert()`) |
| `profiles` | 4 | ❌ none (incl. `.upsert()`) |
| `backups` | 3 | ❌ none (incl. `.upsert()`, `.delete()`) |
| `user_smart_inbox` | 2 | ❌ none |
| `user_xp_levels` | 1 | ⚠️ `SELECT` only |
| `user_streaks` | 1 | ❌ none |
| `user_achievements` | 1 | ❌ none |
| `feature_flag_overrides` | 1 | ❌ none |

Even the one granted table (`user_xp_levels`) is `SELECT`-only, so any write to
it fails.

### 3.2 By file

| File | Calls |
|---|---:|
| `features/planning_sync/services/accounts_push_service.dart` | 9 |
| `features/capture/services/ledger_push_service.dart` | 9 |
| `features/capture/services/notification_log_sync_service.dart` | 5 |
| `features/planning_sync/services/planning_child_sync_service.dart` | 4 |
| `core/diagnostics/duplicate_trace_service.dart` | 4 |
| `features/gamification/services/gamification_sync_service.dart` | 3 |
| `features/planning_sync/services/planning_primary_backfill_service.dart` | 2 |
| `features/planning_sync/services/accounts_backfill_service.dart` | 2 |
| `features/capture/services/transactions_backfill_service.dart` | 2 |
| `features/capture/services/smart_inbox_sync_service.dart` | 2 |
| `core/backup/supabase_remote_backup_store.dart` | 2 |
| `core/backup/encrypted_backup_service.dart` | 2 |
| `features/planning_sync/services/accounts_pull_service.dart` | 1 |
| `features/capture/services/ledger_sync_service.dart` | 1 |
| `data/catalog/feature_flag_service.dart` | 1 |
| `core/tracking/user_activity_service.dart` | 1 |
| `core/session/app_session.dart` | 1 |
| `core/auth/account_deletion_service.dart` | 1 |

Confirmed **write** operations against these tables include
`notification_logs.upsert` (×5), `profiles.upsert`, `backups.upsert`,
`backups.delete`, and `user_plan_transaction_links.update`.

**Not affected:** the `catalog-*` Edge Functions and the Admin Dashboard, both of
which use `service_role` server-side and therefore bypass both grants and RLS.

---

## 4. Current Supabase default / compatibility behaviour

Supabase changed the default so that entities newly created in `public` are **not**
auto-exposed to the Data API roles. The CLI states this explicitly, both in
`config.toml` and at runtime:

> `api.auto_expose_new_tables is deprecated and will be removed on **2026-10-30**.
> Remove the field or set it to false to adopt the new default of revoking Data
> API privileges on new entities in the public schema.`

and in `config.toml`:

> *"When unset, new entities are NOT auto-exposed, matching the new cloud default.
> Set to `true` to keep the legacy behaviour of auto-exposing new entities; this
> is deprecated and the field is removed on 2026-10-30 once the always-revoked
> behaviour is permanent."*

Three consequences:
1. **Today**, a new project needs `auto_expose_new_tables = true` to behave like
   the existing ones — a deprecated compatibility switch.
2. **After 2026-10-30** that switch no longer exists. Always-revoked becomes
   permanent and unavoidable.
3. The compatibility switch is a **local CLI config** knob; it is not a property
   the migration set carries with it.

---

## 5. DR / new-project impact

Any of the following produces a broken environment from these migrations alone:

* **Disaster recovery** — rebuilding production into a new project after loss.
* **Region migration** or moving to a new Supabase org/account.
* **Provisioning a new staging/QA/demo project.**
* **Any project created after 2026-10-30**, unconditionally.

Failure mode is not a clean startup error. Schema, RLS, functions and seed data
all apply successfully and the project looks healthy. Auth works. Edge Functions
work. The Admin Dashboard works (service_role). Only the **app's authenticated
direct-table reads and writes** fail, with `42501`, across all 52 call sites —
i.e. sync, backup, notification logging, gamification and planning. This is a
silent-until-exercised defect that would most likely be discovered *during* a
recovery, which is the worst possible moment.

Severity rationale for **HIGH**: no current production impact, but it defeats
disaster recovery, it is time-bombed to a fixed date (2026-10-30), and the
remediation must land before any fresh provisioning is attempted.

---

## 6. Proof that "existing hosted projects work" does not invalidate the defect

The counter-argument would be: production works, therefore there is no defect.
That does not hold, for four independent reasons.

1. **The working projects were provisioned under the old default.** They carry
   grants created by Supabase's legacy auto-exposure event trigger at table
   creation time — state that lives *in those databases*, not in the migration
   set. Nothing in `0001..0086` reproduces it.

2. **The defect reproduces deterministically on a fresh stack.** Applying the
   identical, unmodified migrations `0001..0086` to a clean database with default
   config yields `authenticated : TRUNCATE,REFERENCES,TRIGGER` on
   `user_transactions` and a `42501` on every app read/write. This was observed
   directly in this session, before the workaround was applied.

3. **The demo required a compatibility workaround to function**, which is itself
   the proof. `auto_expose_new_tables = true` had to be set for the environment
   to work at all. A migration set that needs a deprecated CLI compatibility flag
   to reproduce its own production behaviour is by definition not self-sufficient.

4. **The escape hatch expires.** Even the workaround stops being available on
   2026-10-30. After that date the current migration set cannot produce a working
   project by any configuration.

A useful framing: *the migrations describe the schema, but not the privileges the
schema requires.* Production's correctness currently depends on undocumented
database state that no longer gets created.

---

## 7. Recommended forward-only migration approach

Do **not** rely on `auto_expose_new_tables`. Add a new forward-only migration
(e.g. `0087_data_api_grants.sql`) that states the privilege model explicitly, so
RLS remains the only access-control layer and the migration set stands alone.

Sketch — to be reviewed and completed by the Audit/Main session, not applied from here:

```sql
-- 0087_data_api_grants.sql
-- Make the Data API privilege model explicit. RLS (already enabled on all 60
-- public tables) remains the sole access-control layer; these grants only make
-- the tables reachable through PostgREST at all.

-- User-owned tables the app reads and writes directly as `authenticated`.
grant select, insert, update, delete on table
  public.user_transactions,
  public.user_accounts,
  public.user_plan_transaction_links,
  public.notification_logs,
  public.user_smart_inbox,
  public.user_streaks,
  public.user_achievements,
  public.user_xp_levels,
  public.feature_flag_overrides,
  public.profiles,
  public.backups
to authenticated;

-- Catalog read paths that are intentionally anonymous.
grant select on table
  public.banks, public.sms_parsers, public.categories,
  public.currencies, public.countries, public.feature_flags,
  public.announcements, public.catalog_versions
to anon, authenticated;   -- see DF-005: current policies are anon-only
```

Design notes for whoever lands this:

* **Enumerate tables explicitly.** Do not use `GRANT ... ON ALL TABLES IN SCHEMA
  public`, and do not add an `ALTER DEFAULT PRIVILEGES` blanket — either would
  silently re-expose future tables and recreate the class of problem Supabase's
  new default is designed to prevent.
* **Grant the narrowest verb set per table.** Several of the 11 are read-only in
  practice; the sketch above is deliberately broad and should be tightened
  against the real call sites in §3.
* **Deliberately exclude** the service-role-only tables (`referral_codes`,
  `capture_*`, `metrics_rate_limits`, `ai_request_idempotency`, …), which
  correctly have no anon/authenticated grants today.
* **Idempotent and forward-only.** `GRANT` is naturally idempotent; applying this
  to the existing hosted projects should be a no-op that simply makes their
  current implicit state explicit — which is the point.
* **Verify with a fresh-stack test**, not against an existing project: reset a
  local DB with `auto_expose_new_tables` **unset**, apply `0001..0087`, and assert
  every call site in §3 succeeds. That test is the real regression guard, and its
  absence is why this went unnoticed.
* **Reconcile with DF-005** (catalog RLS policies are scoped to role `anon` only)
  before granting catalog `SELECT` to `authenticated`, so grants and policies agree.

---

## 8. Reproduction from scratch

```bash
cd demo-docker
# 1. remove the demo workaround
#    comment out `auto_expose_new_tables = true` in supabase/config.toml
supabase stop --workdir . --no-backup
supabase start --workdir . -x postgres-meta,studio   # applies 0001..0086

# 2. observe the missing privileges
docker exec -i supabase_db_qirsh-demo psql -U postgres -d postgres -c "
  select grantee, string_agg(privilege_type,',')
    from information_schema.role_table_grants
   where table_schema='public' and table_name='user_transactions'
   group by grantee;"

# 3. observe the runtime failure as an authenticated user
#    -> 42501 permission denied for table user_transactions
```

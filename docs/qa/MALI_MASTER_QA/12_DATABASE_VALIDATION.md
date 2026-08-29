# 12 — Database Validation Playbooks

Related: [04_DATABASE.md](04_DATABASE.md), [05_BACKEND.md](05_BACKEND.md), [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `SEC-001`/`SEC-002`.

This document is the concrete "how" for validating live database state without a running Flutter app — the primary method used to verify RLS, RPCs, idempotency, and migrations against the real (only) Supabase project.

## 1. Access methods

Two safe, non-destructive ways to query the live project directly:

1. **Supabase Management API SQL endpoint** (uses the CLI's own stored access token — has schema-level access equivalent to a superuser for query purposes; use for read-only verification and narrowly-scoped QA-row cleanup only):
   ```bash
   TOKEN=$(cat ~/.supabase/access-token)
   curl -s -X POST "https://api.supabase.com/v1/projects/<project-ref>/database/query" \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"query":"select 1 as ok"}'
   ```
2. **Direct REST calls as a specific QA user's JWT** — the *correct* way to verify RLS actually blocks/allows what it should, since the Management API bypasses RLS entirely and therefore cannot validate it.
   ```bash
   curl -s "$SUPABASE_URL/rest/v1/user_transactions?select=*" \
     -H "apikey: $ANON_KEY" -H "Authorization: Bearer $QA_USER_JWT"
   ```

**Never** use the service-role key from a local shell against production data casually — treat it with the same care as a production database root credential, and prefer the Management API (scoped to your own CLI session) for ad-hoc read verification.

## 2. Pre-migration checklist queries

Before writing or applying any migration that changes a constraint:

```sql
-- Row count and shape of the table being changed
select count(*) from <table>;

-- Does the constraint you're about to add already have violations?
select <columns> from <table> group by <columns> having count(*) > 1;  -- for a new UNIQUE

-- Is the column you're about to make NOT NULL currently ever NULL?
select count(*) from <table> where <column> is null;

-- Existing constraint definitions on a table
select conname, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid = '<table>'::regclass;

-- Existing indexes on a table (check for partial-index/upsert incompatibility, see 04_DATABASE.md §4.2)
select indexname, indexdef from pg_indexes where tablename = '<table>';
```

## 3. Post-migration verification queries

```sql
-- Confirm the new constraint/index exists in the expected (non-partial, if upsert-targeted) form
select conname, pg_get_constraintdef(oid) as def
from pg_constraint where conrelid = '<table>'::regclass and contype = 'p';

-- Confirm row count is unchanged (additive migration) or explicitly accounted for
select count(*) from <table>;

-- Confirm a new function/RPC exists and has the expected security mode
select proname, prosecdef from pg_proc where proname = '<function_name>';
-- prosecdef = true means SECURITY DEFINER; false means SECURITY INVOKER — verify against
-- what the migration intended (04_DATABASE.md / 05_BACKEND.md §5 for which RPCs use which).

-- Confirm RLS is still enabled and policies match expectation
select relrowsecurity from pg_class where relname = '<table>';
select polname, pg_get_expr(polqual, polrelid) as using_expr
from pg_policy where polrelid = '<table>'::regclass;
```

## 4. Migration history synchronization check

```bash
cd supabase
supabase migration list
```

Every migration file present locally must show as applied on **both** the local and remote columns. If a migration was applied via direct SQL (Management API) rather than `supabase db push`, immediately run:

```bash
supabase migration repair --status applied <version>
```

A desynced history is a recurring failure mode — always re-run `supabase migration list` after any out-of-band SQL apply to confirm it converged.

## 5. pg_cron verification

```sql
-- Is the extension installed?
select extname, extversion from pg_extension where extname = 'pg_cron';

-- What jobs are scheduled?
select jobid, jobname, schedule, command, active from cron.job;

-- Has the job actually run, and did it succeed? (cron.job_run_details, if enabled/retained)
select jobid, status, return_message, start_time, end_time
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = '<job-name>')
order by start_time desc limit 5;
```

If `pg_cron` is unavailable on the linked project (some Supabase plans/regions may not expose it), **stop and report the exact blocker** rather than faking success — see [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md) Rule 3 and propose the scheduled-Edge-Function alternative (an Edge Function invoked by an external scheduler, or Supabase's own "Scheduled Functions" feature if available on the plan).

## 6. Safety verification queries (run before AND after any live QA session)

```sql
-- Total row counts for real (non-QA) data — must be unchanged by a QA session
select count(*) from user_accounts where user_id not in (select id from auth.users where email like '%qa%');
select count(*) from user_transactions where user_id not in (select id from auth.users where email like '%qa%');

-- Confirm no QA rows leaked into a real user's scope (should always be zero)
select count(*) from feature_flag_overrides fo
join auth.users u on u.id = fo.user_id
where u.email not like '%qa%' and fo.key like '%_supabase_primary';

-- Confirm global flags are still OFF after any QA session
select key, is_active, rollout_percent from feature_flags
where key like '%supabase_primary%' or key in ('capture_direct_supabase_write', 'ledger_dual_write');
-- Expected: is_active = false (or rollout_percent = 0) for every row, unless a cutover was explicitly authorized.
```

## 7. QA-row cleanup queries (run only against rows unambiguously owned by QA)

```sql
-- Capture-pipeline QA cleanup, scoped by a known QA install_id_hash
delete from processed_captures where install_id_hash = '<qa_install_id_hash>';
delete from capture_fingerprints where install_id_hash = '<qa_install_id_hash>';
delete from capture_rate_limits where install_id_hash = '<qa_install_id_hash>';
delete from capture_devices where install_id_hash = '<qa_install_id_hash>';

-- Feature-flag override cleanup for a QA user
delete from feature_flag_overrides where user_id = '<qa_user_id>';
```

**Never** run a `delete from <table>;` with no `WHERE` clause against any table in this project, under any circumstance, including "cleanup." Always scope by an unambiguous QA identifier and verify the row count matches expectation (`RETURNING *` or a preceding `SELECT` with the same predicate) before deleting.

## 8. Live smoke-test pattern (no running app required)

```bash
# 1. Register a throwaway QA device
SECRET=$(curl -s -X POST "$URL/functions/v1/register-device" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"installId":"qa-<description>-<date>"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['deviceSecret'])")

# 2. Exercise the endpoint under test
curl -s -X POST "$URL/functions/v1/<function>" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"payloadId":"smoke_test_<description>", ...}'

# 3. Verify via SQL (§3/§6 above)

# 4. Clean up (§7 above)
```

This pattern was used to verify the notification/capture pipeline hardening's idempotent-replay, rate-limit RPC, and retention-prune behavior directly against the live project without any device or simulator involved.

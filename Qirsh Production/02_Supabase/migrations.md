# Migrations 0001 → 0092

Detail for runbook [§3.2](../QIRSH_PRODUCTION_RELEASE_RUNBOOK.md#32---auth--apply-migrations-0001--0092).

Canonical files: `supabase/migrations/` (do not move — tooling resolves them).

## Local evidence already captured

`supabase/tools/dryrun_migrations.sh` applies the chain to a throwaway
`postgres:17` container started with `--network none`. The script **refuses to
run** if the container has a network, and never invokes the Supabase CLI, so the
locally-linked ref cannot be involved.

Results on a fresh database:

- all **91** migrations apply cleanly in filename order;
- rollbacks `0086/0087/0089/0090/0091` execute;
- `0084`–`0091` re-apply after rollback (roll-back → fix → roll-forward works).

**What that proves:** every statement parses, every object exists before it is
referenced, and filename order is a valid apply order.
**What it does not prove:** behaviour. `pg_cron`, `pg_net` and `vault` are stubs;
RLS policies compile without being exercised.

## Prerequisites

Extensions and the `backups` bucket must exist first (runbook §2.3) — migrations
attach policies to the bucket but do not create it.

## Applying

```bash
cat supabase/.temp/project-ref     # prove the target

for f in supabase/migrations/*.sql; do
  echo "── $f"
  psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || { echo "STOPPED AT $f"; break; }
done
```

One file at a time so a failure stops at a known point. `supabase db push` works
but applies everything in one pass.

## Verifying

```sql
select count(*) from information_schema.tables where table_schema='public';
select validation_status, count(*) from public.sms_parsers group by 1;
select count(*) from public.categories;      -- 21, including the all_expenses sentinel
select count(*) from pg_policies where schemaname='public';
```

## When a migration fails

1. **Read the error.** Most failures are a missing prerequisite from §2.3, not a
   bad migration.
2. **Do not blindly retry.** A partially-applied non-transactional migration can
   make a retry fail differently and confusingly.
3. Reversals for 0084+ are in `supabase/rollback/`. **Read the file header
   first** — see `../11_Rollback_Recovery/migration_recovery.md`.

## Migrations with consequences worth knowing

| # | Consequence |
|---|---|
| `0087` | demotes evidence-free `passed` parsers; `catalog-delta` serves only passed rules, so **some banks stop parsing** until their rules gain golden-test evidence |
| `0088` | declares grants that previously came from platform defaults — **revoking them breaks the app**, it is not a return to a prior state |
| `0089` | installs a trigger so force-update arming must go through `arm_force_update()` |
| `0091` | widens the parser decimal cap `{1,2}` → `{1,3}`; rolling back re-truncates 3-decimal currencies at capture, which is money corruption |

# Backend Dependencies — Who Creates What

The distinction that matters: migrations create database objects; they cannot
create Supabase **platform** settings. Those are manual.

## Manual — Youssef, in the Dashboard

| Dependency | Where | Why manual |
|---|---|---|
| `pgcrypto`, `pg_cron`, `pg_net` | Database → Extensions | platform-level; migrations only *use* them |
| `backups` storage bucket (private) | Storage → New bucket | policies attach to a bucket that must already exist |
| Apple provider | Authentication → Providers | needs Apple credentials |
| Google provider + **skip nonce checks ON** | Authentication → Providers | needs the iOS client id; the nonce setting breaks device sign-in if left off |
| Redirect URLs | Authentication → URL Configuration | deployment-specific |

## Automatic — created by migrations

| Dependency | Created by |
|---|---|
| All application tables | `0001`…`0091` |
| RLS policies | migrations |
| Storage **policies** on `backups` | `0001_init.sql`, hardened by `0086` |
| Database functions and triggers | migrations |
| SECURITY DEFINER lockdown | migrations, enforced by `check_migrations.sh` |
| Cron jobs | `cron.schedule(...)` in migrations — **requires `pg_cron` enabled first** |
| Vault secrets | `vault.create_secret(...)` |
| Realtime publication membership | migrations `alter publication supabase_realtime` |

## Verification sweep

```sql
select extname from pg_extension where extname in ('pgcrypto','pg_cron','pg_net');
select id, public from storage.buckets;                  -- backups, false
select count(*) from pg_policies where schemaname='public';
select jobname, schedule from cron.job;
select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef;               -- ~41 SECURITY DEFINER
```

## Workers

| Worker | Trigger | Auth |
|---|---|---|
| `purge-scheduled-deletions` | `pg_cron` → `pg_net` → Edge Function | `PURGE_WORKER_SECRET` |
| `process-notification-retries` | `run_notification_retry_dispatch` cron | `NOTIFICATION_RETRY_WORKER_SECRET` |

Without `pg_cron` neither fires. They still work when invoked manually with the
correct bearer secret, so a missing `pg_cron` degrades scheduling rather than
correctness.

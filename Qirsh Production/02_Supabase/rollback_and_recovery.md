# Supabase Rollback & Recovery

See also `../11_Rollback_Recovery/`.

## Rollback coverage

Every migration from **0084** up has a matching
`supabase/rollback/<name>_rollback.sql`, enforced by
`supabase/tools/check_migrations.sh` (`ROLLBACK_FLOOR=84`) and verified to fail
when a file is removed. Earlier migrations predate the convention; retrofitting
reversals for the initial schema would be fiction rather than safety.

## The trap — read before rolling anything back

`0084` and `0085` are `CREATE OR REPLACE` of functions that **already existed**
(`0083`, `0074`).

**A `DROP FUNCTION` rollback would leave account deletion, entitlement grants,
referral qualification and XP awards with no implementation at all** — strictly
worse than the races being reverted.

Their rollback files therefore restore the **previous body** by re-running the
defining migration, which is sound only because both are idempotent — verified
by applying each twice to a throwaway database, not by reading them.

## Per-migration reversibility

| # | Reversible? | Method |
|---|---|---|
| 0084 | via re-run | `psql -f supabase/migrations/0083_referral_rewards.sql` |
| 0085 | via re-run | `0074` then `0083`, in that order |
| 0086 | **exact** | restores the 0010 policies verbatim, then drops the function |
| 0087 | **exact** | replays its own pre-image journal; drop the CHECK first |
| 0088 | **refusal** | revoking breaks the app — read the file header |
| 0089 | **exact** | drops trigger + functions; **keeps the audit rows** |
| 0090 | trivial | drops one diagnostic view |
| 0091 | exact, but | re-truncates 3-decimal currencies at capture = money corruption |

## If the chain fails mid-way

1. Note the exact file that failed. Everything before it applied.
2. Read the error — most are a missing §2.3 prerequisite.
3. Fix the cause, then re-run **from the failed file onward**.
4. Roll back only if the partial state is actively harmful, and only using the
   matching rollback file.

## Data recovery

Supabase point-in-time recovery is a paid-tier feature. On the free tier, take a
manual snapshot before applying the chain:

```bash
pg_dump "$PROD_DATABASE_URL" > qirsh-preflight-$(date +%Y%m%d).sql
```

On a brand-new empty database this is nearly worthless — but it costs seconds
and is the only backup that exists before the first migration.

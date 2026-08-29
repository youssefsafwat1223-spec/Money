# Migration Recovery

Canonical rollbacks: `supabase/rollback/<migration>_rollback.sql`, required for
everything from **0084** up and enforced by `supabase/tools/check_migrations.sh`.

## ⚠️ Read this before running any rollback

**0084 and 0085 are `CREATE OR REPLACE` of functions that already existed** (in
`0083` and `0074`).

A `DROP FUNCTION` rollback would leave **account deletion, entitlement grants,
referral qualification and XP awards with no implementation at all** — strictly
worse than the races being reverted.

Their rollback files restore the **previous body** by re-running the defining
migration. That is sound only because both are idempotent, verified by applying
each twice to a throwaway database rather than by reading them.

## Per migration

| # | Method | Cost of rolling back |
|---|---|---|
| 0084 | re-run `0083_referral_rewards.sql` | deletion completeness regresses — personal data left behind on account deletion. GDPR/CCPA exposure; treat as a brief emergency measure |
| 0085 | re-run `0074` then `0083`, in that order | absent-row races return (H-10/H-11/H-12): double-granted entitlements, double-qualified referrals, double-awarded XP |
| 0086 | exact | a deleted Auth user can write to their old backup prefix until the token expires |
| 0087 | exact — replays its own pre-image journal | `passed` stops meaning "has evidence"; untested regexes can reach real users' money |
| 0088 | **refusal** — read the header | revoking breaks the app; it made an existing privilege explicit, so revoking is a *new* state |
| 0089 | exact | any writer can again block every client with no audit trail |
| 0090 | trivial | lose one diagnostic view |
| 0091 | exact, but | re-truncates 3-decimal currencies **at capture** — money corruption, and rolling forward later does not repair values already stored |

## If the chain fails part-way

1. Note the exact file. Everything before it applied.
2. Read the error — most are a missing platform prerequisite (extensions,
   bucket), not a bad migration.
3. Fix the cause, re-run **from the failed file onward**.
4. Roll back only if the partial state is actively harmful.

## Verifying after a rollback

```sql
select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='public' and proname in
 ('purge_user_data','apply_entitlement_mutation','qualify_referral_internal',
  'award_gamification_for_transaction');
-- all four must still EXIST after any 0084/0085 rollback
```

If any is missing, the wrong rollback was run. Re-apply the defining migration
immediately.

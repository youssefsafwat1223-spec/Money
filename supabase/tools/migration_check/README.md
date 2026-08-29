# Migration Verification Harness

Copied from `research/sms_model_lab/migration_check/` — an untracked working
directory — because **migration `0091` cites this script as the thing that
caught a real defect**:

> `-- (This was caught by research/sms_model_lab/migration_check/verify_0091.sh,`
> `--  not by review.)`

The defect: written as `LIKE '%…(?:\.[0-9]{1,2}…%'`, the pattern searches for a
literal `.` rather than `\.` because PostgreSQL's LIKE treats backslash as an
escape character — so the migration would have updated **0 rows while reporting
success**. `strpos` has no escape semantics and means what it reads.

Verification evidence for a shipped migration should not depend on an untracked
folder, hence this copy.

| File | Purpose |
|---|---|
| `verify_0091.sh` | applies 0002's DDL + the 12-rule seed, then 0091 verbatim, against an isolated throwaway Postgres on port 55433 |
| `seed_0002_rules.sql` | the exact rule seed replayed from `0002_catalog_mvp.sql` |

## Scope, as the script itself states

It exercises 0091's **effect on the real seeded rows**. It does **not** replay
the full 91-migration chain — 0091 has no dependency beyond the table existing,
so the chain would add runtime rather than coverage.

For the full-chain check use [`../dryrun_migrations.sh`](../dryrun_migrations.sh).

## Safety

Own container, own port, torn down at the end. Touches no shared database.

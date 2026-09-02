# Qirsh — migration ledger truth

**As of 2026-09-02. The deployed state of this database CANNOT be determined
from this repository.** This file records exactly what each source claims, why
they cannot all be true, and what has to happen to resolve it.

Nothing here is a guess. Where the truth is unknown it says unknown.

---

## The contradiction

Ten migrations carry an inserted claim, identical in wording and dated
2026-09-01:

> `DEPLOYED (status corrected 2026-09-01: 0001-0092 applied and ledger-verified
> on production; this header was never revised after the deploy).`

They are **0071, 0072, 0073, 0074, 0075, 0076, 0077, 0078, 0079, 0080**.

Three migrations inside that same claimed range say the opposite:

| Migration | Header |
|---|---|
| `0084_purge_user_data_restore.sql` | "SOURCE-ONLY. NOT APPLIED TO ANY PROJECT. Requires explicit authorisation" |
| `0085_concurrency_absent_row_locking.sql` | SOURCE-ONLY |
| `0086_backups_owner_liveness.sql` | SOURCE-ONLY |

**0084 ≤ 0092.** If 0001–0092 are applied, 0084 is applied, and its own header
is false. If 0084 is genuinely unapplied, the "0001-0092" claim is false. There
is no reading in which both are correct.

## Why it cannot be resolved from here

```
$ supabase migration list --linked
Initialising login role...
unexpected login role status 403: {"message":"Your account does not have the
necessary privileges to access this endpoint."}
```

The linked project ref is `rjwphwsefnuotpbtuycf` (verified in
`supabase/.temp/project-ref`). The Management API refuses this account, and no
database password is available in the environment. **No remote mutation was
attempted and none should be.**

## Why it matters more than a documentation nit

`0084_purge_user_data_restore.sql` is a **data-erasure repair**. If it is not
applied, account deletion may not fully erase user data server-side. Shipping a
deletion feature whose server half may be absent is not defensible, and the
client cannot tell the difference.

The other two are a concurrency fix (`0085`, absent-row locking) and a backup
ownership liveness check (`0086`) — both correctness fixes whose absence is
silent.

## Known with certainty

| Range | State | Confidence |
|---|---|---|
| 0093–0098 | **SOURCE-ONLY** | Certain. Written in this session and the previous one; never deployed; every dependent feature is behind an OFF flag. |
| 0084–0092 | **DISPUTED** | The repository contradicts itself. Treat as unapplied until proven otherwise. |
| 0001–0083 | **PROBABLY APPLIED** | Consistent with every header, and with the app functioning against the project. Not independently verified here. |

## How to resolve it

From the Supabase dashboard for `rjwphwsefnuotpbtuycf`, SQL editor:

```sql
select version
from supabase_migrations.schema_migrations
order by version desc
limit 20;
```

Then:

1. Record the highest applied version in this file, with the date.
2. Correct every migration header that disagrees — in **one** commit, so the
   correction is auditable rather than scattered.
3. Apply anything missing from 0084 upward, in order, after reading each
   rollback file first.
4. Only then treat 0093–0098 as deployable.

Until step 1 happens, **no production-readiness claim about the backend is
supportable**, and `RELEASE_BLOCKERS.md` RB-4 stays open.

## A process note

The 2026-09-01 claim was batch-inserted into ten files at once. Whatever its
accuracy, that shape is the problem: a deployment fact repeated in ten places
will disagree with itself the first time one copy is edited, and it did.

Deployment state belongs in **one** place — this file — with migration headers
describing what a migration *does*, not where it has run.

# Qirsh — migration ledger truth

**This is the single source of truth for what is deployed.** Migration file
headers describe what a migration *does*; they do not record where it has run.

---

## Verified production state

| | |
|---|---|
| **Production project** | `rjwphwsefnuotpbtuycf` |
| **Applied continuously through** | **0092** |
| **Verified** | 2026-09-02, owner read-only query against `supabase_migrations.schema_migrations` |
| **Explicitly confirmed present** | 0084, 0085, 0086, 0087, 0088, 0089, 0090, 0091, 0092 |
| **Source-only, NOT deployed** | **0093 – 0098** |

**0093–0098 must not be assumed deployed and must not be applied without an
explicit activation instruction.** Every feature that depends on them is behind
a flag seeded OFF, so nothing is broken by their absence.

| Migration | Feature | Flag |
|---|---|---|
| 0093 | `merchant_keywords` catalog versioning | — (correctness fix) |
| 0094 | `catalog_merchants` + reviewed aliases | `enable_offers_merchants` OFF |
| 0095 | coupon offer economics | `enable_coupons` OFF |
| 0096 | affiliate core | `enable_affiliate_links` OFF |
| 0097 | affiliate attribution | `enable_affiliate_links` OFF |
| 0098 | `record_metric` ad-key allowlist | telemetry silently dropped until applied |

---

## The contradiction that existed, and why it survived

Until 2026-09-02 this repository asserted two incompatible things.

Ten migrations (**0071–0080**) carried, verbatim:

> `DEPLOYED (status corrected 2026-09-01: 0001-0092 applied and ledger-verified
> on production; this header was never revised after the deploy).`

Three migrations **inside that same range** (**0084, 0085, 0086**) said:

> `SOURCE-ONLY. NOT APPLIED TO ANY PROJECT.`

0084 ≤ 0092, so both could not be true. The Management API returned **403** for
the available credentials, so the ledger could not be read from this machine and
the contradiction stood unresolved through the 2026-09-02 finalization audit.

**The owner query resolved it: the 0071–0080 claim was correct, and the
0084–0086 headers were stale.**

**Why they were stale is the part worth keeping.** Those three headers named a
*different* production project — an earlier deployment target that is no longer
in use and is now explicitly off-limits. They were accurate statements about a
project these migrations were never going to run on, and said nothing at all
about the project they did run on. A reader checking "has 0084 been applied?"
got a confident answer to a question they had not asked.

That is why it survived repeated audits: the sentence was not wrong in the way
audits look for. It was wrong about its subject.

**Why it mattered.** `0084` is a *data-erasure repair* — it restores deletion
completeness in `purge_user_data()`. "Possibly not applied" meant "account
deletion may not fully erase, and we cannot tell". That is the single worst
shape an unknown can take in this product, and it is now closed.

---

## The rule this leaves behind

Deployment state lives **here, in one file**. Migration headers must not carry a
per-file deployment claim.

Ten copies of one fact is precisely how the contradiction arose: the copies were
batch-edited on 2026-09-01, three files inside the range were missed, and from
that moment the repository disagreed with itself. A single record cannot
disagree with itself.

The 0071–0080 headers still carry their (correct) claim. They were left alone
rather than swept, because rewriting ten accurate files is churn — but they
should not be treated as authoritative, and nothing new should imitate them.

---

## How to verify, next time

From the Supabase dashboard for `rjwphwsefnuotpbtuycf`, SQL editor:

```sql
select version
from supabase_migrations.schema_migrations
order by version desc
limit 20;
```

Then update the table at the top of this file with the result and the date. If
the highest applied version is below the highest file in `supabase/migrations/`,
list the gap explicitly — do not describe it as "probably applied".

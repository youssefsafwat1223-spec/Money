# Phase 8 — Complete v30 additive schema map (authoritative B8-3 input)

MALI-026. The exact local v30 additive schema for EVERY persisted Phase-8 money field + the planning
currency/marker columns. **PLAN ONLY — not applied; schema stays v29; no `_minor` columns; no migration
file.** This is the authoritative input for B8-3 (the actual additive-schema implementation).

## §20 — naming scheme (one deterministic form)
Every money REAL column `X` gains an INTEGER minor column **`X_minor`** (e.g. `amount → amount_minor`,
`balance_after → balance_after_minor`, `initial_balance → initial_balance_minor`). No mixed forms. Each
`X_minor` is added **NULLABLE** (additive; the REAL column is retained as the compatibility shadow and
keeps its existing nullability). The cutover fills `X_minor`; §22 forbids a NULL `X_minor` for a non-null
`X` once the domain is canonical.

## §19 — field-by-field map (20 money columns + 3 new)
Currency authority: `sameRow` = the row's existing `currency` column; `foreign` = the row's
`foreign_currency`; `row.currency` = the NEW planning currency column (repair-confirmed); `parent goal`
= the contribution's parent goal's currency.

| table | legacy REAL | new INTEGER minor | currency authority | REAL nullable? | backfill conversion | postflight invariant |
|---|---|---|---|---|---|---|
| transactions | amount | amount_minor | sameRow (`currency`) | no | `legacyRealToMinor(amount, currency)` | `minorToDecimalString == exact(amount)` |
| transactions | balance_after | balance_after_minor | sameRow | yes | null→null; else `legacyRealToMinor(…, currency)` | round-trips or both null |
| transactions | foreign_amount | foreign_amount_minor | foreign (`foreign_currency`) | yes | null→null; else `legacyRealToMinor(…, foreign_currency)` | `foreign_amount_minor NULL ⇔ foreign_currency NULL` |
| accounts | initial_balance | initial_balance_minor | sameRow | yes | null→null else convert | round-trips or both null |
| accounts | current_balance | current_balance_minor | sameRow | yes | idem | idem |
| accounts | credit_limit | credit_limit_minor | sameRow | yes | idem | idem |
| accounts | available_credit | available_credit_minor | sameRow | yes | idem | idem |
| budgets | amount | amount_minor | **row.currency** (new) | no | `legacyRealToMinor(amount, budgets.currency)` | round-trips; currency non-null |
| budgets | last_notified_spent_amount | last_notified_spent_amount_minor | row.currency | no (dflt 0) | convert (dormant field) | round-trips |
| goals | target_amount | target_amount_minor | **row.currency** (new) | no | `legacyRealToMinor(…, goals.currency)` | round-trips; currency non-null |
| goals | saved_amount | saved_amount_minor | row.currency | no | convert | round-trips |
| goals | last_notified_saved_amount | last_notified_saved_amount_minor | row.currency | no (dflt 0) | convert (dormant) | round-trips |
| goals | auto_save_amount | auto_save_amount_minor | row.currency | yes | null→null else convert | round-trips or both null |
| goal_contributions | amount | amount_minor | **parent goal.currency** | no | `legacyRealToMinor(amount, parentGoal.currency)` | round-trips; parent has currency |
| subscriptions | amount | amount_minor | sameRow | no | convert | round-trips |
| subscriptions | manual_paid_amount | manual_paid_amount_minor | sameRow | yes | null→null else convert | round-trips or both null |
| subscriptions | total_purchase_amount | total_purchase_amount_minor | sameRow | yes | idem | idem |
| bill_payments | amount | amount_minor | sameRow | no | convert | round-trips |
| plans | budget_amount | budget_amount_minor | sameRow | no | convert | round-trips |
| suspected_duplicates | amount | amount_minor | sameRow | no | convert | round-trips |

New non-`_minor` columns:
| table | column | type | notes |
|---|---|---|---|
| budgets | currency | TEXT NULL | repair-confirmed at cutover; then read-authoritative |
| goals | currency | TEXT NULL | repair-confirmed at cutover; then read-authoritative |
| user_settings | planning_cutover_state | INTEGER NOT NULL DEFAULT 0 | 0 unresolved / 1 canonical; commits in the cutover txn |

**Non-money REAL columns EXCLUDED (never get `_minor`):** `confidence`, `parse_confidence`, `progress`,
`interest_rate`, `ratio` (per `kNonMoneyRealColumns`). **Completeness:** the 20 money `_minor` columns
above are exactly `kMoneyFields`; the money-field completeness guard already fails if a REAL money column
is unclassified, so no persisted money field is omitted.

## Backfill order (the app-level P2 cutover transaction; §21 atomicity)
Per-row-currency domains (currency already present) can cut over independently; the planning domains
require the repair-confirmed currency first:
1. sameRow/foreign domains (transactions, accounts, subscriptions, bill_payments, plans,
   suspected_duplicates): `X_minor = legacyRealToMinor(X, <sameRow/foreign currency>)`.
2. goals: `currency = repairCurrency(goalId)` → `*_minor = legacyRealToMinor(real, goals.currency)`.
3. goal_contributions: `amount_minor = legacyRealToMinor(amount, parentGoal.currency)` (join goals).
4. budgets: `currency = repairCurrency(budgetId)` → `amount_minor = …`.
5. exact postflight over EVERY filled minor (no epsilon); `user_settings.planning_cutover_state = 1`.
All in ONE transaction (all-or-nothing; a crash rolls back backfill + marker — proven by the prototype).

## §21 — future writer atomicity
Every post-cutover write updates `X_minor` (canonical) AND `X` (REAL shadow) in the **same** INSERT/
UPDATE statement (one `customStatement`/companion) — never two statements with a crash window. Both are
derived from the SAME `Money` via `MoneyCodec` (`toMinor` + `toReal`). To be encoded in `MoneyCodec` v30
mode (setter emits both columns) + the writer/path guard.

## §22 — future read authority
- Before a domain's cutover: legacy REAL may be read.
- After a domain is canonical (P3): financial logic reads `X_minor` ONLY. There is NO `minor NULL →
  fallback REAL` in P3. A NULL `X_minor` where the REAL is non-null in P3 is an INVARIANT FAILURE
  (corruption), surfaced by the postflight guard — not a compatibility fallback.

## §23 — exact aggregate replacement map (REAL SUM/AVG → integer minor)
Every remaining SQL money aggregate on a REAL column moves to `SUM(X_minor)` (exact integer) at v30:
- transactions: `expenseTotalBetween` / `incomeTotalBetween` / `categoryExpenseTotalBetween` (refund-
  netted `SUM(CASE … amount …)`); `latestBalanceAfter` (selection, not sum); card in/out totals; the
  recurring `AVG(amount)`/`MIN`/`MAX` spread → `AVG/MIN/MAX(amount_minor)` (integer).
- budgets: `budgetSpent` (via the transaction SUMs above).
- plans: `spentForPlan` (`SUM(netExpenseSignedAmount)` → `SUM(amount_minor …)`).
- reports/dashboard Dart folds already read `*Money` and project to double for the mixed-currency
  DISPLAY total only (transitional; single-currency folds can use `Money.sum`).
**Overflow:** SQLite `SUM(INTEGER)` accumulates as int64 and can overflow only at astronomically large
datasets; where a currency-scoped `SUM` could theoretically exceed int64 minor units, aggregate exactly
in Dart with BigInt over the paged rows. **Do NOT use SQLite `total()`** — it returns a floating REAL
and is not an exact replacement. Document per-aggregate overflow behavior at B8-3.

## §12 — exact future PUSH field coverage (converted domains)
`Money → moneyToNumericText → existing PostgREST NUMERIC column` (no JSON number, no `amount_minor`/
`money_version` on the wire). Fields: transactions amount/balance_after/foreign_amount (3); accounts
initial_balance/current_balance/credit_limit/available_credit (4); subscriptions amount/manual_paid/
total_purchase (3); bill_payments amount (1); plans budget_amount (1); goal_contributions amount (1
via RPC); goals saved_amount (RPC) — **= 13 remotely-synced converted money fields**; suspected_duplicates
is local-only (not remotely synced). budgets/goals push depends on the server currency migration (§17).
Not activated (capability = `unknown` until external verification).

## §13 — push and pull capability are independent
`ExactTransportCapability` is tracked separately for PUSH (string→NUMERIC) and PULL (`NUMERIC::text`);
a backend may support one and not the other. Both default `unknown` until externally verified.

## §15 — repair UI wording (semantic truthfulness)
The proposed currency is a DEFAULT SUGGESTION (current effective base), NOT a detected original. Global
confirm means **"Treat all existing items as X"**, never "these items were originally X." (Screen copy
to be asserted.)

## §17/§18 — server schema source (prepared, NOT deployed)
Additive Supabase migration `0077_planning_currency.sql`: `user_budgets ADD COLUMN currency TEXT NULL`,
`user_goals ADD COLUMN currency TEXT NULL` (NO `goal_contributions.currency` — inherits parent; NO
NOT-NULL on legacy rows). Rollback = drop the two columns (additive, safe). No client dependency activates
merely because the source exists; external verification remains the authority. (Exact-text/exact-NUMERIC
readiness is expressed by the client `ExactTransportCapability` model, not a new server flag system.)

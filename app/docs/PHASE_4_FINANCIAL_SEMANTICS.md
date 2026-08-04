# Mali — Phase 4 Canonical Financial Semantics

Authoritative specification for how Mali derives every financial figure it
displays. It is the single source of truth for income/expense/refund/net-spend,
status, account/currency scope, and time periods, produced by the Phase-4
remediation (batches 1–6, commits `71dc2534`…`acb079a3`).

- **Scope:** on-device (Drift/SQLCipher) financial reads. The UI reads only from
  Drift; sync writes to Drift.
- **Rule:** one shared domain contract, never per-screen arithmetic. Every
  surface routes through the canonical repository aggregate or the canonical
  domain helper listed here.
- **Out of scope:** MALI-026 fixed-precision *storage* (integer minor units) is a
  separate future project (Phase 8). Money is stored as REAL today; the semantics
  below are independent of that and are NOT Phase-4 unfinished work.

Canonical source files:
`lib/domain/finance/financial_semantics.dart` (type/status matrix + SQL
fragments), `financial_period.dart` (half-open periods), `budget_period.dart`
(budget resolver + consumption), `plan_scope.dart` (plan scope model),
`bill_metrics.dart` (subscription metric + payment attribution),
`money_format.dart` (currency exponents); the Drift aggregates in
`lib/data/repositories/drift_transaction_repository.dart` (`_financialAggregateSql`,
`_accountClause`).

---

## A. Transaction-type matrix

Net-spend convention: **net expense = Σ(payment) + Σ(withdrawal) − Σ(refund)**;
**income = Σ(income)**; transfer/unknown/adjustment are excluded from both. A
refund NETS against expense — it is never income, and never both.

| Type | Income | Net expense (sign) | Budget | Category/merchant | Account cash-flow | Gross inflow | Gross outflow | Reporting | Sync round-trip |
|---|---|---|---|---|---|---|---|---|---|
| income | **yes** | no (0) | no | no | in | yes | no | income tile / per-currency | `income`, direction credit |
| payment | no | **+1** | consumes | yes | out | no | yes | net expense / category / largest | `expense`, debit |
| withdrawal | no | **+1** | consumes | yes | out | no | yes | net expense (cash category) | `withdrawal`→expense, debit (v2 canonical metadata preserves withdrawal) |
| refund | **no** | **−1** | restores | reduces | in | yes | no | reduces net expense; on a *labelled gross* surface only, gross inflow | `refund`, credit |
| transfer | no | excluded (0) | no | no | between accounts | no | no | excluded from income & expense | `transfer`, unknown direction |
| adjustment | no | excluded (0) | no | no | no | no | no | excluded | `unknown` (never silently payment) |
| unknown/future | no | excluded (0) | no | no | no | no | no | excluded (never silently an expense) | dead-letters if newer schema; coarse rule otherwise |

Encoded in `kFinancialTypeSemantics` / `FinancialTypeSemantics`. The SQL truth is
`FinancialSql.netExpenseSignedAmount` (`CASE WHEN type='refund' THEN -amount WHEN
type IN ('payment','withdrawal') THEN amount ELSE 0 END`), `netExpenseTypePredicate`,
`incomeTypePredicate`. A `confirm()` grounds an `unknown` row by direction so it
never stays confirmed-but-uncounted.

## B. Status matrix

| Status | Treatment | Where it appears |
|---|---|---|
| confirmed | **counted** | every canonical spend/income total |
| pending | pending-only | only on surfaces that explicitly show pending (see §I); never in a canonical confirmed total |
| ignored | excluded | nowhere in totals |
| deleted / tombstoned | excluded (soft-delete sets `status='ignored'`) | nowhere |
| review-required | a pending sub-state (smart inbox); pending rules apply | review affordances only |
| unknown/future status | excluded (fail-closed) | nowhere |

The SQL truth is `FinancialSql.confirmedPredicate` (`status = 'confirmed'`).
`statusTreatment()` maps the enum. Canonical confirmed totals and intentional
pending gross displays are **never** given the same label (§I).

## C. Refund contract (per surface)

A refund reduces net expense everywhere and is never counted as income.

| Surface | Refund effect |
|---|---|
| Dashboard totals | net expense −refund; income unaffected |
| Transactions header | `transactionsPeriodTotalProvider` net expense −refund (confirmed) |
| Home categories | `categoryBreakdown` net per category −refund |
| Budgets (ring/detail/history) | `budgetSpent` / `categoryExpenseTotalBetween` −refund; history LIST includes the refund row so its signed sum equals the net total |
| Plans | `spentForPlan` net signed sum −refund |
| Reports/PDF | donut/slices/summary/appendix all −refund (per currency) |
| Card summaries | `totalOut` (net spend) −refund; `totalIn` = income only (refund NOT inflow) |
| Bill payments | a refund is reconciled by removing/reducing the corresponding `bill_payments` row (the ledger is authoritative); a fuzzy refund transaction is not auto-netted |
| Account detail | same canonical account-scoped aggregate −refund |
| Exports (report appendix) | rows carry their own signed amount; expense rows per currency net to that currency's expense total |

## D. Account and exclusion contract

- **Exact ownership.** A specific account's scope is `account_id = ?`
  (`_accountClause`). No currency fallback.
- **Unassigned (`account_id IS NULL`).** Belongs to no account; appears only in
  the all-accounts scope (`accountId == null`). Never attributed to an account
  because its currency matches. Assigning it moves it exactly once; it then
  appears there because it is assigned. The dashboard's one-time currency
  reconciliation is an explicit persistent assignment (one account each), not a
  read-time fallback.
- **`exclude_from_totals`.** Applies ONLY to combined/all-accounts totals
  (`FinancialSql.excludedAccountExclusion` / `_includedTotalsAccountClause`, only
  when `accountId == null`). An explicitly opened account's own detail shows its
  full totals even if flagged.
- **Global/all-accounts.** `accountId == null` = every account + unassigned rows,
  minus flagged accounts.
- **Card/account linkage.** Cards carry `card_last4`; a card's owning account is
  the confident owner of its transactions (`CardAccountGrouper`, confidence 1.0),
  never a currency guess.

## E. Currency contract

- **No cross-currency raw sum labelled as one currency.** Ever.
- **Scope by currency** via account scope (each account is one currency) or an
  explicit `currency` filter (`categoryBreakdown(currency:)`,
  `currencyTotalsBetween`, per-currency card summaries). Multi-currency surfaces
  group by currency or pick one explicit currency.
- **No FX conversion** anywhere in Phase 4.
- **Formatting.** `money_format.dart` `currencyDecimalDigits` gives 0/2/3 fraction
  digits (JPY/KRW = 0; KWD/BHD/OMR/… = 3; default 2). Used by reports and cards.
- **Ownership.** Plans, cards, and bills each carry a currency; a report picks a
  primary currency and labels only rows filtered to it; totals are per-currency.
- MALI-026 exact-storage conversion is separate and NOT Phase-4 work.

## F. Period contract

The universal window is **half-open `[fromInclusive, toExclusive)`**
(`occurred_at >= from AND occurred_at < to`). A transaction at exactly
`toExclusive` belongs to the next period; one immediately before is included.

| Period | Definition |
|---|---|
| day | `[startOfDay, +1 day)` |
| week | **Saturday-anchored** `[startOfWeek, +7 days)` (`RiyadhTime.startOfWeek`, `(weekday+1)%7`) |
| month | `[1st, 1st of next month)` (leap-safe) |
| year | `[Jan 1, next Jan 1)` |
| custom | stored `[from, toExclusive)` |
| budget | `resolveBudgetPeriod` → the above by kind, from `now` (recurring), never the screen filter |
| plan | `[startDate, endExclusive)` where `endExclusive = startOfDay(endDate)+1 day` derived from the legacy `23:59:59` endDate with NO epsilon |
| report | `ReportPeriodResolver` half-open; previous period ends where the current begins |
| appendix | same half-open window as the totals |
| comparison | previous half-open period `[prevStart, currentStart)` |

**No epsilon / end-minus-one-millisecond / `23:59:59` / inclusive last instant is
permitted** in any Phase-4 caller. Boundaries are computed in the device-local
(business) timezone.

## G. Surface contracts (source of truth)

| Surface | Source | Semantics |
|---|---|---|
| Dashboard totals/rings | `expenseTotalBetween`/`incomeTotalBetween`; rings via `resolveBudgetPeriod`+`budgetSpent` | net expense; ring uses the budget's OWN period, never the filter |
| Transactions header | `transactionsPeriodTotalProvider` → `expenseTotalBetween(accountId)` | canonical net expense over the complete dataset, period×account, single-currency, pagination-independent |
| Home category totals | `monthlyExpenseGroupsProvider` → `categoryBreakdown` | net per category; agrees with the budget chip |
| Budget ring & detail | `budgetSpent(resolveBudgetPeriod)` | one resolver+consumption shared by ring/detail/reports/alerts |
| Budget history | `buildEntry` totals + `_budgetTransactionsForPeriod` list | list signed sum == net total (refunds included, half-open, excluded-account) |
| Plans | `spentForPlan`/`transactionsForPlan` | one membership: half-open window, plan currency, net-expense types, UNION account/card + manual link |
| Reports / PDF | `ReportSnapshotBuilder` + `ReportComposer` | per-currency donut/slices/appendix; primary-currency scoped; exponent formatter |
| Bills | `billPaidTotal` (authoritative ledger) | recorded payments + legacy manual residual; fuzzy = suggestion |
| Subscriptions | `subscriptionMonthlyTotal`/`monthlyEquivalent`/`annualEquivalent` | one normalization (monthly = annual/12); active-only; single-currency |
| Cards | `getCardSummaries`/`getCardAccountBreakdown` + `CardAccountGrouper` | per (last4,currency); net spend / income-only; set-based |
| Account details | canonical account-scoped aggregates | exact ownership; no currency fallback |
| Installments | `_recomputeInstallmentPaidCount` | distinct settled installments from the ledger |
| Exports (report appendix) | `_appendixFor` | confirmed, half-open, excluded-account; per-currency rows net to totals |

## H. Bill and installment contract

- **Authoritative ledger.** `bill_payments` is the settled-payment record; each
  row = one payment, optionally carrying `transaction_id`.
- **Paid total** = Σ recorded payments + legacy-manual residual
  (`max(0, manual − recorded)`). A payment counts exactly once regardless of
  representation.
- **Linked-transaction dedup.** A transaction referenced by a `bill_payment` is
  counted through that payment (once); `linkedTransactionIds` keeps it out of the
  "suggested to link" list.
- **Fuzzy merchant matching is suggestion-only** — never authoritative counting.
- **Subscription metrics.** `monthlyEquivalent` (weekly×52/12, monthly×1,
  yearly÷12, custom×365/days/12) and `annualEquivalent` = monthly×12.
  `subscriptionMonthlyTotal` sums active subscriptions, single-currency.
- **Installment paid-count** = DISTINCT settled installments in the ledger for the
  bill's currency (`COUNT(DISTINCT installment_index)` + one per null-indexed row,
  non-deleted, capped), recomputed after every settle/delete. Never
  `MAX(installment_index)`.
- **Refund/deletion/currency.** Deleting a payment recomputes down;
  foreign-currency payments never count; duplicate-index rows collapse to one.

## I. Intentionally different metrics

These are NOT canonical net-expense totals and carry their own labels; none reuses
a misleading canonical label:

| Metric | Label | Semantics |
|---|---|---|
| Dashboard pending review | "قيد المراجعة" | gross sum of pending items awaiting review (pending status, not confirmed) |
| Recurring-candidate estimate | dashboard subscriptions preview | heuristic average of auto-detected recurring spend (not saved subscriptions) |
| Remaining installment debt | "إجمالي مديونية الأقساط" | projected `Σ remainingInstallments × amount` (forward obligation, built on the corrected paid-count) |
| Card gross inflow (if shown) | "داخل" (income) / "الصافي" (net) | income only / (income − net spend); distinct from net spend "خارج" |
| Subscription monthly obligation | "الاشتراكات الشهرية" | projected recurring obligation, distinct from actual confirmed spend |

---

## Architectural guardrails (enforced)

1. UI/providers do not invent financial semantics — they call a canonical
   repository aggregate or a `domain/finance` helper.
2. No raw amount folds for canonical totals (the `TransactionsView`/Home/dashboard
   folds were removed; `BillsView.totalDue` deleted).
3. No page-dependent totals (header/Home/card totals are set-based SQL).
4. No cross-currency sums under one label.
5. No inclusive financial date ranges — half-open `[from, to)`, no epsilon.
6. No NULL-account currency fallback — exact account ownership.
7. No fuzzy merchant payment counting — `bill_payments` is authoritative; fuzzy is
   suggestion-only.
8. No `MAX(installment_index)` paid-count — distinct settled installments.
9. No dormant Supabase summary switch — the 0030 flags/provider/branches are
   removed; the RPCs are marked historical.
10. Drift remains the local authoritative source for displayed financial data.

### Invariant tests locking these rules

Behavioral (Drift/provider), not source-text:

- `test/data/financial_totals_invariant_test.dart` — headline == category ==
  merchant == daily == budget == report on one fixture.
- `test/data/financial_aggregate_boundary_test.dart` (3) — half-open at exact
  from/before-to/exactly-to; currency isolation.
- `test/features/finance/financial_cross_surface_invariant_test.dart` (10) —
  repo/header/Home/budget-ring/budget-detail/plan/report/card agreement +
  excluded account + multi-currency + card tie-in + type matrix.
- `test/features/budgets/budget_consumption_canonical_test.dart` (7) — genuine
  half-open resolver + filter-invariant budget consumption.
- `test/features/budgets/budget_history_reconciliation_test.dart` (2) — list
  signed sum == net total.
- `test/data/plan_spending_canonical_test.dart` (11) — plan currency/refund/
  status/boundaries/UNION/fail-closed/list==total.
- `test/domain/finance/bill_metrics_test.dart` (7) — normalization + attribution.
- `test/data/reporting/report_multicurrency_test.dart` (3) — per-currency donut +
  exponents + boundary.
- `test/data/null_account_attribution_test.dart` (4) — exact ownership.
- `test/data/card_summary_canonical_test.dart` (4) — per-currency net card.
- `test/data/installment_paid_count_test.dart` (7) — distinct settled installments.
- `test/data/exclude_from_totals_test.dart` (2) — excluded-account policy.
- `test/domain/finance/financial_semantics_test.dart` (12) — the type/status/SQL
  matrix + half-open period + Saturday week + exponents.

---

## Closure verdict

**Phase 4 — Code complete; automated verification Closed locally; device/PDF/UI
spot-checks External-verification-pending.**

- All Phase-4 production code and its automated (Drift/provider/domain) invariants
  are locally verified: `flutter analyze` 0, full suite 1179, plus the complete
  Deno / Node-contract / migration-lint gates unchanged.
- Remaining acceptance is device-only: on-device PDF render (multi-currency
  donut), card in/out/net per currency, account-detail unassigned handling, and
  installment "X of N" display. These require a device and are tracked as
  external, never marked done without evidence.
- This closes the Phase-4 financial-semantics work item. It does NOT close the
  wider remediation program: Phases 5–9, MALI-026 (fixed-precision storage), live
  revision-CAS activation, and external validation remain open.

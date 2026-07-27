# Mali — PDF Financial Report Engine Plan

> Status: **Proposal — awaiting approval. No production code has been written.**
> Scope: A premium, configurable, on-device PDF "Financial Report" for the Mali app.
> Author role: Staff Product Designer + Senior Flutter Architect + fintech privacy engineer.
> Grounding: Every claim below is anchored to real code inspected on branch `feat/accounts-multicurrency`. Citations use `path:line`.

---

## 1. Executive summary

Mali already contains **all the financial data and most of the math** needed for a professional report, but has **no PDF layer at all** and **no report engine as a domain concept**. The existing `lib/features/reports/` is an on-screen, **expense-only** analytics screen (charts + hardcoded Arabic "insight" strings); it is not a document generator and cannot be reused for print output directly.

The recommendation is to build a **layered report engine** that:

1. Reuses the existing **Drift SQL aggregation methods** (`expenseTotalBetween`, `incomeTotalBetween`, `categoryBreakdown`, `merchantBreakdown`, `dailyExpenseTotals`, `currencyTotalsBetween`, `recurringCandidates`) and the existing **pure calculators** (period presets, `savingsScore`, `detectSpendingAnomaly`, `BudgetProgressUseCase`, `GoalDetailsUseCase`, `PlanProgress`) as its data + math foundation.
2. Adds **one immutable `ReportDataSnapshot`** assembled in a single async pass so figures stay internally consistent even if the DB changes mid-generation.
3. Adds a **pure PDF renderer** (via the `pdf` + `printing` packages) that consumes only plain section models — **never** Riverpod, repositories, or `BuildContext`.
4. Ships a **print-friendly light theme** built from the app's already-canonical light palette (`AppColors.light`) and the documented **blue→indigo brand accent `#2E6BFF → #5B4FE0`** (`MaliTokens.accentStart/accentEnd`).
5. Solves the **hard problem — Arabic shaping in PDF** — by **bundling the OFL-licensed IBM Plex Sans Arabic + IBM Plex Sans TTFs** (the app's real fonts, currently fetched at runtime by `google_fonts` and therefore unavailable to a headless renderer).

The single largest technical risk is **Arabic/RTL text shaping inside `package:pdf`** — it must be prototyped in the very first phase before any UI is built. The single largest product risk is **semantic honesty**: Mali's transaction classification has real quirks (refunds are treated three different ways; only *internal* transfers are excluded; `nextDueDate` is never auto-advanced; subscription price-increase and "new subscription" detection **do not exist**). The plan calls these out and refuses to invent metrics the data cannot support.

**No DB schema change, no sync change, and no provider rewrite are required for the MVP.** The only *possible* data-layer addition is a set of **read-only** repository query methods for the optional "subset of accounts" scope, which the current API does **not** support cleanly.

---

## 2. Current-codebase findings

### 2.1 Stack & conventions (grounded)

| Concern | Reality | Source |
|---|---|---|
| State / DI | Riverpod, **100% manual providers, zero codegen** (no `@riverpod`, no `.g.dart`) | `lib/core/di/app_providers.dart`; grep `@riverpod` → 0 |
| Routing | `go_router`, single flat `GoRouter`, bottom nav is a manual `IndexedStack` | `lib/core/router/app_router.dart:40`; `lib/features/app/app_shell.dart:1024` |
| DB | Drift over SQLCipher, **hand-rolled raw SQL** (`customSelect`), no generated tables | `lib/data/db/app_database.dart:16,42`; `lib/data/repositories/drift_transaction_repository.dart` |
| Schema version | **`_targetSchemaVersion = 26`** (CLAUDE.md's "4" is stale) | `lib/data/db/app_database.dart:14` |
| Money type | **`double` everywhere** — no minor-units, no `Decimal`, no Money value-object | `transaction_entity.dart:66`; `parsed_transaction.dart:25`; DB `amount REAL` |
| Sign | **Not stored**; derived from `type`/`direction` at display time | `formatters.dart:49-52`; `transaction_direction.dart:11-25` |
| Timestamps | `occurred_at` = **UTC ISO-8601 TEXT**; daily grouping converts to `'localtime'` | `sql_value_codec.dart:5-7`; `drift_transaction_repository.dart:557` |
| Currency | Free-form ISO string per row; **no FX; never summed across currencies** | `currencyTotalsBetween` `drift_transaction_repository.dart:519-547` |
| Locale | `localeProvider` from `userSettings.language`, default **`ar`** | `lib/core/i18n/locale_provider.dart:6-18` |
| Theme | **Light-only at app level** (`AppTheme.light`, page `#F6F7FB`) | `lib/app.dart:22`; `docs/MALI_DESIGN_SYSTEM.md` "Corrections" |
| Fonts | **IBM Plex Sans Arabic + IBM Plex Sans (OFL), fetched at runtime by `google_fonts`; nothing bundled** | `lib/core/theme/app_typography.dart:23,33`; no `fonts:` in `pubspec.yaml` |
| PDF/printing dep | **NONE** (`pdf`, `printing`, `pdf_render`, `syncfusion` all absent) | `pubspec.lock` grep → 0 |

### 2.2 Transaction classification (the rules the report MUST preserve)

- **Domain enum** `TransactionTypeEntity { payment, withdrawal, transfer, refund, income, unknown }` (`transaction_entity.dart:1-8`). (The richer engine enum with `creditCardPayment`/`governmentPayment` is collapsed before persistence — the report reads the domain/DB side.)
- **Expense** = `type IN ('payment','withdrawal') AND status = 'confirmed'` (`drift_transaction_repository.dart:467-468`).
- **Income** = `type = 'income' AND status = 'confirmed'` (`:490-491`). **The SQL income total EXCLUDES refunds.**
- **⚠ Refund is inconsistent across the codebase:**
  - SQL income total: refund **excluded** (`:490`).
  - Dart getter `TransactionsView.incomeTotal`: refund **included with income** (`transactions_providers.dart:33-35`).
  - `categoryExpenseTotalBetween`: refund **netted as `-amount`** against category spend (`:627-636`).
  - This is an **open product decision** (§25) — the report must pick one rule and document it.
- **Transfers**: excluded from totals only by *never being selected*. Crucially, only **internal** transfers keep `type='transfer'`; **external** transfers are reclassified into `payment`/`income` at ingest (`add_transaction_usecase.dart:465-491`; capture path `capture_sync_service.dart:308-315`). The report inherits this automatically because it reads the persisted `type`.
- **Pending / ignored**: `TransactionStatus { confirmed, pending, ignored }` (`transaction_entity.dart:19`); **all aggregates require `status='confirmed'`**, so pending & ignored (soft-deleted) never appear in totals.
- `exclude_from_totals` accounts are dropped **only** from all-account totals (`drift_transaction_repository.dart:406-416`).
- **NOT FOUND**: split transactions, an "edited" flag, category parent/child. The report must not assume these exist.

### 2.3 What already exists to REUSE vs what must be BUILT NEW

| Capability | Verdict | Source |
|---|---|---|
| Period boundaries (today/week/month/prevMonth/7/30/90/custom) | **REUSE** (pure fns) | `transactions_providers.dart:118-176` (week starts **Saturday**) |
| Yearly period | **BUILD** (only `BudgetPeriod.yearly` exists) | `budget_entity.dart:1` |
| Income / expense / net totals | **REUSE** | drift `:457-501`; `DashboardData.rangeIncome/rangeExpense` `dashboard_providers.dart:462-469` |
| Savings rate | **REUSE** (`savingsScore = (income−spent)/income`) | `dashboard_providers.dart:153-158` |
| Category breakdown | **REUSE** | drift `:582-616`; slice loop `reports_providers.dart:132-144` |
| Previous-period comparison | **REUSE** (`deltaPercent`, window math) | `reports_providers.dart:27-28,159-174`; `dashboard_providers.dart:342-349` |
| Spending anomaly (largest/unusual day) | **REUSE** (pure fn) | `reports_providers.dart:179-207` |
| Budget performance (spent/ratio/health/projection) | **REUSE** | `budget_progress_usecase.dart:58-85`; `budget_alert_planner.dart:52-70` |
| Bills/subs due-soon, unused, recurring-detect | **REUSE (partial)** | `bill_entity.dart:111-124`; `getDueBetween` `bill_repository.dart:6`; `recurringCandidates` `:754-785` |
| Goal progress (remaining/recommended/days) | **REUSE** | `goal_details_usecase.dart:16-35` |
| Plan progress (ratio/isOver/perDayLeft, multi-account `IN`) | **REUSE** | `plans_providers.dart:8-27`; `drift_plan_repository.dart:113-132,207-217` |
| Income-inclusive daily cash-flow series | **BUILD** (no `dailyIncomeTotals`; only expense series) | `drift_transaction_repository.dart:549-580` |
| Safe-to-Spend | **BUILD or OMIT** (only a render widget + gallery placeholder; no logic) | `ring_progress.dart:6`; `design_gallery_screen.dart:244` |
| Insights / rules engine | **BUILD** (today's insights are hardcoded UI strings) | `reports_screen.dart:244-293,960-1043` |
| Multi-account **subset** query | **BUILD read-only method** (only single/all supported) | `drift_transaction_repository.dart:388-401` |
| Subscription price-increase / "new subscription" detection | **DOES NOT EXIST** — must build or defer | (variance filter `≤ avg*0.15` *excludes* increases) `:772` |
| PDF layer / vector charts in PDF | **BUILD** (fl_chart is Canvas-only, not portable) | `spending_charts.dart` |
| Privacy-mode amount masking | **REUSE** (`privacyModeEnabled` + `'••••'`) | `supporting_entities.dart:166`; `dashboard_screen.dart:427-433`; `app_metric_card.dart:21-37` |
| Free-text redaction (merchant/note) | **REUSE pattern** (`SmsSanitizer`) | `lib/engine/privacy/sms_sanitizer.dart:72-101` |
| Screenshot protection | **REUSE (partial)** — Android `FLAG_SECURE` global; iOS app-switcher overlay only | `MainActivity.kt:25-28`; `AppDelegate.swift:30-44` |
| Biometric gate | **REUSE** (global via `app.dart:45`, 30s re-lock) | `app_lock_service.dart:40-57`; `app_lock_gate.dart:19-95` |
| Sentry PII scrubbing (`beforeSend`) | **DOES NOT EXIST** — must add | `main.dart:17-30` |
| Temp-file write→share→`finally delete` | **REUSE** | `data_transfer_screen.dart:151-219` |
| Test harness (in-memory Drift + `_MemoryKeyStore` + real repos) | **REUSE** | `test/data/reports_query_test.dart:9-40` |
| Golden / snapshot test infra | **DOES NOT EXIST** — must add if wanted | grep `matchesGoldenFile`/`golden_toolkit` → 0 |

---

## 3. Product scope

One configurable document: **"التقرير المالي / Financial Report."**

**Periods:** Weekly · Monthly · Yearly · Custom range.
**Account scope:** All accounts · One selected account. *(Multiple-selected accounts is an **open decision** — see §25 — because the current repo API does not support an account subset cleanly.)*
**Language:** Arabic (default) · English.
**Currency:** follows existing app behavior (`baseCurrencyProvider`, per-currency grouping, no FX). Mixed-currency periods render **per-currency**, never summed.

**User configuration toggles:** period · accounts · language · include/exclude {transaction details, merchant names, account names, balances, insights} · **privacy mode for sharing**.

**Report answers the six product questions:** earned / spent / where it went / vs previous period / what needs attention / key observations.

---

## 4. MVP and non-goals

### MVP (must-have)
- Config → generate → progress → **preview** → save / share / print, on-device.
- Sections: Cover · Executive summary · Income/Expense/Net/Savings-rate · Previous-period comparison · Spending by category · Daily cash-flow trend · Budget performance · Upcoming/paid bills & subscriptions · Goal progress · Largest/unusual transactions · Rule-based observations · Optional transaction appendix.
- Bilingual AR/EN, RTL-correct, bundled OFL fonts.
- Deterministic rule-based insights (no AI).
- Privacy mode (amount masking + free-text redaction) + share warning.
- Temp-file default (not saved to a history) with reliable cleanup.

### Non-goals (explicitly out for MVP)
- ❌ AI / LLM narrative insights.
- ❌ Any backend/server-side rendering or upload of transactions.
- ❌ Password protection / PDF encryption (later phase — §23).
- ❌ Saved in-app "report history" (later phase; MVP reports are ephemeral).
- ❌ FX conversion / single-currency consolidation of mixed-currency data.
- ❌ Safe-to-Spend and `qirshScore` unless explicitly approved with a defined, transparent formula (§25).
- ❌ Subscription price-increase and "new subscription this period" insights (detection does not exist — §11).
- ❌ Multi-account *subset* scope unless approved to add read-only queries (§25).
- ❌ Scheduled/automated report emailing.

---

## 5. User journeys

**J1 — Generate from Analytics tab (primary).**
Analytics tab (`app_shell.dart` index 4 → `ReportsScreen`) → tap new **"إنشاء تقرير / Create report"** action in `_ReportsHeader` (`reports_screen.dart:53`) → **Config sheet** (period, accounts, language, content toggles, privacy) → **Generate** → **Progress** (determinate + cancel) → **Preview** (paged) → action bar: **Share · Save · Print · Edit settings (regenerate)**.

**J2 — Share with privacy.** From Preview → **Share** → if the report contains sensitive fields and privacy mode is OFF, show a **pre-share warning** ("This report contains account balances and merchant names") with a one-tap **"Mask sensitive data"** that regenerates in privacy mode.

**J3 — Print.** From Preview → **Print** → `printing`'s system print dialog (AirPrint / Android print framework).

**J4 — Deep link.** Existing `'reports' → '/reports'` notification deep link (`local_notification_service.dart:970`) lands on the Analytics tab; the Create-report action is reachable from there. (No new deep link required for MVP.)

**J5 — Error/retry.** Any failure → **Error view** with a plain-language cause + **Retry** (re-runs from the cached snapshot when possible, else re-collects).

All journeys occur **behind the global biometric gate** (`AppLockGate`, `app.dart:45`) since every routed screen inherits it.

---

## 6. Report information architecture

```
Financial Report
├─ 1  Cover + metadata          (brand, title, period, scope, generated-at, privacy badge)
├─ 2  Executive summary         (3–5 headline tiles + one plain-language verdict)
├─ 3  Cash flow                 (income · expense · net · savings rate [· safe-to-spend?])
├─ 4  Comparison                (this period vs previous equivalent, deltas)
├─ 5  Spending by category      (donut/bar + ranked table, per currency)
├─ 6  Trend                     (daily/weekly bars; expense now, income overlay if built)
├─ 7  Budget performance        (bars vs limit, health, projection)
├─ 8  Bills & subscriptions     (upcoming + paid this period + possibly-unused)
├─ 9  Goals                     (progress bars, remaining, recommended pace)
├─ 10 Largest / unusual         (top N transactions + anomaly-day callout)
├─ 11 Observations              (rule-based insights, ranked by severity)
└─ 12 Appendix (optional)       (full transaction table, paginated)
```

Every page carries a **running header** (Mali mark + report title) and **footer** (period label · page X of Y · "Generated by Mali — on device"). Sections collapse gracefully: a section with no data renders a short empty-state line, never a blank page (except the appendix, which is omitted entirely if excluded).

---

## 7. Report page-by-page specification

> Layout language: A4/Letter portrait, page margin `28pt`, section gap `32pt` (mirrors `AppSpacing.sectionGap`), card radius `20pt` (`AppRadius.card`), hairline `#DDE2EC`. Numbers use tabular figures, U+2212 minus, Western digits, trailing currency word — see §15.

**1 · Cover & metadata.** Brand mark (see branding note below), report title, **period label** (localized; reuse `TransactionsDateRange.label` style), **account scope** (name if included, else "All accounts"), generated-at timestamp (device local), language, and a **privacy badge** if privacy mode is on. No financial figures on the cover.

**2 · Executive summary.** 3–5 metric tiles (Income, Expense, Net, Savings rate, optionally #transactions) + one **verdict sentence** generated from the top-ranked insight (e.g. "You spent 12% less than last month and stayed within 3 of 4 budgets."). Plain language, no score.

**3 · Cash flow.** Income / Expense / Net / Savings rate. **Per-currency block** when >1 currency present (`currencyTotalsBetween`). Net sign styled with `income`/`expense` colors (`#16A34A` / `#DC2626`). Safe-to-Spend appears **only if** approved and computable (§25).

**4 · Comparison.** Two-column "This period" vs "Previous equivalent period" for income, expense, net, savings rate, top category — with signed deltas and % (reuse `deltaPercent` semantics; guard `prevTotal == 0 → null`). For custom ranges, the previous window is the same length immediately preceding (matches `reports_providers.dart:166-174`).

**5 · Spending by category.** Vector **donut** (share) + ranked **table** (category, amount, % of spend, count). Colors from the canonical map (`database_seed.dart::_colorFor`, §6 tokens). **Honesty note:** deleted categories are dropped from slices but their spend stays in the denominator (`reports_providers.dart:132`), so shown percentages can sum to <100%; the report adds an explicit **"Other / uncategorized"** remainder row so the table always sums to 100% (a small fix over the current screen behavior).

**6 · Trend.** Daily (weekly/monthly period) or monthly (yearly period) **bar chart** of expense; income overlay only if the income series is built (§10). Include average line and mark the anomaly day if `detectSpendingAnomaly` fires.

**7 · Budget performance.** For each active budget in-period: horizontal bar spent-vs-limit, `health` color (safe/warning/over from `budget_progress_usecase.dart:63-70`), remaining, and projected overrun (from `budget_alert_planner.dart:63-69`). Sorted by ratio desc (as the use case already returns).

**8 · Bills & subscriptions.** Two lists: **Upcoming** (from `nextDueDate` via `getDueBetween` over the period, tagged overdue/today/soon) and **Paid this period** (from `bill_payments` in-window). A muted **"possibly unused"** callout for `mightBeUnused` subscriptions. Annualized cost total. **Honesty note:** "current cycle paid vs unpaid" is *not* derivable today (nextDueDate isn't auto-advanced) — MVP shows due-dates + recorded payments, not a reconciled paid/unpaid state.

**9 · Goals.** Progress bar per goal (`savedAmount/targetAmount`), remaining, days remaining, recommended daily/weekly (`goal_details_usecase.dart`). "Behind schedule" flag is optional (data present; needs a small new comparison — §10).

**10 · Largest / unusual transactions.** Top N by absolute amount in-period (expense side), plus the anomaly-day callout. Merchant names respect the "include merchant names" and privacy toggles.

**11 · Observations.** Ranked rule-based insights (§11), each a one-line plain statement with a severity accent. Cap at ~6–8 to stay meaningful.

**12 · Appendix (optional).** Full transaction table (date, merchant, category, account, amount, currency), paginated with repeating column header, respecting all include/exclude + privacy toggles. Designed for thousands of rows (§17).

---

## 8. Data-source mapping (providers / models / repositories)

The snapshot builder reads **repository providers directly in one async pass** (the pattern `reportsProvider`/`dashboardDataProvider` already use) rather than composing UI Futures, to get a coherent snapshot.

| Report need | Source method / provider | File:line | Type |
|---|---|---|---|
| Expense total (range, account) | `TransactionRepository.expenseTotalBetween` | `drift_transaction_repository.dart:457` | Future SUM |
| Income total (range, account) | `incomeTotalBetween` | `:480` | Future SUM |
| Per-currency income+expense | `currencyTotalsBetween` *(all-accounts only)* | `:519` | Future |
| Category breakdown | `categoryBreakdown` | `:582` | Future |
| Category spend net of refunds | `categoryExpenseTotalBetween` | `:618` | Future |
| Merchant breakdown (top N) | `merchantBreakdown` | `:649` | Future |
| Daily expense series | `dailyExpenseTotals` | `:549` | Future |
| Recurring candidates | `recurringCandidates` | `:754` | Future |
| Latest balance | `latestBalanceAfter` | `:503` | Future |
| Full/paged transactions (appendix) | `getPage` / `getAll` | `:76,79` | Future |
| Accounts (names, currency, exclude flag) | `accountsProvider` → `AccountRepository.getAll` | `app_providers.dart:504`; `account_repository.dart:4` | Future |
| Category catalog (id/key→view+color) | `categoryCatalogProvider` | `category_catalog.dart:55` | Future |
| Budgets + progress | `budgetProgressUseCaseProvider` / `budgetsViewProvider` | `app_providers.dart:949`; `budgets_providers.dart:48` | Future |
| Bills/subs + payments | `billRepositoryProvider` (`getAll`,`getDueBetween`,`getPayments`) | `app_providers.dart:564`; `bill_repository.dart` | Future |
| Goals + details | `goalRepositoryProvider` / `goalDetailsProvider` | `app_providers.dart:599`; `goals_providers.dart:24` | Future |
| Plans + spent | `planRepositoryProvider.spentForPlan` / `plansWithSpentProvider` | `plan_repository.dart:13`; `plans_providers.dart:29` | Future |
| Base currency | `baseCurrencyProvider` (active→default→settings, fallback `'SAR'`) | `app_providers.dart:536` | Future |
| Language | `userSettingsProvider.language` / `localeProvider` (default `ar`) | `settings_providers.dart:38`; `locale_provider.dart:6` | Future/Provider |
| Privacy flag | `userSettingsProvider.privacyModeEnabled` | `supporting_entities.dart:166` | Future |
| Live-refresh tick (for provider layer only) | `dbRevisionProvider` | `app_providers.dart:125` | Stream<int> |

**Consistency rule:** the snapshot builder captures a `capturedAt` timestamp and one set of query results; it does **not** re-read on `dbRevisionProvider` ticks mid-build. Renderer receives the frozen snapshot only.

**Multi-account subset gap:** every date-ranged method takes a single `String? accountId` (`_accountClause` `drift_transaction_repository.dart:388-401`) — one account or all. The only `account_id IN (...)` in the codebase is private to Plans (`_membershipSql :207-217`). Options in §25.

---

## 9. Proposed domain models

Pure Dart, **no Flutter / Riverpod / pdf imports** — lives under `lib/domain/reporting/`.

```dart
// Configuration (immutable, hashable → reusable as cache key)
class ReportRequest {
  final ReportPeriod period;             // sealed: Weekly|Monthly|Yearly|Custom(from,to)
  final ReportScope scope;               // AllAccounts | SingleAccount(id) | Accounts([ids])*
  final String languageCode;             // 'ar' | 'en'
  final ReportContentOptions content;    // include flags below
  final bool privacyMode;
}

class ReportContentOptions {
  final bool includeTransactionDetails;  // the appendix
  final bool includeMerchantNames;
  final bool includeAccountNames;
  final bool includeBalances;
  final bool includeInsights;
}

// Immutable snapshot — the single source of truth for one document
class ReportDataSnapshot {
  final DateTime capturedAt;
  final ReportRequest request;
  final DateRange range;                 // resolved concrete [from,to] UTC
  final DateRange previousRange;         // same-length prior window
  final List<AccountRef> accountsInScope;// name/currency/exclude flag (deleted→placeholder)
  final List<CurrencyTotals> currencyTotals;      // per-currency income/expense
  final List<CategoryAggregate> categories;       // incl. resolved color + "other" remainder
  final List<CategoryAggregate> previousCategories;
  final List<DailyAmount> dailyExpense;           // (+ dailyIncome if built)
  final List<MerchantAggregate> topMerchants;
  final List<TxnLite> largestTransactions;
  final AnomalyResult? anomaly;
  final List<BudgetProgressLite> budgets;
  final List<BillLite> upcomingBills, paidBills, possiblyUnused;
  final List<GoalProgressLite> goals;
  final List<PlanProgressLite> plans;
  final List<TxnLite>? appendixTransactions;      // null unless includeTransactionDetails
}

// Computed metrics (derived from snapshot; pure)
class ReportMetrics {
  final double income, expense, net, savingsRate; // per primary currency
  final ComparisonMetrics comparison;             // deltas vs previousRange
}

// Sections & document (renderer input)
sealed class ReportSectionModel { }               // Cover, Summary, CashFlow, Comparison,
                                                  // Category, Trend, Budget, Bills, Goals,
                                                  // Largest, Observations, Appendix
class ReportDocumentModel {
  final ReportThemeSpec theme;                    // resolved from AppColors.light
  final ReportLocaleSpec locale;                  // dir, strings, formatters
  final List<ReportSectionModel> sections;
}

// Insights
class Insight { final InsightKind kind; final InsightSeverity severity;
               final String messageKey; final Map<String,Object?> args; }
```

`*` `Accounts([ids])` scope exists in the model but is only **wired** if the multi-account decision (§25) is approved.

**Design constraints honored:** amounts stay `double` (matches the app; §24 documents the precision caveat); sign is derived, not stored; refund handling is a single explicit enum on `ReportRequest`/config resolved once in the calculator (§10/§25).

---

## 10. Calculation definitions and formulas

All calculators are **pure functions on `ReportDataSnapshot`**, unit-tested in isolation (mirroring `detectSpendingAnomaly`).

1. **Period resolution.** Reuse `transactionsRangeForPreset` / `effectiveTransactionsRange` (`transactions_providers.dart:118-176`) for weekly/monthly/custom. **BUILD** `yearly`: `from = DateTime(year,1,1)`, `to = min(now, DateTime(year,12,31,23,59,59))`. Preserve **Saturday week start** unless changed (§25). All bounds `.toUtc()` before querying (matches `:472-473`); daily buckets use `'localtime'`. Budget periods keep using `RiyadhTime` (`budget_progress_usecase.dart:141-156`) — note the fixed-Riyadh anchor in §22.

2. **Income / Expense / Net.**
   `expense = expenseTotalBetween(from,to,account)` (`type IN payment,withdrawal`, confirmed).
   `income = incomeTotalBetween(...)` (`type=income`, confirmed).
   `net = income − expense` (matches `dashboard_screen.dart:449`).
   **Refund rule (config-resolved, §25):** default proposal = treat refunds as **negative expense** inside category spend (matches `categoryExpenseTotalBetween`) and **exclude from income** (matches SQL) — one consistent rule, documented on the page.

3. **Savings rate.** `income <= 0 ? null : ((income − expense) / income).clamp(0,1)` — same as `savingsScore` (`dashboard_providers.dart:153-158`) but returns `null` (shown as "—") instead of a magic `50` when income is 0.

4. **Comparison.** `deltaAbs = current − previous`; `deltaPct = previous == 0 ? null : (current − previous)/previous` (reuse `ReportSection.deltaPercent` `:27-28`). Applied to income, expense, net, savings rate, top-category spend.

5. **Category aggregation.** Reuse `categoryBreakdown`; resolve `catalog.byId ?? byKey`; **add** an explicit `Other/uncategorized` remainder = `totalSpend − Σ(resolved slices)` so shares sum to 100% (fixes the <100% drift at `reports_providers.dart:132`).

6. **Trend.** Reuse `dailyExpenseTotals`; `averageDaily`/`highestDaily`/`bestSavingsDay` from `ReportSection` getters (`:30-46`); `detectSpendingAnomaly` (`:179-207`) for the callout. **Income overlay is BUILD-NEW** (no `dailyIncomeTotals`); MVP may ship expense-only trend and defer the overlay (§25).

7. **Budgets.** Reuse `BudgetProgressUseCase` → `{spent, remaining, ratio, health}` and `BudgetAlertPlanner` projection `projected = spent + (spent/daysPassed)*daysRemaining` (`:63-69`).

8. **Bills/subs.** Upcoming = `getDueBetween(from,to)`; paid = `getPayments` where `paidAt ∈ [from,to]`; unused = `BillEntity.mightBeUnused`; annualized cost = existing `_annualSubscriptionCost` logic.

9. **Goals.** Reuse `GoalDetailsUseCase` (progress, remaining, recommendedDaily/Weekly, daysRemaining). Optional behind-schedule: `elapsedFraction = (now−createdAt)/(deadline−createdAt); behind = progress < elapsedFraction` (BUILD, data present).

10. **Plans.** Reuse `PlanProgress` (`ratio`, `isOver`, `perDayLeft`) with the multi-account `IN` query already in `spentForPlan`.

11. **Multi-currency.** Never sum across currencies. Primary currency = `baseCurrencyProvider`; other currencies rendered as separate blocks from `currencyTotals`. (Account-scoped multi-currency needs the new query — §25 — because `currencyTotalsBetween` has no `accountId` param.)

**Decimal precision caveat (documented, not silently ignored):** `Formatters` hard-codes 2 decimals and locale `en_US` (`formatters.dart:9-10`), ignoring per-currency `decimal_places` in `assets/catalog/currencies.json`. The report uses a **report-scoped formatter** that reads per-currency decimals so 3-decimal Gulf currencies (KWD/BHD/OMR) render correctly — a bug the app has today (§24).

---

## 11. Rule-based insights specification

Deterministic engine under `lib/domain/reporting/insights/`. Each rule is a pure `Insight? evaluate(ReportDataSnapshot)`. Output is localized via message keys (AR/EN), ranked by severity, capped at ~8. **No AI. No fabricated metrics.**

| Rule | Fires when | Inputs (all real) | Severity | MVP? |
|---|---|---|---|---|
| Spending up/down vs previous | `|deltaPct(expense)| ≥ 10%` | comparison | info/warn | ✅ |
| Savings rate improved/declined | `Δ savingsRate ≥ 5pp` | comparison | success/warn | ✅ |
| Category over budget | any `budget.health == over` | `BudgetProgressEntry` | danger | ✅ |
| Budget projected overrun | `projected > limit` & not yet over | `BudgetAlertPlanner` | warn | ✅ |
| Dominant category | top category share `≥ 40%` of spend | category aggregates | info | ✅ |
| Bill due soon | `nextDueDate` within N days of period end | `getDueBetween` | warn | ✅ |
| Possibly-unused subscription | `mightBeUnused == true` | `BillEntity` | info | ✅ |
| Unusual spending day | `detectSpendingAnomaly` fires | daily series | info | ✅ |
| Goal behind schedule | `progress < elapsedFraction` | goal + dates | warn | ⚠ opt |
| **Recurring expense increased** | — | **NO detection exists** (variance filter excludes it) | — | ❌ defer |
| **New subscription appeared** | — | `recurringCandidates` is a recurrence heuristic, **not** "new this period" | — | ❌ defer* |

`*` A weaker proxy ("newly detected recurring merchant") is possible using `merchants.first_seen_at`, but it is **not** a true price/new-subscription signal — proposed as a later, clearly-labeled enhancement rather than an MVP claim.

Each insight is transparent (states the number and threshold) — no opaque scoring.

---

## 12. Architecture and dependency flow

Five strictly separated layers. **Arrows point in one direction; the renderer never reaches back into providers.**

```
┌────────────────────────────────────────────────────────────────────┐
│ UI (features/reporting/ui)  — Riverpod, BuildContext, l10n           │
│  ReportConfigSheet → ReportGenerationController (StateNotifier-free   │
│  AsyncNotifier)                                                       │
└───────────────┬──────────────────────────────────────────────────────┘
                │ ReportRequest
                ▼
┌────────────────────────────────────────────────────────────────────┐
│ (1) DATA COLLECTION  — data/reporting/ReportSnapshotBuilder          │
│  reads repositories in ONE async pass → ReportDataSnapshot (frozen)  │
│  (Riverpod-aware; the ONLY layer that touches repos)                 │
└───────────────┬──────────────────────────────────────────────────────┘
                │ ReportDataSnapshot (immutable, pure data)
                ▼
┌────────────────────────────────────────────────────────────────────┐
│ (2) CALCULATION  — domain/reporting/metrics + insights (PURE)        │
│  ReportMetricsCalculator · ComparisonCalculator · PeriodResolver ·   │
│  InsightEngine → ReportMetrics + List<Insight>                       │
└───────────────┬──────────────────────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────────────────────┐
│ (3) COMPOSITION  — domain/reporting/ReportComposer (PURE)            │
│  snapshot + metrics + insights + theme + locale → ReportDocumentModel │
└───────────────┬──────────────────────────────────────────────────────┘
                │ ReportDocumentModel (plain models + resolved fonts bytes)
                ▼
┌────────────────────────────────────────────────────────────────────┐
│ (4) PDF RENDERING  — features/reporting/pdf/ReportPdfRenderer        │
│  pure: (document, fontBytes) → Uint8List.  NO Riverpod, NO repo,     │
│  NO BuildContext.  Runs in Isolate.run().                            │
└───────────────┬──────────────────────────────────────────────────────┘
                │ Uint8List (pdf bytes)
                ▼
┌────────────────────────────────────────────────────────────────────┐
│ (5) FILE DELIVERY  — features/reporting/services/ReportFileService   │
│  temp write · safe name · share_plus/printing · print · cleanup      │
└────────────────────────────────────────────────────────────────────┘
```

**Rules enforced:**
- Renderer input is a `ReportDocumentModel` + `Uint8List` font bytes only. Fonts are loaded from `rootBundle` on the **main isolate** and passed in (a background isolate cannot use `rootBundle`).
- The isolate boundary carries only sendable plain data (snapshot/document are pure); the resulting bytes come back. `printing`'s platform calls (print/share dialogs) stay on the main isolate.
- The controller owns progress/cancel/error/retry (§18) and caches the last `ReportDataSnapshot` so "regenerate with different toggles" can skip re-collection when data hasn't changed.

### New dependencies (justified)

| Package | Why needed | Exact responsibility | AR/RTL | Fonts | Vector | Print | Share | Platform | Maintenance risk |
|---|---|---|---|---|---|---|---|---|---|
| **`pdf`** (`^3.11.x`, pkg `pdf`) | Only mature pure-Dart PDF document builder; no PDF layer exists | Build `pw.Document`, layout, tables, vector charts, embed TTF fonts | Yes — `pw.Directionality(rtl)` + shaping-capable TTF; **must prototype shaping** | Yes — `pw.Font.ttf(byteData)` | Yes — `pw.CustomPaint`/native chart primitives | via `printing` | via `printing`/`share_plus` | Pure Dart, all platforms | Low — de-facto standard, active (DavBfr) |
| **`printing`** (`^5.13.x`) | System print dialog + preview widget + PDF sharing that `pdf` itself lacks | `Printing.layoutPdf` (print), `PdfPreview` widget, `Printing.sharePdf`, raster fallback | inherits pdf | — | — | Yes (AirPrint/Android print) | Yes | iOS/Android/macOS/Win/Linux/web | Low — same author, widely used |

`share_plus` (already `^10.1.4`), `path_provider` (`^2.1.4`) are reused as-is (§19/§20). We may skip `Printing.sharePdf` and reuse the app's existing `Share.shareXFiles` pattern to minimize surface area — **open decision** (§25). No other new deps. **No AI, no backend, no HTTP** added.

---

## 13. Folder and file structure

New feature `reporting` (kept distinct from the existing on-screen `features/reports/` to avoid confusion; the existing screen only gains a launch button).

```
lib/
  domain/reporting/                      # PURE (no flutter/riverpod/pdf)
    report_request.dart
    report_content_options.dart
    report_data_snapshot.dart
    report_metrics.dart
    report_section_model.dart            # sealed section models
    report_document_model.dart
    date_range.dart
    metrics/
      period_resolver.dart               # + yearly (BUILD)
      report_metrics_calculator.dart
      comparison_calculator.dart
      category_aggregator.dart           # + "other" remainder
    insights/
      insight.dart
      insight_rule.dart
      insight_engine.dart
      rules/
        spending_trend_rule.dart
        savings_rate_rule.dart
        budget_over_rule.dart
        budget_projection_rule.dart
        dominant_category_rule.dart
        bill_due_rule.dart
        unused_subscription_rule.dart
        anomaly_rule.dart
        goal_behind_rule.dart            # optional
    report_composer.dart                 # snapshot+metrics+insights → document
  data/reporting/
    report_snapshot_builder.dart         # reads repos in ONE async pass
    report_query_ext.dart                # NEW read-only account-subset queries (IF approved)
  features/reporting/
    providers/
      report_providers.dart              # request state, snapshot future, controller
    pdf/
      report_theme_spec.dart             # mirrors AppColors.light + accent
      report_fonts.dart                  # loads bundled OFL TTFs (main isolate)
      report_pdf_renderer.dart           # PURE: document+fonts → bytes (Isolate.run)
      components/                         # reusable pw widgets (see §14)
        pdf_page_scaffold.dart
        pdf_header_footer.dart
        pdf_cover.dart
        pdf_section_title.dart
        pdf_metric_tile.dart
        pdf_kv_table.dart
        pdf_data_table.dart
        pdf_progress_bar.dart
        pdf_donut_chart.dart
        pdf_bar_chart.dart
        pdf_line_chart.dart
        pdf_insight_row.dart
        pdf_amount_text.dart             # RTL-safe, tabular, per-currency decimals
        pdf_empty_state.dart
    services/
      report_file_service.dart           # temp/name/save/share/print/cleanup
      report_generation_controller.dart  # progress/cancel/error/retry
      report_redactor.dart               # privacy-mode masking (reuses SmsSanitizer pattern)
    ui/
      report_launch_action.dart          # button injected into _ReportsHeader
      report_config_sheet.dart
      report_progress_view.dart
      report_error_view.dart
      report_preview_screen.dart         # route: /reports/preview
assets/fonts/                            # NEW bundled OFL TTFs
  IBMPlexSansArabic-Regular.ttf, -Medium.ttf, -SemiBold.ttf, -Bold.ttf
  IBMPlexSans-Regular.ttf, -Medium.ttf, -SemiBold.ttf, -Bold.ttf
test/
  domain/reporting/…                     # pure metric/insight/period tests
  data/reporting/report_snapshot_builder_test.dart
  features/reporting/pdf/…               # golden/snapshot tests (if infra added)
```

`pubspec.yaml` additions: `pdf`, `printing` deps; a `fonts:` section for the bundled TTFs; the `assets/fonts/` path.

---

## 14. Reusable PDF component inventory

Each is a pure `pw.Widget` factory taking data + `ReportThemeSpec` + `ReportLocaleSpec` (no Riverpod/context):

1. **`PdfPageScaffold`** — margins, running header/footer slots, RTL direction, page-number resolution.
2. **`PdfHeaderFooter`** — Mali mark + title (header); period · "page X of Y" · on-device note (footer).
3. **`PdfCover`** — logo, title, period, scope, generated-at, privacy badge.
4. **`PdfSectionTitle`** — section heading + optional subtitle, consistent spacing.
5. **`PdfMetricTile`** — label + big tabular amount + optional delta chip (income/expense colored).
6. **`PdfKvTable`** — 2-column key/value (used by cash-flow, comparison).
7. **`PdfDataTable`** — striped, header-repeating, RTL-aware table (category table, appendix). Handles pagination.
8. **`PdfProgressBar`** — horizontal ratio bar with health color (budgets, goals, plans).
9. **`PdfDonutChart`** — vector donut with legend + center total (category share).
10. **`PdfBarChart`** — vector bars with average line + anomaly marker (trend, budgets).
11. **`PdfLineChart`** — vector line/area (optional income-vs-expense overlay).
12. **`PdfInsightRow`** — severity dot + one-line insight text.
13. **`PdfAmountText`** — the critical primitive: tabular figures, U+2212 minus, Western digits, per-currency decimals, LTR-wrapped numeric run inside an RTL page, trailing Arabic/EN currency word.
14. **`PdfEmptyState`** — one-line graceful empty message for data-less sections.

Charts are drawn as **vectors** (not rasterized widget screenshots) using `pdf`'s primitives — satisfying "no screenshots, vector where practical, no decorative charts."

---

## 15. Arabic, RTL, font, and localization strategy

**Fonts (the hard part).** The app's fonts are **IBM Plex Sans Arabic + IBM Plex Sans**, both **OFL 1.1 → legally embeddable in a PDF** (`app_typography.dart:23,33`). They are currently **runtime-fetched by `google_fonts` and not present on disk** — a headless/isolate PDF renderer cannot rely on that. **Strategy: bundle the TTFs** in `assets/fonts/` and load via `pw.Font.ttf(await rootBundle.load(...))` on the main isolate, passing bytes into the renderer. Bundle Regular/Medium/SemiBold/Bold weights (matches the app's `w400–w700` usage after the design doc's "retire w800" guidance). **SF Pro is explicitly NOT bundled** (proprietary; not present in repo — confirmed).

**Shaping.** `package:pdf` does not use the OS shaper; correct Arabic ligatures/joining depend on the TTF + pdf's bidi handling. **This must be prototyped in Phase 1** with real Arabic merchant names and mixed AR/Latin/number strings before committing to layout work. If pdf's built-in shaping proves insufficient, the fallback is to pre-shape strings — flagged as a risk (§24).

**RTL.** Mirror the app's proven pattern: an **RTL page** (`pw.Directionality(textDirection: TextDirection.rtl)` when `language=='ar'`) with **numeric runs forced LTR** (the app wraps amounts/nav in LTR — `dashboard_screen.dart:491`, `app_shell.dart:1221`). `PdfAmountText` (§14) encapsulates this. Direction is **derived from the language string**, not `Directionality.of(context)` (unavailable in a headless renderer).

**Numbers & currency.** Keep the app's conventions: **Western digits (0–9)**, `,` thousands / `.` decimal (`NumberFormat('#,##0.00','en_US')`), **U+2212** minus for expenses (`formatters.dart:49-52`), trailing **currency word** (`Currency.money → "1,240.00 ريال"`, `currency.dart:52-54`). **Improvement:** the report formatter reads per-currency `decimal_places` from `assets/catalog/currencies.json` so KWD/BHD/OMR render 3 decimals (the app currently mis-renders these — §24). For English reports, either keep the Arabic currency word (app's current behavior) or use the ISO symbol from the catalog (`ر.س`, `name_en`) — **open decision** (§25).

**l10n.** Add ~40–60 report string keys to **both** `lib/l10n/app_ar.arb` (template) and `app_en.arb`, regenerate `AppL10n` via `flutter gen-l10n`. UI reads `context.l10n`; the renderer receives a resolved `ReportLocaleSpec` (a plain string map + direction) built from `AppL10n` on the main isolate — so the pure renderer needs no `BuildContext`.

---

## 16. Privacy and security model

**Principle: on-device only.** Generation reads local Drift and writes a local temp file. **No transaction data is uploaded to create a PDF.** Nothing in this feature calls Supabase/HTTP. (If a future phase ever needs server rendering, it will be called out explicitly — none is planned.)

**Privacy controls (before generation).** Config sheet exposes include/exclude {merchant names, account names, balances, transaction details, insights} and a **privacy mode** toggle. Privacy mode reuses the existing `privacyModeEnabled` convention (`supporting_entities.dart:166`) and the `'••••'` masking used app-wide (`dashboard_screen.dart:427-433`, `app_metric_card.dart:21-37`) via a `ReportRedactor`:
- Amounts → `'••••'` when masked.
- Merchant/note free-text → redacted using the **`SmsSanitizer` pattern** (`sms_sanitizer.dart:72-101`) so account numbers / names embedded in merchant strings don't leak.
- Account numbers/`card_last4` → last-4 only or hidden per toggle.

**Share warning.** Before share/print of an **unmasked** report containing balances or merchant names, show a confirmation with a one-tap "mask & regenerate."

**Screenshot / app-switcher.** Android `FLAG_SECURE` (global, `MainActivity.kt:25-28`) already blocks screenshots + switcher thumbnails everywhere, including the preview. iOS has an app-switcher overlay (`AppDelegate.swift:30-44`) but **does not block in-app screenshots** — a documented gap; if the preview must be screenshot-proof on iOS, that is a native add (§24/§25).

**Biometric.** The preview/route inherits the global `AppLockGate` (`app.dart:45`, 30s re-lock). Optional forced re-auth on opening a report is a small add if desired.

**Logging / crash / analytics.**
- App uses `debugPrint` only (not sent to Sentry). **Discipline: report code logs no transaction data and throws no data-bearing exception messages.**
- **Add a Sentry `beforeSend` scrubber** — currently **absent** (`main.dart:17-30`). Without it, an uncaught exception whose message embeds an amount/merchant would reach Sentry. `sendDefaultPii=false`/`attachScreenshot=false`/`tracesSampleRate=0` are already set; the scrubber closes the message-content gap.
- `MetricsClient` is safe (event-key + fixed dimension only, `metrics_client.dart:10-32`). Report telemetry, if any, emits only counters like `report_generated` — never amounts/merchants.

**Deleted / unavailable accounts.** Accounts soft-delete via `deleted_at` and are invisible to `AccountEntity`. If a report is scoped to an account that becomes unavailable mid-generation, the snapshot records an `AccountRef` placeholder ("Unavailable account") and the figures for confirmed transactions still resolve from the frozen snapshot. Deleted categories already resolve to the "Other" remainder (§10).

**Encryption / password protection.** Deferred to a later phase (§23). `pdf` supports `PdfEncryption`/owner+user passwords; MVP relies on on-device generation + OS file sandboxing + the share warning.

---

## 17. Performance strategy

- **Thousands of transactions.** Totals/breakdowns are already **SQL aggregates** (SUM/GROUP BY) — O(rows) in SQLite, not in Dart. The only large in-Dart payload is the **optional appendix**; fetch it via `getPage(offset,limit)` (`:79`) in chunks, stream rows into `PdfDataTable` page-by-page rather than materializing everything.
- **No UI freeze.** Run the pure `ReportPdfRenderer` in a background isolate via **`Isolate.run`** (SDK 3.4+ available; the app's existing isolate precedent is `Isolate.spawn` in `parser_isolate.dart`, but `Isolate.run` is simpler for a one-shot build). Snapshot/document are pure/sendable; bytes return to the main isolate.
- **Fonts.** Load TTF bytes once on the main isolate, cache in a top-level `ReportFonts` holder, pass into the isolate. Avoids repeated `rootBundle` loads and keeps fonts off the network entirely.
- **Chart cost.** Vector charts are cheap; cap category slices (~top 18, as the screen already does `reports_providers.dart:133`) and merchant rows to keep the donut/legend readable.
- **Memory / pagination.** `pdf` builds pages lazily with `pw.MultiPage`; the appendix uses `MultiPage` with a repeating header so a 20-page table doesn't hold all widgets at once. Target: keep peak memory bounded regardless of transaction count.
- **Progress reporting.** Coarse determinate stages: Collect (30%) → Compute (10%) → Compose (10%) → Render (40%) → Write (10%). The isolate posts stage updates back over its port.
- **Cancellation.** Cooperative: the controller sets a cancel flag checked between stages and between appendix page batches; on cancel, kill the isolate and delete any partial temp file.

---

## 18. Error handling and cancellation

`ReportGenerationController` is an `AsyncNotifier`-style state machine (no `StateNotifier`, matching the app's convention — `transactions_providers.dart:195`):

```
Idle → Collecting → Computing → Composing → Rendering → Writing → Ready(bytes,file)
                                     �“cancel”↘ Cancelled (temp cleaned)
                                     �“throw”↘  Failed(reason) → Retry
```

- **Error taxonomy** (plain-language, localized): `noData` (empty period), `fontLoadFailed`, `renderFailed`, `writeFailed`, `shareFailed`, `cancelled`, `unknown`. Each maps to a specific message + whether Retry re-collects or re-renders.
- **Retry** re-uses the cached `ReportDataSnapshot` when the failure is downstream of collection (render/write), avoiding a second DB pass.
- **No data:** produces a valid one-page report with an empty-state summary rather than an error, unless the user chose an empty custom range (then `noData` with guidance).
- **Failures never surface raw exception text** to the user or logs (privacy §16).

---

## 19. File lifecycle, naming, storage, and cleanup

- **Storage:** `getTemporaryDirectory()` (the app's established share pattern — `data_transfer_screen.dart:174`), **not** documents dir, so MVP reports are ephemeral.
- **Naming (safe):** `Mali-Report-<periodSlug>-<YYYY-MM-DD_HH-mm>.pdf`, timestamp sanitized like the CSV path (`toIso8601String().replaceAll(RegExp(r'[:.]'),'-')`, `data_export.dart:20-21`). ASCII-only slug (transliterate/omit Arabic) to avoid filesystem/`Content-Disposition` issues; period slug from the resolved range, never from user free-text.
- **Cleanup:** write → preview/share/print → **delete in `finally`** (clone `data_transfer_screen.dart:213-216`, which deletes on every early-return/error branch too). Note `data_export.dart` currently **leaks** its temp file — we do **not** repeat that mistake. On app start, an optional best-effort sweep of stale `Mali-Report-*.pdf` in temp (no app-wide sweeper exists today).
- **Ephemeral vs history:** MVP = **ephemeral temp file, no in-app history**. A privacy-safe, biometric-gated "recent reports" list is a later phase (§23) — flagged because storing generated financial PDFs on disk is itself a privacy surface.

---

## 20. Preview / save / share / print behavior

- **Preview happens before sharing**, always. `report_preview_screen.dart` (route `/reports/preview`, behind `AppLockGate`) shows the paged PDF. Two implementation options: `printing`'s `PdfPreview` widget (fastest, includes built-in print/share buttons) **or** a custom paged viewer over rendered pages — **open decision** (§25).
- **Save:** write to a user-chosen location via the OS (`printing`/`share_plus` "save to Files"); MVP may treat "Save" as "Share → Save to Files" to avoid extra scope.
- **Share:** reuse `Share.shareXFiles([XFile(path, mimeType:'application/pdf', name: fileName)], sharePositionOrigin: …)` — the exact call the app already uses for CSV/backup (`data_transfer_screen.dart:199-210`), with the iPad popover origin. Gated by the privacy warning (§16).
- **Print:** `Printing.layoutPdf(onLayout: (_) => bytes)` → system print dialog (AirPrint / Android print).
- **Regenerate / edit settings:** Preview action bar → back to Config sheet with current `ReportRequest` pre-filled; regenerating with the same data reuses the cached snapshot.

---

## 21. Testing matrix

Harness: **in-memory Drift (`NativeDatabase.memory()`) + `_MemoryKeyStore` + real repositories** (the app's standard, `reports_query_test.dart:9-40`). Pure calculators/insights tested as free functions (like `detectSpendingAnomaly`).

| Area | Tests | Type |
|---|---|---|
| Income/Expense/Net/Savings-rate | Value correctness per currency; income=0 → savings null; refund rule applied once | Unit (pure) |
| Previous-period comparison | Same-length prior window; `prev==0 → null` delta; custom-range prior window | Unit |
| Category aggregation | Shares sum to 100% incl. "Other"; deleted category → remainder; uncategorized handling | Unit |
| Currency & precision | 2-dp default, 3-dp KWD/BHD/OMR; `,`/`.` separators; U+2212 minus; trailing label | Unit |
| Date boundaries / timezone | Sat week start; month/year edges; leap year (Feb 29); UTC↔localtime bucketing; DST/Riyadh anchor | Unit |
| Transaction classification | transfers excluded; only internal stays transfer; pending/ignored excluded; refund per chosen rule | Unit (via repo) |
| Budget/goal/plan metrics | health thresholds 0.8/1.0; projection; goal recommended pace; plan `IN` membership | Unit |
| Insights engine | each rule fires/does-not at threshold boundaries; ranking; cap; unavailable rules absent | Unit |
| Privacy config | masked amounts `'••••'`; merchant/note redaction; excluded sections omitted; account-number hiding | Unit |
| Snapshot consistency | mutate DB after snapshot → rendered figures unchanged | Integration |
| Large dataset | 10k transactions → generation completes, memory bounded, appendix paginates | Perf/integration |
| Empty data | no transactions → valid one-page report, no crash | Unit/golden |
| RTL rendering | AR report direction, numeric LTR runs, mixed AR/Latin | Golden (if infra) |
| Page snapshots | cover, summary, category, appendix pages | **Golden — needs new infra** (`golden_toolkit` or `matchesGoldenFile`) |
| File lifecycle | temp created; deleted in finally on success/cancel/error; safe filename | Integration |
| Save/share/print | invoked with correct mime/name (mock platform channels) | Integration (where feasible) |

**Edge cases explicitly covered:** no transactions · income-only / expense-only · transfers excluded (matching app) · refunds (chosen rule) · edited txns (plain update, no special handling — asserted) · split (N/A — asserted absent) · multiple currencies · deleted categories · deleted accounts (placeholder) · pending (excluded) · very long / Arabic merchant names (wrap/ellipsis) · custom ranges · leap years & month boundaries · timezone/DST · extremely large amounts (tabular formatting) · negative balances · many-page reports.

**Gate discipline:** `flutter analyze` (0 issues), `flutter test` (all green incl. current 136), `flutter gen-l10n` after ARB edits — per CLAUDE.md.

---

## 22. Migration and compatibility considerations

- **No DB schema change, no migration, no schema-version bump.** All report data is readable through existing methods. (The optional account-subset feature adds **read-only query methods** — new SQL SELECTs, not table changes — only if approved.)
- **No sync change.** Reports read local Drift only; nothing touches the outbox/Supabase paths.
- **No provider rewrite.** New providers are additive; existing ones are only *read*.
- **`pubspec` additions:** `pdf`, `printing`, a `fonts:` section + `assets/fonts/` (~1–2 MB of TTFs). No transitive AI/backend deps.
- **ARB additions** are backward-compatible content changes; `flutter gen-l10n` regenerates `AppL10n`.
- **Classification preserved:** the report reads persisted `type`/`status`, so it inherits the app's exact income/expense/transfer/refund/pending rules with zero divergence — except the **one deliberate refund choice** it documents (§25).
- **Branding note (corrected during the sample-PDF exercise):** there is **no "Mali" logo asset in the repo**. The only brand images on disk are the **old gold "Qirsh" coin** (`assets/logo/logo_light.png` == `assets/brand/branding_light_1024.png`, and `assets/qirsh/qirsh_logo_tagline.png` with the "كل قرش محسوب / Every Qirsh Counts" tagline; `assets/brand/symbol_green_light.png` is a divergent green mark). These are **gold/blue**, which clashes with the plan's blue→indigo (`#2E6BFF→#5B4FE0`) accent. The report needs an official **Mali** mark before launch; until one exists, either ship with the real Qirsh coin (brand-consistent as a *Qirsh* document) or a generated placeholder Mali mark. See open decision #13.
- **CLAUDE.md drift:** doc says schema v4 / ~70 tests; reality is **v26 / 136 tests** — worth correcting in a separate housekeeping change (not part of this feature).

---

## 23. Implementation phases

Complexity scale: **S** ≈ trivial, **M** ≈ moderate, **L** ≈ substantial, **XL** ≈ large/risky.

| Phase | Deliverable | Complexity | Depends on |
|---|---|---|---|
| **P0 — Domain + math (no PDF, no UI)** | `ReportRequest`, `ReportDataSnapshot`, `PeriodResolver` (+yearly), `ReportMetricsCalculator`, `ComparisonCalculator`, `CategoryAggregator`, `ReportSnapshotBuilder`; full **unit tests**; proves figures match app | **M** | — |
| **P1 — PDF spine + font/RTL prototype** | Add `pdf`/`printing`, bundle OFL TTFs, `ReportThemeSpec`, `ReportFonts`, `PdfPageScaffold`/`PdfAmountText`, render **one page** (cover+summary) in AR & EN; **validate Arabic shaping** | **L** (risk front-loaded) | P0 |
| **P2 — Full composition + charts** | All section models, `ReportComposer`, vector donut/bar/line, tables, appendix pagination; `Isolate.run` rendering | **L** | P1 |
| **P3 — UX flow** | Launch action in `_ReportsHeader`, `ReportConfigSheet`, `ReportGenerationController` (progress/cancel/error/retry), `ReportPreviewScreen`, save/share/print, `ReportFileService` cleanup | **L** | P2 |
| **P4 — Insights engine** | `InsightEngine` + MVP rules (§11), verdict sentence, ranking; unit tests | **M** | P0/P2 |
| **P5 — Privacy hardening** | `ReportRedactor`, share warning, Sentry `beforeSend` scrubber, temp-sweep, filename safety, log discipline | **M** | P3 |
| **P6 — Optional/later** | Golden-test infra; account-subset read-only queries; income-overlay trend; goal behind-schedule; report history; **PDF encryption/password**; iOS in-app screenshot block; safe-to-spend / score (if approved) | **M–XL** | as needed |

---

## 24. Risks and mitigations

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | **Arabic shaping/bidi in `package:pdf`** renders disconnected/wrong glyphs | **High** | Prototype in **P1** with real Arabic merchant/mixed strings before layout work; fallback to pre-shaping; treat as go/no-go gate |
| R2 | Fonts unavailable in isolate (google_fonts is network/runtime) | High | **Bundle OFL TTFs**, load bytes on main isolate, pass into renderer |
| R3 | Refund/transfer semantics mismatch vs app | Med | Pick **one** refund rule (§25), document on page, unit-test against repo behavior; transfers inherited automatically |
| R4 | Multi-currency confusion (no FX) | Med | Never sum across currencies; per-currency blocks; primary = `baseCurrencyProvider` |
| R5 | Precision bug for 3-decimal Gulf currencies (app has it today) | Med | Report formatter reads per-currency `decimal_places`; keep `double` but format correctly |
| R6 | Account-subset scope not supported by repo API | Med | Defer, or add **read-only** `IN (...)` methods (proven pattern in `spentForPlan`); do not fake with lossy Dart fan-out |
| R7 | UI freeze / OOM on huge appendix | Med | Isolate render + `MultiPage` streaming + chunked `getPage`; cap slices/merchants |
| R8 | PII leak via Sentry/logs | Med | Add `beforeSend` scrubber; no data-bearing `debugPrint`/exception messages |
| R9 | iOS in-app screenshot of sensitive preview | Low–Med | Documented gap; optional native block in P6; privacy mode reduces exposure |
| R10 | Temp-file leak | Low | `finally`-delete pattern + startup sweep |
| R11 | "New subscription"/"price increase" insights promise data we don't have | Med | **Excluded from MVP**; only ship insights the data supports |
| R12 | Golden tests brittle across platforms/font versions | Low | Pin bundled TTFs; tolerance/CI-host goldens; keep goldens optional |
| R13 | Scope creep into history/encryption/AI | Med | Hard non-goals (§4); phased in P6 |

---

## 25. Open product decisions requiring your approval

1. **Refund treatment.** Proposal: refunds = **negative expense within category spend, excluded from income** (one consistent rule). Alternatives: include-with-income (matches a Dart getter) or a separate "refunds" line. **Which?**
2. **Multi-account subset scope.** Not supported cleanly today. (a) Ship **All / Single only** for MVP (recommended), or (b) approve **read-only** `account_id IN (...)` query methods now?
3. **Safe-to-Spend.** No logic exists. Omit for MVP (recommended), or define a formula now (e.g. `remainingBudget − projectedRemainingSpend`)?
4. **`qirshScore` / health score.** Exists but composite/opaque (`dashboard_providers.dart:167`). Recommend **omit** (prefer transparent metrics). Include as an optional, explained tile?
5. **Reports: ephemeral vs history.** Recommend **ephemeral temp file** for MVP; biometric-gated history later. Agree?
6. **Default privacy on share.** Recommend **warn + opt-in masking** (share unmasked only after confirmation). Or **default-masked** shares?
7. **MVP insight set.** Confirm the ✅ rules in §11 and that price-increase / new-subscription are **deferred**.
8. **Week start & yearly.** Keep **Saturday** week start (app default) and add **calendar-year** yearly. Agree?
9. **English currency label.** In EN reports, keep the Arabic currency word (app behavior) or switch to ISO symbol / `name_en` from the catalog?
10. **Font bundle.** Approve bundling IBM Plex Sans Arabic + IBM Plex Sans TTFs (OFL) into `assets/fonts/` (~1–2 MB)?
11. **Preview + share libs.** Use `printing`'s `PdfPreview` + `Printing.sharePdf`, or reuse the app's existing `Share.shareXFiles` and a custom preview to minimize surface?
12. **iOS in-app screenshot block.** Add native protection for the preview (P6), or accept the documented gap for MVP?
13. **Brand mark on the report.** No Mali logo asset exists — only the gold "Qirsh" coin (old brand, gold/blue). Ship the report as *Qirsh* using the real coin, generate a placeholder blue→indigo *Mali* mark, or block on you providing an official Mali logo? *(Confirmed via the sample-PDF exercise, where the real coin was used and the wordmark set to Qirsh/قرش.)*

---

## Recommended MVP scope

**Ship:** one Financial Report; periods Weekly/Monthly/Yearly/Custom; scope **All / Single account**; AR + EN, RTL-correct, bundled OFL fonts; sections 1–11 (§6) plus **optional appendix**; deterministic insights (§11 ✅ set); privacy mode + share warning; on-device generation in an isolate; preview → save/share/print; ephemeral temp file with reliable cleanup. **Defer:** multi-account subset, income-overlay trend, safe-to-spend/score, price-increase/new-sub insights, report history, PDF encryption, iOS in-app screenshot block, golden-test infra (nice-to-have).

## Estimated implementation complexity by phase

P0 **M** · P1 **L (front-loaded risk)** · P2 **L** · P3 **L** · P4 **M** · P5 **M** · P6 **M–XL** (optional). The bulk of risk is **P1** (Arabic-in-PDF); the bulk of surface area is **P2+P3**.

## Smallest safe first phase

**P0 only** — pure domain models, calculators, and the snapshot builder, with full unit tests, **no `pdf`/`printing` dependency, no UI, no isolate**. It changes nothing user-facing, adds no dependencies, cannot regress the app, and proves the numbers match existing screens before any rendering investment. It is fully reversible and keeps `analyze`/`test` green.

## Product decisions needed from you (quick list)

Refund rule (#1) · account-subset yes/no (#2) · safe-to-spend omit/define (#3) · score include/omit (#4) · ephemeral vs history (#5) · share privacy default (#6) · MVP insight set (#7) · week-start/yearly (#8) · EN currency label (#9) · font bundling (#10) · preview/share lib choice (#11) · iOS screenshot block (#12).

## Ready-for-approval checklist

- [ ] §25 decisions #1–#12 answered (at minimum #1, #2, #3, #5, #10 to start P0/P1).
- [ ] Approve adding `pdf` + `printing` dependencies and a `fonts:` asset section.
- [ ] Approve bundling IBM Plex Sans Arabic + IBM Plex Sans (OFL) TTFs (~1–2 MB).
- [ ] Approve **no** DB/schema/sync changes for MVP (read-only account-subset queries only if #2 = yes).
- [ ] Approve the layered architecture (§12) — renderer never touches Riverpod/repos; one immutable snapshot.
- [ ] Approve the refund rule and its on-page disclosure (§10/§25 #1).
- [ ] Approve the MVP insight set and the explicit deferral of price-increase / new-subscription insights (§11).
- [ ] Approve starting with **P0 (domain + math + tests)** and treating **P1 Arabic-shaping** as a go/no-go gate before UI.
- [ ] Confirm gate policy: `flutter analyze` clean, `flutter test` green, `flutter gen-l10n` run after ARB edits; **do not commit** (leave in working tree).

---

*Prepared from a read-only inspection of `feat/accounts-multicurrency`. No production code written. Awaiting your approval and the §25 decisions before any implementation begins.*

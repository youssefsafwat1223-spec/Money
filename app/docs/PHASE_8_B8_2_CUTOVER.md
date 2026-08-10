# Phase 8 / B8-2 — Exact Read/Write Source Cutover (working ledger)

MALI-026. **Schema stays v29.** No `_minor` columns, no v30 migration, no deploy, no
push, no new Supabase schema objects. Invariants held: `kServerRevisionCas=false`,
0070 inactive, 0068–0076 undeployed, backup envelope v3 unchanged. Base commit `3a850bd8`.

Goal (exit condition): **normal production money writers with non-exact sources = 0**,
AND post-v30 money reads that can feed calc/writes are prepared to originate from `_minor`.

---

## Design decisions (rationale in the B8-2 report)

1. **Entities carry canonical `Money`** (single source of truth) + a **display-only
   `double` getter** (`Money.toDouble()`), so the ~354 display read-sites stay green while
   the write/calc path is exact. Required by §13 (read-modify-write must preserve minor
   units across an unrelated edit) and §1 (reads feeding writes originate from `_minor`).
   The double getter is NEVER a write source (enforced by the §10 writer/path guard + arch
   guard). This is a strict subset / stepping-stone of a later full type-flip if desired.
2. **Dual-schema persistence adapter = `MoneyCodec`** (`lib/data/db/money_codec.dart`).
   `MoneyStorageMode { v29Real, v30Minor }`, resolved centrally (v29Real today). It owns
   physical⇄Money conversion at the **raw-SQL bind boundary** (every writer is raw SQL —
   zero Drift companions). v29: REAL⇄Money via `fromLegacyReal` (allowed adapter usage);
   v30: minor⇄Money. Repositories operate purely on Money.
3. **Pull exactness** (§6): change 9 `.select()`-all projections to add **aliased text
   casts** (`select('*, amount_text:amount::text, ...')`) — keyset/horizontal filters stay
   on the original uncast columns. Deserialize `row['x_text']` (String) → `Money.parse`.
   Client-only; works against the deployed server; no server migration. Live string return
   is external evidence.
4. **Push** (§7): ONE exact serializer `Money → decimal String`. Do **not** activate the
   string→NUMERIC request-shape change (unverified against live server). Keep the current
   JSON-number shape live but derive it exactly from Money. Classify
   **READY_EXACT_NOT_ACTIVATED**. End-to-end sync exactness stays external-pending.
5. **Aggregates** computed in SQL as `SUM(REAL)` cannot be made exact in v29 (no integer
   column). They stay REAL in v29, routed through the adapter, and become exact at v30
   (`SUM(_minor)`). Documented as the v29 limitation the §13 test demonstrates.
6. **Calcs that CREATE money** (persisted + threshold-compared) → Money/BigInt now.
   Ratios that terminate in presentation stay `double`.

### Discovered findings that shape scope
- Exact v30 `_minor` column count = **20** (see §14 below). Two of them
  (`budgets.last_notified_spent_amount`, `goals.last_notified_saved_amount`) are **dormant**
  — written as literal `0`, never read into a live threshold (dedup uses SHA-256 IDs).
- **No account-balance calculation exists** (no `initial + Σtx` derivation). `balance_after`
  comes verbatim from the SMS parser. So §8 "account balance calculations" = none to convert.
- `supabase_financial_summary_service` (8 deserialize sites) is **retired/unwired** — not a
  live writer or read-feeding-write. Out of scope (kept for credential-gated contract tests).
- `interest_rate` confirmed **non-money** (display-only %, in `kNonMoneyRealColumns`).

---

## Inventory (file:line anchors) — the money path

### Writers — 41 sites, ALL raw SQL (customStatement/Insert/Update). Grand total 41.
- transactions(5): drift_transaction_repository 191/200/208 (INSERT interp), 292 (UPDATE Var), 382 (UPDATE Var); ledger_sync_service 351/362/363; drift_financial_importer 215/222/228.
- accounts(6): drift_account_repository 133/136/50/53 (insert), 176/179/50/53 (update); drift_financial_importer 146/147; accounts_pull_service 241/242/244/245 & 285/286/288/289; app_database 2542 (seed NULL).
- budgets(5): drift_budget_repository 85/89 & 111/115; drift_financial_importer 255/259; planning_pull_service 419/423 & 445/449.
- goals(7): drift_goal_repository 142/143/148/149 & 161/162/167/168, **36 (saved_amount += Var)**; drift_financial_importer 346/347/352/355; planning_pull_service 704/705/710 & 727/728/732; planning_child_sync_service 242 (RPC result).
- goal_contributions(3): drift_goal_repository 27; drift_financial_importer 367; planning_child_sync_service 543.
- subscriptions(6): drift_bill_repository 117/142/145 & 179/203/206; drift_financial_importer 288/302/303; planning_pull_service 626/641/642 & 665/679/680; planning_child_sync_service 807.
- bill_payments(3): drift_bill_repository 261; drift_financial_importer 320; planning_child_sync_service 588.
- plans(5): drift_plan_repository 60(val 45) & 78(val 45); drift_financial_importer 384; planning_pull_service 754 & 776.
- suspected_duplicates(1): drift_suspected_duplicate_repository 34.

### Pull — 43 active deserializations, 9 SELECT-all sites. All JSON-number (lossy).
- SELECTs: ledger_sync_service 49; transactions_backfill 199 & 210; accounts_pull 47; accounts_backfill 107 & 118; planning_pull 55; planning_child 69 & 94.
- Deserialize: ledger_sync 323/362/363/472/506/507, backfill 219; accounts_pull 241/242/244/245/285/286/288/289, accounts_backfill 129/131; planning_pull budgets 419/423/445/449, subs 626/641/642/665/679/680, goals 704/705/710/727/728/732, plans 754/776; planning_child goal_contrib 543, bill_pay 588, RPCs 242/807; capture_sync 234/255 (_num). Retired: supabase_financial_summary 84/85/86/87/113/114/141/168.

### UI input — 11 surfaces / 19 parse sites (all double.parse/tryParse; none use money_input).
allocate_income_sheet 77/78/79; goal_form_screen 240/449/508/514; goal_details_screen 335; budget_form_screen 274/413; bill_form_sheet 249/251/276 (_parseDecimalInput→115); manual_transaction_sheet 146; plan_form_sheet 89; account_form_sheet 125(_parseNum→161/168/170); bill_details_sheet 831(used 397); transaction_details_screen 490; confirm_transaction_sheet 398.

### Parser — 7 sites. parser_engine 282/335/336/352/353/382; shared_preview_parser 185-188.
Targets ParsedTransaction.amount/balanceAfter/foreignAmount (double); AmountCandidate.value+score both double (money token entangled with confidence).

### Import/backup. drift_financial_importer _double 485 / _positiveDouble 488 (~20 col binds);
generic_transaction_import parseImportAmount 174-193; import_normalizer 110; app_data_portability_service 298; restore_backup_usecase _variable 485-491 (int|double bind), verify 332; backup_snapshot_builder 367/453 (export JSON); drift_financial_exporter (CSV). Versions: backup envelope v1..3 (backup_crypto), snapshot schemaVersion=3, qirshPackageVersion=1 — DO NOT bump.

### Calculations. Persisted(7): drift_goal_repository 36; bill_details_sheet 305; bill_form_sheet 289; budget_form_screen 550-553/562-564; allocate_income_sheet 88/90. Threshold(6): budget_alert_planner 69/86; reports_providers 178-179 (≥75); drift_transaction_repository 1141 (*0.15 spread); duplicate_transaction_detector 65 (epsilon); restore_backup_usecase 300 (1e-6); plans_providers 18. Aggregate SUM(REAL) ~40 (bill_metrics, budget/category SQL sums, card summaries, report metrics, dashboard folds) — stay REAL in v29 via adapter.

---

## §14 — exact `_minor` column count for v30 = **20**
transactions 3 (amount, balance_after, foreign_amount) · accounts 4 (initial_balance,
current_balance, credit_limit, available_credit) · budgets 2 (amount,
last_notified_spent_amount) · goals 4 (target_amount, saved_amount,
last_notified_saved_amount, auto_save_amount) · goal_contributions 1 · subscriptions 3
(amount, manual_paid_amount, total_purchase_amount) · bill_payments 1 · plans 1 ·
suspected_duplicates 1 = **20 ALTER ADD COLUMN**. (2 dormant: budgets/goals last_notified.)

## §15 — v30 atomic activation boundary (NOT authorized; after B8-2 conversion is done)
1) version 29→30; 2) add 20 `_minor` columns; 3) preflight currency/value validity;
4) backfill `_minor` from REAL via exact converter; 5) exact postflight (no epsilon);
6) activate MoneyCodec v30 capability so writers dual-write minor+REAL-shadow;
7) canonical reads use `_minor`; 8) REAL = compatibility shadow; 9) user_version commit last.

---

## Staging (each stage ends GREEN: flutter analyze + affected tests)
S0 Foundation (additive): MoneyCodec + Money.toDouble + serializers + tests. [green]
S1 Entities → Money + display getters (+ per-entity: mappers, repo writers, source sites, tests).
   Vertical slices in low-coupling order: suspected_duplicate → plan → goal_contribution →
   budget → goal → bill/subscription → account → transaction.
S2 Sync pull ::text + push serializer.
S3 UI input surfaces.
S4 Parser/capture.
S5 Import/backup converters.
S6 Calculations (persisted/threshold) + aggregate adapter-wrapping.
S7 Direct-SQL audit + guards (writer/path + arch) + RMW adversarial tests.
S8 Validate + commit (no push) + report.

## STATUS
- [x] S0 foundation — GREEN. MoneyCodec, Money.toDouble, money_transport.dart + tests.
  analyze clean; 97 tests. Additive only. Nothing pushed; schema v29.
- [x] Architecture confirmed by user: **Money field + display-only double getter**;
  **post detailed plan first, execute on approval.**
- [x] Plan APPROVED with binding corrections (v29-aggregates-legacy-only; pull `::text` +
  request-shape tests; heuristics only if non-money; push renamed `moneyToLegacyJsonNumber`;
  no version bump; **Correction A** classify every old-getter read presentation-vs-logic,
  migrate all logic → `<field>Money`, unresolved=0; **Correction B** base-currency mutability =
  v30 blocker; per-domain focused commits; record REAL-aggregate consumers).
- [x] Push helper renamed `moneyToLegacyJsonNumber` (green).
- [x] **Correction B investigated (v30 BLOCKER, item K):** base currency IS fully mutable after
  financial data exists, NO guard — via `SaveCountryCurrencyUseCase` (settings/onboarding), the
  account-form currency dropdown (`account_form_sheet.dart:378-393`), and the active-account
  switcher; `baseCurrencyProvider` derives base from the active/default ACCOUNT currency
  (`app_providers.dart:619-632`), `user_settings.currency` only a fallback. A change
  REINTERPRETS existing budgets/goals/goal_contributions (silent magnitude change; NO FX/rescale
  anywhere). Per-row-currency tables (transactions/accounts/subscriptions/bill_payments/plans)
  are SAFE. **⇒ v30 minor-unit storage for budgets/goals/goal_contributions is UNSAFE until
  stable currency semantics.** Recommended before v30: **Option A — persist a `currency` column
  on budgets/goals/goal_contributions** (backfilled from current base at v30), pinning per-row
  scale like the others. (Options B rescale-on-change / C prohibit-change are alternatives.)
  For B8-2 these tables use the current base currency as the temporary v29 carrier
  (`readBaseCurrency` = default-account currency → user_settings.currency → 'SAR').
- [x] **Transaction getter classification done (Correction A):** 53 reads = 35 presentation / 18
  logic. Logic files to migrate to `.amountMoney`/`.balanceAfterMoney`/`.foreignMoney`:
  app_data_portability_service (CSV export 76/87/88), ledger_outbox_queue (payload 249/263/264),
  drift_transaction_repository (INSERT 191/200/208), duplicate_transaction_detector (63/65 →
  exact Money `==`), dashboard_providers (fold 398), budgets_providers (signed 288),
  manual_paste_screen (confirm filter 645/646 → `isZero`/`foreignMoney!=null`),
  confirm_transaction_sheet (81 → business gate).
- [~] Domain 1 (transaction+parser) STARTED then reverted to keep the tree GREEN: the root is
  deeply coupled (ParsedTransaction/AmountCandidate + add_transaction_usecase multi-source
  parser/AI/manual + capture + AI client), too large to finish green this session. Entity/mapper/
  repo/dedup edits were made and reverted; they are fully specified by this plan + the
  classification above (cheap to redo). **Next session resumes domain 1 from green.**
- [ ] S1–S8 sweep — proceed per-domain, each a green focused commit.

**CHECKPOINT: foundation committed GREEN. Sweep continues per-domain. Nothing pushed. schema v29.**

### Sweep progress (safe per-row-currency domains; STOP before budgets/goals/goal_contributions)
- [x] **account** domain GREEN + committed. AccountEntity → 4 `*Money` fields + display getters;
  accountFromRow via codec; create/update writers via `kMoneyCodec.realVarOrNull`;
  account_form_sheet → `parseLocalizedMoney` (ambiguous/over-precision now fails validation);
  account sync payload (planning_outbox_queue) → `moneyToLegacyJsonNumberOrNull` (LOGIC read
  migrated); 3 prod auto-account sites + 6 test files updated. analyze clean; focused account +
  money tests pass. (Full-suite run hit the known Argon2-KDF-timeout-under-load flake in
  backup_crypto — environmental, untouched by this change.) The accounts PULL service
  (accounts_pull_service, accounts_backfill) writes SQL directly (not via the entity) — left for
  the S2 pull `::text` step; no NEW double write source introduced.
- [x] **plan** domain GREEN + committed. PlanEntity.budgetAmount → budgetAmountMoney + display
  getter; planFromRow + save writer via codec; plan_form_sheet → parseLocalizedMoney (currency =
  plan's per-row currency; invalid → snackbar, magnitude never guessed); plan payload →
  moneyToLegacyJsonNumber; 6 test files updated (incl. invalid-currency helper via
  isSupportedCurrency fallback). analyze clean; focused plan tests pass.
- [ ] transaction+parser, bill/subscription, suspected_duplicate — pending.

### v29 REAL-aggregate consumers recorded for v30 (transitional; NOT persisted-money sources)
- `plans_providers` remaining/ratio/isOver = `plan.budgetAmount` (display getter) vs `spent`
  (SQL `SUM` of REAL, v29 legacy). Kept double (display/threshold on a REAL aggregate) — migrate
  to integer `SUM(_minor)` at v30. Produces display/bool only; no persisted Money derived.

---

# DETAILED PER-DOMAIN EXECUTION PLAN (for approval)

Confirmed shape: each entity's canonical money → a `Money` field named `<field>Money`; the
existing accessor name stays a **display-only `double get`** (so ~354 read-sites are
untouched). Writers/pull/import/calc source ONLY from the `Money` field, bound via `MoneyCodec`.
`const kMoneyCodec = MoneyCodec();` (v29Real) added to money_codec.dart for ergonomics.

## Entity spec (Money field + display getter; keep existing currency fields)
| entity | Money fields (new) | display getters kept | currency source |
|---|---|---|---|
| TransactionEntity | amountMoney, balanceAfterMoney?, foreignMoney? | amount, balanceAfter?, foreignAmount? | keep `currency`,`foreignCurrency` fields; money built with them (assert equal) |
| AccountEntity | initialBalanceMoney?, currentBalanceMoney?, creditLimitMoney?, availableCreditMoney? | initialBalance? … | keep `currency` field |
| BudgetEntity | amountMoney, lastNotifiedSpentMoney | amount, lastNotifiedSpentAmount | baseCurrency (Money carries it; no currency field) |
| GoalEntity | targetMoney, savedMoney, lastNotifiedSavedMoney, autoSaveMoney? | targetAmount, savedAmount, … | baseCurrency |
| GoalContributionEntity | amountMoney | amount | baseCurrency |
| BillEntity | amountMoney, manualPaidMoney?, totalPurchaseMoney? | amount, manualPaidAmount?, … | keep `currency`; `interestRate` stays double (non-money) |
| BillPaymentEntity | amountMoney | amount | keep `currency` |
| PlanEntity | budgetAmountMoney | budgetAmount | keep `currency` |
| SuspectedDuplicateEntity | amountMoney | amount | keep `currency` |

`copyWith` takes the `Money` fields. Constructors require the `Money` field (breaks only
CONSTRUCTION sites — the sources we are converting; reads stay green via getters).

## Base-currency threading (budget/goal/goal_contribution)
Add `Future<String> readBaseCurrency(AppDatabase)` (SELECT currency FROM user_settings LIMIT 1)
in drift_repository_support.dart. Callers that need it: budget/goal repos (read+write), planning
pull (budgets/goals/contributions), importer (budgets/goals/contributions), UI forms (via
`baseCurrencyProvider`, already in scope). Money built with the resolved base currency.

## Codec usage
- read (bound repos): `kMoneyCodec.readColumn(row,'amount',currency)` / `readColumnNullable`.
- write (bound repos): `kMoneyCodec.realVar(e.amountMoney)` / `realVarOrNull(e.balanceAfterMoney)`.
- write (interpolation repos — transactions/goals): `kMoneyCodec.sqlRealLiteral(...)` /
  `sqlNullableRealLiteral(...)`.
- pull: `moneyFromPulledValue(row['x_text'], currency)` → `kMoneyCodec.sqlNullableRealLiteral(money)`.

## S1 — domains, root-first (each ends GREEN: analyze + that domain's tests)
Order: **transaction+parser** (root) → account → bill/subscription+bill_payment → plan →
budget → goal+goal_contribution → suspected_duplicate.
Per domain, in one slice: (a) entity Money fields+getters+copyWith; (b) repo read-mapper via
codec; (c) repo writers via codec; (d) that domain's construction/source sites (usecases);
(e) that domain's tests. Cross-cutting sources (UI/pull/import/calc) done in S3–S6 but each
must leave the tree green.

### transaction (root) — writers: drift_transaction_repository 191/200/208 (INSERT interp →
sqlRealLiteral/sqlNullableRealLiteral), 292 & 382 (UPDATE Var → realVar). mapper:
transactionFromRow (support) → amountMoney/balanceAfterMoney/foreignMoney via codec (currency,
foreignCurrency from row). findDuplicate/findSuspiciousDuplicate params `double amount` →
`Money` (or keep double at the query-bind, using codec.sqlRealLiteral). Construction sites:
add_transaction_usecase, capture pipeline, manual/import (S3–S5).
### parser (root) — parser_engine 282/335/336/352/353/382, shared_preview_parser 185: extract
amount TEXT (not double) → build `Money.parse(canonicalDecimal, currency)` once currency is
resolved (detected/fallback). ParsedTransaction.amount→amountMoney (Money), balanceAfter→
balanceAfterMoney, foreignAmount→foreignMoney. AmountCandidate: split money token (decimal
STRING) from `score` (double). Confidence/score stay double. Persisted amount never via double.

## S2 — sync pull ::text (§6) + push (§7)
Pull SELECTs (9) → add aliased casts, keyset filters unchanged:
- ledger_sync_service:49 `.select('*, amount_text:amount::text, balance_after_text:balance_after::text, foreign_amount_text:foreign_amount::text')`; transactions_backfill 199/210 likewise.
- accounts_pull:47 & accounts_backfill 107/118 → initial_balance/current_balance/credit_limit/available_credit ::text.
- planning_pull:55 → per table (budgets amount/last_notified; subs amount/manual_paid/total_purchase; goals target/saved/auto_save; plans budget_amount) ::text.
- planning_child:69 → goal_contributions.amount / bill_payments.amount ::text.
Deserialize: `moneyFromPulledValue(row['x_text'], currency)` (currency: row currency for
txn/accounts/subs/bill_pay; baseCurrency for budgets/goals/contributions) → write via
`kMoneyCodec.sqlNullableRealLiteral`. RPC results (planning_child 242/807) likewise. capture
Edge Function `_num` → keep (external JSON), but build Money via legacy converter for the write.
Push (READY_NOT_ACTIVATED): payload builders (ledger_push/accounts_push/planning_push/outboxes)
read `e.<field>Money` → `moneyToJsonNumber(m)` (current shape, exact-derived). `moneyToNumericText`
stays ready, unactivated.

## S3 — UI (§4): 11 surfaces → `parseLocalizedMoney(text, currency)` (currency = row/base).
Remove money double.parse/tryParse. Over-precision/ambiguous → validation error. Sites:
allocate_income 77-79, goal_form 240/449/508/514, goal_details 335, budget_form 274/413,
bill_form 249/251/276, manual_transaction 146, plan_form 89, account_form 125, bill_details 831,
transaction_details 490, confirm_transaction 398. Add widget/use-case regressions.

## S4 — parser done in S1 root. Capture sync (capture_sync_service 234/255) → Money via
legacy/canonical converter feeding TransactionEntity.amountMoney + suspected-dup.amountMoney.

## S5 — import/backup (§12): CSV → `Money.parse` (post-normalize); qirsh legacy CSV cell →
`legacyDecimalTextToMoney` (quantizing, new helper); backup JSON number → `Money.fromLegacyReal`;
future exact minor → Money direct. drift_financial_importer (_double/_positiveDouble → Money
builders, base currency for budgets/goals), generic_transaction_import, restore_backup_usecase
_variable (build Money → codec REAL bind). EXPORT stays current shape (no snapshot/qirsh version
bump) — converters+tests only.

## S6 — calculations (§8)
- Persisted: drift_goal_repository:36 saved_amount += → Dart RMW (read savedMoney + contribMoney,
  write via codec); bill_details:305 full payoff → `bill.amountMoney * remainingCount`;
  bill_form:289 manual-paid delta → Money subtract, floor at zero; allocate_income:88/90 →
  `incomeMoney.allocate(weights)` (exact). budget_form suggestions stay double PRE-FILL (persisted
  value re-parsed exactly via S3 form parse — the exact boundary is the field).
- Threshold: dup epsilon (detector:65) → exact Money equality (no epsilon); restore parity
  (300) → Money.sum compare exact; recurring *0.15 spread (repo:1141) and report ≥75 / plan-over
  operate on SQL SUM(REAL) aggregates → stay REAL in v29 (heuristic/aggregate), exact at v30.
- Aggregates (~40 SQL SUM(REAL)): stay REAL in v29; read boundary wraps to Money via codec where
  it feeds further money logic; exactness at v30 (SUM of `_minor`). bill_metrics annualization →
  Money.applyRate.

## S7 — direct-SQL audit (§11) + guards (§10) + RMW tests (§13)
- All money writes now route through kMoneyCodec. **Arch-guard check #7**: money-column
  INSERT/UPDATE only in an allowlist of persistence modules (repos + pull services + importer);
  any money-column raw write elsewhere fails (structural, not per-symbol grep).
- Writer/path guard (test): instrument codec — write a Money, prove REAL (and v30 minor) both
  derive from the SAME Money. Report SEPARATELY from the field guard.
- RMW adversarial (§13): value > 2^53 minor; v29 REAL loses it, v30 minor identical; entity
  read→edit(category/merchant/sync-meta/notification-state)→write leaves minor units untouched.

## S8 — validate (§16, NOT the closure gate) + commit (no push) + report (§17 A–O).

## OPEN RISKS / NOTES for reviewer
1. **v29 aggregates stay REAL** (SQL SUM/AVG) — cannot be exact without integer columns;
   exactness lands at v30. B8-2 prepares the read boundary only. Confirm acceptable.
2. **Pull `::text` activates a live request-shape change** (authorized by §6). Live string
   return remains external evidence.
3. **Recurring `*0.15` spread & report/plan aggregate thresholds** stay REAL heuristics in v29.
4. **Push stays JSON-number shape** (READY_EXACT_NOT_ACTIVATED); end-to-end exactness external.
5. **No export/snapshot/qirsh version bump** — import converters + tests only.
6. Base-currency threading adds one `user_settings.currency` read per repo/pull/import batch.

# Phase 8 / B8-2.6 — Planning-currency repair workflow + stable per-row currency contract

MALI-026. Pre-v30 foundation so budgets/goals/goal_contributions can move to fixed-precision minor
storage at v30 WITHOUT the silent-reinterpretation defect proven in B8-2.5. **Schema stays v29; no
`_minor`; no migration; no budget/goal entity conversion; nothing deployed/pushed.**

## Approved stable per-row currency contract (Decision 1)
- v30 will add `budgets.currency` and `goals.currency` (per-row authority). **NOT
  `goal_contributions.currency`** — a contribution derives its currency from its parent goal
  (`goal_contribution.amountMoney.currency == parent_goal.currency`); a contribution never consults
  `baseCurrencyProvider` to interpret an existing persisted contribution. (A contribution currency
  column would be proposed only if contributions were proven to be synced/restored/processed
  independently AND the parent currency were not deterministically available — neither is true today.)
- **Create-time snapshot:** when a budget/goal is created (post-v30), the effective base currency at
  creation is snapshotted into `row.currency`.
- **Existing rows are interpreted via `row.currency`, never the current `baseCurrencyProvider`.** After
  creation, changes to active/default account, `user_settings.currency`, country, or another account's
  currency MUST NOT reinterpret an existing budget/goal/contribution.
- No FX contract exists → NO automatic conversion in Phase 8. Existing objects stay in their historical
  persisted currency unless a future explicit conversion feature is built.
- **`baseCurrencyProvider` after cutover** is for: defaults for NEW objects, dashboard/base display
  context, and form initial currency — it is NOT the authority for interpreting an existing budget/
  goal/contribution. (Arch regression test asserting this is DEFERRED until the planning entities are
  actually converted — they are not, this batch.)

## Historical ambiguity (Critical correction — accepted)
The current DB contains NO historical planning currency. So **ANY pre-v30 budget/goal row is
potentially historically ambiguous** (created under an older base, base later changed → the original
is unrecoverable). Migration MUST NOT silently stamp the current base and call it correct.

## Repair workflow (A — exact UX/flow) — runs while schema is still v29, OUTSIDE the Drift migration
- **Case A — no existing budgets/goals:** no ambiguity; `evaluate()` → `notRequired`; v30 may proceed.
- **Case B — existing budgets/goals:** the app must establish a durable, confirmed repair decision
  BEFORE the v30 DB migration is allowed to run. UX (a settings/onboarding-gate screen — foundation
  landed here; screen wiring is the next step):
  1. Explain older planning rows do not store their original currency, and show the proposed currency.
  2. Offer **(1) global** — "All existing budgets and goals use `<CURRENCY>`" (explicit global
     confirmation), OR **(2) per-row** — assign a currency per budget/goal.
  3. Contributions inherit the repaired currency of their parent goal.
  4. If the user does not confirm, the v30 planning-money migration remains **blocked/deferred**. No
     silent assumption. A global assumption is valid ONLY after explicit confirmation that it applies
     to all existing planning rows.

## Repair manifest (B — storage; C — stale protection; D — per-row vs global)
Implemented: `lib/data/db/planning_currency_repair.dart` (`PlanningCurrencyRepairManifest` +
`PlanningCurrencyRepairService`), tested by `test/data/db/planning_currency_repair_test.dart` (10 tests).
- **B. Storage:** the app's existing durable KV — **flutter_secure_storage** (same mechanism as
  `InstallId` / app-lock / theme), via a `RepairKeyValueStore` seam (`SecureRepairKeyValueStore` in
  the app; in-memory in tests). **No new database schema** (per the constraint). The key is
  namespaced by install (`planning_currency_repair_v1:<installId>`) and the manifest additionally
  carries `installId` + `userId`, so a decision can never apply to another dataset/user.
- **C. Stale protection:** the manifest stores a **SHA-256 fingerprint of the sorted budget/goal id
  set**. `evaluate()` returns `stale` (v30 blocked) if the current id set differs — so `confirm → add/
  delete a budget/goal → migrate` can never consume a stale assumption. Per-row decisions must cover
  every existing id or they are `stale`. A foreign install/user → `needsConfirmation`.
- **D. Per-row vs global:** `mode = global` (one currency for all) or `perRow` (id→currency map; must
  cover every existing budget/goal id). `confirmGlobal(currency)` / `confirmPerRow(map)`; unsupported
  currency is rejected at confirmation.
- **Statuses:** `notRequired` (Case A) · `needsConfirmation` (Case B, none) · `stale` (changed/foreign)
  · `satisfied` (valid + complete + fingerprint match → v30 unblocked).

## Migration consume API (how the future v30 migration uses it)
`migrationCurrencyForBudget(id)` / `migrationCurrencyForGoal(id)` /
`migrationCurrencyForContribution(parentGoalId)` return the confirmed currency, and **throw if the
decision is not currently satisfied** — the v30 migration MUST treat that as blocked/deferred and NEVER
fall back to `baseCurrencyProvider`. v30 stamp: `confirmed row currency → row.currency →
legacyRealToMinor(amount, row.currency)`; contribution uses its parent goal's confirmed currency.

## STATUS / remaining blockers to planning-entity conversion (I)
Foundation only (model/service/fingerprint/consume API/tests). **Before budgets/goals can be
converted + v30 run:** (1) the repair UX SCREEN wired to `evaluate()`/`confirm*` (foundation done);
(2) `budgets.currency`/`goals.currency` schema columns (v30); (3) budget/goal entity + repo + pull/push
Money conversion using `row.currency`; (4) AI/capture `amount_text` backend deployed + verified;
(5) exact Supabase push activated/proven; (6) remaining pull exactness; (7) final writer/read/aggregate
guard before schema activation; (8) the `baseCurrencyProvider`-not-authority arch test. schema v29;
nothing pushed/deployed.

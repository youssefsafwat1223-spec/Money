# Phase 8 / B8-2.5 — Base-currency contract (investigation + v30 recommendation)

MALI-026. Decision input for whether/how budgets · goals · goal_contributions can move to
fixed-precision minor-unit storage at v30. **No schema change here — investigation + recommendation
only.** Schema stays v29. These three tables are the ONLY persisted money with no per-row currency
(`money_fields.dart:21-23,49-58` — `CurrencyAuthority.baseCurrency`); every other money domain is
`sameRowCurrency` and is already safe/converted.

## §1 — Every path that changes base currency (proven from code)
Base currency = `baseCurrencyProvider` (`app_providers.dart:619-632`): **active account currency →
default account currency → `user_settings.currency` (fallback only)**. Mutation paths, all
**unguarded** (no data-existence check):
1. **Settings → change currency/country** — `settings_screen.dart:121-140` / `_editCountry:97-118` →
   `SaveCountryCurrencyUseCase` (`user_settings_usecases.dart:58-90`) → `DriftUserSettingsRepository.
   saveSettings` `UPDATE user_settings SET currency=?` (`drift_user_settings_repository.dart:74`).
   Invalidates `baseCurrencyProvider`.
3. **Onboarding / default country** — `setup_screen.dart:126-155` → same use case.
4. **Account-form currency dropdown** — `account_form_sheet.dart:378-393` edits the default/active
   account's `currency` → `drift_account_repository.update` (`:174`) — touches no amounts. Since the
   base derives from the account, this silently changes the base.
5. **Active-account switcher** — `activeAccountIdProvider` (consumed `app_providers.dart:622-626`):
   switching to an account with a different currency changes the effective base on the fly.
- Seed/default: `app_database.dart` seeds `user_settings`/default account currency (default `'SAR'`).
- Remote pull of settings/accounts can change the stored currency too (planning pull writes accounts/
  user_settings currency).
**No path converts, rescales, or guards budgets/goals/goal_contributions.** No FX logic exists anywhere.

## §2 — Current v29 consequence (EGP scale-2 data → base switched to KWD scale-3)
Stored REAL stays literally `100.0 / 1000.0 / 250.0`. **Verdict: (A) reinterpret** across all 9 surfaces
(none convert, none prohibit, none store original currency, none mixed):
| surface | behavior | evidence |
|---|---|---|
| DISPLAY | raw number, relabeled KWD (`budget.amount` at `budgets_screen.dart:755`; goals `:214/:223`; per-account label override is label-only) | budgets_screen 42-43/736-755; goals_screen 25-26/214-223; goal_details 151-263 |
| EDIT | pre-fills the raw stored number, label = new currency; saves raw | budget_form_screen 176-178/498/413; goal_form_screen 172-173/438/514 |
| PROGRESS | pure numeric ratio (currency-agnostic): `spent/amount`, `saved/target` | budget_progress_usecase 64-66; goal_details_usecase 16-21; plans_providers 14-18 |
| CONTRIBUTION | `saved_amount += ?` numeric add, no currency check | drift_goal_repository 33-43 |
| NOTIF THRESHOLD | **dormant** — `last_notified_*` persisted/synced/backed-up but never compared (dedup = SHA-256 id) | budget_alert_planner 11-23/46-102; grep of comparisons = empty |
| SYNC PUSH | payload carries **no currency** (contrast bill/plan payloads, which do) | planning_outbox_queue 643-660/692-711/210-224 |
| SYNC PULL | reads/writes **no currency** | planning_pull_service 412-449/695-732 |
| BACKUP | exports **no currency** for these tables | backup_snapshot_builder 67-101 |
| RESTORE | restores raw doubles, **no currency** (currency-aware verify is transactions-only) | restore_backup_usecase 471-482/281-338 |
Net: EGP→KWD silently inflates the conceptual value ~1000× (scale 2→3) with zero conversion.
**Currency column/field for these 3 tables anywhere (schema/entity/push/pull/backup/restore): NONE.**

## §3 — v30 base-currency contract options
- **Option A — persist currency per row (RECOMMENDED).** Add `budgets.currency`, `goals.currency`,
  and `goal_contributions.currency` (contribution currency = its parent goal's currency, stamped at
  insert; an independent contribution currency is not needed by any current flow). Existing rows are
  stamped at the v30 migration with the base currency in effect at migration time. Future base-currency
  changes affect only FUTURE rows; existing objects keep their stamped currency unless the user
  explicitly converts them. Pins each row's scale exactly like transactions/accounts/subscriptions/
  plans (which are already safe). Lowest ongoing risk; makes these tables convertible to `_minor`.
- **Option B — transactional conversion on base-currency change.** Requires a trustworthy FX rate +
  conversion timestamp/source + deterministic Money×Rate + transactional rewrite + audit. **The product
  has NO FX contract today** ("per-currency totals (no FX yet)" — app CLAUDE.md). NOT recommended.
- **Option C — prohibit base-currency change while dependent data exists.** Simple but restrictive;
  contradicts the current freely-mutable UX (settings, account-form dropdown, account switcher all
  change it today). High UX regression. Not recommended as the primary.
**Recommendation: Option A** (per-row currency column on the 3 tables, backfilled at v30 from the
migration-time base currency), because it matches the existing per-row-currency model, needs no FX
contract, and preserves current UX. It requires a v30 schema change (3 columns) — **NOT authorized yet**.

## §4 — Migration authority + the historical-row ambiguity (CRITICAL)
For v30, each base-currency field's currency authority under Option A = the new per-row `currency`
column, backfilled at migration. **Backfill value = the base currency in effect at migration time.**

**Critical ambiguity:** because no currency was ever stored, and base currency is freely mutable, a row
CREATED under an older base currency and then left through a base-currency change has an
**UNRECOVERABLE original currency** — the data does not contain it. So the migration **cannot perfectly
recover historical currency**. Classify explicitly: **IRRECOVERABLE for any install whose base currency
changed after these rows were created.** (For the common case — base currency never changed — the
migration-time base is correct.)
**Proposed repair policy (no silent historical guessing):**
1. **Preflight detection:** at v30 migration, if there is evidence the base currency ever changed
   (e.g. accounts of differing currencies, or a recorded settings-currency change), flag it.
2. **One-time assumption + user confirmation:** stamp existing rows with the current base currency as a
   documented one-time assumption, but surface a **preflight warning requiring explicit user
   confirmation** ("existing budgets/goals were created without a stored currency; they will be treated
   as <BASE>; confirm or correct"). 
3. **No silent guess:** never infer a per-row original currency from unrelated signals. If unconfirmed,
   the migration must halt/defer for that install rather than assume.
This ambiguity + the (external) AI/capture `amount_text` deployment are the two hard v30 blockers.

## STATUS
Investigation + recommendation only. **schema v29; no `_minor`; nothing pushed/deployed.** Budgets/
goals/goal_contributions money fields **NOT modified** (awaiting contract approval). Recommended: adopt
Option A for v30; require the preflight-warning + user-confirmation repair policy for the historical
ambiguity.

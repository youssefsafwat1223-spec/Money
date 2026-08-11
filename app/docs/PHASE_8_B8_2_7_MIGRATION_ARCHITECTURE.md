# Phase 8 / B8-2.7 — v30 migration/bootstrap architecture + planning schema plan (PLAN ONLY)

MALI-026. Proves how a future v30 binary reaches the planning-currency repair UX without a boot loop,
and proposes (does NOT apply) the planning schema. **Schema stays v29; no `_minor`; no migration file;
no budget/goal cutover; nothing deployed/pushed.**

## D — actual DB-open / migration lifecycle (proven)
- Launch: `main` → `BootstrapRunner` opens `AppDatabase` DURING bootstrap, then
  `appDatabaseProvider.overrideWithValue(database)` → `runApp`. So **the DB is opened before the
  provider tree / normal UI exists** (`main.dart:45/116`, `app_providers.dart:99`).
- `AppDatabase.open()` runs `_createSchema` + `_applyVersionedMigrations` + compatibility repairs +
  backfills + postflight + the `PRAGMA user_version` bump **inside ONE transaction** (`app_database.dart`
  ~511-531). A throw anywhere rolls back and `open()` fails.
- ⇒ **If a v30 migration THREW because a repair manifest was missing, `open()` would fail → the DB is
  unavailable → the app cannot render the repair UX → permanent boot loop.** This is the risk to avoid.
- The app already has an idempotent additive-column helper `_ensureColumn(table, col, 'TEXT NULL')`
  used in the compatibility phase (`app_database.dart:1479+`) — adding nullable columns opens cleanly.

## E — selected architecture: R2 (v30 additive columns + deferred, app-level planning cutover)
The v30 schema migration is **ADDITIVE ONLY and NEVER blocks DB open**; the money cutover is a separate
app-level step gated on the manifest.
1. **v30 schema migration (inside `open()`):** `_ensureColumn`-style `ADD COLUMN … NULL` for the new
   planning columns (currency + `_minor`). No backfill, no NOT-NULL, no manifest dependency → always
   succeeds → **DB always opens**. The downgrade guard (`fromVersion > _targetSchemaVersion → throw`) is
   UNCHANGED (additive columns don't affect it).
2. **App opens; providers/session initialize normally.**
3. **Detect planning-not-cut-over:** existing budgets/goals have `currency IS NULL` (and/or a durable
   `planning_cutover_complete` marker is absent).
4. **If `PlanningCurrencyRepairService.evaluate() != satisfied`:** render the repair UX
   (`evaluate`/`confirmGlobal`/`confirmPerRow`). No silent assumption.
5. **App-level planning cutover (only when repair is satisfied), in ONE app-level DB transaction:** for
   each budget/goal, `currency = manifestCurrencyFor(id)`, `amount_minor = legacyRealToMinor(amount,
   currency)`; contributions use their parent goal's currency; set the completion marker. The
   `MoneyCodec` planning-storage authority flips to `_minor` only after this succeeds (Strategy-A: no
   partial canonical state consumed; writers stay safe; planning stays REAL-authoritative until cutover).
Authority states: **pre-cutover** = REAL authoritative for planning, `_minor`/currency NULL (not read);
**post-cutover** = `_minor` authoritative, REAL compatibility shadow. There is never a stale dual
representation because the additive columns are inert (NULL) until the atomic cutover fills them.
(R1 mandatory-v29-prep rejected — users skip versions/reinstall/restore. R3 open-v29-in-compat-mode
rejected — needs a version-guard weakening. R2 needs neither.)

## F — skipped-version upgrade (old pre-repair v29 install → directly installs v30 binary)
Additive v30 migration runs (adds NULL columns) → **DB opens** → app sees planning not-cut-over →
repair UX → app-level cutover. **No data loss, no boot loop, no forced reset, no silent currency
assumption.** (An existing v29 install that never did the repair is exactly Case B at first v30 launch.)

## G — old v3 backup restore ambiguity (fresh v30 install + restore a v3 backup)
A v3 backup contains budgets/goals REAL but NO currency. After restore, those rows have `currency IS
NULL` → the SAME repair contract applies: the restore/canonicalization must require a repair decision
before the planning cutover; it must NOT silently stamp the current base. Backup envelope v3 is NOT
changed. (Wiring the restore preflight is B8-2.7 item D; the design is: restore REAL rows → mark
planning not-cut-over → require `evaluate()==satisfied` before the app-level cutover.) A future exact
machine format (minor units in the snapshot) is a later version-bumped machine-format cutover, not here.

## H — future planning schema proposal (PLAN ONLY — NOT applied, no migration file)
Proposed v30 additive columns (all `ADD COLUMN … NULL`, filled by the app-level cutover):
```
ALTER TABLE budgets ADD COLUMN currency TEXT NULL;
ALTER TABLE budgets ADD COLUMN amount_minor INTEGER NULL;
ALTER TABLE budgets ADD COLUMN last_notified_spent_amount_minor INTEGER NULL;   -- dormant field
ALTER TABLE goals   ADD COLUMN currency TEXT NULL;
ALTER TABLE goals   ADD COLUMN target_amount_minor INTEGER NULL;
ALTER TABLE goals   ADD COLUMN saved_amount_minor INTEGER NULL;
ALTER TABLE goals   ADD COLUMN last_notified_saved_amount_minor INTEGER NULL;    -- dormant field
ALTER TABLE goals   ADD COLUMN auto_save_amount_minor INTEGER NULL;
ALTER TABLE goal_contributions ADD COLUMN amount_minor INTEGER NULL;             -- currency = parent goal
```
- **Currency authority:** `budgets.currency`, `goals.currency`. **No `goal_contributions.currency`** —
  a contribution inherits its parent goal's currency (join on `goal_id`). REAL columns are retained as
  the compatibility shadow.
- **Backfill order (app-level cutover, one transaction, only when repair satisfied):**
  1. goals: `currency = repairCurrency(goalId)`; then each goal `_minor = legacyRealToMinor(real,
     currency)`.
  2. goal_contributions: `amount_minor = legacyRealToMinor(amount, parentGoal.currency)` (join goals).
  3. budgets: `currency = repairCurrency(budgetId)`; then each budget `_minor = legacyRealToMinor(real,
     currency)`.
  4. exact postflight (no epsilon) that every filled `_minor` round-trips; set `planning_cutover_complete`.
- This is the ONLY remaining planning-money schema work for v30; it composes with the already-approved
  20-column global `_minor` plan (these are a subset — budgets 2 + goals 4 + goal_contributions 1 = 7 of
  the 20; the other 13 are the already-safe per-row-currency domains).

## Remaining v30 blockers (unchanged + refined)
Repair UX SCREEN wired · budgets/goals schema columns (this plan) · budget/goal entity+repo+pull/push
Money conversion using `row.currency` · restore preflight wiring · AI/capture `amount_text` deployed +
live-verified · exact Supabase push activated/proven · remaining pull exactness · final writer/read/
aggregate guard · `baseCurrencyProvider`-not-authority arch test. schema v29; nothing pushed/deployed.

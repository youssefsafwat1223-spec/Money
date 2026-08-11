# Phase 8 / B8-2.8 — R2 cutover-safety contract, exact-push prep, restore safety, planning conversion plan

MALI-026. Integration/cutover-safety design (NOT Money representation). **Schema stays v29; no `_minor`;
no `budgets.currency`/`goals.currency` migration; no planning entity cutover; no Edge deploy; no push.**

## §1 — R2 runtime authority state machine (P0→P3)
- **P0 legacy v29:** no new columns; legacy planning behavior.
- **P1 v30 structure present, repair unresolved:** additive nullable currency/`_minor` columns exist but
  historical planning rows are NOT canonical. **BLOCKED in P1:** any budget/goal/contribution money
  mutation; creating a new budget/goal/contribution; editing existing planning money; automatic
  contribution/auto-save/bill-like planning mutation; planning sync PUSH that could mutate remote money;
  planning PULL must NOT reinterpret unresolved rows as canonical Money (they stay legacy REAL). **The
  user may** inspect the repair flow, assign/confirm currencies, cancel/defer, and use unrelated domains
  normally. No new planning rows may be created in P1 (avoids a mixed legacy/canonical dataset).
- **P2 cutover executing (one app-level transaction, all-or-nothing):** verify manifest still satisfied;
  set `budgets.currency` / `goals.currency`; derive contribution currency from parent goal; REAL→minor
  via `legacyRealToMinor(real, row.currency)`; exact postflight; flip the durable cutover marker.
- **P3 planning canonical:** `row.currency` / parent goal.currency is authority; `_minor` canonical;
  REAL is compatibility shadow; all planning writers dual-write from the SAME Money; `baseCurrencyProvider`
  is default-for-new only. **No ambiguous intermediate writer state exists** because P1 columns are inert
  (NULL, not read) until the atomic P2 transaction fills them.

## §2 — durable cutover-state marker (proposed; NOT added)
Secure storage alone is insufficient (a crash between the DB commit and a secure-storage write diverges
authority). **The marker must commit in the SAME SQLite transaction as the planning backfill.** Existing
durable state candidates inspected: no generic app-state KV table exists; `financial_cache_health` is
bookkeeping. **Proposed minimal location:** a single DB-local marker in the existing single-row
`user_settings` table via one additive column at v30 (`planning_cutover_state INTEGER NOT NULL DEFAULT 0`)
— it is per-dataset, wiped/replaced by a restore, and commits atomically with the backfill. **States:**
`0 = unresolved (P0/P1)`, `1 = canonical (P3)`. (A single integer; avoid overlapping state concepts.)
NOT added this batch (would be a schema change).

## §3 — fresh-install behavior
Fresh v30 install (no legacy budgets/goals): `evaluate() == notRequired` → the empty P2 cutover runs
immediately/idempotently (nothing to backfill) → marker `= 1` → P3; the user creates new rows normally.
**No repair prompt for an empty dataset.**

## §4 — crash/restart atomicity (proven by prototype)
- Crash BEFORE P2 → marker still `0` → still P1 → repair still required.
- Crash DURING P2 → SQLite rolls back the whole transaction (backfill + marker) → still `0`/P1.
- Crash AFTER P2 commit → marker `1` and canonical data agree (committed together) → P3.
- Restart in P3 → no repair prompt, no re-backfill (idempotent on `marker == 1`).
`test/data/db/planning_v30_additive_prototype_test.dart` proves the additive-open + the all-or-nothing
gated cutover (a mid-transaction throw rolls back both the `_minor` backfill and the marker).

## §7 — fingerprint identity policy (corrected; UUID-collision claim removed)
goals: `(id, created_at)` — the immutable `created_at` detects a same-id goal replacement. budgets have
NO immutable creation field and `category_id` is MUTABLE business data (not identity), so the budget
**`id` itself is the authoritative logical identity**: a same-id budget is intentionally treated as the
SAME planning object; a restore that brings a DIFFERENT dataset under the same budget id is handled by
the restore payload's OWN scoped repair (§8/§9), not by this live-dataset fingerprint. Amount edits /
contributions never invalidate (currency ⟂ amount). Tests updated (`category edit → still satisfied`).

## §8/§9 — old-v3 restore into a canonical (P3) DB (design)
**Never insert ambiguous planning rows into live P3 tables.** Required restore flow (envelope v3
UNCHANGED; reuse the existing decrypt/preflight/staging architecture):
1. decrypt + validate the backup payload;
2. planning-ambiguity PREFLIGHT: detect budgets/goals in the payload with no currency BEFORE any
   destructive restore;
3. obtain/validate a repair decision **scoped to the RESTORE PAYLOAD** (its own fingerprint), reusing the
   same repair engine/types but keyed `RESTORE_PAYLOAD:<payloadFingerprint>` — NEVER the `LIVE_DATASET`
   manifest (no cross-application);
4. only then apply the restore ATOMICALLY, writing `row.currency` + `_minor` canonically (legacy REAL →
   minor via the confirmed currency) so the restored rows land already-canonical (P3-consistent);
5. exact postflight.
If the business snapshot format cannot yet express exact minor, legacy REAL is converted during restore
using the confirmed currency; the snapshot version bump is a separate later machine-format step.
(Wiring is the next implementation step; the contract is fixed here.)

## §10/§11/§12 — exact Supabase PUSH preparation
- **ONE serializer:** `moneyToNumericText(Money) -> canonical decimal String` (already in
  `money_transport.dart`; string conversion is NOT scattered through repositories). Legacy inventory: the
  16 converted-domain push fields currently go through `moneyToLegacyJsonNumber` (transaction 3+3 backfill,
  account 4, bill 3 + payment 1, plan 1).
- **No `amount_minor` / `money_version`** for Supabase — direct PostgREST tables already have NUMERIC
  columns; the exact path writes the decimal STRING into the existing NUMERIC column.
- **Capability states:** `EXACT_SOURCE_READY` (now — serializer + proof exist) → `EXTERNAL_POSTGREST_
  VERIFICATION_REQUIRED` (server string→NUMERIC not exercised) → `EXACT_TRANSPORT_ACTIVE` (only after
  verification, behind a narrow transport gate). **Not active.**
- **§12 proof (test):** `money_transport_test` proves `moneyToNumericText` is a byte-exact JSON STRING
  through `json.encode` for scale 0/2/3, negative, a value beyond JS safe-integer precision (byte-preserved
  where a JSON number collapses), and INT64-near-boundary — server coercion stays EXTERNAL.

## §13 — cloud-sync behavior before exact transport is verified (selected)
**Selected: exact-money cloud writes are GATED/PARKED until the exact-transport capability is verified;
the app remains locally canonical.** A canonical local Money must NEVER be pushed via a known-lossy path
and later lossy-pulled to overwrite itself. Queued exact-money writes are NOT dropped or silently coerced
— they are parked in the existing durable sync outbox/dead-letter infrastructure until
`EXACT_TRANSPORT_ACTIVE`, then flushed. (Until v30/activation this is design; the local canonical state is
authoritative.)

## §14 — AI/capture old-backend behavior under future v30 (selected)
No Edge deploy. If the deployed backend returns ONLY a legacy numeric amount (no `amount_text`), the
client must NOT turn it into canonical exact Money. **Selected: route it to the explicitly legacy/
non-canonical compatibility flow that CANNOT overwrite canonical financial authority — the transaction is
marked `pending` (review) via `legacyLossyNumberToMoney` (already implemented, B8-2 `d8f71cfa`).** It never
silently becomes canonical; exactness waits for `amount_text` deployment + verification.

## §15 — baseCurrencyProvider architecture guard (added)
`test/domain/finance/base_currency_authority_guard_test.dart`: the planning data-layer never uses
`baseCurrencyProvider` / `user_settings.currency` as a money-currency authority (existing rows use
`row.currency` / parent goal.currency). Passes today; will fail the moment a planning repo wires the base
currency into a money read/write.

## §16 — planning entity conversion plan (implementation-ready; NOT applied)
- **BudgetEntity:** `currency` + `amountMoney` + `lastNotifiedSpentMoney` (+ display double getters).
- **GoalEntity:** `currency` + `targetMoney` + `savedMoney` + `lastNotifiedSavedMoney` + `autoSaveMoney?`.
- **GoalContributionEntity:** `amountMoney`, **NO independent currency field** — construction/mapping
  requires the parent goal's currency.
- **No N+1:** the contribution repository loads the parent goals' currencies in ONE batched query
  (`SELECT id, currency FROM goals WHERE id IN (...)`) / a preloaded `Map<goalId,currency>` passed to the
  mapper — never a per-contribution parent lookup. Mirrors the account/bill/plan conversion pattern; money
  binds through `kMoneyCodec`; reads via `row.currency`.

## §17 — post-cutover planning pull/push wire contract + server dependency
- **Pull:** budgets/goals → `row.currency` + `amount::text`/`target_amount::text`/`saved_amount::text` …
  → `moneyFromPulledValue`; goal_contributions → parent goal currency + `amount::text`. (Same per-table
  `::text` mechanism already used for subscriptions/plans/accounts/transactions.)
- **Push:** `moneyToLegacyJsonNumber` (until exact transport active), then `moneyToNumericText`.
- **Server dependency (future, NOT created/deployed):** the Supabase `user_budgets`/`user_goals` tables
  do not yet have a `currency` column — a future server migration must add it before the budget/goal
  currency can round-trip through sync. Identified only; no migration in this batch.

## Remaining v30 blockers
Repair UX screen wired · budgets/goals + `user_settings.planning_cutover_state` schema columns (this plan)
· budget/goal entity+repo+pull/push Money via row.currency · restore-payload preflight wiring · exact push
transport verification + activation · AI/capture `amount_text` deploy+verify · final writer/read/aggregate
guard · server `user_budgets/user_goals.currency` migration. schema v29; nothing pushed/deployed.

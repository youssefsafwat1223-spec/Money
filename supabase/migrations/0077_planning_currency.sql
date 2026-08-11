-- 0077_planning_currency.sql — MALI-026 (Phase-8 B8-2.9, §17). NOT DEPLOYED.
--
-- Phase-8 fixed-precision money makes budgets/goals carry a PER-ROW currency
-- (they historically had none — money_fields.dart CurrencyAuthority.baseCurrency),
-- so the client's future v30 planning cutover writes a repair-confirmed currency
-- per budget/goal. This is the SERVER half of that dependency: add a nullable
-- `currency` column to `user_budgets` and `user_goals` so the client can sync it
-- once budgets/goals are converted.
--
-- Additive and backward-compatible (new NULLABLE columns only; existing rows,
-- import RPCs, and RLS are untouched). Safe to apply after 0021..0076 (no
-- dependency on their objects). NOT DEPLOYED in this batch, and no client
-- behavior activates merely because this source exists — the client
-- ExactTransportCapability/cutover gates external verification.
--
-- NOTE (pre-existing, out of scope): some import RPCs (0046-0050) already list a
-- `currency` column in their INSERT into public.user_budgets even though the base
-- table lacked it; this migration also makes that column real. Do NOT rely on
-- that side effect — the intended purpose is the per-row planning currency.
--
-- goal_contributions intentionally get NO currency column: a contribution
-- inherits its parent goal's currency (no independent authority).
--
-- Rollback (safe, additive-only):
--   alter table public.user_budgets drop column if exists currency;
--   alter table public.user_goals   drop column if exists currency;

alter table public.user_budgets
  add column if not exists currency text null;

alter table public.user_goals
  add column if not exists currency text null;

-- Deliberately NULLABLE with no CHECK/NOT-NULL: legacy rows created before the
-- client cutover have no currency yet; the client backfills the repair-confirmed
-- currency during its atomic v30 planning cutover. A NOT-NULL / format CHECK is a
-- LATER tightening step once all rows are backfilled (do not enforce it here — it
-- would reject existing legacy NULL rows).

-- A-6 — awaiting-FX transactions (server half).
--
-- DECISION (Astra A2, option A): a confirmed foreign-currency transaction that
-- is still awaiting FX pricing is stored with
--     amount = 0, foreign_amount > 0, foreign_currency IS NOT NULL.
-- The server NEVER fabricates a converted amount. This migration accepts exactly
-- that shape and nothing looser.
--
--   1. chk_user_transactions_amount_positive (amount > 0, 0022) is replaced by
--      chk_user_transactions_amount_or_awaiting_fx:
--        amount > 0  OR  (amount = 0 AND foreign_amount > 0 AND foreign_currency IS NOT NULL)
--      Negative amounts, and amount 0 without a foreign amount, stay rejected.
--   2. category_spending_summary (latest def: 0030) is the only server aggregate
--      that COUNTS rows; it now excludes awaiting-FX rows (mirrors the app's
--      `_pricedOnly` rule). Pure sums need no change (adding 0). See the
--      "functions checked" list at the bottom.
--   3. qirsh_server_capabilities() — the app's explicit capability probe.
--
-- CAPABILITY RPC CONTRACT: every LATER migration that adds an app-visible
-- server capability MUST `CREATE OR REPLACE FUNCTION public.qirsh_server_capabilities()`
-- returning the PREVIOUS keys plus its own (copy the body, add one key). Never
-- drop a key a shipped client may read.
--
-- ACTIVATION CONDITION: deploy before (or with) the app release that writes
-- awaiting-FX rows. Ordering: independent of 0100-0102 (references none of them);
-- the active chain ends at 0099, so renumber to the next free active number if
-- this is activated while 0100-0102 stay deferred.

BEGIN;

-- ─── 1. amount constraint ───────────────────────────────────────
ALTER TABLE public.user_transactions
  DROP CONSTRAINT IF EXISTS chk_user_transactions_amount_positive;
ALTER TABLE public.user_transactions
  DROP CONSTRAINT IF EXISTS chk_user_transactions_amount_or_awaiting_fx;
ALTER TABLE public.user_transactions
  ADD CONSTRAINT chk_user_transactions_amount_or_awaiting_fx CHECK (
    amount > 0
    OR (amount = 0 AND foreign_amount > 0 AND foreign_currency IS NOT NULL)
  );

-- ─── 2. category_spending_summary: exclude awaiting-FX rows ─────
-- Body identical to 0030 except the added awaiting-FX exclusion.
create or replace function public.category_spending_summary(
  p_from_inclusive timestamptz,
  p_to_exclusive timestamptz,
  p_account_id uuid default null
)
returns table(category_id text, total numeric, transaction_count bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select tx.category_id, sum(tx.amount), count(*)
  from public.user_transactions tx
  where tx.user_id = auth.uid()
    and tx.deleted_at is null
    and tx.status = 'confirmed'
    and tx.transaction_type = 'expense'
    and tx.category_id is not null
    and not (tx.amount = 0 and tx.foreign_amount is not null)
    and tx.occurred_at >= p_from_inclusive
    and tx.occurred_at < p_to_exclusive
    and (p_account_id is null or tx.server_account_id = p_account_id)
  group by tx.category_id
  order by sum(tx.amount) desc, tx.category_id;
$$;

-- ─── 3. capability RPC ──────────────────────────────────────────
create or replace function public.qirsh_server_capabilities()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object('awaiting_fx_transactions', true);
$$;

revoke all on function public.qirsh_server_capabilities() from public, anon;
grant execute on function public.qirsh_server_capabilities() to authenticated;

-- Functions checked, NOT changed (sum adds 0; no per-row count/average):
--   monthly_financial_summary (0030)  sums only
--   budget_progress_summary (0030)    sums only (budget.amount is the budget limit)
--   plan_spent_summary (0031)         sum over plan_transactions
--   plan_transactions (0031)          row list, not an aggregate
--   import_financial_package (0051)   no amount validation; upsert relies on the CHECK
--   award_gamification_for_transaction (0085) count(*) of ALL rows for exact
--     1/10/100 achievement thresholds fired by an INSERT trigger; a logged
--     transaction is an achievement event regardless of pricing, and excluding
--     awaiting rows would skip a threshold forever (repricing is an UPDATE).
COMMIT;

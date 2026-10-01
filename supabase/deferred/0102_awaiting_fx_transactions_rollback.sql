-- ROLLBACK for 0102_awaiting_fx_transactions.sql
--
-- Refuses while any awaiting-FX row exists: restoring `amount > 0` would violate
-- them. Resolve first, either by pricing them (set amount > 0 from a real FX
-- rate) or by deleting/ignoring them:
--   SELECT id FROM public.user_transactions WHERE amount = 0 AND foreign_amount IS NOT NULL;
BEGIN;

DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM public.user_transactions WHERE amount = 0;
  IF n > 0 THEN
    RAISE EXCEPTION '0102 rollback refused: % awaiting-FX transaction(s) (amount = 0) exist. Price them (set amount > 0) or delete them first; restoring CHECK (amount > 0) would violate them.', n
      USING ERRCODE = '23514';
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.qirsh_server_capabilities();

-- Restore category_spending_summary exactly as 0030 defined it.
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
    and tx.occurred_at >= p_from_inclusive
    and tx.occurred_at < p_to_exclusive
    and (p_account_id is null or tx.server_account_id = p_account_id)
  group by tx.category_id
  order by sum(tx.amount) desc, tx.category_id;
$$;

ALTER TABLE public.user_transactions
  DROP CONSTRAINT IF EXISTS chk_user_transactions_amount_or_awaiting_fx;
ALTER TABLE public.user_transactions
  ADD CONSTRAINT chk_user_transactions_amount_positive CHECK (amount > 0);

COMMIT;

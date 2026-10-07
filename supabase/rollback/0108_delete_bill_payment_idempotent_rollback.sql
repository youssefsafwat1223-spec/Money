-- ROLLBACK for 0108_delete_bill_payment_idempotent.sql
--
-- Restores the 0031 body: an absent or already-deleted payment raises P0002
-- again (and the 'outcome' key disappears). Re-introduces the retry dead letter.
BEGIN;

CREATE OR REPLACE FUNCTION public.delete_bill_payment(p_payment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
declare
  payment_row public.user_bill_payments%rowtype;
  subscription_row public.user_subscriptions%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  update public.user_bill_payments set deleted_at = now()
    where id = p_payment_id and user_id = auth.uid() and deleted_at is null
    returning * into payment_row;
  if payment_row.id is null then raise exception 'payment not found' using errcode = 'P0002'; end if;
  update public.user_subscriptions set paid_count = coalesce((
    select max(installment_index) from public.user_bill_payments
    where user_id = auth.uid() and subscription_id = payment_row.subscription_id
      and deleted_at is null
  ), 0) where id = payment_row.subscription_id and user_id = auth.uid()
    returning * into subscription_row;
  return jsonb_build_object('payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
end;
$$;

COMMIT;

-- 0108_delete_bill_payment_idempotent.sql — WP-2 (manifest 0109): B10.
--
-- delete_bill_payment (0031) raised P0002 'payment not found' for a payment that
-- was absent or already deleted, so a retry after a lost ACK dead-lettered the
-- client's delete op. A delete is idempotent: the end state (no live payment) is
-- already reached, so these are now successes.
--
-- Result keeps the legacy keys 'payment' and 'subscription' (build-50 reads both
-- as maps) and adds 'outcome':
--   deleted         payment tombstoned now; subscription.paid_count recomputed (as before)
--   already_deleted payment row exists with deleted_at set; returns that row and the
--                   current subscription row; paid_count is NOT recomputed again
--   absent          no such payment for this user (never existed / purged / not
--                   owned - indistinguishable on purpose); payment and subscription
--                   are JSON null. A legacy client cannot read null as a map, which
--                   is no worse than the previous P0002 dead letter.
-- Unauthenticated callers still get 42501. Signature, SECURITY INVOKER, search_path
-- and grants are unchanged (CREATE OR REPLACE keeps them).

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
  if payment_row.id is null then
    select * into payment_row from public.user_bill_payments
      where id = p_payment_id and user_id = auth.uid();
    if payment_row.id is null then
      return jsonb_build_object('outcome', 'absent', 'payment', null, 'subscription', null);
    end if;
    select * into subscription_row from public.user_subscriptions
      where id = payment_row.subscription_id and user_id = auth.uid();
    return jsonb_build_object('outcome', 'already_deleted',
      'payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
  end if;
  update public.user_subscriptions set paid_count = coalesce((
    select max(installment_index) from public.user_bill_payments
    where user_id = auth.uid() and subscription_id = payment_row.subscription_id
      and deleted_at is null
  ), 0) where id = payment_row.subscription_id and user_id = auth.uid()
    returning * into subscription_row;
  return jsonb_build_object('outcome', 'deleted',
    'payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
end;
$$;

COMMIT;

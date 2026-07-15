-- Same-day fix for a live bug introduced by 0039: user_subscriptions_user_local_id_uidx
-- is a partial unique index (WHERE local_id IS NOT NULL), but
-- create_subscription_and_record_payment's INSERT ... ON CONFLICT (user_id, local_id)
-- omitted that predicate, so Postgres could not infer the target index and raised
-- 42P10 on every call. Same bug class already fixed once before in
-- 0027_fix_upsert_conflict_indexes.sql. This migration changes only the ON CONFLICT
-- clause; every other parameter, the return shape, security mode, search_path, and
-- grants are unchanged from 0039.

create or replace function public.create_subscription_and_record_payment(
  p_subscription_local_id text,
  p_payment_client_request_id text,
  p_name text,
  p_amount numeric,
  p_currency text,
  p_type text,
  p_frequency text,
  p_next_due_date timestamptz,
  p_created_at timestamptz,
  p_server_account_id uuid default null,
  p_merchant_id text default null,
  p_reminder_on boolean default true,
  p_is_confirmed boolean default true,
  p_custom_interval_days integer default null,
  p_note text default null,
  p_status text default 'active',
  p_total_installments integer default null,
  p_paid_count integer default null,
  p_manual_paid_amount numeric default null,
  p_total_purchase_amount numeric default null,
  p_lender_name text default null,
  p_interest_rate numeric default null,
  p_payment_amount numeric default null,
  p_payment_period_start timestamptz default null,
  p_payment_period_end timestamptz default null,
  p_payment_paid_at timestamptz default null,
  p_payment_installment_index integer default null,
  p_payment_note text default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  subscription_row public.user_subscriptions%rowtype;
  payment_row public.user_bill_payments%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_payment_amount is null or p_payment_period_start is null or p_payment_period_end is null or p_payment_paid_at is null then
    raise exception 'missing payment fields' using errcode = '22023';
  end if;

  insert into public.user_subscriptions(
    user_id, local_id, server_account_id, merchant_id, name, amount, currency,
    type, frequency, next_due_date, created_at, reminder_on, is_confirmed,
    custom_interval_days, note, status, total_installments, paid_count,
    manual_paid_amount, total_purchase_amount, lender_name, interest_rate,
    metadata
  ) values (
    auth.uid(), p_subscription_local_id, p_server_account_id, p_merchant_id,
    p_name, p_amount, upper(p_currency), p_type, p_frequency, p_next_due_date,
    p_created_at, p_reminder_on, p_is_confirmed, p_custom_interval_days, p_note,
    p_status, p_total_installments, p_paid_count, p_manual_paid_amount,
    p_total_purchase_amount, p_lender_name, p_interest_rate, '{}'::jsonb
  ) on conflict (user_id, local_id) where local_id is not null do update set
    server_account_id = excluded.server_account_id,
    merchant_id = excluded.merchant_id,
    name = excluded.name,
    amount = excluded.amount,
    currency = excluded.currency,
    type = excluded.type,
    frequency = excluded.frequency,
    next_due_date = excluded.next_due_date,
    reminder_on = excluded.reminder_on,
    is_confirmed = excluded.is_confirmed,
    custom_interval_days = excluded.custom_interval_days,
    note = excluded.note,
    status = excluded.status,
    total_installments = excluded.total_installments,
    paid_count = excluded.paid_count,
    manual_paid_amount = excluded.manual_paid_amount,
    total_purchase_amount = excluded.total_purchase_amount,
    lender_name = excluded.lender_name,
    interest_rate = excluded.interest_rate
  returning * into subscription_row;

  select * into subscription_row from public.user_subscriptions
    where user_id = auth.uid() and local_id = p_subscription_local_id and deleted_at is null
    for update;
  if subscription_row.id is null then raise exception 'subscription not found' using errcode = 'P0002'; end if;

  insert into public.user_bill_payments(
    user_id, subscription_id, transaction_id, local_id, client_request_id,
    amount, currency, period_start, period_end, paid_at, installment_index, note
  ) values (
    auth.uid(), subscription_row.id, null, p_payment_client_request_id,
    p_payment_client_request_id, p_payment_amount, upper(p_currency),
    p_payment_period_start, p_payment_period_end, p_payment_paid_at,
    p_payment_installment_index, p_payment_note
  ) on conflict (user_id, client_request_id) do nothing returning * into payment_row;

  if payment_row.id is null then
    select * into payment_row from public.user_bill_payments
      where user_id = auth.uid() and client_request_id = p_payment_client_request_id;
  elsif subscription_row.type = 'installment' then
    update public.user_subscriptions set paid_count = greatest(
      coalesce(paid_count, 0),
      coalesce(p_payment_installment_index, coalesce(paid_count, 0) + 1)
    ) where id = subscription_row.id and user_id = auth.uid()
    returning * into subscription_row;
  end if;

  select * into subscription_row from public.user_subscriptions
    where id = subscription_row.id and user_id = auth.uid();
  return jsonb_build_object('payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
end;
$$;

revoke all on function public.create_subscription_and_record_payment(
  text, text, text, numeric, text, text, text, timestamptz, timestamptz, uuid,
  text, boolean, boolean, integer, text, text, integer, integer, numeric,
  numeric, text, numeric, numeric, timestamptz, timestamptz, timestamptz,
  integer, text
) from public, anon;
grant execute on function public.create_subscription_and_record_payment(
  text, text, text, numeric, text, text, text, timestamptz, timestamptz, uuid,
  text, boolean, boolean, integer, text, text, integer, integer, numeric,
  numeric, text, numeric, numeric, timestamptz, timestamptz, timestamptz,
  integer, text
) to authenticated;

-- Rollback for 0034_fix_financial_child_ownership_trigger.sql
--
-- Restores the pre-0034 (broken) function body. Do not roll back unless a
-- new, unrelated regression is suspected to originate from this change —
-- the pre-0034 version fails 100% of the time for user_bill_payments and
-- user_plan_transaction_links inserts.

CREATE OR REPLACE FUNCTION public.validate_financial_child_ownership()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
begin
  if tg_table_name = 'user_goal_contributions' and not exists (
    select 1 from public.user_goals where id = new.goal_id and user_id = new.user_id
  ) then raise exception 'goal ownership mismatch' using errcode = '42501';
  elsif tg_table_name = 'user_bill_payments' then
    if not exists (
      select 1 from public.user_subscriptions
      where id = new.subscription_id and user_id = new.user_id
    ) then raise exception 'subscription ownership mismatch' using errcode = '42501'; end if;
    if new.transaction_id is not null and not exists (
      select 1 from public.user_transactions
      where id = new.transaction_id and user_id = new.user_id
    ) then raise exception 'transaction ownership mismatch' using errcode = '42501'; end if;
  elsif tg_table_name = 'user_plan_transaction_links' then
    if not exists (
      select 1 from public.user_plans where id = new.plan_id and user_id = new.user_id
    ) then raise exception 'plan ownership mismatch' using errcode = '42501'; end if;
    if not exists (
      select 1 from public.user_transactions
      where id = new.transaction_id and user_id = new.user_id
    ) then raise exception 'transaction ownership mismatch' using errcode = '42501'; end if;
  end if;
  return new;
end;
$function$;

-- Fixes a critical, live-reproduced bug in validate_financial_child_ownership():
-- the user_goal_contributions branch combined the table-name guard and the
-- new.goal_id-referencing subquery into a single `IF cond1 AND cond2 THEN`
-- condition. Because NEW is a generic RECORD in a trigger shared across three
-- tables, Postgres must resolve new.goal_id's type to plan the embedded
-- NOT EXISTS subquery as part of evaluating that single combined condition —
-- and it does this even when the row is not a user_goal_contributions row,
-- because the whole AND expression is one statement to plan/evaluate, not two
-- independently short-circuited scalar checks. Result: every insert into
-- user_bill_payments and user_plan_transaction_links failed unconditionally
-- with "record \"new\" has no field \"goal_id\"" (42703), live-reproduced via
-- record_bill_payment() and a direct insert to user_plan_transaction_links.
--
-- Fix: nest the table-name check as its own outer IF/ELSIF, with the
-- column-referencing validation as a separate statement in the branch body —
-- exactly the pattern the bill_payments and plan_transaction_links branches
-- already used correctly. A statement inside an untaken PL/pgSQL branch is
-- never planned/executed, so this removes the unconditional field lookup.
-- No behavior change for any branch that was already working; same exception
-- messages and error codes throughout.

CREATE OR REPLACE FUNCTION public.validate_financial_child_ownership()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
begin
  if tg_table_name = 'user_goal_contributions' then
    if not exists (
      select 1 from public.user_goals where id = new.goal_id and user_id = new.user_id
    ) then raise exception 'goal ownership mismatch' using errcode = '42501'; end if;
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

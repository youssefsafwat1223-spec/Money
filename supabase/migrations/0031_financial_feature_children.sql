-- Phase 4: missing child entities and atomic user-owned mutations.
-- Dark launch only. Existing relay/capture routing is unchanged.

alter table public.user_plans
  add column if not exists server_account_ids uuid[] not null default '{}';

create table if not exists public.user_goal_contributions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  goal_id uuid not null references public.user_goals(id) on delete cascade,
  local_id text null,
  client_request_id text not null,
  amount numeric not null check (amount > 0),
  note text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

create unique index if not exists user_goal_contributions_request_uidx
  on public.user_goal_contributions(user_id, client_request_id);
create unique index if not exists user_goal_contributions_local_uidx
  on public.user_goal_contributions(user_id, local_id)
  where local_id is not null;
create index if not exists user_goal_contributions_goal_idx
  on public.user_goal_contributions(user_id, goal_id, created_at desc)
  where deleted_at is null;

create table if not exists public.user_bill_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subscription_id uuid not null references public.user_subscriptions(id) on delete cascade,
  transaction_id uuid null references public.user_transactions(id) on delete set null,
  local_id text null,
  client_request_id text not null,
  amount numeric not null check (amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  period_start timestamptz not null,
  period_end timestamptz not null,
  paid_at timestamptz not null,
  installment_index integer null check (installment_index is null or installment_index > 0),
  note text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  check (period_end >= period_start)
);

create unique index if not exists user_bill_payments_request_uidx
  on public.user_bill_payments(user_id, client_request_id);
create unique index if not exists user_bill_payments_local_uidx
  on public.user_bill_payments(user_id, local_id)
  where local_id is not null;
create index if not exists user_bill_payments_subscription_idx
  on public.user_bill_payments(user_id, subscription_id, paid_at desc)
  where deleted_at is null;
create index if not exists user_bill_payments_transaction_idx
  on public.user_bill_payments(user_id, transaction_id)
  where transaction_id is not null and deleted_at is null;

create table if not exists public.user_plan_transaction_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_id uuid not null references public.user_plans(id) on delete cascade,
  transaction_id uuid not null references public.user_transactions(id) on delete cascade,
  client_request_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

create unique index if not exists user_plan_links_request_uidx
  on public.user_plan_transaction_links(user_id, client_request_id);
create unique index if not exists user_plan_links_active_uidx
  on public.user_plan_transaction_links(user_id, plan_id, transaction_id)
  where deleted_at is null;
create index if not exists user_plan_links_transaction_idx
  on public.user_plan_transaction_links(user_id, transaction_id)
  where deleted_at is null;

alter table public.user_goal_contributions enable row level security;
alter table public.user_bill_payments enable row level security;
alter table public.user_plan_transaction_links enable row level security;

drop policy if exists user_goal_contributions_owner on public.user_goal_contributions;
create policy user_goal_contributions_owner
  on public.user_goal_contributions for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists user_bill_payments_owner on public.user_bill_payments;
create policy user_bill_payments_owner
  on public.user_bill_payments for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists user_plan_transaction_links_owner on public.user_plan_transaction_links;
create policy user_plan_transaction_links_owner
  on public.user_plan_transaction_links for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists trg_user_goal_contributions_updated_at on public.user_goal_contributions;
create trigger trg_user_goal_contributions_updated_at before update
  on public.user_goal_contributions for each row execute function public.set_updated_at();
drop trigger if exists trg_user_bill_payments_updated_at on public.user_bill_payments;
create trigger trg_user_bill_payments_updated_at before update
  on public.user_bill_payments for each row execute function public.set_updated_at();
drop trigger if exists trg_user_plan_links_updated_at on public.user_plan_transaction_links;
create trigger trg_user_plan_links_updated_at before update
  on public.user_plan_transaction_links for each row execute function public.set_updated_at();

create or replace function public.validate_financial_child_ownership()
returns trigger language plpgsql set search_path = public as $$
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
$$;

create or replace function public.validate_planning_account_ownership()
returns trigger language plpgsql set search_path = public as $$
declare account_id uuid;
begin
  if tg_table_name = 'user_plans' then
    foreach account_id in array new.server_account_ids loop
      if not exists (
        select 1 from public.user_accounts
        where id = account_id and user_id = new.user_id and deleted_at is null
      ) then raise exception 'account ownership mismatch' using errcode = '42501'; end if;
    end loop;
  elsif new.server_account_id is not null and not exists (
    select 1 from public.user_accounts
    where id = new.server_account_id and user_id = new.user_id and deleted_at is null
  ) then
    raise exception 'account ownership mismatch' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_user_budgets_account_ownership on public.user_budgets;
create trigger trg_user_budgets_account_ownership before insert or update
  on public.user_budgets for each row execute function public.validate_planning_account_ownership();
drop trigger if exists trg_user_subscriptions_account_ownership on public.user_subscriptions;
create trigger trg_user_subscriptions_account_ownership before insert or update
  on public.user_subscriptions for each row execute function public.validate_planning_account_ownership();
drop trigger if exists trg_user_goals_account_ownership on public.user_goals;
create trigger trg_user_goals_account_ownership before insert or update
  on public.user_goals for each row execute function public.validate_planning_account_ownership();
drop trigger if exists trg_user_plans_account_ownership on public.user_plans;
create trigger trg_user_plans_account_ownership before insert or update
  on public.user_plans for each row execute function public.validate_planning_account_ownership();

drop trigger if exists trg_user_goal_contributions_ownership on public.user_goal_contributions;
create trigger trg_user_goal_contributions_ownership before insert or update
  on public.user_goal_contributions for each row execute function public.validate_financial_child_ownership();
drop trigger if exists trg_user_bill_payments_ownership on public.user_bill_payments;
create trigger trg_user_bill_payments_ownership before insert or update
  on public.user_bill_payments for each row execute function public.validate_financial_child_ownership();
drop trigger if exists trg_user_plan_links_ownership on public.user_plan_transaction_links;
create trigger trg_user_plan_links_ownership before insert or update
  on public.user_plan_transaction_links for each row execute function public.validate_financial_child_ownership();

create or replace function public.add_goal_contribution(
  p_goal_id uuid,
  p_client_request_id text,
  p_local_id text,
  p_amount numeric,
  p_created_at timestamptz,
  p_note text default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  contribution_row public.user_goal_contributions%rowtype;
  goal_row public.user_goals%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_amount <= 0 then raise exception 'amount must be positive' using errcode = '22023'; end if;
  select * into goal_row from public.user_goals
    where id = p_goal_id and user_id = auth.uid() and deleted_at is null for update;
  if goal_row.id is null then raise exception 'goal not found' using errcode = 'P0002'; end if;

  insert into public.user_goal_contributions(
    user_id, goal_id, local_id, client_request_id, amount, note, created_at
  ) values (
    auth.uid(), p_goal_id, p_local_id, p_client_request_id, p_amount, p_note,
    coalesce(p_created_at, now())
  ) on conflict (user_id, client_request_id) do nothing returning * into contribution_row;

  if contribution_row.id is null then
    select * into contribution_row from public.user_goal_contributions
      where user_id = auth.uid() and client_request_id = p_client_request_id;
  else
    update public.user_goals set saved_amount = saved_amount + p_amount
      where id = p_goal_id and user_id = auth.uid() returning * into goal_row;
  end if;
  select * into goal_row from public.user_goals
    where id = p_goal_id and user_id = auth.uid();
  return jsonb_build_object('contribution', to_jsonb(contribution_row), 'goal', to_jsonb(goal_row));
end;
$$;

create or replace function public.record_bill_payment(
  p_subscription_id uuid,
  p_transaction_id uuid,
  p_client_request_id text,
  p_local_id text,
  p_amount numeric,
  p_currency text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_paid_at timestamptz,
  p_installment_index integer default null,
  p_note text default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  payment_row public.user_bill_payments%rowtype;
  subscription_row public.user_subscriptions%rowtype;
  inserted boolean := false;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  select * into subscription_row from public.user_subscriptions
    where id = p_subscription_id and user_id = auth.uid() and deleted_at is null for update;
  if subscription_row.id is null then raise exception 'subscription not found' using errcode = 'P0002'; end if;

  insert into public.user_bill_payments(
    user_id, subscription_id, transaction_id, local_id, client_request_id,
    amount, currency, period_start, period_end, paid_at, installment_index, note
  ) values (
    auth.uid(), p_subscription_id, p_transaction_id, p_local_id, p_client_request_id,
    p_amount, upper(p_currency), p_period_start, p_period_end, p_paid_at,
    p_installment_index, p_note
  ) on conflict (user_id, client_request_id) do nothing returning * into payment_row;
  inserted := payment_row.id is not null;
  if not inserted then
    select * into payment_row from public.user_bill_payments
      where user_id = auth.uid() and client_request_id = p_client_request_id;
  elsif subscription_row.type = 'installment' then
    update public.user_subscriptions set paid_count = greatest(
      coalesce(paid_count, 0),
      coalesce(p_installment_index, coalesce(paid_count, 0) + 1)
    ) where id = p_subscription_id and user_id = auth.uid() returning * into subscription_row;
  end if;
  select * into subscription_row from public.user_subscriptions
    where id = p_subscription_id and user_id = auth.uid();
  return jsonb_build_object('payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
end;
$$;

create or replace function public.delete_bill_payment(p_payment_id uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
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

create or replace function public.plan_transactions(p_plan_id uuid)
returns setof public.user_transactions language sql stable security invoker set search_path = public as $$
  select tx.* from public.user_transactions tx
  join public.user_plans plan on plan.id = p_plan_id and plan.user_id = auth.uid()
  where tx.user_id = auth.uid() and tx.deleted_at is null and tx.status = 'confirmed'
    and tx.transaction_type = 'expense'
    and (
      exists (select 1 from public.user_plan_transaction_links link
        where link.user_id = auth.uid() and link.plan_id = plan.id
          and link.transaction_id = tx.id and link.deleted_at is null)
      or (
        tx.occurred_at >= plan.start_date and tx.occurred_at <= plan.end_date
        and (
          (cardinality(plan.server_account_ids) = 0 and cardinality(plan.card_last4s) = 0)
          or tx.server_account_id = any(plan.server_account_ids)
          or tx.metadata->>'card_last4' = any(plan.card_last4s)
        )
      )
    )
  order by tx.occurred_at desc, tx.id desc;
$$;

create or replace function public.plan_spent_summary(p_plan_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select coalesce(sum(amount), 0) from public.plan_transactions(p_plan_id);
$$;

revoke all on function public.add_goal_contribution(uuid, text, text, numeric, timestamptz, text) from public, anon;
revoke all on function public.record_bill_payment(uuid, uuid, text, text, numeric, text, timestamptz, timestamptz, timestamptz, integer, text) from public, anon;
revoke all on function public.delete_bill_payment(uuid) from public, anon;
revoke all on function public.plan_transactions(uuid) from public, anon;
revoke all on function public.plan_spent_summary(uuid) from public, anon;
grant execute on function public.add_goal_contribution(uuid, text, text, numeric, timestamptz, text) to authenticated;
grant execute on function public.record_bill_payment(uuid, uuid, text, text, numeric, text, timestamptz, timestamptz, timestamptz, integer, text) to authenticated;
grant execute on function public.delete_bill_payment(uuid) to authenticated;
grant execute on function public.plan_transactions(uuid) to authenticated;
grant execute on function public.plan_spent_summary(uuid) to authenticated;

update public.feature_flags
set value = 'false', rollout_percent = 0, is_active = false
where key in (
  'budgets_supabase_primary', 'goals_supabase_primary',
  'subscriptions_supabase_primary', 'plans_supabase_primary',
  'smart_inbox_supabase_primary'
);

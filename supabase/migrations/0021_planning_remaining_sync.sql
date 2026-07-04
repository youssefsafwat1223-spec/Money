-- Phase G2-G5 planning sync foundation.
-- Adds dark-launched server tables for independent planning entities only.
-- Payment/contribution/link child tables remain plan-only to avoid double
-- counting and broken transaction references.

create table if not exists public.user_budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text null,
  local_account_id text null,
  server_account_id uuid null,
  category_id text not null,
  amount numeric not null,
  period text not null check (period in ('daily', 'weekly', 'monthly', 'yearly')),
  start_date timestamptz not null,
  is_active boolean not null default true,
  alert_80_sent boolean not null default false,
  alert_100_sent boolean not null default false,
  show_on_header boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

create unique index if not exists user_budgets_user_local_id_uidx
  on public.user_budgets(user_id, local_id)
  where local_id is not null;
create index if not exists user_budgets_user_updated_idx
  on public.user_budgets(user_id, updated_at desc);

create table if not exists public.user_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text null,
  local_account_id text null,
  server_account_id uuid null,
  merchant_id text null,
  name text not null,
  amount numeric not null,
  currency text not null,
  type text not null check (type in ('subscription', 'installment')),
  frequency text not null check (frequency in ('weekly', 'monthly', 'yearly', 'custom')),
  next_due_date timestamptz not null,
  reminder_on boolean not null default true,
  is_confirmed boolean not null default false,
  custom_interval_days integer null,
  note text null,
  status text not null check (status in ('active', 'paused', 'cancelled')),
  total_installments integer null,
  paid_count integer null,
  manual_paid_amount numeric null,
  total_purchase_amount numeric null,
  lender_name text null,
  interest_rate numeric null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

create unique index if not exists user_subscriptions_user_local_id_uidx
  on public.user_subscriptions(user_id, local_id)
  where local_id is not null;
create index if not exists user_subscriptions_user_updated_idx
  on public.user_subscriptions(user_id, updated_at desc);

create table if not exists public.user_goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text null,
  local_account_id text null,
  server_account_id uuid null,
  name text not null,
  target_amount numeric not null,
  saved_amount numeric not null,
  deadline timestamptz null,
  vault_skin text not null,
  status text not null,
  auto_save_amount numeric null,
  auto_save_period text null,
  auto_save_last_run timestamptz null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

create unique index if not exists user_goals_user_local_id_uidx
  on public.user_goals(user_id, local_id)
  where local_id is not null;
create index if not exists user_goals_user_updated_idx
  on public.user_goals(user_id, updated_at desc);

create table if not exists public.user_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text null,
  name text not null,
  budget_amount numeric not null,
  currency text not null,
  start_date timestamptz not null,
  end_date timestamptz not null,
  local_account_ids text[] not null default '{}',
  card_last4s text[] not null default '{}',
  status text not null check (status in ('active', 'closed')),
  icon text null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

create unique index if not exists user_plans_user_local_id_uidx
  on public.user_plans(user_id, local_id)
  where local_id is not null;
create index if not exists user_plans_user_updated_idx
  on public.user_plans(user_id, updated_at desc);

alter table public.user_budgets enable row level security;
alter table public.user_subscriptions enable row level security;
alter table public.user_goals enable row level security;
alter table public.user_plans enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'user_budgets'
      and policyname = 'user_budgets_owner'
  ) then
    create policy user_budgets_owner on public.user_budgets
      for all using (user_id = auth.uid())
      with check (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'user_subscriptions'
      and policyname = 'user_subscriptions_owner'
  ) then
    create policy user_subscriptions_owner on public.user_subscriptions
      for all using (user_id = auth.uid())
      with check (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'user_goals'
      and policyname = 'user_goals_owner'
  ) then
    create policy user_goals_owner on public.user_goals
      for all using (user_id = auth.uid())
      with check (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'user_plans'
      and policyname = 'user_plans_owner'
  ) then
    create policy user_plans_owner on public.user_plans
      for all using (user_id = auth.uid())
      with check (user_id = auth.uid());
  end if;
end $$;

drop trigger if exists trg_user_budgets_updated_at on public.user_budgets;
create trigger trg_user_budgets_updated_at
  before update on public.user_budgets
  for each row execute function public.set_updated_at();

drop trigger if exists trg_user_subscriptions_updated_at on public.user_subscriptions;
create trigger trg_user_subscriptions_updated_at
  before update on public.user_subscriptions
  for each row execute function public.set_updated_at();

drop trigger if exists trg_user_goals_updated_at on public.user_goals;
create trigger trg_user_goals_updated_at
  before update on public.user_goals
  for each row execute function public.set_updated_at();

drop trigger if exists trg_user_plans_updated_at on public.user_plans;
create trigger trg_user_plans_updated_at
  before update on public.user_plans
  for each row execute function public.set_updated_at();

insert into public.feature_flags (
  key, value_type, default_enabled, is_active, rollout_percent, description
) values
  ('planning_budgets_sync', 'boolean', false, false, 100, 'Dark-launched budget sync foundation.'),
  ('planning_subscriptions_sync', 'boolean', false, false, 100, 'Dark-launched subscription/bill sync foundation.'),
  ('planning_goals_sync', 'boolean', false, false, 100, 'Dark-launched goals sync foundation.'),
  ('planning_plans_sync', 'boolean', false, false, 100, 'Dark-launched plans sync foundation.')
on conflict (key) do nothing;

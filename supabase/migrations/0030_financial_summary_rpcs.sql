-- Phase 3: authenticated financial summary RPCs. All functions are SECURITY
-- INVOKER, explicitly scope rows to auth.uid(), and exclude tombstones.

create or replace function public.monthly_financial_summary(
  p_from_inclusive timestamptz,
  p_to_exclusive timestamptz,
  p_account_id uuid default null
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'expense', coalesce(sum(amount) filter (where transaction_type = 'expense'), 0),
    'income', coalesce(sum(amount) filter (where transaction_type = 'income'), 0),
    'refund', coalesce(sum(amount) filter (where transaction_type = 'refund'), 0),
    'transfer', coalesce(sum(amount) filter (where transaction_type = 'transfer'), 0)
  )
  from public.user_transactions
  where user_id = auth.uid()
    and deleted_at is null
    and status = 'confirmed'
    and occurred_at >= p_from_inclusive
    and occurred_at < p_to_exclusive
    and (p_account_id is null or server_account_id = p_account_id);
$$;

create or replace function public.account_balance_summary(
  p_account_id uuid
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'account_id', account_row.id,
    'currency', account_row.currency,
    'current_balance', account_row.current_balance,
    'latest_balance_after', (
      select tx.balance_after
      from public.user_transactions tx
      where tx.user_id = auth.uid()
        and tx.server_account_id = account_row.id
        and tx.deleted_at is null
        and tx.balance_after is not null
      order by tx.occurred_at desc, tx.id desc
      limit 1
    )
  )
  from public.user_accounts account_row
  where account_row.user_id = auth.uid()
    and account_row.id = p_account_id
    and account_row.deleted_at is null;
$$;

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

create or replace function public.budget_progress_summary(
  p_from_inclusive timestamptz,
  p_to_exclusive timestamptz
)
returns table(budget_id uuid, spent numeric, budget_limit numeric)
language sql
stable
security invoker
set search_path = public
as $$
  select
    budget.id,
    coalesce(sum(tx.amount) filter (
      where tx.transaction_type = 'expense'
        and (
          budget.category_id in ('all_expenses', '__all_expenses__')
          or tx.category_id = budget.category_id
        )
    ), 0) as spent,
    budget.amount as budget_limit
  from public.user_budgets budget
  left join public.user_transactions tx
    on tx.user_id = budget.user_id
   and tx.deleted_at is null
   and tx.status = 'confirmed'
   and tx.occurred_at >= p_from_inclusive
   and tx.occurred_at < p_to_exclusive
   and (budget.server_account_id is null or tx.server_account_id = budget.server_account_id)
  where budget.user_id = auth.uid()
    and budget.deleted_at is null
    and budget.is_active = true
  group by budget.id, budget.amount
  order by budget.id;
$$;

create or replace function public.goal_progress_summary()
returns table(goal_id uuid, saved_amount numeric, target_amount numeric, ratio numeric)
language sql
stable
security invoker
set search_path = public
as $$
  select
    goal.id,
    goal.saved_amount,
    goal.target_amount,
    case
      when goal.target_amount <= 0 then 0
      else goal.saved_amount / goal.target_amount
    end
  from public.user_goals goal
  where goal.user_id = auth.uid()
    and goal.deleted_at is null
  order by goal.created_at, goal.id;
$$;

create index if not exists idx_user_transactions_account_occurred
  on public.user_transactions(user_id, server_account_id, occurred_at desc)
  where deleted_at is null;

insert into public.feature_flags (
  key, value_type, value, description, rollout_percent, is_active
) values (
  'dashboard_supabase_summary',
  'boolean',
  'false',
  'Phase 3: use authenticated Supabase summary RPCs for dashboard and reports.',
  0,
  false
)
on conflict (key) do update set
  value = 'false',
  rollout_percent = 0,
  is_active = false;

revoke all on function public.monthly_financial_summary(timestamptz, timestamptz, uuid) from public, anon;
revoke all on function public.account_balance_summary(uuid) from public, anon;
revoke all on function public.category_spending_summary(timestamptz, timestamptz, uuid) from public, anon;
revoke all on function public.budget_progress_summary(timestamptz, timestamptz) from public, anon;
revoke all on function public.goal_progress_summary() from public, anon;

grant execute on function public.monthly_financial_summary(timestamptz, timestamptz, uuid) to authenticated;
grant execute on function public.account_balance_summary(uuid) to authenticated;
grant execute on function public.category_spending_summary(timestamptz, timestamptz, uuid) to authenticated;
grant execute on function public.budget_progress_summary(timestamptz, timestamptz) to authenticated;
grant execute on function public.goal_progress_summary() to authenticated;

update public.feature_flags
set value = 'false', rollout_percent = 0, is_active = false
where key = 'dashboard_supabase_summary';

drop function if exists public.goal_progress_summary();
drop function if exists public.budget_progress_summary(timestamptz, timestamptz);
drop function if exists public.category_spending_summary(timestamptz, timestamptz, uuid);
drop function if exists public.account_balance_summary(uuid);
drop function if exists public.monthly_financial_summary(timestamptz, timestamptz, uuid);
drop index if exists public.idx_user_transactions_account_occurred;

alter table public.user_subscriptions
  drop constraint if exists chk_user_subscriptions_amount_positive;

alter table public.user_plans
  drop constraint if exists chk_user_plans_date_range;

alter table public.user_plans
  drop constraint if exists chk_user_plans_budget_amount_positive;

alter table public.user_goals
  drop constraint if exists chk_user_goals_target_amount_positive;

alter table public.user_budgets
  drop constraint if exists chk_user_budgets_amount_positive;

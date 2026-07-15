-- Batch 2: parent financial table data-quality constraints.
-- Additive only; run violation-count checks before applying to any live DB.

alter table public.user_budgets
  add constraint chk_user_budgets_amount_positive
  check (amount > 0);

alter table public.user_goals
  add constraint chk_user_goals_target_amount_positive
  check (target_amount > 0);

alter table public.user_plans
  add constraint chk_user_plans_budget_amount_positive
  check (budget_amount > 0);

alter table public.user_plans
  add constraint chk_user_plans_date_range
  check (end_date >= start_date);

alter table public.user_subscriptions
  add constraint chk_user_subscriptions_amount_positive
  check (amount > 0);

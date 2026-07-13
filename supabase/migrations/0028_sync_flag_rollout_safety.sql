-- Keep every legacy sync and Supabase-primary cutover flag fully dark.
-- 0016/0017 originally seeded rollout_percent=100. is_active=false already
-- kept them inert, but rollout metadata must also be safe before staged QA.

update public.feature_flags
set
  value = 'false',
  rollout_percent = 0,
  is_active = false
where key in (
  'ledger_dual_write',
  'ledger_pull_sync',
  'ledger_push_sync',
  'smart_inbox_pull_sync',
  'planning_accounts_sync',
  'planning_budgets_sync',
  'planning_subscriptions_sync',
  'planning_goals_sync',
  'planning_plans_sync',
  'capture_direct_ledger_write',
  'accounts_supabase_primary',
  'transactions_supabase_primary'
);

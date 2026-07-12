-- Rollback for supabase/migrations/0023_feature_flag_rollout_safety.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Run manually via the SQL Editor only if 0023 needs
-- to be undone.
--
-- Restores rollout_percent to its pre-0023 value (100) for the six flags.
-- value and is_active are left as 'false'/false — 0023 did not change what
-- they were before it ran (they were already false), so there is nothing
-- to revert on those two columns.

UPDATE public.feature_flags
SET rollout_percent = 100
WHERE key IN (
  'planning_accounts_sync',
  'planning_budgets_sync',
  'planning_subscriptions_sync',
  'planning_goals_sync',
  'planning_plans_sync',
  'capture_direct_ledger_write'
);

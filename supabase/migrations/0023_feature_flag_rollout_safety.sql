-- Phase G safety correction: the six planning/capture dark-launch flags
-- seeded in 0020 were inserted with rollout_percent = 100 instead of 0.
-- is_active = false already makes them inert, but rollout_percent must
-- also read 0 per the approved safety spec. Scoped to exactly these keys.

UPDATE public.feature_flags
SET
  value = 'false',
  rollout_percent = 0,
  is_active = false
WHERE key IN (
  'planning_accounts_sync',
  'planning_budgets_sync',
  'planning_subscriptions_sync',
  'planning_goals_sync',
  'planning_plans_sync',
  'capture_direct_ledger_write'
);

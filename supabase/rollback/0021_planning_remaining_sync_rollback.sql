-- Rollback for supabase/migrations/0021_planning_remaining_sync.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Run manually via the SQL Editor / Management API only.
--
-- Written against the CORRECTED version of 0021 (see review notes: the
-- feature_flags INSERT in the migration as currently authored references a
-- column `default_enabled` that does not exist on the live feature_flags
-- table — the live/actual column is `value`. 0021 must be fixed to use the
-- same (key, value_type, value, description, rollout_percent, is_active)
-- shape as 0020 before it can be applied at all. This rollback assumes that
-- fix was made, since a migration that never successfully applied needs no
-- rollback.
--
-- No ordering dependency on 0020 or 0022: 0021's server_account_id columns
-- are plain UUID with no foreign key, so this can be rolled back independently.

DROP TRIGGER IF EXISTS trg_user_budgets_updated_at ON public.user_budgets;
DROP TRIGGER IF EXISTS trg_user_subscriptions_updated_at ON public.user_subscriptions;
DROP TRIGGER IF EXISTS trg_user_goals_updated_at ON public.user_goals;
DROP TRIGGER IF EXISTS trg_user_plans_updated_at ON public.user_plans;

DROP POLICY IF EXISTS user_budgets_owner ON public.user_budgets;
DROP POLICY IF EXISTS user_subscriptions_owner ON public.user_subscriptions;
DROP POLICY IF EXISTS user_goals_owner ON public.user_goals;
DROP POLICY IF EXISTS user_plans_owner ON public.user_plans;

DROP TABLE IF EXISTS public.user_budgets;
DROP TABLE IF EXISTS public.user_subscriptions;
DROP TABLE IF EXISTS public.user_goals;
DROP TABLE IF EXISTS public.user_plans;

DELETE FROM public.feature_flags WHERE key IN (
  'planning_budgets_sync',
  'planning_subscriptions_sync',
  'planning_goals_sync',
  'planning_plans_sync'
);

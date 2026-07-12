-- Rollback for supabase/migrations/0020_planning_accounts_sync.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Run manually via the SQL Editor / Management API only.
--
-- ORDER MATTERS: migration 0022 adds a foreign key from
-- user_transactions.server_account_id to user_accounts(id). If 0022 has been
-- applied, run 0022_ledger_hardening_rollback.sql FIRST, then this file.
-- Do not run this file while 0022's FK still exists — DROP TABLE will fail
-- with a dependent-objects error (which is the correct, safe behavior:
-- Postgres refusing to silently orphan the FK protects you here).
--
-- Does NOT drop public.set_updated_at() — that function pre-dates this
-- migration (already live, used by trg_user_transactions_updated_at since
-- migration 0014). 0020 only does CREATE OR REPLACE on it; dropping it here
-- would break the existing, already-live user_transactions trigger.

DROP TRIGGER IF EXISTS trg_user_accounts_updated_at ON public.user_accounts;
DROP POLICY IF EXISTS user_accounts_owner ON public.user_accounts;
DROP TABLE IF EXISTS public.user_accounts;

DELETE FROM public.feature_flags WHERE key IN (
  'planning_accounts_sync',
  'planning_budgets_sync',
  'planning_subscriptions_sync',
  'planning_goals_sync',
  'planning_plans_sync',
  'capture_direct_ledger_write'
);

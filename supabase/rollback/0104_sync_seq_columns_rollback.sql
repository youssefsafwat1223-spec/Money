-- ROLLBACK for 0104_sync_seq_columns.sql
--
-- Drops the backfill helper, the indexes and the sync_seq columns on the 17
-- synced tables. Roll back 0105 (the stamp triggers) first: they reference
-- NEW.sync_seq. Reversible: sync_seq is derived data; re-applying 0104 numbers
-- the rows again (the numbers may differ, which is harmless because clients
-- re-bootstrap their cursors when the capability is withdrawn).
-- user_sync_state.last_seq is NOT reset here (0103 rollback drops the table).
BEGIN;

DROP FUNCTION IF EXISTS public.backfill_sync_seq();

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'user_accounts', 'user_transactions', 'user_budgets', 'user_goals',
    'user_goal_contributions', 'user_plans', 'user_plan_transaction_links',
    'user_subscriptions', 'user_bill_payments', 'user_cards', 'user_categories',
    'user_settings', 'user_smart_inbox', 'sender_bank_mappings',
    'user_achievements', 'user_streaks', 'user_xp_levels'
  ] LOOP
    EXECUTE format('DROP INDEX IF EXISTS public.%I', 'idx_' || t || '_user_sync_seq');
    EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS sync_seq', t);
  END LOOP;
END $$;

COMMIT;

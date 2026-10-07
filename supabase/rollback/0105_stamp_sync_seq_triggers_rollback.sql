-- ROLLBACK for 0105_stamp_sync_seq_triggers.sql
--
-- Drops the 17 stamp triggers and the function. Existing sync_seq values stay
-- (0104 rollback drops the column). Rows written after this point are no longer
-- stamped and updated_at is client-supplied on INSERT again.
BEGIN;

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
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'trg_' || t || '_stamp_sync_seq', t);
  END LOOP;
END $$;

DROP FUNCTION IF EXISTS public.stamp_sync_seq();

COMMIT;

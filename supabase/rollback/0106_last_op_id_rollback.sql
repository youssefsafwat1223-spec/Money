-- ROLLBACK for 0106_last_op_id.sql
--
-- Drops last_op_id from the 9 parent tables. Roll back 0107 first (its RPCs
-- reference the column). Receipts are lost; a client op in flight at that
-- moment may be reported as a conflict instead of an ACK. No user data lost.
BEGIN;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'user_transactions', 'user_accounts', 'user_budgets', 'user_goals',
    'user_plans', 'user_subscriptions', 'user_cards', 'user_categories',
    'user_settings'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS last_op_id', t);
  END LOOP;
END $$;

COMMIT;

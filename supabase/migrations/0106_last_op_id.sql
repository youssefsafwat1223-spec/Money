-- 0106_last_op_id.sql — WP-2 (manifest 0107): the operation receipt column.
--
-- last_op_id is the id of the client operation that last wrote the row through
-- the sync_* RPCs (0107). A retried operation whose ACK was lost finds its own
-- id on the row and is ACKed instead of reported as a conflict.
--
-- Parent tables = every revisioned (0068) entity: user_transactions,
-- user_accounts, user_budgets, user_goals, user_plans, user_subscriptions,
-- user_cards, user_categories, user_settings. Children (contributions, bill
-- payments, plan links) are append-only and idempotent through their own
-- client_request_id RPCs, so they get no receipt.
--
-- Nullable, no default, never written by build-50 clients: an extra column they
-- ignore. No index (it is only compared on a row already located by key).

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
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS last_op_id uuid', t);
  END LOOP;
END $$;

COMMIT;

-- 0115_revoke_synced_table_delete.sql — WP-7 / manifest 0116 (P5): clients can
-- only TOMBSTONE synced rows; they can no longer hard-DELETE them.
--
-- Fixes B13: a hard delete never reaches the change stream (no sync_seq, no
-- tombstone), so other devices kept the row. Whole-account purge stays a
-- service-role function (purge_user_data, EXECUTE service_role only) and
-- bumps the epoch; service_role is untouched here.
--
-- Scope: DELETE on the synced tables of 0104 from `authenticated` (`anon` is left
-- alone: every policy needs auth.uid(), so it can delete nothing, and its platform
-- default grants differ per environment),
-- plus the explicit owner DELETE policy of sender_bank_mappings (0008), so the
-- mapping becomes soft-delete only (it has a `deleted_at` tombstone column).
-- Policies written FOR ALL on the other tables are left as they are: without
-- the DELETE privilege they can no longer permit a delete.
--
-- Checked, not affected:
--   * every client RPC that "deletes" (delete_user_category_safely 0044,
--     delete_user_account_safely 0037, delete_bill_payment 0108) is a soft
--     delete (UPDATE ... deleted_at); no SECURITY INVOKER function issues a
--     DELETE on these tables for the caller; the purge_user_data family is
--     SECURITY INVOKER but EXECUTE-granted to service_role only;
--   * the only client `.delete()` on a server table is `backups` (not synced,
--     not touched; 0088 keeps its grant).
-- user_achievements / user_streaks / user_xp_levels already had DELETE revoked
-- by 0073; REVOKE of a privilege not held is a no-op.
--
-- Reversible: rollback/0115_revoke_synced_table_delete_rollback.sql re-grants
-- exactly what was held (tables of 0088, plus sender_bank_mappings) and
-- recreates the policy. Capabilities and flags are not touched.

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
    EXECUTE format('REVOKE DELETE ON TABLE public.%I FROM authenticated', t);
  END LOOP;
END $$;

DROP POLICY IF EXISTS "sender_bank_mappings_delete_own" ON public.sender_bank_mappings;

COMMIT;

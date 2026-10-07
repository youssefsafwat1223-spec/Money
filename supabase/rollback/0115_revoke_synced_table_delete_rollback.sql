-- ROLLBACK for 0115_revoke_synced_table_delete.sql (manifest §13 P5: re-grant
-- DELETE). Restores exactly what 0115 removed: DELETE for `authenticated` on the
-- 0088 owner tables that are synced, DELETE on sender_bank_mappings, and its
-- owner DELETE policy. user_achievements / user_streaks / user_xp_levels are NOT
-- re-granted: 0073 revoked them before 0115 and that must stay.
BEGIN;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'user_accounts', 'user_transactions', 'user_budgets', 'user_goals',
    'user_goal_contributions', 'user_plans', 'user_plan_transaction_links',
    'user_subscriptions', 'user_bill_payments', 'user_cards', 'user_categories',
    'user_settings', 'user_smart_inbox', 'sender_bank_mappings'
  ] LOOP
    EXECUTE format('GRANT DELETE ON TABLE public.%I TO authenticated', t);
  END LOOP;
END $$;

DROP POLICY IF EXISTS "sender_bank_mappings_delete_own" ON public.sender_bank_mappings;
CREATE POLICY "sender_bank_mappings_delete_own"
  ON public.sender_bank_mappings FOR DELETE
  USING (auth.uid() = user_id);

COMMIT;

-- SQL proof for WP-7: migration 0115 (clients can only tombstone synced rows).
-- Everything is rolled back. Driver: supabase/tests/revoke_delete_0115.sh
-- (also proves the rollback round trip: grants and policies compared exactly).

BEGIN;

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
GRANT ALL ON _r TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION pg_temp.expect_err(p_name text, p_sql text, p_state text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    INSERT INTO _r VALUES (p_name, false, 'no error raised');
  EXCEPTION WHEN others THEN
    INSERT INTO _r VALUES (p_name, SQLSTATE = p_state, SQLSTATE || ' ' || SQLERRM);
  END;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.expect_err(text,text,text) TO authenticated, anon;

-- ── fixtures (table owner) ────────────────────────────────────────────────────
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000e4'),
  ('00000000-0000-0000-0000-0000000000e5');

INSERT INTO public.user_transactions (id, user_id, client_request_id, amount, currency, occurred_at, source, direction, transaction_type)
VALUES ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000e4', 'r-1', 5, 'EGP', now(), 'manual', 'debit', 'expense'),
       ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000e5', 'r-2', 6, 'EGP', now(), 'manual', 'debit', 'expense');
INSERT INTO public.user_categories (id, user_id, local_id, key, name_ar, icon, color)
VALUES ('20000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000e4', 'k-1', 'k1', 'x', 'i', '#000');
INSERT INTO public.user_subscriptions (id, user_id, local_id, name, amount, currency, type, frequency, next_due_date, status)
VALUES ('20000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e4', 's-1', 's', 5, 'EGP', 'subscription', 'monthly', now(), 'active');
INSERT INTO public.user_bill_payments (id, user_id, subscription_id, client_request_id, amount, currency, period_start, period_end, paid_at)
VALUES ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000e4', '20000000-0000-0000-0000-0000000000f1', 'bp-1', 5, 'EGP', '2026-01-01', '2026-02-01', '2026-01-05');
INSERT INTO public.user_accounts (id, user_id, local_id, name, currency, type)
VALUES ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000e4', 'a-1', 'A', 'EGP', 'bank');
INSERT INTO public.user_accounts (id, user_id, local_id, name, currency, type)
VALUES ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000e4', 'a-2', 'B', 'EGP', 'bank');
INSERT INTO public.sender_bank_mappings (id, user_id, sender_id, normalized_sender_id, suggested_bank_name, suggested_country, confidence, status, source, first_seen_at, last_seen_at)
VALUES ('20000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000e4', 'CIB', 'cib', 'CIB', 'EG', 0.9, 'pending', 'user_manual', now(), now());

-- ── privileges and policies (catalog) ─────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'user_accounts','user_transactions','user_budgets','user_goals','user_goal_contributions',
    'user_plans','user_plan_transaction_links','user_subscriptions','user_bill_payments',
    'user_cards','user_categories','user_settings','user_smart_inbox','sender_bank_mappings',
    'user_achievements','user_streaks','user_xp_levels'
  ] LOOP
    INSERT INTO _r VALUES ('P1 ' || t || ': authenticated holds no DELETE',
      NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), '');
    INSERT INTO _r VALUES ('P1 ' || t || ': SELECT/INSERT/UPDATE for authenticated unchanged where granted (0088/0073)',
      has_table_privilege('authenticated', 'public.' || t, 'SELECT')
      AND (t IN ('user_achievements','user_streaks','user_xp_levels')
           OR (has_table_privilege('authenticated', 'public.' || t, 'INSERT')
               AND has_table_privilege('authenticated', 'public.' || t, 'UPDATE'))), '');
  END LOOP;
  INSERT INTO _r VALUES ('P2 sender_bank_mappings owner DELETE policy removed',
    NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'sender_bank_mappings' AND cmd = 'DELETE'), '');
  INSERT INTO _r VALUES ('P3 backups (not synced) keeps its DELETE grant',
    has_table_privilege('authenticated', 'public.backups', 'DELETE'), '');
  INSERT INTO _r VALUES ('P4 service_role keeps DELETE on every synced table (purge path)',
    (SELECT bool_and(has_table_privilege('service_role', 'public.' || x, 'DELETE'))
       FROM unnest(ARRAY['user_transactions','user_accounts','user_categories','sender_bank_mappings','user_settings']) x), '');
END $$;

-- ── behaviour as an authenticated user ────────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000e4","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e4', true);
SET LOCAL ROLE authenticated;

SELECT pg_temp.expect_err('B1 hard DELETE of own user_transactions row is refused',
  $$DELETE FROM public.user_transactions WHERE id = '20000000-0000-0000-0000-000000000001'$$, '42501');
SELECT pg_temp.expect_err('B1 hard DELETE of own user_categories row is refused',
  $$DELETE FROM public.user_categories WHERE id = '20000000-0000-0000-0000-0000000000c1'$$, '42501');
SELECT pg_temp.expect_err('B1 hard DELETE of own sender_bank_mappings row is refused',
  $$DELETE FROM public.sender_bank_mappings WHERE id = '20000000-0000-0000-0000-0000000000d1'$$, '42501');
SELECT pg_temp.expect_err('B1 hard DELETE of own user_accounts row is refused',
  $$DELETE FROM public.user_accounts WHERE id = '20000000-0000-0000-0000-0000000000a1'$$, '42501');

DO $$
DECLARE n int; d jsonb; cat public.user_categories;
BEGIN
  -- tombstone UPDATE still works and enters the stream
  UPDATE public.user_transactions SET deleted_at = now() WHERE id = '20000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO _r VALUES ('B2 tombstone UPDATE (deleted_at) still works', n = 1, '');
  UPDATE public.sender_bank_mappings SET deleted_at = now() WHERE id = '20000000-0000-0000-0000-0000000000d1';
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO _r VALUES ('B2 sender mapping soft delete still works', n = 1, '');
  INSERT INTO _r VALUES ('B2 tombstone got a sync_seq',
    (SELECT sync_seq IS NOT NULL FROM public.user_transactions WHERE id = '20000000-0000-0000-0000-000000000001'), '');
  -- RPCs that "delete" are soft deletes and keep working
  cat := public.delete_user_category_safely('20000000-0000-0000-0000-0000000000c1');
  INSERT INTO _r VALUES ('B3 delete_user_category_safely still works (soft)', cat.deleted_at IS NOT NULL, '');
  d := public.delete_bill_payment('20000000-0000-0000-0000-0000000000b1');
  INSERT INTO _r VALUES ('B3 delete_bill_payment still works', d IS NOT NULL, d::text);
  PERFORM public.delete_user_account_safely('20000000-0000-0000-0000-0000000000a1');
  INSERT INTO _r VALUES ('B3 delete_user_account_safely still works (soft)',
    (SELECT deleted_at IS NOT NULL FROM public.user_accounts WHERE id = '20000000-0000-0000-0000-0000000000a1'), '');
  -- RLS isolation intact
  INSERT INTO _r VALUES ('B4 RLS: user e4 cannot see e5 rows',
    NOT EXISTS (SELECT 1 FROM public.user_transactions WHERE user_id = '00000000-0000-0000-0000-0000000000e5'), '');
  UPDATE public.user_transactions SET deleted_at = now() WHERE id = '20000000-0000-0000-0000-000000000002';
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO _r VALUES ('B4 RLS: user e4 cannot tombstone e5 rows', n = 0, '');
END $$;
RESET ROLE;

-- ── service role purge still hard-deletes ─────────────────────────────────────
SET LOCAL ROLE service_role;
DO $$
BEGIN
  PERFORM public.purge_user_data('00000000-0000-0000-0000-0000000000e5');
  INSERT INTO _r VALUES ('S1 service_role purge_user_data still hard-deletes',
    NOT EXISTS (SELECT 1 FROM public.user_transactions WHERE user_id = '00000000-0000-0000-0000-0000000000e5'), '');
END $$;
RESET ROLE;

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, left(detail, 160) AS detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'revoke_delete_0115 proof FAILED'; END IF; END $$;
ROLLBACK;

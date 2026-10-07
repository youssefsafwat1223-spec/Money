-- SQL proof for WP-2: migrations 0103-0109 and 0114 (user_sync_state, sync_seq,
-- stamp triggers, last_op_id, sync_* RPCs, idempotent delete_bill_payment,
-- consent NULL, capabilities). Everything is rolled back.
--
-- Run through the driver, which stages the DB (chain to 0102, seed, then 0103+):
--   PSQL_HOST=<socket dir or host> PSQL_USER=postgres supabase/tests/sync_foundation_0103_0114.sh
-- or by hand on a DB staged as the driver does:
--   psql -h "$HOST" -U postgres -d "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/sync_foundation_0103_0114.sql
--
-- Part A asserts the BACKFILL against supabase/tests/sync_seed_pre_0103.sql
-- (users c1/c2/c3); part B is behaviour as the `authenticated` role.

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

-- ───────────────────────── Part A: backfill (as table owner) ─────────────────
DO $$
DECLARE
  c1 constant uuid := '00000000-0000-0000-0000-0000000000c1';
  c2 constant uuid := '00000000-0000-0000-0000-0000000000c2';
  c3 constant uuid := '00000000-0000-0000-0000-0000000000c3';
  t text;
  n bigint;
  seqs bigint[];
  v_last bigint;
BEGIN
  INSERT INTO _r VALUES ('A0 seed present (run sync_seed_pre_0103.sql before 0103)',
    (SELECT count(*) FROM auth.users WHERE id IN (c1, c2, c3)) = 3, '');

  -- A1: every auth.users row has a state row; c3 (no data) too.
  INSERT INTO _r VALUES ('A1 user_sync_state row for every auth.users row',
    NOT EXISTS (SELECT 1 FROM auth.users u WHERE NOT EXISTS (SELECT 1 FROM public.user_sync_state s WHERE s.user_id = u.id)), '');
  INSERT INTO _r VALUES ('A1 empty user c3 has last_seq 0, epoch_reason initial',
    (SELECT last_seq = 0 AND epoch_reason = 'initial' AND epoch IS NOT NULL FROM public.user_sync_state WHERE user_id = c3), '');

  -- T-guard: every synced table has the column, index, ENABLED trigger and no NULL sync_seq.
  FOREACH t IN ARRAY ARRAY[
    'user_accounts','user_transactions','user_budgets','user_goals','user_goal_contributions',
    'user_plans','user_plan_transaction_links','user_subscriptions','user_bill_payments',
    'user_cards','user_categories','user_settings','user_smart_inbox','sender_bank_mappings',
    'user_achievements','user_streaks','user_xp_levels'
  ] LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE sync_seq IS NULL', t) INTO n;
    INSERT INTO _r VALUES ('T-guard ' || t || ': sync_seq column, index, enabled stamp trigger, no NULL rows',
      n = 0
      AND EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename=t AND indexname='idx_'||t||'_user_sync_seq'
                  AND indexdef LIKE '%(user_id, sync_seq)%')
      AND EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgrelid=('public.'||t)::regclass AND g.tgname='trg_'||t||'_stamp_sync_seq'
                  AND g.tgenabled='O' AND g.tgtype & 2 = 2 AND g.tgtype & 4 = 4 AND g.tgtype & 16 = 16)  -- BEFORE, INSERT, UPDATE
      AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=t AND column_name='user_id'),
      'null rows: ' || n);
  END LOOP;
  INSERT INTO _r VALUES ('T-guard: no public table has sync_seq outside the 17 listed',
    NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND column_name='sync_seq'
      AND table_name NOT IN ('user_accounts','user_transactions','user_budgets','user_goals','user_goal_contributions',
        'user_plans','user_plan_transaction_links','user_subscriptions','user_bill_payments','user_cards',
        'user_categories','user_settings','user_smart_inbox','sender_bank_mappings','user_achievements',
        'user_streaks','user_xp_levels')), '');
  INSERT INTO _r VALUES ('T-guard: processed_captures has no sync_seq',
    NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='processed_captures' AND column_name='sync_seq'), '');

  -- A2: backfill order (updated_at, id) across c1's tables: account 01-01 < tx-2 01-02 < tx-1 01-03.
  INSERT INTO _r VALUES ('A2 backfill order follows (updated_at, id): account=1, tx-2=2, tx-1=3',
    (SELECT sync_seq FROM public.user_accounts WHERE local_id = 'acc-1') = 1
    AND (SELECT sync_seq FROM public.user_transactions WHERE client_request_id = 'tx-2') = 2
    AND (SELECT sync_seq FROM public.user_transactions WHERE client_request_id = 'tx-1') = 3, '');
  -- A3: dense, unique per user across all tables; last_seq = count.
  SELECT array_agg(s ORDER BY s) INTO seqs FROM (
    SELECT sync_seq s FROM public.user_accounts WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_transactions WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_budgets WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_goals WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_goal_contributions WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_plans WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_plan_transaction_links WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_subscriptions WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_bill_payments WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_cards WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_categories WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_settings WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_smart_inbox WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.sender_bank_mappings WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_achievements WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_streaks WHERE user_id = c1 UNION ALL
    SELECT sync_seq FROM public.user_xp_levels WHERE user_id = c1) x;
  SELECT last_seq INTO v_last FROM public.user_sync_state WHERE user_id = c1;
  INSERT INTO _r VALUES ('A3 c1 sequence is dense 1..N, unique across all tables, last_seq = N',
    seqs = (SELECT array_agg(g) FROM generate_series(1, v_last) g) AND v_last >= 17, 'last_seq ' || v_last);
  INSERT INTO _r VALUES ('A3 c2 has its own counter (settings+account = 2)',
    (SELECT last_seq FROM public.user_sync_state WHERE user_id = c2) = 2, '');
  -- A4: backfill ran with USER triggers off: revision and updated_at untouched.
  INSERT INTO _r VALUES ('A4 backfill did not bump revision or updated_at of existing rows',
    (SELECT revision = 1 AND updated_at = '2026-01-03T00:00:00Z' FROM public.user_transactions WHERE client_request_id = 'tx-1'), '');
  -- A5: consent backfill.
  INSERT INTO _r VALUES ('A5 consent: existing TRUE/TRUE -> NULL/NULL (c1)',
    (SELECT ai_consent_granted IS NULL AND cloud_processing_enabled IS NULL AND consent_version = 0 AND consent_granted_at IS NULL
       FROM public.user_settings WHERE user_id = c1), '');
  INSERT INTO _r VALUES ('A5 consent: explicit FALSE stays FALSE (c2)',
    (SELECT ai_consent_granted IS FALSE AND cloud_processing_enabled IS FALSE FROM public.user_settings WHERE user_id = c2), '');
  INSERT INTO _r VALUES ('A5 consent: no TRUE remains in user_settings',
    NOT EXISTS (SELECT 1 FROM public.user_settings WHERE ai_consent_granted IS TRUE OR cloud_processing_enabled IS TRUE), '');
  INSERT INTO _r VALUES ('A5 consent column defaults are NULL and columns nullable; consent_version NOT NULL default 0',
    (SELECT bool_and(is_nullable = 'YES' AND column_default IS NULL) FROM information_schema.columns
       WHERE table_schema='public' AND table_name='user_settings' AND column_name IN ('ai_consent_granted','cloud_processing_enabled'))
    AND (SELECT is_nullable = 'NO' AND column_default = '0' FROM information_schema.columns
       WHERE table_schema='public' AND table_name='user_settings' AND column_name='consent_version')
    AND (SELECT is_nullable = 'YES' FROM information_schema.columns
       WHERE table_schema='public' AND table_name='user_settings' AND column_name='consent_granted_at'), '');
END $$;

-- ───────────────────────── Part B: behaviour (authenticated) ─────────────────
INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-0000000000d4'),
  ('00000000-0000-0000-0000-0000000000d5');

DO $$
BEGIN
  INSERT INTO _r VALUES ('B1 new-user hook created user_sync_state (last_seq 0, initial, epoch set)',
    (SELECT count(*) = 2 AND bool_and(last_seq = 0 AND epoch_reason = 'initial' AND epoch IS NOT NULL)
       FROM public.user_sync_state WHERE user_id IN ('00000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-0000000000d5')), '');
END $$;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d4","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d4', true);
SET LOCAL ROLE authenticated;

-- B2 stamping order + B3 server clock on INSERT + client sync_seq ignored.
DO $$
DECLARE
  u constant uuid := '00000000-0000-0000-0000-0000000000d4';
  s1 bigint; s2 bigint; s3 bigint; s4 bigint; u1 timestamptz; u2 timestamptz; last bigint;
BEGIN
  INSERT INTO public.user_accounts (user_id, local_id, name, currency, type, updated_at, sync_seq)
    VALUES (u, 'a-1', 'A', 'EGP', 'bank', '2001-01-01T00:00:00Z', 999) RETURNING sync_seq, updated_at INTO s1, u1;
  INSERT INTO public.user_transactions (user_id, client_request_id, amount, currency, occurred_at, source, direction, transaction_type, updated_at)
    VALUES (u, 'o-1', 5, 'EGP', now(), 'manual', 'debit', 'expense', '2001-01-01T00:00:00Z') RETURNING sync_seq, updated_at INTO s2, u2;
  INSERT INTO public.user_cards (user_id, local_id, last4) VALUES (u, 'c-1', '4242') RETURNING sync_seq INTO s3;
  -- the gamification AFTER trigger on the tx insert also stamped rows in this tx; read the head
  SELECT last_seq INTO last FROM public.user_sync_state WHERE user_id = u;
  INSERT INTO _r VALUES ('B2 stamping order: rows get strictly increasing sync_seq in write order',
    s1 < s2 AND s2 < s3, s1 || ',' || s2 || ',' || s3);
  INSERT INTO _r VALUES ('B2 client-supplied sync_seq (999) is overwritten', s1 <> 999 AND s1 = 1, 's1=' || s1);
  INSERT INTO _r VALUES ('B2 owner reads own user_sync_state; last_seq >= last stamped', last >= s3, 'head ' || last);
  INSERT INTO _r VALUES ('B3 client-supplied updated_at on INSERT is replaced by server now()',
    u1 = now() AND u2 = now(), u1 || ' ' || u2);
  -- cascading rows (gamification) were stamped too, in the same tx
  INSERT INTO _r VALUES ('B2 cascading trigger rows are stamped (no NULL sync_seq among d4 gamification rows)',
    NOT EXISTS (SELECT 1 FROM public.user_xp_levels WHERE user_id = u AND sync_seq IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.user_streaks WHERE user_id = u AND sync_seq IS NULL), '');
  -- UPDATE re-stamps with a larger number
  UPDATE public.user_cards SET nickname = 'x' WHERE user_id = u AND local_id = 'c-1' RETURNING sync_seq INTO s4;
  INSERT INTO _r VALUES ('B2 UPDATE draws a new, larger sync_seq', s4 > last, s4 || ' > ' || last);
END $$;

-- B4 build-50 style merge-upserts (T26 subset) on the stamped tables.
DO $$
DECLARE
  u constant uuid := '00000000-0000-0000-0000-0000000000d4';
  a1 bigint; a2 bigint; r1 int; r2 int; n int;
BEGIN
  -- user_transactions: ON CONFLICT (user_id, client_request_id)
  INSERT INTO public.user_transactions (user_id, client_request_id, amount, currency, occurred_at, source, direction, transaction_type)
    VALUES (u, 'm-1', 10, 'EGP', now(), 'manual', 'debit', 'expense')
    ON CONFLICT (user_id, client_request_id) DO UPDATE SET amount = EXCLUDED.amount RETURNING sync_seq, revision INTO a1, r1;
  INSERT INTO public.user_transactions (user_id, client_request_id, amount, currency, occurred_at, source, direction, transaction_type)
    VALUES (u, 'm-1', 11, 'EGP', now(), 'manual', 'debit', 'expense')
    ON CONFLICT (user_id, client_request_id) DO UPDATE SET amount = EXCLUDED.amount RETURNING sync_seq, revision INTO a2, r2;
  SELECT count(*) INTO n FROM public.user_transactions WHERE user_id = u AND client_request_id = 'm-1';
  INSERT INTO _r VALUES ('B4 merge-upsert user_transactions (user_id, client_request_id): one row, re-stamped, revision bumped',
    n = 1 AND a2 > a1 AND r2 = r1 + 1, a1 || '->' || a2);
  -- user_accounts (user_id, local_id)
  INSERT INTO public.user_accounts (user_id, local_id, name, currency, type) VALUES (u, 'm-a', 'n1', 'EGP', 'cash')
    ON CONFLICT (user_id, local_id) DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a1;
  INSERT INTO public.user_accounts (user_id, local_id, name, currency, type) VALUES (u, 'm-a', 'n2', 'EGP', 'cash')
    ON CONFLICT (user_id, local_id) DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_accounts (user_id, local_id)', a2 > a1 AND (SELECT count(*) FROM public.user_accounts WHERE user_id=u AND local_id='m-a') = 1, '');
  -- user_budgets / goals / plans / subscriptions (partial unique index on local_id)
  INSERT INTO public.user_budgets (user_id, local_id, category_id, amount, period, start_date) VALUES (u, 'm-b', 'g', 1, 'monthly', now())
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET amount = EXCLUDED.amount RETURNING sync_seq INTO a1;
  INSERT INTO public.user_budgets (user_id, local_id, category_id, amount, period, start_date) VALUES (u, 'm-b', 'g', 2, 'monthly', now())
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET amount = EXCLUDED.amount RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_budgets (partial unique local_id)', a2 > a1, '');
  INSERT INTO public.user_goals (user_id, local_id, name, target_amount, saved_amount, vault_skin, status) VALUES (u, 'm-g', 'g', 10, 0, 'd', 'active')
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a1;
  INSERT INTO public.user_goals (user_id, local_id, name, target_amount, saved_amount, vault_skin, status) VALUES (u, 'm-g', 'g2', 10, 0, 'd', 'active')
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_goals', a2 > a1, '');
  INSERT INTO public.user_plans (user_id, local_id, name, budget_amount, currency, start_date, end_date, status) VALUES (u, 'm-p', 'p', 10, 'EGP', now(), now() + interval '1 day', 'active')
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a1;
  INSERT INTO public.user_plans (user_id, local_id, name, budget_amount, currency, start_date, end_date, status) VALUES (u, 'm-p', 'p2', 10, 'EGP', now(), now() + interval '1 day', 'active')
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_plans', a2 > a1, '');
  INSERT INTO public.user_subscriptions (user_id, local_id, name, amount, currency, type, frequency, next_due_date, status) VALUES (u, 'm-s', 's', 5, 'EGP', 'subscription', 'monthly', now(), 'active')
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a1;
  INSERT INTO public.user_subscriptions (user_id, local_id, name, amount, currency, type, frequency, next_due_date, status) VALUES (u, 'm-s', 's2', 5, 'EGP', 'subscription', 'monthly', now(), 'active')
    ON CONFLICT (user_id, local_id) WHERE local_id IS NOT NULL DO UPDATE SET name = EXCLUDED.name RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_subscriptions', a2 > a1, '');
  -- user_cards / user_settings (unique constraint), user_categories
  INSERT INTO public.user_cards (user_id, local_id, last4) VALUES (u, 'm-c', '1111')
    ON CONFLICT (user_id, local_id) DO UPDATE SET nickname = 'n1' RETURNING sync_seq INTO a1;
  INSERT INTO public.user_cards (user_id, local_id, last4) VALUES (u, 'm-c', '1111')
    ON CONFLICT (user_id, local_id) DO UPDATE SET nickname = 'n2' RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_cards', a2 > a1, '');
  INSERT INTO public.user_settings (user_id, local_id, theme) VALUES (u, 'user_settings', 'dark')
    ON CONFLICT (user_id, local_id) DO UPDATE SET theme = EXCLUDED.theme RETURNING sync_seq INTO a1;
  INSERT INTO public.user_settings (user_id, local_id, theme, ai_consent_granted, cloud_processing_enabled) VALUES (u, 'user_settings', 'light', true, true)
    ON CONFLICT (user_id, local_id) DO UPDATE SET theme = EXCLUDED.theme, ai_consent_granted = EXCLUDED.ai_consent_granted,
      cloud_processing_enabled = EXCLUDED.cloud_processing_enabled RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_settings (incl. an old client pushing consent TRUE)', a2 > a1, '');
  INSERT INTO public.user_categories (user_id, local_id, key, name_ar, icon, color) VALUES (u, 'm-k', 'mk', 'x', 'i', '#000')
    ON CONFLICT (user_id, local_id) DO UPDATE SET name_ar = 'y' RETURNING sync_seq INTO a1;
  INSERT INTO public.user_categories (user_id, local_id, key, name_ar, icon, color) VALUES (u, 'm-k', 'mk', 'x', 'i', '#000')
    ON CONFLICT (user_id, local_id) DO UPDATE SET name_ar = 'z' RETURNING sync_seq INTO a2;
  INSERT INTO _r VALUES ('B4 merge-upsert user_categories', a2 > a1, '');
END $$;

-- B4b children through their existing idempotent RPCs (what build-50 calls).
DO $$
DECLARE
  u constant uuid := '00000000-0000-0000-0000-0000000000d4';
  g uuid; s uuid; r1 jsonb; r2 jsonb; n int; d jsonb;
BEGIN
  SELECT id INTO g FROM public.user_goals WHERE user_id = u AND local_id = 'm-g';
  r1 := public.add_goal_contribution(g, 'gc-x', 'gc-x', 5, now(), null);
  r2 := public.add_goal_contribution(g, 'gc-x', 'gc-x', 5, now(), null);
  SELECT count(*) INTO n FROM public.user_goal_contributions WHERE user_id = u AND client_request_id = 'gc-x';
  INSERT INTO _r VALUES ('B4 add_goal_contribution replay: one row, both calls succeed, row stamped',
    n = 1 AND (r1->'contribution'->>'id') = (r2->'contribution'->>'id')
    AND (SELECT sync_seq IS NOT NULL FROM public.user_goal_contributions WHERE user_id = u AND client_request_id = 'gc-x'), '');
  SELECT id INTO s FROM public.user_subscriptions WHERE user_id = u AND local_id = 'm-s';
  r1 := public.record_bill_payment(s, null, 'bp-x', 'bp-x', 5, 'EGP', now(), now(), now(), null, null);
  r2 := public.record_bill_payment(s, null, 'bp-x', 'bp-x', 5, 'EGP', now(), now(), now(), null, null);
  INSERT INTO _r VALUES ('B4 record_bill_payment replay succeeds, one stamped row',
    (SELECT count(*) = 1 AND bool_and(sync_seq IS NOT NULL) FROM public.user_bill_payments WHERE user_id = u AND client_request_id = 'bp-x'), '');

  -- B6 delete_bill_payment idempotent (0108)
  d := public.delete_bill_payment((r1->'payment'->>'id')::uuid);
  INSERT INTO _r VALUES ('B6 delete_bill_payment first delete: outcome deleted, legacy keys payment+subscription maps',
    d->>'outcome' = 'deleted' AND jsonb_typeof(d->'payment') = 'object' AND jsonb_typeof(d->'subscription') = 'object'
    AND d->'payment'->>'deleted_at' IS NOT NULL, d::text);
  d := public.delete_bill_payment((r1->'payment'->>'id')::uuid);
  INSERT INTO _r VALUES ('B6 delete_bill_payment already deleted: success (no P0002), outcome already_deleted, maps returned',
    d->>'outcome' = 'already_deleted' AND jsonb_typeof(d->'payment') = 'object' AND jsonb_typeof(d->'subscription') = 'object', d::text);
  d := public.delete_bill_payment('99999999-9999-9999-9999-999999999999');
  INSERT INTO _r VALUES ('B6 delete_bill_payment absent id: success, outcome absent',
    d->>'outcome' = 'absent' AND d->'payment' = 'null'::jsonb, d::text);
END $$;

-- B5 insert-if-absent / CAS / tombstone for user_transactions.
DO $$
DECLARE
  u constant uuid := '00000000-0000-0000-0000-0000000000d4';
  e uuid; e2 uuid := gen_random_uuid();
  op1 constant uuid := '00000000-0000-0000-0000-00000000a001';
  op2 constant uuid := '00000000-0000-0000-0000-00000000a002';
  op3 constant uuid := '00000000-0000-0000-0000-00000000a003';
  base jsonb := '{"client_request_id":"ia-1","amount":"12.50","currency":"EGP","direction":"debit","transaction_type":"expense","source":"manual","occurred_at":"2026-05-10T10:00:00.123456Z","merchant":"Foo","description":"d","status":"confirmed","category_id":"groceries","metadata":{"last4":"1234"}}';
  r jsonb; row0 jsonb; id1 uuid; rev int;
BEGIN
  SELECT epoch INTO e FROM public.user_sync_state WHERE user_id = u;

  r := public.sync_insert_if_absent('user_transactions', e, op1, base);
  id1 := (r->'row'->>'id')::uuid;
  INSERT INTO _r VALUES ('B5 insert-if-absent: inserted (row, last_op_id = op, revision 1, stamped, server updated_at)',
    r->>'outcome' = 'inserted' AND r->'row'->>'last_op_id' = op1::text AND (r->'row'->>'revision')::int = 1
    AND (r->'row'->>'sync_seq') IS NOT NULL AND (r->'row'->>'user_id') = u::text, r::text);

  r := public.sync_insert_if_absent('user_transactions', e, op1, base);
  INSERT INTO _r VALUES ('A17 B5 lost-ACK: same client id + same op -> ack with the server row',
    r->>'outcome' = 'ack' AND (r->'row'->>'id')::uuid = id1, r::text);

  r := public.sync_insert_if_absent('user_transactions', e, op2,
    base || '{"amount":12.5,"currency":"egp","merchant":"  Foo ","description":"d","occurred_at":"2026-05-10T10:00:00.123999Z"}');
  INSERT INTO _r VALUES ('B5 foreign op, equal normalized fields (12.50=12.5, egp=EGP, trimmed, same ms) -> adopted (server row)',
    r->>'outcome' = 'adopted' AND (r->'row'->>'id')::uuid = id1 AND r->'row'->>'last_op_id' = op1::text, r::text);

  r := public.sync_insert_if_absent('user_transactions', e, op2, base || '{"amount":"13.00"}');
  INSERT INTO _r VALUES ('B5 foreign op, different amount -> conflict, server row returned, unchanged',
    r->>'outcome' = 'conflict' AND (r->'row'->>'amount')::numeric = 12.5 AND r->'row'->>'last_op_id' = op1::text, r::text);
  r := public.sync_insert_if_absent('user_transactions', e, op2, base || '{"metadata":{"last4":"9999"}}');
  INSERT INTO _r VALUES ('B5 foreign op, different card_last4 -> conflict', r->>'outcome' = 'conflict', r::text);
  r := public.sync_insert_if_absent('user_transactions', e, op2, base || '{"occurred_at":"2026-05-10T10:00:00.124Z"}');
  INSERT INTO _r VALUES ('B5 foreign op, occurred_at differs by 1 ms -> conflict', r->>'outcome' = 'conflict', r::text);

  -- CAS update
  SELECT (row->>'revision')::int INTO rev FROM (SELECT public.sync_insert_if_absent('user_transactions', e, op1, base)->'row' AS row) x;
  r := public.sync_cas_update('user_transactions', e, op2, id1, rev, '{"amount":20,"merchant":"Bar","revision":99,"user_id":"00000000-0000-0000-0000-0000000000d5","deleted_at":"2020-01-01T00:00:00Z","last_op_id":"00000000-0000-0000-0000-00000000ffff"}');
  INSERT INTO _r VALUES ('B5 CAS update at expected revision -> applied; only writable keys applied (revision/user_id/deleted_at/last_op_id in patch ignored)',
    r->>'outcome' = 'applied' AND (r->'row'->>'amount')::numeric = 20 AND r->'row'->>'merchant' = 'Bar'
    AND (r->'row'->>'revision')::int = rev + 1 AND r->'row'->>'last_op_id' = op2::text
    AND r->'row'->>'deleted_at' IS NULL AND r->'row'->>'user_id' = u::text, r::text);
  r := public.sync_cas_update('user_transactions', e, op2, id1, rev, '{"amount":20,"merchant":"Bar"}');
  INSERT INTO _r VALUES ('B5 CAS update retried after lost ACK (stale revision, row.last_op_id = op) -> ack',
    r->>'outcome' = 'ack' AND (r->'row'->>'amount')::numeric = 20, r::text);
  r := public.sync_cas_update('user_transactions', e, op3, id1, rev, '{"amount":30}');
  INSERT INTO _r VALUES ('B5 CAS update with stale revision and foreign op -> conflict (server row, amount unchanged)',
    r->>'outcome' = 'conflict' AND (r->'row'->>'amount')::numeric = 20, r::text);
  r := public.sync_cas_update('user_transactions', e, op3, '99999999-9999-9999-9999-999999999999', 1, '{"amount":30}');
  INSERT INTO _r VALUES ('B5 CAS update on unknown id -> not_found', r->>'outcome' = 'not_found', r::text);
  PERFORM pg_temp.expect_err('B5 CAS update with only non-writable keys is rejected (22023)',
    format($q$SELECT public.sync_cas_update('user_transactions', %L, %L, %L, 1, '{"revision":5,"deleted_at":"2020-01-01T00:00:00Z"}')$q$, e, op3, id1), '22023');

  -- CAS tombstone
  r := public.sync_cas_tombstone('user_transactions', e, op3, id1, rev);
  INSERT INTO _r VALUES ('B5 CAS tombstone with stale revision (live row) -> conflict, not deleted',
    r->>'outcome' = 'conflict' AND r->'row'->>'deleted_at' IS NULL, r::text);
  r := public.sync_cas_tombstone('user_transactions', e, op3, id1, rev + 1);
  INSERT INTO _r VALUES ('B5 CAS tombstone at expected revision -> applied, deleted_at set, op recorded',
    r->>'outcome' = 'applied' AND r->'row'->>'deleted_at' IS NOT NULL AND r->'row'->>'last_op_id' = op3::text, r::text);
  r := public.sync_cas_tombstone('user_transactions', e, op3, id1, rev + 1);
  INSERT INTO _r VALUES ('B5 CAS tombstone on already-deleted row -> ack', r->>'outcome' = 'ack', r::text);
  r := public.sync_cas_tombstone('user_transactions', e, gen_random_uuid(), id1, 1);
  INSERT INTO _r VALUES ('B5 CAS tombstone (other op, any revision) on already-deleted row -> ack', r->>'outcome' = 'ack', r::text);
  r := public.sync_cas_update('user_transactions', e, op1, id1, rev + 2, '{"amount":99}');
  INSERT INTO _r VALUES ('B5 CAS update of a tombstoned row -> conflict (remote tombstone wins), still deleted',
    r->>'outcome' = 'conflict' AND r->'row'->>'deleted_at' IS NOT NULL AND (r->'row'->>'amount')::numeric = 20, r::text);
  r := public.sync_cas_tombstone('user_transactions', e, op3, '99999999-9999-9999-9999-999999999999', 1);
  INSERT INTO _r VALUES ('B5 CAS tombstone on unknown id -> not_found', r->>'outcome' = 'not_found', r::text);

  -- insert-if-absent against the tombstone: A18 / A19
  SELECT to_jsonb(t.*) INTO row0 FROM public.user_transactions t WHERE t.id = id1;
  r := public.sync_insert_if_absent('user_transactions', e, gen_random_uuid(), base || '{"amount":"20","merchant":"Bar"}');
  INSERT INTO _r VALUES ('A18 insert-if-absent hitting a tombstone (foreign op, equal fields) -> conflict, never un-deletes',
    r->>'outcome' = 'conflict' AND r->'row'->>'deleted_at' IS NOT NULL, r::text);
  r := public.sync_insert_if_absent('user_transactions', e, op3, base);
  INSERT INTO _r VALUES ('A19 tombstone check FIRST: even the SAME op id on a tombstone is conflict, not ack',
    r->>'outcome' = 'conflict' AND r->'row'->>'deleted_at' IS NOT NULL, r::text);
  INSERT INTO _r VALUES ('A18/A19 deleted_at stays set and the row is untouched by insert-if-absent (revision, amount, op)',
    (SELECT deleted_at IS NOT NULL AND revision = (row0->>'revision')::int AND amount = (row0->>'amount')::numeric
        AND last_op_id = (row0->>'last_op_id')::uuid FROM public.user_transactions WHERE id = id1)
    AND (SELECT count(*) FROM public.user_transactions WHERE user_id = u AND client_request_id = 'ia-1') = 1, '');

  -- epoch mismatch for all three
  r := public.sync_insert_if_absent('user_transactions', e2, gen_random_uuid(), base || '{"client_request_id":"ia-2"}');
  INSERT INTO _r VALUES ('B5 epoch mismatch: insert-if-absent -> epoch_mismatch, nothing written, server epoch returned',
    r->>'outcome' = 'epoch_mismatch' AND (r->>'epoch')::uuid = e
    AND NOT EXISTS (SELECT 1 FROM public.user_transactions WHERE user_id = u AND client_request_id = 'ia-2'), r::text);
  r := public.sync_cas_update('user_transactions', e2, gen_random_uuid(), id1, 1, '{"amount":1}');
  INSERT INTO _r VALUES ('B5 epoch mismatch: CAS update', r->>'outcome' = 'epoch_mismatch', r::text);
  r := public.sync_cas_tombstone('user_transactions', e2, gen_random_uuid(), id1, 1);
  INSERT INTO _r VALUES ('B5 epoch mismatch: CAS tombstone', r->>'outcome' = 'epoch_mismatch', r::text);
  r := public.sync_insert_if_absent('user_transactions', NULL, gen_random_uuid(), base || '{"client_request_id":"ia-3"}');
  INSERT INTO _r VALUES ('B5 NULL expected epoch is a mismatch', r->>'outcome' = 'epoch_mismatch', r::text);

  -- request validation
  PERFORM pg_temp.expect_err('B5 unsupported table is rejected (22023)',
    format($q$SELECT public.sync_insert_if_absent('profiles', %L, %L, '{"id":"x"}')$q$, e, op1), '22023');
  PERFORM pg_temp.expect_err('B5 user_settings is not a sync_* family (22023)',
    format($q$SELECT public.sync_insert_if_absent('user_settings', %L, %L, '{"local_id":"user_settings"}')$q$, e, op1), '22023');
  PERFORM pg_temp.expect_err('B5 missing identity key is rejected (22023)',
    format($q$SELECT public.sync_insert_if_absent('user_transactions', %L, %L, '{"amount":1}')$q$, e, op1), '22023');
  PERFORM pg_temp.expect_err('B5 identifier injection via p_table is rejected (22023)',
    format($q$SELECT public.sync_insert_if_absent('user_transactions; drop table user_goals', %L, %L, '{"client_request_id":"x"}')$q$, e, op1), '22023');
END $$;

-- B5b other families: inserted / ack / adopted / conflict + tombstone rules.
DO $$
DECLARE
  u constant uuid := '00000000-0000-0000-0000-0000000000d4';
  e uuid; r jsonb; r2 jsonb; op1 uuid := gen_random_uuid(); op2 uuid := gen_random_uuid(); op3 uuid := gen_random_uuid();
  t text; row_ jsonb; id1 uuid; rev int;
  fam jsonb := jsonb_build_object(
    'user_accounts',      '{"local_id":"f-acc","name":"Cash","currency":"EGP","type":"cash"}'::jsonb,
    'user_budgets',       '{"local_id":"f-bud","category_id":"g","amount":100,"period":"monthly","start_date":"2026-01-01T00:00:00Z"}'::jsonb,
    'user_goals',         '{"local_id":"f-goal","name":"Trip","target_amount":500,"saved_amount":7,"vault_skin":"d","status":"active"}'::jsonb,
    'user_plans',         '{"local_id":"f-plan","name":"P","budget_amount":50,"currency":"EGP","start_date":"2026-01-01T00:00:00Z","end_date":"2026-02-01T00:00:00Z","status":"active"}'::jsonb,
    'user_subscriptions', '{"local_id":"f-sub","name":"S","amount":9,"currency":"EGP","type":"installment","frequency":"monthly","next_due_date":"2026-03-01T00:00:00Z","status":"active","paid_count":2}'::jsonb,
    'user_cards',         '{"local_id":"f-card","last4":"7777"}'::jsonb,
    'user_categories',    '{"local_id":"f-cat","key":"f_cat","name_ar":"x","icon":"i","color":"#fff"}'::jsonb);
BEGIN
  SELECT epoch INTO e FROM public.user_sync_state WHERE user_id = u;
  FOR t, row_ IN SELECT * FROM jsonb_each(fam) LOOP
    r := public.sync_insert_if_absent(t, e, op1, row_);
    id1 := (r->'row'->>'id')::uuid;
    INSERT INTO _r VALUES ('B5b ' || t || ': inserted with last_op_id and stamp', r->>'outcome' = 'inserted' AND r->'row'->>'last_op_id' = op1::text AND r->'row'->>'sync_seq' IS NOT NULL, r::text);
    r := public.sync_insert_if_absent(t, e, op1, row_);
    INSERT INTO _r VALUES ('B5b ' || t || ': same op -> ack', r->>'outcome' = 'ack', r::text);
    r := public.sync_insert_if_absent(t, e, op2, row_);
    INSERT INTO _r VALUES ('B5b ' || t || ': foreign op, same fields -> adopted', r->>'outcome' = 'adopted', r::text);
    r := public.sync_insert_if_absent(t, e, op2, row_ || jsonb_build_object(
      CASE t WHEN 'user_cards' THEN 'last4' WHEN 'user_categories' THEN 'name_ar' WHEN 'user_plans' THEN 'budget_amount'
             WHEN 'user_goals' THEN 'target_amount' WHEN 'user_budgets' THEN 'amount' ELSE 'name' END,
      CASE t WHEN 'user_plans' THEN to_jsonb(51) WHEN 'user_goals' THEN to_jsonb(501) WHEN 'user_budgets' THEN to_jsonb(101) ELSE to_jsonb('different'::text) END));
    INSERT INTO _r VALUES ('B5b ' || t || ': foreign op, different client field -> conflict', r->>'outcome' = 'conflict', r::text);
    IF t = 'user_goals' THEN
      r := public.sync_insert_if_absent(t, e, op2, row_ || '{"saved_amount":999}');
      INSERT INTO _r VALUES ('B5b user_goals: saved_amount is server-managed and not compared (999 vs 7 -> adopted)', r->>'outcome' = 'adopted' AND (r->'row'->>'saved_amount')::numeric = 7, r::text);
    END IF;
    IF t = 'user_subscriptions' THEN
      INSERT INTO _r VALUES ('B5b user_subscriptions: paid_count accepted on insert only', (SELECT paid_count = 2 FROM public.user_subscriptions WHERE id = id1), '');
      SELECT revision INTO rev FROM public.user_subscriptions WHERE id = id1;
      r := public.sync_cas_update(t, e, op3, id1, rev, '{"paid_count":9,"name":"S2"}');
      INSERT INTO _r VALUES ('B5b user_subscriptions: CAS update ignores server-managed paid_count', r->>'outcome' = 'applied' AND (r->'row'->>'paid_count')::int = 2 AND r->'row'->>'name' = 'S2', r::text);
    END IF;
    IF t = 'user_categories' THEN
      PERFORM pg_temp.expect_err('B5b user_categories: no CAS tombstone RPC (22023, use delete_user_category_safely)',
        format($q$SELECT public.sync_cas_tombstone('user_categories', %L, %L, %L, 1)$q$, e, op3, id1), '22023');
    ELSE
      EXECUTE format('SELECT revision FROM public.%I WHERE id = $1', t) INTO rev USING id1;
      r := public.sync_cas_tombstone(t, e, op3, id1, rev);
      INSERT INTO _r VALUES ('B5b ' || t || ': CAS tombstone applied', r->>'outcome' = 'applied' AND r->'row'->>'deleted_at' IS NOT NULL, r::text);
      r := public.sync_insert_if_absent(t, e, op1, row_);
      INSERT INTO _r VALUES ('B5b ' || t || ': insert-if-absent on tombstone -> conflict, still deleted', r->>'outcome' = 'conflict' AND r->'row'->>'deleted_at' IS NOT NULL, r::text);
    END IF;
  END LOOP;
  -- card unique (user, account, last4) clash from a different local_id -> conflict (unique_violation), not an error
  r := public.sync_insert_if_absent('user_cards', e, gen_random_uuid(), '{"local_id":"f-card-dup-a","last4":"5555","local_account_id":"acc-z"}');
  r2 := public.sync_insert_if_absent('user_cards', e, gen_random_uuid(), '{"local_id":"f-card-dup-b","last4":"5555","local_account_id":"acc-z"}');
  INSERT INTO _r VALUES ('B5b user_cards: (user, account, last4) clash from another local_id -> conflict (unique_violation)',
    r->>'outcome' = 'inserted' AND r2->>'outcome' = 'conflict' AND r2->>'reason' = 'unique_violation', r2::text);
END $$;

-- B7 cross-user isolation: user d5 cannot touch d4's rows and gets independent state.
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d5","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d5', true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  e5 uuid; r jsonb; d4tx uuid; s bigint;
BEGIN
  SELECT epoch INTO e5 FROM public.user_sync_state;   -- RLS: only own row
  INSERT INTO _r VALUES ('B7 owner SELECT on user_sync_state sees only own row',
    (SELECT count(*) FROM public.user_sync_state) = 1 AND (SELECT user_id FROM public.user_sync_state) = '00000000-0000-0000-0000-0000000000d5', '');
  SELECT id INTO d4tx FROM public.user_transactions;  -- RLS: none visible
  INSERT INTO _r VALUES ('B7 d5 cannot see d4 transactions', d4tx IS NULL, '');
  r := public.sync_insert_if_absent('user_transactions', e5, gen_random_uuid(),
    '{"client_request_id":"ia-1","amount":"12.50","currency":"EGP","direction":"debit","transaction_type":"expense","source":"manual","occurred_at":"2026-05-10T10:00:00Z"}');
  INSERT INTO _r VALUES ('B7 same client_request_id under another user is an independent insert (identity is per user)',
    r->>'outcome' = 'inserted' AND r->'row'->>'user_id' = '00000000-0000-0000-0000-0000000000d5', r::text);
  SELECT sync_seq INTO s FROM public.user_transactions;
  INSERT INTO _r VALUES ('B7 per-user counters are independent (d5 first stamped row is below d4 head)', s >= 1 AND s <= 4, 'seq ' || s);
  r := public.sync_cas_update('user_transactions', e5, gen_random_uuid(), (SELECT id FROM public.user_transactions WHERE user_id = '00000000-0000-0000-0000-0000000000d5'), 1, '{"amount":2}');
  INSERT INTO _r VALUES ('B7 CAS on own row works', r->>'outcome' = 'applied', r::text);
END $$;
SELECT pg_temp.expect_err('B7 d5 cannot UPDATE user_sync_state', $q$UPDATE public.user_sync_state SET last_seq = 0$q$, '42501');
SELECT pg_temp.expect_err('B7 d5 cannot INSERT user_sync_state', $q$INSERT INTO public.user_sync_state (user_id) VALUES (gen_random_uuid())$q$, '42501');
SELECT pg_temp.expect_err('B7 d5 cannot DELETE user_sync_state', $q$DELETE FROM public.user_sync_state$q$, '42501');
SELECT pg_temp.expect_err('B7 stamp_sync_seq is not callable by authenticated', $q$SELECT public.stamp_sync_seq()$q$, '42501');
SELECT pg_temp.expect_err('B7 backfill_sync_seq is not callable by authenticated', $q$SELECT public.backfill_sync_seq()$q$, '42501');
SELECT pg_temp.expect_err('B7 create_user_sync_state is not callable by authenticated', $q$SELECT public.create_user_sync_state()$q$, '42501');

-- unauthenticated JWT (no sub) on the RPCs
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_err('B7 sync_insert_if_absent without a user -> 28000',
  $q$SELECT public.sync_insert_if_absent('user_transactions', gen_random_uuid(), gen_random_uuid(), '{"client_request_id":"x"}')$q$, '28000');
SELECT pg_temp.expect_err('B7 delete_bill_payment without a user -> 42501',
  $q$SELECT public.delete_bill_payment(gen_random_uuid())$q$, '42501');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_err('B7 anon cannot read user_sync_state', $q$SELECT * FROM public.user_sync_state$q$, '42501');
SELECT pg_temp.expect_err('B7 anon cannot execute sync_insert_if_absent', $q$SELECT public.sync_insert_if_absent('user_transactions', null, null, null)$q$, '42501');
SELECT pg_temp.expect_err('B7 anon cannot execute sync_lock_epoch', $q$SELECT public.sync_lock_epoch()$q$, '42501');
SELECT pg_temp.expect_err('B7 anon cannot execute capabilities', $q$SELECT public.qirsh_server_capabilities()$q$, '42501');
RESET ROLE;

-- B8 lazy state creation: a missing state row can never leave a row unstamped.
DELETE FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000d5';
DO $$
DECLARE s bigint;
BEGIN
  INSERT INTO public.user_cards (user_id, local_id, last4) VALUES ('00000000-0000-0000-0000-0000000000d5', 'lazy-1', '0001') RETURNING sync_seq INTO s;
  INSERT INTO _r VALUES ('B8 stamping recreates a missing user_sync_state row lazily (seq 1, state last_seq 1, reason initial)',
    s = 1 AND (SELECT last_seq = 1 AND epoch_reason = 'initial' FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000d5'), 's=' || s);
END $$;
DELETE FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000d5';
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d5","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d5', true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE e uuid; r jsonb;
BEGIN
  e := gen_random_uuid();
  r := public.sync_insert_if_absent('user_cards', e, gen_random_uuid(), '{"local_id":"lazy-2","last4":"0002"}');
  INSERT INTO _r VALUES ('B8 RPC lock helper recreates a missing state row; supplied epoch cannot match a fresh one',
    r->>'outcome' = 'epoch_mismatch', r::text);
END $$;
RESET ROLE;

-- B9 consent defaults for newly created settings rows (build-50 insert without consent keys)
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d5","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d5', true);
SET LOCAL ROLE authenticated;
INSERT INTO public.user_settings (user_id, local_id, theme) VALUES ('00000000-0000-0000-0000-0000000000d5', 'user_settings', 'dark');
DO $$
BEGIN
  INSERT INTO _r VALUES ('B9 new settings row without consent keys: ai/cloud NULL, consent_version 0, granted_at NULL',
    (SELECT ai_consent_granted IS NULL AND cloud_processing_enabled IS NULL AND consent_version = 0 AND consent_granted_at IS NULL
       FROM public.user_settings WHERE user_id = '00000000-0000-0000-0000-0000000000d5'), '');
END $$;

-- B10 capabilities (0114)
DO $$
DECLARE c jsonb;
BEGIN
  c := public.qirsh_server_capabilities();
  INSERT INTO _r VALUES ('B10 capabilities: awaiting_fx_transactions preserved = true', c->'awaiting_fx_transactions' = 'true'::jsonb, c::text);
  INSERT INTO _r VALUES ('B10 capabilities: capture_contract_v2, sync_seq, revision_cas, replica_epoch, min_supported_seq, min_client_build all false',
    c->'capture_contract_v2' = 'false'::jsonb AND c->'sync_seq' = 'false'::jsonb AND c->'revision_cas' = 'false'::jsonb
    AND c->'replica_epoch' = 'false'::jsonb AND c->'min_supported_seq' = 'false'::jsonb AND c->'min_client_build' = 'false'::jsonb, c::text);
  INSERT INTO _r VALUES ('B10 capabilities: exactly 7 keys, nothing advertised true except the old key',
    (SELECT count(*) FROM jsonb_object_keys(c)) = 7 AND (SELECT count(*) FROM jsonb_each(c) WHERE value = 'true'::jsonb) = 1, '');
END $$;
RESET ROLE;

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, left(detail, 160) AS detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'sync_foundation_0103_0114 proof FAILED'; END IF; END $$;
ROLLBACK;

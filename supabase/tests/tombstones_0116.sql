-- SQL proof for D1: migration 0116 (sync_cas_tombstone_category,
-- sync_tombstone_goal_contribution). Everything is rolled back.
-- Driver (stages the chain, runs this, proves the rollback round trip):
--   PGHOST=/path/to/socket-dir supabase/tests/tombstones_0116.sh

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
  ('00000000-0000-0000-0000-0000000000f4'),
  ('00000000-0000-0000-0000-0000000000f5');

INSERT INTO public.user_categories (id, user_id, local_id, key, name_ar, icon, color) VALUES
  ('30000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f4', 'k-1', 'custom_1', 'x', 'i', '#000'),
  ('30000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000f4', 'k-2', 'custom_2', 'y', 'i', '#000'),
  ('30000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000f4', 'k-3', 'custom_3', 'z', 'i', '#000'),
  ('30000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000000f5', 'k-9', 'custom_9', 'o', 'i', '#000');
INSERT INTO public.user_transactions (id, user_id, client_request_id, amount, currency, occurred_at, source, direction, transaction_type, category_id, user_category_id) VALUES
  ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000f4', 'ct-1', 5, 'EGP', now(), 'manual', 'debit', 'expense', 'groceries', '30000000-0000-0000-0000-0000000000c1'),
  ('30000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000f4', 'ct-2', 6, 'EGP', now(), 'manual', 'debit', 'expense', 'groceries', '30000000-0000-0000-0000-0000000000c2');
INSERT INTO public.user_budgets (id, user_id, local_id, category_id, user_category_id, amount, period, start_date) VALUES
  ('30000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000f4', 'b-1', 'groceries', '30000000-0000-0000-0000-0000000000c1', 100, 'monthly', now());
INSERT INTO public.user_goals (id, user_id, local_id, name, target_amount, saved_amount, vault_skin, status) VALUES
  ('30000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000f4', 'g-1', 'G', 1000, 0, 'default', 'active'),
  ('30000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-0000000000f5', 'g-9', 'G9', 1000, 0, 'default', 'active');

-- Contributions go through the real RPC so saved_amount is server-managed exactly as in production.
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f4","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f4', true);
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE _ids (k text PRIMARY KEY, v uuid);
GRANT ALL ON _ids TO authenticated;
INSERT INTO _ids
SELECT 'c' || i, (public.add_goal_contribution('30000000-0000-0000-0000-0000000000a1', 'gc-' || i, 'gc-' || i, i * 10, now(), null) -> 'contribution' ->> 'id')::uuid
FROM generate_series(1, 3) i;
RESET ROLE;
-- user f5 contribution (for isolation)
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f5","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f5', true);
SET LOCAL ROLE authenticated;
INSERT INTO _ids SELECT 'c9', (public.add_goal_contribution('30000000-0000-0000-0000-0000000000a9', 'gc-9', 'gc-9', 50, now(), null) -> 'contribution' ->> 'id')::uuid;
RESET ROLE;

-- ── structure ─────────────────────────────────────────────────────────────────
DO $$
BEGIN
  INSERT INTO _r VALUES ('S1 both functions are SECURITY INVOKER with a pinned search_path',
    (SELECT count(*) = 2 AND bool_and(NOT prosecdef AND proconfig::text LIKE '%search_path=public%')
       FROM pg_proc WHERE proname IN ('sync_cas_tombstone_category','sync_tombstone_goal_contribution')), '');
  INSERT INTO _r VALUES ('S2 EXECUTE: authenticated yes, anon no, PUBLIC no',
    has_function_privilege('authenticated', 'public.sync_cas_tombstone_category(uuid,uuid,uuid,integer)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.sync_tombstone_goal_contribution(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.sync_cas_tombstone_category(uuid,uuid,uuid,integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.sync_tombstone_goal_contribution(uuid,uuid)', 'EXECUTE'), '');
  INSERT INTO _r VALUES ('S3 fixture: saved_amount = 10+20+30 = 60 via add_goal_contribution',
    (SELECT saved_amount = 60 FROM public.user_goals WHERE id = '30000000-0000-0000-0000-0000000000a1'), '');
END $$;

-- ── as user f4 ────────────────────────────────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f4","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f4', true);
SET LOCAL ROLE authenticated;

-- Category tombstone.
DO $$
DECLARE
  ep uuid := (SELECT epoch FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000f4');
  c1 constant uuid := '30000000-0000-0000-0000-0000000000c1';
  c2 constant uuid := '30000000-0000-0000-0000-0000000000c2';
  c3 constant uuid := '30000000-0000-0000-0000-0000000000c3';
  c9 constant uuid := '30000000-0000-0000-0000-0000000000c9';
  op1 constant uuid := '40000000-0000-0000-0000-000000000001';
  op2 constant uuid := '40000000-0000-0000-0000-000000000002';
  rev int; r jsonb; r2 jsonb; sq1 bigint; sq2 bigint;
BEGIN
  SELECT revision INTO rev FROM public.user_categories WHERE id = c1;
  r := public.sync_cas_tombstone_category(ep, op1, c1, rev);
  INSERT INTO _r VALUES ('C1 applied: tombstoned, last_op_id = op, row returned',
    r ->> 'outcome' = 'applied' AND r -> 'row' ->> 'deleted_at' IS NOT NULL AND r -> 'row' ->> 'last_op_id' = op1::text, r ->> 'outcome');
  INSERT INTO _r VALUES ('C1 applied: live transaction + budget re-parented to category_id other, user_category_id NULL (0044 semantics)',
    (SELECT user_category_id IS NULL AND category_id = 'other' FROM public.user_transactions WHERE client_request_id = 'ct-1')
    AND (SELECT user_category_id IS NULL AND category_id = 'other' FROM public.user_budgets WHERE local_id = 'b-1'), '');
  INSERT INTO _r VALUES ('C1 applied: another category''s transaction untouched',
    (SELECT user_category_id = c2 FROM public.user_transactions WHERE client_request_id = 'ct-2'), '');
  INSERT INTO _r VALUES ('C1 no hard delete: the category row still exists (tombstone only)',
    EXISTS (SELECT 1 FROM public.user_categories WHERE id = c1 AND deleted_at IS NOT NULL), '');

  -- replay with the same op (lost ACK), and a different op: both ack, dependants not touched again.
  SELECT sync_seq INTO sq1 FROM public.user_transactions WHERE client_request_id = 'ct-1';
  r := public.sync_cas_tombstone_category(ep, op1, c1, rev);
  r2 := public.sync_cas_tombstone_category(ep, op2, c1, rev + 99);
  SELECT sync_seq INTO sq2 FROM public.user_transactions WHERE client_request_id = 'ct-1';
  INSERT INTO _r VALUES ('C2 replay of the same op -> ack', r ->> 'outcome' = 'ack', r ->> 'outcome');
  INSERT INTO _r VALUES ('C2 already-deleted with another op / stale revision -> ack (idempotent)', r2 ->> 'outcome' = 'ack', r2 ->> 'outcome');
  INSERT INTO _r VALUES ('C2 replay re-parents nothing (transaction sync_seq unchanged)', sq1 = sq2, sq1 || '/' || sq2);

  -- stale revision on a live category -> conflict, nothing written.
  SELECT revision INTO rev FROM public.user_categories WHERE id = c2;
  r := public.sync_cas_tombstone_category(ep, op2, c2, rev - 1);
  INSERT INTO _r VALUES ('C3 stale revision on a live category -> conflict with the cloud row',
    r ->> 'outcome' = 'conflict' AND r -> 'row' ->> 'deleted_at' IS NULL AND (r -> 'row' ->> 'revision')::int = rev, r ->> 'outcome');
  INSERT INTO _r VALUES ('C3 conflict wrote nothing: category live, its transaction still attached',
    (SELECT deleted_at IS NULL FROM public.user_categories WHERE id = c2)
    AND (SELECT user_category_id = c2 FROM public.user_transactions WHERE client_request_id = 'ct-2'), '');

  -- not_found: random id, and another user's category (RLS-invisible).
  r := public.sync_cas_tombstone_category(ep, op2, gen_random_uuid(), 1);
  INSERT INTO _r VALUES ('C4 absent id -> not_found', r ->> 'outcome' = 'not_found', r ->> 'outcome');
  r := public.sync_cas_tombstone_category(ep, op2, c9, 1);
  INSERT INTO _r VALUES ('C4 another user''s category -> not_found (isolation; indistinguishable from absent)',
    r ->> 'outcome' = 'not_found', r ->> 'outcome');

  -- epoch.
  r := public.sync_cas_tombstone_category(gen_random_uuid(), op2, c3, 1);
  INSERT INTO _r VALUES ('C5 wrong epoch -> epoch_mismatch carrying the current epoch, nothing written',
    r ->> 'outcome' = 'epoch_mismatch' AND (r ->> 'epoch')::uuid = ep
    AND (SELECT deleted_at IS NULL FROM public.user_categories WHERE id = c3), '');
  r := public.sync_cas_tombstone_category(NULL, op2, c3, 1);
  INSERT INTO _r VALUES ('C5 NULL epoch -> epoch_mismatch', r ->> 'outcome' = 'epoch_mismatch', r ->> 'outcome');

  -- applied again on a fresh category with the right revision (no dependants).
  SELECT revision INTO rev FROM public.user_categories WHERE id = c3;
  r := public.sync_cas_tombstone_category(ep, op2, c3, rev);
  INSERT INTO _r VALUES ('C6 category without dependants -> applied', r ->> 'outcome' = 'applied', r ->> 'outcome');
END $$;

SELECT pg_temp.expect_err('C7 NULL op id -> 22023',
  $q$SELECT public.sync_cas_tombstone_category((SELECT epoch FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000f4'), NULL, '30000000-0000-0000-0000-0000000000c2', 1)$q$, '22023');

-- Goal-contribution tombstone.
DO $$
DECLARE
  ep uuid := (SELECT epoch FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000f4');
  g constant uuid := '30000000-0000-0000-0000-0000000000a1';
  c2 uuid := (SELECT v FROM _ids WHERE k = 'c2');
  c3 uuid := (SELECT v FROM _ids WHERE k = 'c3');
  c9 uuid := (SELECT v FROM _ids WHERE k = 'c9');
  r jsonb; r2 jsonb; saved numeric; rev1 int; rev2 int;
BEGIN
  r := public.sync_tombstone_goal_contribution(ep, c2);
  SELECT saved_amount INTO saved FROM public.user_goals WHERE id = g;
  INSERT INTO _r VALUES ('G1 applied: contribution tombstoned, row returned',
    r ->> 'outcome' = 'applied' AND r -> 'row' ->> 'deleted_at' IS NOT NULL, r ->> 'outcome');
  INSERT INTO _r VALUES ('G1 saved_amount reduced by exactly the contribution (60 - 20 = 40)', saved = 40, saved::text);
  INSERT INTO _r VALUES ('G1 goal returned with exact saved_amount_text',
    r -> 'goal' ->> 'saved_amount_text' = saved::text, r -> 'goal' ->> 'saved_amount_text');

  SELECT revision INTO rev1 FROM public.user_goals WHERE id = g;
  r2 := public.sync_tombstone_goal_contribution(ep, c2);
  SELECT saved_amount, revision INTO saved, rev2 FROM public.user_goals WHERE id = g;
  INSERT INTO _r VALUES ('G2 replay -> ack', r2 ->> 'outcome' = 'ack' AND r2 -> 'row' ->> 'deleted_at' IS NOT NULL, r2 ->> 'outcome');
  INSERT INTO _r VALUES ('G2 replay does NOT reduce saved_amount again (still 40) and does not touch the goal',
    saved = 40 AND rev1 = rev2 AND r2 -> 'goal' ->> 'saved_amount_text' = '40', saved::text);

  -- second, different contribution: 40 - 30 = 10; the live ones left are consistent with sum.
  r := public.sync_tombstone_goal_contribution(ep, c3);
  SELECT saved_amount INTO saved FROM public.user_goals WHERE id = g;
  INSERT INTO _r VALUES ('G3 second contribution -> 10 = sum of the remaining live contribution',
    r ->> 'outcome' = 'applied' AND saved = 10
    AND saved = (SELECT sum(amount) FROM public.user_goal_contributions WHERE goal_id = g AND deleted_at IS NULL), saved::text);
  INSERT INTO _r VALUES ('G3 no hard delete: all three contribution rows still exist',
    (SELECT count(*) = 3 FROM public.user_goal_contributions WHERE goal_id = g), '');

  -- add after delete still works and keeps the arithmetic (add 5 -> 15).
  PERFORM public.add_goal_contribution(g, 'gc-new', 'gc-new', 5, now(), null);
  INSERT INTO _r VALUES ('G4 add_goal_contribution after deletes keeps saved_amount consistent (15)',
    (SELECT saved_amount = 15 FROM public.user_goals WHERE id = g), '');

  r := public.sync_tombstone_goal_contribution(ep, gen_random_uuid());
  INSERT INTO _r VALUES ('G5 absent id -> not_found, goal null', r ->> 'outcome' = 'not_found' AND r -> 'goal' = 'null'::jsonb, r ->> 'outcome');
  r := public.sync_tombstone_goal_contribution(ep, c9);
  INSERT INTO _r VALUES ('G5 another user''s contribution -> not_found and their goal is unchanged',
    r ->> 'outcome' = 'not_found', r ->> 'outcome');

  r := public.sync_tombstone_goal_contribution(gen_random_uuid(), (SELECT id FROM public.user_goal_contributions WHERE client_request_id = 'gc-new'));
  INSERT INTO _r VALUES ('G6 wrong epoch -> epoch_mismatch, nothing written',
    r ->> 'outcome' = 'epoch_mismatch' AND (r ->> 'epoch')::uuid = ep
    AND (SELECT deleted_at IS NULL FROM public.user_goal_contributions WHERE client_request_id = 'gc-new')
    AND (SELECT saved_amount = 15 FROM public.user_goals WHERE id = g), '');
  r := public.sync_tombstone_goal_contribution(NULL, c3);
  INSERT INTO _r VALUES ('G6 NULL epoch -> epoch_mismatch', r ->> 'outcome' = 'epoch_mismatch', r ->> 'outcome');

  -- the floor: a goal whose saved_amount was lowered by an edit never goes negative.
  UPDATE public.user_goals SET saved_amount = 2 WHERE id = g;
  r := public.sync_tombstone_goal_contribution(ep, (SELECT id FROM public.user_goal_contributions WHERE client_request_id = 'gc-new'));
  INSERT INTO _r VALUES ('G7 saved_amount below the contribution floors at 0 (never negative)',
    r ->> 'outcome' = 'applied' AND (SELECT saved_amount = 0 FROM public.user_goals WHERE id = g), '');
END $$;
SELECT pg_temp.expect_err('G8 NULL id -> 22023',
  $q$SELECT public.sync_tombstone_goal_contribution((SELECT epoch FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000f4'), NULL)$q$, '22023');

-- ── RLS isolation as the OTHER user, and no hard delete from the client ──────
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f5","role":"authenticated"}', true);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f5', true);
DO $$
DECLARE
  ep5 uuid := (SELECT epoch FROM public.user_sync_state WHERE user_id = '00000000-0000-0000-0000-0000000000f5');
  r jsonb;
BEGIN
  r := public.sync_tombstone_goal_contribution(ep5, (SELECT v FROM _ids WHERE k = 'c1'));
  INSERT INTO _r VALUES ('I1 user f5 cannot tombstone f4''s contribution (not_found) and f4''s goal is untouched',
    r ->> 'outcome' = 'not_found', r ->> 'outcome');
  r := public.sync_cas_tombstone_category(ep5, '40000000-0000-0000-0000-000000000009', '30000000-0000-0000-0000-0000000000c2', 1);
  INSERT INTO _r VALUES ('I1 user f5 cannot tombstone f4''s category (not_found)', r ->> 'outcome' = 'not_found', r ->> 'outcome');
  r := public.sync_tombstone_goal_contribution(ep5, (SELECT v FROM _ids WHERE k = 'c9'));
  INSERT INTO _r VALUES ('I2 f5 deletes own contribution (50 -> 0) and only own goal changes',
    r ->> 'outcome' = 'applied'
    AND (SELECT saved_amount = 0 FROM public.user_goals WHERE local_id = 'g-9')
    AND (SELECT count(*) = 0 FROM public.user_goals WHERE local_id = 'g-1'), '');
END $$;
SELECT pg_temp.expect_err('I3 client hard DELETE of a contribution stays revoked (0115)',
  $q$DELETE FROM public.user_goal_contributions$q$, '42501');
SELECT pg_temp.expect_err('I3 client hard DELETE of a category stays revoked (0115)',
  $q$DELETE FROM public.user_categories$q$, '42501');
RESET ROLE;
DO $$
BEGIN
  INSERT INTO _r VALUES ('I4 owner view: f4 data unchanged by f5 (goal saved_amount 0 after G7, category c2 live)',
    (SELECT saved_amount = 0 FROM public.user_goals WHERE local_id = 'g-1')
    AND (SELECT deleted_at IS NULL FROM public.user_categories WHERE id = '30000000-0000-0000-0000-0000000000c2'), '');
END $$;

-- anon cannot call either function.
SET LOCAL ROLE anon;
SELECT pg_temp.expect_err('A1 anon cannot call sync_cas_tombstone_category',
  $q$SELECT public.sync_cas_tombstone_category(gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 1)$q$, '42501');
SELECT pg_temp.expect_err('A1 anon cannot call sync_tombstone_goal_contribution',
  $q$SELECT public.sync_tombstone_goal_contribution(gen_random_uuid(), gen_random_uuid())$q$, '42501');
RESET ROLE;

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, left(detail, 160) AS detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'tombstones_0116 proof FAILED'; END IF; END $$;
ROLLBACK;

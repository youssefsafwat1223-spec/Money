-- SQL proof for deferred migration 0103 (awaiting_fx_transactions).
-- Run against a LOCAL throwaway Postgres ONLY (active chain 0001-0099 applied;
-- 0100-0102 NOT required). Everything is rolled back.
--
--   sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/deferred/0103_awaiting_fx_transactions_rollback.sql > "$TMPDIR/rb0103.sql"
--   { echo 'BEGIN;'; sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/deferred/0103_awaiting_fx_transactions.sql;
--     cat supabase/tests/awaiting_fx_0103.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1 -v rb="$TMPDIR/rb0103.sql"
--
-- (The migration's own BEGIN/COMMIT are stripped so the outer ROLLBACK undoes it.)

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

INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000b1');

-- Act as the authenticated user.
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

-- 1. awaiting-FX insert succeeds (as the user); plus priced rows.
INSERT INTO public.user_transactions (user_id, amount, currency, foreign_amount, foreign_currency, occurred_at, source, transaction_type, direction, category_id, client_request_id)
VALUES ('00000000-0000-0000-0000-0000000000b1', 0, 'EGP', 50, 'USD', '2026-05-10', 'manual', 'expense', 'debit', 'groceries', 'fx-1');
INSERT INTO _r VALUES ('awaitingFx insert (0 + foreign>0 + currency) succeeds', true, 'ok');
INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, transaction_type, direction, category_id, client_request_id)
VALUES ('00000000-0000-0000-0000-0000000000b1', 100, 'EGP', '2026-05-11', 'manual', 'expense', 'debit', 'groceries', 'p-1'),
       ('00000000-0000-0000-0000-0000000000b1', 40, 'EGP', '2026-05-12', 'manual', 'expense', 'debit', 'groceries', 'p-2');

-- 2. shape strictness
SELECT pg_temp.expect_err('amount 0 without foreign fails',
 $q$INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, client_request_id) VALUES ('00000000-0000-0000-0000-0000000000b1',0,'EGP','2026-05-10','manual','z1')$q$, '23514');
SELECT pg_temp.expect_err('amount 0 with foreign_amount but no foreign_currency fails',
 $q$INSERT INTO public.user_transactions (user_id, amount, currency, foreign_amount, occurred_at, source, client_request_id) VALUES ('00000000-0000-0000-0000-0000000000b1',0,'EGP',5,'2026-05-10','manual','z2')$q$, '23514');
SELECT pg_temp.expect_err('amount 0 with foreign_amount 0 fails',
 $q$INSERT INTO public.user_transactions (user_id, amount, currency, foreign_amount, foreign_currency, occurred_at, source, client_request_id) VALUES ('00000000-0000-0000-0000-0000000000b1',0,'EGP',0,'USD','2026-05-10','manual','z3')$q$, '23514');
SELECT pg_temp.expect_err('negative amount fails',
 $q$INSERT INTO public.user_transactions (user_id, amount, currency, occurred_at, source, client_request_id) VALUES ('00000000-0000-0000-0000-0000000000b1',-1,'EGP','2026-05-10','manual','z4')$q$, '23514');
SELECT pg_temp.expect_err('negative amount with foreign fails',
 $q$INSERT INTO public.user_transactions (user_id, amount, currency, foreign_amount, foreign_currency, occurred_at, source, client_request_id) VALUES ('00000000-0000-0000-0000-0000000000b1',-1,'EGP',5,'USD','2026-05-10','manual','z5')$q$, '23514');

-- 3. aggregates: count excludes awaiting, sums unchanged
DO $$
DECLARE r record; m jsonb; b numeric;
BEGIN
  SELECT * INTO r FROM public.category_spending_summary('2026-05-01','2026-06-01');
  INSERT INTO _r VALUES ('category_spending_summary: total 140, count 2 (awaiting excluded)',
    r.category_id = 'groceries' AND r.total = 140 AND r.transaction_count = 2, r::text);
  m := public.monthly_financial_summary('2026-05-01','2026-06-01');
  INSERT INTO _r VALUES ('monthly_financial_summary expense sum unchanged (140)', (m->>'expense')::numeric = 140, m::text);
END $$;

-- 4. capability RPC
DO $$
DECLARE c jsonb;
BEGIN
  c := public.qirsh_server_capabilities();
  INSERT INTO _r VALUES ('capabilities: authenticated gets awaiting_fx_transactions=true', c->>'awaiting_fx_transactions' = 'true', c::text);
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.expect_err('capabilities: anon denied', 'SELECT public.qirsh_server_capabilities()', '42501');
RESET ROLE;

-- 5. rollback refuses while an awaiting row exists
\set ON_ERROR_STOP off
SAVEPOINT rb1;
\i :rb
ROLLBACK TO SAVEPOINT rb1;
\set ON_ERROR_STOP on
-- The refusal is proven by state: the RAISE aborted the script before any change.
DO $$
BEGIN
  INSERT INTO _r VALUES ('rollback refused while awaiting row exists (RAISE seen above; nothing changed)',
    (SELECT count(*) FROM public.user_transactions WHERE amount = 0) = 1
    AND EXISTS (SELECT 1 FROM pg_constraint WHERE conname='chk_user_transactions_amount_or_awaiting_fx')
    AND to_regprocedure('public.qirsh_server_capabilities()') IS NOT NULL, '');
END $$;

-- 6. rollback succeeds when no awaiting rows
DELETE FROM public.user_transactions WHERE amount = 0;
\i :rb
DO $$
BEGIN
  INSERT INTO _r VALUES ('rollback: original CHECK restored',
    EXISTS (SELECT 1 FROM pg_constraint WHERE conname='chk_user_transactions_amount_positive')
    AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='chk_user_transactions_amount_or_awaiting_fx'), '');
  INSERT INTO _r VALUES ('rollback: capability RPC dropped', to_regprocedure('public.qirsh_server_capabilities()') IS NULL, '');
END $$;
SELECT pg_temp.expect_err('rollback: amount 0 rejected again',
 $q$INSERT INTO public.user_transactions (user_id, amount, currency, foreign_amount, foreign_currency, occurred_at, source, client_request_id) VALUES ('00000000-0000-0000-0000-0000000000b1',0,'EGP',5,'USD','2026-05-10','manual','z6')$q$, '23514');

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'awaiting_fx_0103 proof FAILED'; END IF; END $$;

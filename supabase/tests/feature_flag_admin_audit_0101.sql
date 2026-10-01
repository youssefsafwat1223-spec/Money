-- SQL proof for deferred migration 0101 (feature_flag_admin_audit).
-- Run against a LOCAL throwaway Postgres ONLY. Everything is rolled back.
--
--   { echo 'BEGIN;'; sed '/^BEGIN;$/d;/^COMMIT;$/d' supabase/migrations/0101_feature_flag_admin_audit.sql;
--     cat supabase/tests/feature_flag_admin_audit_0101.sql; echo 'ROLLBACK;'; } \
--   | psql "$LOCAL_URL" -v ON_ERROR_STOP=1
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

INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-0000000000a1');
INSERT INTO public.feature_flags (key, value_type, value, rollout_percent, is_active)
VALUES ('t_bool','boolean','false',0,false),
       ('t_num','number','995',100,true),
       ('t_srv','boolean','false',0,false),
       ('ai_sender_mapping_auto','boolean','false',0,false);
ALTER TABLE public.feature_flags DISABLE TRIGGER trg_feature_flags_updated_at;
UPDATE public.feature_flags SET updated_at = '2026-01-01 00:00:00+00' WHERE key LIKE 't\_%' OR key='ai_sender_mapping_auto';
ALTER TABLE public.feature_flags ENABLE TRIGGER trg_feature_flags_updated_at;

-- 1. atomic apply + audit row per field + actor in audit + trigger bump
DO $$
DECLARE r jsonb; n int; ua timestamptz; ub uuid;
BEGIN
  r := public.admin_apply_feature_flag_changes(
    '00000000-0000-0000-0000-0000000000a1', 'enable for canary', '10000000-0000-0000-0000-000000000001',
    '[{"key":"t_bool","expected_updated_at":"2026-01-01T00:00:00+00:00","set":{"is_active":true,"rollout_percent":25,"value":"true"}},
      {"key":"t_num","expected_updated_at":"2026-01-01T00:00:00+00:00","set":{"value":"996","rollout_percent":100}}]');
  SELECT count(*) INTO n FROM feature_flag_admin_audit WHERE operation_id='10000000-0000-0000-0000-000000000001';
  INSERT INTO _r VALUES ('audit: one row per changed field (3 + 1; unchanged rollout skipped)', n = 4, n::text);
  SELECT updated_at INTO ua FROM feature_flags WHERE key='t_bool';
  SELECT actor_admin_id INTO ub FROM feature_flag_admin_audit WHERE flag_key='t_bool' ORDER BY created_at DESC LIMIT 1;
  INSERT INTO _r VALUES ('trigger bumped updated_at', ua > '2026-01-01', ua::text);
  INSERT INTO _r VALUES ('actor recorded in audit', ub = '00000000-0000-0000-0000-0000000000a1', ub::text);
  INSERT INTO _r VALUES ('result not replayed', (r->>'replayed')::boolean = false, r->>'replayed');
END $$;

-- 2. replay idempotency: same op id => prior result, no extra audit, no double write
DO $$
DECLARE r jsonb; n int;
BEGIN
  r := public.admin_apply_feature_flag_changes(
    '00000000-0000-0000-0000-0000000000a1', 'enable for canary', '10000000-0000-0000-0000-000000000001',
    '[{"key":"t_bool","expected_updated_at":"2026-01-01T00:00:00+00:00","set":{"is_active":true}}]');
  SELECT count(*) INTO n FROM feature_flag_admin_audit WHERE operation_id='10000000-0000-0000-0000-000000000001';
  INSERT INTO _r VALUES ('replay returns prior result, no double audit', (r->>'replayed')::boolean AND n = 4, n::text);
END $$;

-- 3. stale expected_updated_at raises and writes NOTHING (incl. the valid sibling change)
SELECT pg_temp.expect_err('stale => P0409',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','stale attempt','10000000-0000-0000-0000-000000000002',
     '[{"key":"t_srv","expected_updated_at":"2026-01-01T00:00:00+00:00","set":{"value":"true"}},
       {"key":"t_bool","expected_updated_at":"2026-01-01T00:00:00+00:00","set":{"rollout_percent":50}}]')$q$, 'P0409');
INSERT INTO _r SELECT 'stale: nothing written (atomic)',
  (SELECT value FROM feature_flags WHERE key='t_srv') = 'false'
  AND NOT EXISTS (SELECT 1 FROM feature_flag_admin_audit WHERE operation_id='10000000-0000-0000-0000-000000000002'), '';

-- 4. validation
SELECT pg_temp.expect_err('rollout 150 rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','bad rollout','10000000-0000-0000-0000-000000000003',
     format('[{"key":"t_srv","expected_updated_at":"%s","set":{"rollout_percent":150}}]', (SELECT updated_at FROM feature_flags WHERE key='t_srv'))::jsonb)$q$, 'P0422');
SELECT pg_temp.expect_err('boolean flag with value banana rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','bad value','10000000-0000-0000-0000-000000000004',
     format('[{"key":"t_srv","expected_updated_at":"%s","set":{"value":"banana"}}]', (SELECT updated_at FROM feature_flags WHERE key='t_srv'))::jsonb)$q$, 'P0422');
SELECT pg_temp.expect_err('bad country code rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','bad country','10000000-0000-0000-0000-000000000005',
     format('[{"key":"t_bool","expected_updated_at":"%s","set":{"target_countries":["eg"]}}]', (SELECT updated_at FROM feature_flags WHERE key='t_bool'))::jsonb)$q$, 'P0422');
SELECT pg_temp.expect_err('number flag with non-number rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','bad number','10000000-0000-0000-0000-000000000006',
     format('[{"key":"t_num","expected_updated_at":"%s","set":{"value":"abc"}}]', (SELECT updated_at FROM feature_flags WHERE key='t_num'))::jsonb)$q$, 'P0422');
SELECT pg_temp.expect_err('server-read partial rollout rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','partial server','10000000-0000-0000-0000-000000000007',
     format('[{"key":"t_srv","server_read":true,"expected_updated_at":"%s","set":{"is_active":true,"value":"true","rollout_percent":50}}]', (SELECT updated_at FROM feature_flags WHERE key='t_srv'))::jsonb)$q$, 'P0422');
SELECT pg_temp.expect_err('server-read activation with stored rollout 0 rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','arm server','10000000-0000-0000-0000-000000000008',
     format('[{"key":"t_srv","server_read":true,"expected_updated_at":"%s","set":{"is_active":true,"value":"true"}}]', (SELECT updated_at FROM feature_flags WHERE key='t_srv'))::jsonb)$q$, 'P0422');
SELECT pg_temp.expect_err('short reason rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','ab','10000000-0000-0000-0000-000000000009','[{"key":"t_srv"}]')$q$, 'P0422');

-- server-read full rollout is accepted
DO $$
BEGIN
  PERFORM public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','arm server ok','10000000-0000-0000-0000-00000000000a',
     format('[{"key":"t_srv","server_read":true,"expected_updated_at":"%s","set":{"is_active":true,"value":"true","rollout_percent":100}}]',
            (SELECT updated_at FROM feature_flags WHERE key='t_srv'))::jsonb);
  INSERT INTO _r VALUES ('server-read full rollout accepted', true, '');
END $$;

-- 5. ai_sender_mapping_auto dependency: blocked w/o column, allowed once column exists
SELECT pg_temp.expect_err('ai_sender_mapping_auto blocked without accepted_by',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','arm ai map','10000000-0000-0000-0000-00000000000b',
     format('[{"key":"ai_sender_mapping_auto","expected_updated_at":"%s","set":{"is_active":true,"value":"true","rollout_percent":100}}]',
            (SELECT updated_at FROM feature_flags WHERE key='ai_sender_mapping_auto'))::jsonb)$q$, 'P0422');
ALTER TABLE public.sender_bank_mappings ADD COLUMN IF NOT EXISTS accepted_by text NULL;
DO $$
BEGIN
  PERFORM public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','arm ai map ok','10000000-0000-0000-0000-00000000000c',
     format('[{"key":"ai_sender_mapping_auto","expected_updated_at":"%s","set":{"is_active":true,"value":"true","rollout_percent":100}}]',
            (SELECT updated_at FROM feature_flags WHERE key='ai_sender_mapping_auto'))::jsonb);
  INSERT INTO _r VALUES ('ai_sender_mapping_auto allowed once column exists', true, '');
END $$;

-- 5b. enable_proof_autocommit: arming hard-blocked; off / description allowed
INSERT INTO public.feature_flags (key, value_type, value, rollout_percent, is_active)
VALUES ('enable_proof_autocommit','boolean','false',0,false);
SELECT pg_temp.expect_err('arming enable_proof_autocommit blocked',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','arm proof','10000000-0000-0000-0000-0000000000b1',
     format('[{"key":"enable_proof_autocommit","expected_updated_at":"%s","set":{"is_active":true,"value":"true","rollout_percent":100}}]',
            (SELECT updated_at FROM feature_flags WHERE key='enable_proof_autocommit'))::jsonb)$q$, 'P0422');
INSERT INTO _r SELECT 'blocked arm wrote nothing', is_active = false, '' FROM feature_flags WHERE key='enable_proof_autocommit';
DO $$
BEGIN
  PERFORM public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','describe proof','10000000-0000-0000-0000-0000000000b2',
     format('[{"key":"enable_proof_autocommit","expected_updated_at":"%s","set":{"description":"not armed"}}]',
            (SELECT updated_at FROM feature_flags WHERE key='enable_proof_autocommit'))::jsonb);
  INSERT INTO _r VALUES ('proof description edit allowed', true, '');
END $$;
-- simulate a legacy armed row, then turning it off must work
ALTER TABLE public.feature_flags DISABLE TRIGGER trg_feature_flags_updated_at;
UPDATE public.feature_flags SET is_active = true, value = 'true', rollout_percent = 100 WHERE key='enable_proof_autocommit';
ALTER TABLE public.feature_flags ENABLE TRIGGER trg_feature_flags_updated_at;
DO $$
BEGIN
  PERFORM public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','disarm proof','10000000-0000-0000-0000-0000000000b3',
     format('[{"key":"enable_proof_autocommit","expected_updated_at":"%s","set":{"is_active":false}}]',
            (SELECT updated_at FROM feature_flags WHERE key='enable_proof_autocommit'))::jsonb);
  INSERT INTO _r VALUES ('turning proof autocommit OFF allowed', true, '');
END $$;
INSERT INTO _r SELECT 'feature_flags has no updated_by column',
  NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='feature_flags' AND column_name='updated_by'), '';

-- 6. create-inactive row
DO $$
DECLARE a record;
BEGIN
  PERFORM public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','create missing row','10000000-0000-0000-0000-00000000000d',
    '[{"key":"t_created","create":true,"value_type":"boolean"}]');
  SELECT * INTO a FROM feature_flags WHERE key='t_created';
  INSERT INTO _r VALUES ('create makes inactive rollout-0 row', a.is_active = false AND a.rollout_percent = 0 AND a.value='false', '');
END $$;
SELECT pg_temp.expect_err('create active rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','create active','10000000-0000-0000-0000-00000000000e',
     '[{"key":"t_created2","create":true,"value_type":"boolean","set":{"is_active":true}}]')$q$, 'P0422');
SELECT pg_temp.expect_err('create existing rejected',
  $q$SELECT public.admin_apply_feature_flag_changes('00000000-0000-0000-0000-0000000000a1','create dup','10000000-0000-0000-0000-00000000000f',
     '[{"key":"t_created","create":true,"value_type":"boolean"}]')$q$, 'P0409');

-- 7. audit is append-only
SELECT pg_temp.expect_err('audit UPDATE blocked', $q$UPDATE feature_flag_admin_audit SET reason='tampered ok'$q$, 'P0403');
SELECT pg_temp.expect_err('audit DELETE blocked', $q$DELETE FROM feature_flag_admin_audit$q$, 'P0403');
SELECT pg_temp.expect_err('audit TRUNCATE blocked', $q$TRUNCATE feature_flag_admin_audit$q$, 'P0403');

-- 8. privileges: anon / authenticated cannot read audit or execute the RPC; service_role can
SET LOCAL ROLE anon;
SELECT pg_temp.expect_err('anon cannot SELECT audit', $q$SELECT * FROM public.feature_flag_admin_audit$q$, '42501');
SELECT pg_temp.expect_err('anon cannot EXECUTE rpc',
  $q$SELECT public.admin_apply_feature_flag_changes(NULL,'xxxx',gen_random_uuid(),'[]')$q$, '42501');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_err('authenticated cannot SELECT audit', $q$SELECT * FROM public.feature_flag_admin_audit$q$, '42501');
SELECT pg_temp.expect_err('authenticated cannot EXECUTE rpc',
  $q$SELECT public.admin_apply_feature_flag_changes(NULL,'xxxx',gen_random_uuid(),'[]')$q$, '42501');
SELECT pg_temp.expect_err('authenticated cannot EXECUTE admin_can_change_flag',
  $q$SELECT public.admin_can_change_flag(gen_random_uuid(),'k')$q$, '42501');
RESET ROLE;
INSERT INTO _r SELECT 'service_role can EXECUTE rpc',
  has_function_privilege('service_role','public.admin_apply_feature_flag_changes(uuid,text,uuid,jsonb)','EXECUTE'), '';
INSERT INTO _r SELECT 'RLS enabled on audit', relrowsecurity, '' FROM pg_class WHERE oid = 'public.feature_flag_admin_audit'::regclass;

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM _r ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;

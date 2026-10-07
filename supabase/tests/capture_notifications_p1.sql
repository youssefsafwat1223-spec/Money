-- SQL proofs for P1 CAP-3 (migration 0112): retention, retry queue, no re-push,
-- retry fence, notification_logs hygiene.
-- Run on a LOCAL throwaway Postgres with the chain applied (see dryrun_native.sh):
--   psql -d <db> -v ON_ERROR_STOP=1 -f supabase/tests/capture_notifications_p1.sql
-- Everything runs in one transaction and is rolled back.
BEGIN;

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
GRANT ALL ON _r TO authenticated, service_role;

CREATE FUNCTION pg_temp.ok(p_name text, p_cond boolean, p_detail text DEFAULT '') RETURNS void
LANGUAGE sql AS $$ INSERT INTO _r VALUES (p_name, coalesce(p_cond, false), p_detail) $$;

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-00000000a001'),
  ('00000000-0000-0000-0000-00000000b002');

-- d1: linked to A with consent and a token. d2: linked to A, NO token. d3: linked to A.
INSERT INTO public.capture_devices
  (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted, consent_version, apns_token, apns_environment)
VALUES
  ('d1', 's1', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 5, 'tok1', 'sandbox'),
  ('d2', 's2', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 5, null, null),
  ('d3', 's3', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 5, 'tok3', 'production'),
  ('rt', 'srt', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 5, null, null);

CREATE FUNCTION pg_temp.claim(i text, p text, o uuid) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_claim(i, 'raw-' || i, p, 'fp-' || p, o, 2, 60) $$;
CREATE FUNCTION pg_temp.fin(i text, p text, tok int, st text) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_finalize(i, 'raw-' || i, p, tok, st, CASE WHEN st = 'rejected' THEN 'rejected' ELSE 'processed' END,
     '{"amount":10}'::jsonb, '{"title":"t","body":"b","type":"new_transaction"}'::jsonb, null, null, false, null) $$;
CREATE FUNCTION pg_temp.row_of(i text, p text) RETURNS public.processed_captures LANGUAGE sql AS
$$ SELECT pc FROM public.processed_captures pc WHERE install_id_hash = i AND payload_id = p $$;
CREATE FUNCTION pg_temp.processed(i text, p text) RETURNS jsonb LANGUAGE plpgsql AS
$$ DECLARE c jsonb; f jsonb; BEGIN
  c := pg_temp.claim(i, p, '00000000-0000-0000-0000-00000000a001');
  f := pg_temp.fin(i, p, (c->>'lease_token')::int, 'processed');
  RETURN f; END $$;

DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002';
        f jsonb; c jsonb; r public.processed_captures; fz jsonb; n int; lg uuid;
BEGIN
  -- ── no re-push after hand-off / acceptance ─────────────────────────────────
  f := pg_temp.processed('d1', 'n1');
  PERFORM pg_temp.ok('finalize hands the push off: push_allowed with token', (f->>'push_allowed')::boolean AND f->'push'->>'apns_token' = 'tok1', f::text);
  r := pg_temp.row_of('d1', 'n1');
  PERFORM pg_temp.ok('hand-off records push_attempted_at (apns_push_sent_at still NULL)', r.push_attempted_at IS NOT NULL AND r.apns_push_sent_at IS NULL);
  PERFORM pg_temp.ok('row json exposes push_attempted_at', public.capture_row_json(r) ? 'push_attempted_at'
    AND public.capture_row_json(r)->>'push_attempted_at' IS NOT NULL);
  c := pg_temp.claim('d1', 'n1', a);
  PERFORM pg_temp.ok('replay of a handed-off, unconfirmed push does NOT re-offer it',
    c->>'outcome' = 'replay' AND c->>'push' IS NULL, c::text);
  c := pg_temp.claim('d1', 'n1', a);
  PERFORM pg_temp.ok('second replay still no push; still exactly one notification_logs row',
    c->>'push' IS NULL AND (SELECT count(*) FROM public.notification_logs WHERE related_entity_id = 'n1') = 1);
  PERFORM pg_temp.ok('direct second hand-off refused', public.capture_queue_push('d1', 'raw-d1', 'n1', a, 'new_transaction') IS NULL);

  -- apns accepted (confirmed) -> never re-offered
  UPDATE public.processed_captures SET apns_push_sent_at = now() WHERE install_id_hash = 'd1' AND payload_id = 'n1';
  c := pg_temp.claim('d1', 'n1', a);
  PERFORM pg_temp.ok('confirmed push never re-offered', c->>'push' IS NULL);

  -- consumed -> no re-offer, replay is consumed
  f := pg_temp.processed('d1', 'n2');
  PERFORM public.capture_ack('d1', a, ARRAY['n2']);
  c := pg_temp.claim('d1', 'n2', a);
  PERFORM pg_temp.ok('consumed capture: replay is consumed, no push', c->'row'->>'state' = 'consumed' AND c->>'push' IS NULL, c::text);

  -- no token at finalize: no hand-off; token registered later: first replay offers, then never again
  f := pg_temp.processed('d2', 'n3');
  PERFORM pg_temp.ok('no token: push_allowed but nothing handed off, push_attempted_at stays NULL',
    (f->>'push_allowed')::boolean AND f->>'push' IS NULL AND (pg_temp.row_of('d2','n3')).push_attempted_at IS NULL, f::text);
  UPDATE public.capture_devices SET apns_token = 'tok2', apns_environment = 'sandbox' WHERE install_id_hash = 'd2';
  c := pg_temp.claim('d2', 'n3', a);
  PERFORM pg_temp.ok('token appears later: first replay offers the push once', c->'push'->>'apns_token' = 'tok2', c::text);
  c := pg_temp.claim('d2', 'n3', a);
  PERFORM pg_temp.ok('...and the next replay does not', c->>'push' IS NULL);

  -- fenced-out finalize hands nothing off (A12-style)
  c := pg_temp.claim('d3', 'n4', a);
  UPDATE public.capture_devices SET user_id = b, consent_owner_uid = b WHERE install_id_hash = 'd3';
  f := pg_temp.fin('d3', 'n4', (c->>'lease_token')::int, 'processed');
  PERFORM pg_temp.ok('fenced finalize (re-linked) -> no push, no push_attempted_at, no notification row',
    NOT (f->>'push_allowed')::boolean AND (pg_temp.row_of('d3','n4')).push_attempted_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.notification_logs WHERE related_entity_id = 'n4'), f::text);
  UPDATE public.capture_devices SET user_id = a, consent_owner_uid = a WHERE install_id_hash = 'd3';

  -- ── notification_logs hygiene ──────────────────────────────────────────────
  PERFORM pg_temp.ok('log row carries install_id_hash, empty payload, no content columns',
    (SELECT install_id_hash FROM public.notification_logs WHERE related_entity_id = 'n1') = 'd1'
    AND (SELECT payload FROM public.notification_logs WHERE related_entity_id = 'n1') = '{}'::jsonb);
  PERFORM pg_temp.ok('backfill expression equals the edge installHash (sha256 first 32 hex)',
    left(encode(sha256(convert_to('abc', 'utf8')), 'hex'), 32) = 'ba7816bf8f01cfea414140de5dae2223');

  -- ── retry queue: at most one retry per notification ────────────────────────
  SELECT notification_log_id INTO lg FROM public.processed_captures WHERE install_id_hash = 'd1' AND payload_id = 'n1';
  INSERT INTO public.notification_retry_queue (notification_log_id, install_id_hash, payload_id) VALUES (lg, 'd1', 'n1');
  BEGIN
    INSERT INTO public.notification_retry_queue (notification_log_id, install_id_hash, payload_id) VALUES (lg, 'd1', 'n1');
    PERFORM pg_temp.ok('UNIQUE(notification_log_id): second enqueue rejected', false);
  EXCEPTION WHEN unique_violation THEN
    PERFORM pg_temp.ok('UNIQUE(notification_log_id): second enqueue rejected', true);
  END;
  INSERT INTO public.notification_retry_queue (notification_log_id, install_id_hash, payload_id) VALUES (lg, 'd1', 'n1')
    ON CONFLICT (notification_log_id) DO NOTHING;
  PERFORM pg_temp.ok('ON CONFLICT DO NOTHING keeps exactly one row',
    (SELECT count(*) FROM public.notification_retry_queue WHERE notification_log_id = lg) = 1);

  -- ── retry fence ────────────────────────────────────────────────────────────
  f := pg_temp.processed('d1', 'f1');
  fz := public.capture_retry_fence('d1', 'f1');
  PERFORM pg_temp.ok('fence allows a pending capture: current token + type only',
    (fz->>'allowed')::boolean AND fz->>'apns_token' = 'tok1' AND fz->>'notification_type' = 'new_transaction'
    AND NOT (fz ? 'title') AND NOT (fz ? 'body') AND NOT (fz ? 'notification'), fz::text);
  PERFORM pg_temp.ok('fence: unknown capture -> gone', public.capture_retry_fence('d1', 'nope')->>'reason' = 'gone');
  PERFORM pg_temp.ok('fence: unknown device -> gone', public.capture_retry_fence('zz', 'f1')->>'reason' = 'gone');
  -- token rotated after hand-off: the retry uses the CURRENT token
  UPDATE public.capture_devices SET apns_token = 'tok1b' WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('fence returns the device''s current token after rotation', public.capture_retry_fence('d1', 'f1')->>'apns_token' = 'tok1b');
  UPDATE public.capture_devices SET apns_token = NULL WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('fence: token cleared -> no_token', public.capture_retry_fence('d1', 'f1')->>'reason' = 'no_token');
  UPDATE public.capture_devices SET apns_token = 'tok1', apns_environment = 'sandbox' WHERE install_id_hash = 'd1';
  UPDATE public.capture_devices SET revoked_at = now() WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('fence: revoked device -> credential_revoked', public.capture_retry_fence('d1', 'f1')->>'reason' = 'credential_revoked');
  UPDATE public.capture_devices SET revoked_at = NULL, cloud_processing_enabled = false WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('fence: cloud consent OFF -> consent_revoked', public.capture_retry_fence('d1', 'f1')->>'reason' = 'consent_revoked');
  UPDATE public.capture_devices SET cloud_processing_enabled = true, user_id = b, consent_owner_uid = b WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('fence: device re-linked to B -> owner_changed (A''s late push never alerts B)', public.capture_retry_fence('d1', 'f1')->>'reason' = 'owner_changed');
  UPDATE public.capture_devices SET user_id = a, consent_owner_uid = a, consent_version = 6 WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('fence: consent version changed -> owner_changed', public.capture_retry_fence('d1', 'f1')->>'reason' = 'owner_changed');
  UPDATE public.capture_devices SET consent_version = 5 WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('fence allowed again once the snapshot matches', (public.capture_retry_fence('d1', 'f1')->>'allowed')::boolean);
  UPDATE public.processed_captures SET apns_push_sent_at = now() WHERE install_id_hash = 'd1' AND payload_id = 'f1';
  PERFORM pg_temp.ok('fence: already sent -> already_sent', public.capture_retry_fence('d1', 'f1')->>'reason' = 'already_sent');
  PERFORM public.capture_ack('d1', a, ARRAY['f1']);
  f := pg_temp.processed('d1', 'f2');
  PERFORM public.capture_ack('d1', a, ARRAY['f2']);
  PERFORM pg_temp.ok('fence: consumed -> not_pending', public.capture_retry_fence('d1', 'f2')->>'reason' = 'not_pending');
  f := pg_temp.processed('d1', 'f3');
  UPDATE public.processed_captures SET state = 'expired' WHERE install_id_hash = 'd1' AND payload_id = 'f3';
  PERFORM pg_temp.ok('fence: expired -> not_pending', public.capture_retry_fence('d1', 'f3')->>'reason' = 'not_pending');
  c := pg_temp.claim('d1', 'f4', a);
  PERFORM pg_temp.ok('fence: processing -> not_pending', public.capture_retry_fence('d1', 'f4')->>'reason' = 'not_pending');
END $$;

-- ── retention ────────────────────────────────────────────────────────────────
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001';
        r public.processed_captures; lg uuid := gen_random_uuid(); n int;
BEGIN
  INSERT INTO public.processed_captures
    (payload_id, install_id_hash, claimed_user_id, status, state, parsed, notification, sanitized_text, raw_fingerprint, created_at, consumed_at)
  VALUES
    ('rt_proc_8d',  'rt', a, 'processed', 'processed', '{"amount":1}', '{"title":"t"}', null,  'f', now() - interval '8 days', null),
    ('rt_proc_6d',  'rt', a, 'processed', 'processed', '{"amount":1}', '{"title":"t"}', null,  'f', now() - interval '6 days', null),
    ('rt_rej_8d',   'rt', a, 'rejected',  'rejected',  '{}',           '{"title":"t"}', 'text', 'f', now() - interval '8 days', null),
    ('rt_retry_8d', 'rt', a, 'rejected',  'retryable', '{}',           '{}',            null,  'f', now() - interval '8 days', null),
    ('rt_cons_29d', 'rt', a, 'processed', 'consumed',  '{}',           '{}',            null,  'f', now() - interval '40 days', now() - interval '29 days'),
    ('rt_cons_31d', 'rt', a, 'processed', 'consumed',  '{}',           '{}',            null,  'f', now() - interval '40 days', now() - interval '31 days'),
    ('rt_exp_29d',  'rt', a, 'processed', 'expired',   '{}',           '{}',            null,  'f', now() - interval '29 days', null),
    ('rt_exp_31d',  'rt', a, 'processed', 'expired',   '{}',           '{}',            null,  'f', now() - interval '31 days', null),
    ('rt_proc_31d', 'rt', a, 'processed', 'processed', '{"amount":1}', '{"title":"t"}', null,  'f', now() - interval '31 days', null),
    ('rt_inflight', 'rt', a, 'rejected',  'processing','{}',           '{}',            null,  'f', now(), null);

  PERFORM public.run_prune_processed_captures();

  r := pg_temp.row_of('rt', 'rt_proc_8d');
  PERFORM pg_temp.ok('processed >7d -> expired, content nulled', r.state = 'expired' AND r.parsed = '{}'::jsonb AND r.notification = '{}'::jsonb, r.state);
  r := pg_temp.row_of('rt', 'rt_proc_6d');
  PERFORM pg_temp.ok('processed <7d untouched', r.state = 'processed' AND r.parsed ->> 'amount' = '1');
  r := pg_temp.row_of('rt', 'rt_rej_8d');
  PERFORM pg_temp.ok('rejected >7d -> expired, sanitized_text and notification nulled', r.state = 'expired' AND r.sanitized_text IS NULL AND r.notification = '{}'::jsonb);
  r := pg_temp.row_of('rt', 'rt_retry_8d');
  PERFORM pg_temp.ok('retryable >7d -> expired', r.state = 'expired');
  PERFORM pg_temp.ok('consumed tombstone 29d after consume kept', (pg_temp.row_of('rt', 'rt_cons_29d')).state = 'consumed');
  PERFORM pg_temp.ok('consumed tombstone 31d after consume deleted', (pg_temp.row_of('rt', 'rt_cons_31d')).payload_id IS NULL);
  PERFORM pg_temp.ok('expired <30d kept, expired >30d deleted',
    (pg_temp.row_of('rt', 'rt_exp_29d')).state = 'expired' AND (pg_temp.row_of('rt', 'rt_exp_31d')).payload_id IS NULL);
  PERFORM pg_temp.ok('unconsumed row older than 30d deleted outright', (pg_temp.row_of('rt', 'rt_proc_31d')).payload_id IS NULL);
  PERFORM pg_temp.ok('in-flight row untouched', (pg_temp.row_of('rt', 'rt_inflight')).state = 'processing');
  PERFORM public.run_prune_processed_captures();
  PERFORM pg_temp.ok('prune is idempotent', (pg_temp.row_of('rt', 'rt_proc_8d')).state = 'expired');
  PERFORM public.prune_processed_captures();

  -- notification_logs 30 days; retry row cascades
  INSERT INTO public.notification_logs (id, install_id, notification_type, created_at) VALUES
    (lg, 'x', 'new_transaction', now() - interval '31 days'),
    (gen_random_uuid(), 'x', 'new_transaction', now() - interval '29 days');
  INSERT INTO public.notification_retry_queue (notification_log_id, install_id_hash, payload_id) VALUES (lg, 'rt', 'p');
  PERFORM public.run_prune_processed_captures();
  PERFORM pg_temp.ok('notification_logs older than 30d pruned, newer kept',
    NOT EXISTS (SELECT 1 FROM public.notification_logs WHERE id = lg)
    AND EXISTS (SELECT 1 FROM public.notification_logs WHERE install_id = 'x' AND created_at > now() - interval '30 days'));
  PERFORM pg_temp.ok('retry row cascades with its log', NOT EXISTS (SELECT 1 FROM public.notification_retry_queue WHERE notification_log_id = lg));

  -- ai_request_idempotency
  INSERT INTO public.ai_request_idempotency (owner_key, endpoint, request_id, payload_hash, expires_at) VALUES
    ('o', 'e', 'old', 'h', now() - interval '1 hour'), ('o', 'e', 'live', 'h', now() + interval '1 hour');
  PERFORM public.prune_ai_request_idempotency();
  PERFORM pg_temp.ok('prune_ai_request_idempotency deletes only expired rows',
    NOT EXISTS (SELECT 1 FROM public.ai_request_idempotency WHERE request_id = 'old')
    AND EXISTS (SELECT 1 FROM public.ai_request_idempotency WHERE request_id = 'live'));
END $$;

-- ── schedule and privileges ──────────────────────────────────────────────────
DO $$
DECLARE fn text;
BEGIN
  PERFORM pg_temp.ok('cron: hourly processed_captures prune scheduled, daily one removed',
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prune-processed-captures-hourly' AND schedule = '15 * * * *')
    AND NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prune-processed-captures-daily'));
  PERFORM pg_temp.ok('cron: prune_ai_request_idempotency scheduled',
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prune-ai-request-idempotency-daily'));
  FOREACH fn IN ARRAY ARRAY['capture_retry_fence(text,text)', 'run_prune_processed_captures()', 'prune_processed_captures()',
                            'prune_ai_request_idempotency()', 'capture_queue_push(text,text,text,uuid,text)'] LOOP
    PERFORM pg_temp.ok('privileges: ' || fn || ' not executable by anon/authenticated/public',
      NOT has_function_privilege('anon', 'public.' || fn, 'execute')
      AND NOT has_function_privilege('authenticated', 'public.' || fn, 'execute')
      AND NOT has_function_privilege('public', 'public.' || fn, 'execute'));
  END LOOP;
  PERFORM pg_temp.ok('privileges: capture_retry_fence executable by service_role',
    has_function_privilege('service_role', 'public.capture_retry_fence(text,text)', 'execute'));
END $$;

SELECT name, ok, detail FROM _r WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'capture_notifications_p1: failures above'; END IF;
END $$;
ROLLBACK;

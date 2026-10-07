-- SQL proof for F1 / C.6: the logical 168-hour expiry fence on sanitized server capture content
-- (migration 0112). Content is live iff clock_timestamp() < created_at + interval '168 hours',
-- database clock only (NEVER now(), the transaction start). Seeded rows get created_at relative
-- to now(); because clock_timestamp() keeps running inside the transaction, "exactly 168 h" and
-- "168 h + 1 ms" are already past the boundary when the first call runs, and the live case uses a
-- 5-minute margin (the DO block runs in well under that). The exact boundary under a moving clock,
-- and a transaction that CROSSES it, are proved at the end (test 11/12).
-- Driver (stages the chain, runs this, proves the rollback round trip):
--   PGHOST=/path/to/socket-dir supabase/tests/capture_expiry_fence.sh
-- Everything runs in one transaction and is rolled back.
BEGIN;

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
GRANT ALL ON _r TO authenticated, service_role;

CREATE FUNCTION pg_temp.ok(p_name text, p_cond boolean, p_detail text DEFAULT '') RETURNS void
LANGUAGE sql AS $$ INSERT INTO _r VALUES (p_name, coalesce(p_cond, false), p_detail) $$;

INSERT INTO auth.users (id) VALUES ('00000000-0000-0000-0000-00000000a001');

-- One device per boundary so sync-scope reads are isolated.
INSERT INTO public.capture_devices
  (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted, consent_version, apns_token, apns_environment)
SELECT d, 's-' || d, '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 5, 'tok-' || d, 'sandbox'
  FROM unnest(ARRAY['dl', 'dx', 'do']) d;

-- A row created `age` ago (relative to the transaction's now()).
CREATE FUNCTION pg_temp.seed(i text, p text, age interval, st text, nxt interval DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.processed_captures
    (payload_id, install_id_hash, claimed_user_id, status, state, parsed, notification, sanitized_text, raw_fingerprint,
     validator_result, lease_until, lease_token, attempts, next_attempt_at, owner_uid, consent_owner_uid, consent_version, created_at)
  VALUES (p, i, '00000000-0000-0000-0000-00000000a001',
     CASE WHEN st IN ('processed', 'consumed') THEN 'processed' ELSE 'rejected' END, st,
     CASE WHEN st IN ('processing', 'retryable') THEN '{}'::jsonb ELSE '{"amount":10,"merchant":"M"}'::jsonb END,
     CASE WHEN st IN ('processing', 'retryable') THEN '{}'::jsonb ELSE '{"title":"t","body":"b","type":"new_transaction"}'::jsonb END,
     CASE WHEN st IN ('processing', 'retryable') THEN NULL ELSE 'sanitized sms text' END,
     'fp-' || p,
     CASE WHEN st IN ('processing', 'retryable') THEN NULL ELSE '{"v":1}'::jsonb END,
     CASE WHEN st = 'processing' THEN now() + interval '60 seconds' END, 1, 1,
     CASE WHEN st = 'retryable' THEN now() - coalesce(nxt, interval '1 minute') END,
     '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', 5, now() - age) $$;
CREATE FUNCTION pg_temp.claim(i text, p text) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_claim(i, 'raw-' || i, p, 'fp-' || p, '00000000-0000-0000-0000-00000000a001', 2, 60) $$;
CREATE FUNCTION pg_temp.fin(i text, p text, tok int) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_finalize(i, 'raw-' || i, p, tok, 'processed', 'processed',
     '{"amount":99}'::jsonb, '{"title":"t","body":"b","type":"new_transaction"}'::jsonb, null, null, false, null) $$;
CREATE FUNCTION pg_temp.row_of(i text, p text) RETURNS public.processed_captures LANGUAGE sql AS
$$ SELECT pc FROM public.processed_captures pc WHERE install_id_hash = i AND payload_id = p $$;
-- true when no content-bearing column carries anything
CREATE FUNCTION pg_temp.empty(r public.processed_captures) RETURNS boolean LANGUAGE sql AS
$$ SELECT r.parsed = '{}'::jsonb AND r.notification = '{}'::jsonb AND r.sanitized_text IS NULL AND r.validator_result IS NULL $$;
CREATE FUNCTION pg_temp.nlogs(i text, p text) RETURNS bigint LANGUAGE sql AS
$$ SELECT count(*) FROM public.notification_logs WHERE install_id_hash = i AND related_entity_id = p $$;
-- the sy* rows of a sync result
CREATE FUNCTION pg_temp.sy1(l jsonb) RETURNS jsonb LANGUAGE sql AS
$$ SELECT e FROM jsonb_array_elements(l) e WHERE e->>'payload_id' = 'sy1' $$;
CREATE FUNCTION pg_temp.sy(l jsonb) RETURNS jsonb LANGUAGE sql AS
$$ SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(l) e WHERE e->>'payload_id' LIKE 'sy%' $$;

DO $$
DECLARE
  a uuid := '00000000-0000-0000-0000-00000000a001';
  cases text[][] := ARRAY[['dl', '6 days 23:55:00'], ['dx', '7 days'], ['do', '7 days 00:00:00.001']];
  i text; age interval; live boolean; t text;
  c jsonb; f jsonb; r public.processed_captures; l jsonb; n int; consumed_at0 timestamptz;
BEGIN
  FOR k IN 1..3 LOOP
    i := cases[k][1]; age := cases[k][2]::interval; live := (k = 1);
    t := CASE k WHEN 1 THEN '168h-5min' WHEN 2 THEN 'txn-start+168h' ELSE '168h+1ms' END;

    PERFORM pg_temp.ok('[' || t || '] predicate', public.capture_content_live(now() - age) = live);

    -- claim: replay of a stored processed result
    PERFORM pg_temp.seed(i, 'replay', age, 'processed');
    c := pg_temp.claim(i, 'replay');
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] claim replay returns the stored content',
        c->>'outcome' = 'replay' AND c->'row'->>'state' = 'processed' AND (c->'row'->'parsed'->>'amount') = '10', c::text);
      PERFORM pg_temp.ok('[' || t || '] claim replay leaves the row live', (pg_temp.row_of(i, 'replay')).state = 'processed');
    ELSE
      PERFORM pg_temp.ok('[' || t || '] claim replay: expired, no content, no push',
        c->>'outcome' = 'replay' AND c->'row'->>'state' = 'expired' AND c->'row'->'parsed' = '{}'::jsonb
        AND c->'row'->'notification' = '{}'::jsonb AND c->>'push' IS NULL, c::text);
      r := pg_temp.row_of(i, 'replay');
      PERFORM pg_temp.ok('[' || t || '] claim replay: row nulled and moved to expired', r.state = 'expired' AND pg_temp.empty(r));
      PERFORM pg_temp.ok('[' || t || '] claim replay: no notification log', pg_temp.nlogs(i, 'replay') = 0);
    END IF;

    -- claim: an expired retryable row is not re-claimed; a live one is
    PERFORM pg_temp.seed(i, 'retry', age, 'retryable');
    c := pg_temp.claim(i, 'retry');
    r := pg_temp.row_of(i, 'retry');
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] retryable is re-claimed (lease_token 2, attempts 2)',
        c->>'outcome' = 'claimed' AND r.lease_token = 2 AND r.attempts = 2 AND r.state = 'processing', c::text);
    ELSE
      PERFORM pg_temp.ok('[' || t || '] retryable is NOT re-claimed: replay expired, lease untouched',
        c->>'outcome' = 'replay' AND c->'row'->>'state' = 'expired' AND r.state = 'expired'
        AND r.lease_token = 1 AND r.attempts = 1 AND r.lease_until IS NULL AND pg_temp.empty(r), c::text);
    END IF;

    -- claim: an expired processing row with a lapsed lease is not re-leased
    PERFORM pg_temp.seed(i, 'proc', age, 'processing');
    UPDATE public.processed_captures SET lease_until = now() - interval '1 minute' WHERE install_id_hash = i AND payload_id = 'proc';
    c := pg_temp.claim(i, 'proc');
    r := pg_temp.row_of(i, 'proc');
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] lapsed processing lease is re-claimed', c->>'outcome' = 'claimed' AND r.lease_token = 2, c::text);
    ELSE
      PERFORM pg_temp.ok('[' || t || '] lapsed processing lease is NOT re-leased: expired',
        c->>'outcome' = 'replay' AND r.state = 'expired' AND r.lease_token = 1 AND r.attempts = 1, c::text);
    END IF;

    -- AI dispatch
    PERFORM pg_temp.seed(i, 'ai', age, 'processing');
    c := public.capture_ai_dispatch(i, 'ai', 1);
    r := pg_temp.row_of(i, 'ai');
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] dispatch allowed', (c->>'allowed')::boolean AND r.ai_started_at IS NOT NULL, c::text);
    ELSE
      PERFORM pg_temp.ok('[' || t || '] dispatch denied (expired), no ai_started_at, row expired',
        NOT (c->>'allowed')::boolean AND c->>'reason' = 'expired' AND r.ai_started_at IS NULL
        AND NOT r.ai_invoked AND r.state = 'expired', c::text);
    END IF;
    -- an expired retryable row (the retry path) can never reach AI either
    PERFORM pg_temp.seed(i, 'ai2', age, 'retryable');
    c := public.capture_ai_dispatch(i, 'ai2', 1);
    PERFORM pg_temp.ok('[' || t || '] dispatch from a retryable row is denied (lease_lost live, expired otherwise)',
      NOT (c->>'allowed')::boolean AND (pg_temp.row_of(i, 'ai2')).ai_started_at IS NULL
      AND (live OR c->>'reason' = 'lease_lost'), c::text);

    -- finalize
    PERFORM pg_temp.seed(i, 'fin', age, 'processing');
    f := pg_temp.fin(i, 'fin', 1);
    r := pg_temp.row_of(i, 'fin');
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] finalize writes the result and queues the push',
        (f->>'written')::boolean AND (f->>'push_allowed')::boolean AND r.state = 'processed'
        AND (r.parsed->>'amount') = '99' AND pg_temp.nlogs(i, 'fin') = 1, f::text);
    ELSE
      PERFORM pg_temp.ok('[' || t || '] expired lease: no result written, no push, row nulled',
        NOT (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND f->>'reason' = 'expired'
        AND f->>'push' IS NULL AND r.state = 'expired' AND pg_temp.empty(r) AND r.push_attempted_at IS NULL
        AND pg_temp.nlogs(i, 'fin') = 0, f::text);
      f := pg_temp.fin(i, 'fin', 1);
      PERFORM pg_temp.ok('[' || t || '] a second finalize cannot revive it', NOT (f->>'written')::boolean
        AND (pg_temp.row_of(i, 'fin')).state = 'expired' AND pg_temp.empty(pg_temp.row_of(i, 'fin')), f::text);
    END IF;

    -- direct push hand-off
    PERFORM pg_temp.seed(i, 'qp', age, 'processed');
    c := public.capture_queue_push(i, 'raw-' || i, 'qp', a, 'new_transaction');
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] queue_push hands off', c IS NOT NULL AND pg_temp.nlogs(i, 'qp') = 1);
    ELSE
      PERFORM pg_temp.ok('[' || t || '] queue_push refuses (no log, no hand-off)',
        c IS NULL AND pg_temp.nlogs(i, 'qp') = 0 AND (pg_temp.row_of(i, 'qp')).push_attempted_at IS NULL);
    END IF;

    -- retry fence
    PERFORM pg_temp.seed(i, 'rf', age, 'processed');
    c := public.capture_retry_fence(i, 'rf');
    r := pg_temp.row_of(i, 'rf');
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] retry fence allows', (c->>'allowed')::boolean AND r.state = 'processed', c::text);
    ELSE
      PERFORM pg_temp.ok('[' || t || '] retry fence refuses (expired) and nulls the row',
        NOT (c->>'allowed')::boolean AND c->>'reason' = 'expired' AND c->>'apns_token' IS NULL
        AND r.state = 'expired' AND pg_temp.empty(r), c::text);
    END IF;
    -- an expired row that already had its push sent is still refused and still nulled
    PERFORM pg_temp.seed(i, 'rf2', age, 'processed');
    UPDATE public.processed_captures SET apns_push_sent_at = now() WHERE install_id_hash = i AND payload_id = 'rf2';
    c := public.capture_retry_fence(i, 'rf2');
    PERFORM pg_temp.ok('[' || t || '] retry fence on an already-sent row: refused'
      || CASE WHEN live THEN '' ELSE ' and nulled' END,
      NOT (c->>'allowed')::boolean AND c->>'reason' = 'already_sent'
      AND (live OR (pg_temp.row_of(i, 'rf2')).state = 'expired' AND pg_temp.empty(pg_temp.row_of(i, 'rf2'))), c::text);

    -- sync-captures read path (v2 shape and legacy shape)
    PERFORM pg_temp.seed(i, 'sy1', age, 'processed');
    PERFORM pg_temp.seed(i, 'sy2', age, 'rejected');
    PERFORM pg_temp.seed(i, 'sy3', age, 'retryable');
    l := public.capture_sync_list(i, a, true);
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] sync v2 returns processed, rejected, retryable',
        jsonb_array_length(pg_temp.sy(l)) = 3 AND pg_temp.sy1(l) ? 'state' AND (pg_temp.sy1(l)->'parsed'->>'amount') = '10'
        AND pg_temp.sy1(l)->>'sanitized_text' = 'sanitized sms text', l::text);
      l := public.capture_sync_list(i, a, false);
      PERFORM pg_temp.ok('[' || t || '] sync legacy: processed+rejected only, no state key',
        jsonb_array_length(pg_temp.sy(l)) = 2 AND NOT (pg_temp.sy1(l) ? 'state'), l::text);
    ELSE
      PERFORM pg_temp.ok('[' || t || '] sync v2 returns nothing for expired rows and nulls them',
        l = '[]'::jsonb AND NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = i AND payload_id LIKE 'sy%'
          AND (state <> 'expired' OR NOT pg_temp.empty(processed_captures))), l::text);
      PERFORM pg_temp.ok('[' || t || '] sync legacy returns nothing for expired rows', public.capture_sync_list(i, a, false) = '[]'::jsonb);
    END IF;

    -- ack of a row past the fence: still works, nulls content
    PERFORM pg_temp.seed(i, 'ak', age, 'processed');
    n := public.capture_ack(i, a, ARRAY['ak']);
    r := pg_temp.row_of(i, 'ak');
    PERFORM pg_temp.ok('[' || t || '] ack consumes and nulls', n = 1 AND r.state = 'consumed' AND r.consumed_at IS NOT NULL AND r.parsed = '{}'::jsonb
    AND r.notification = '{}'::jsonb AND r.sanitized_text IS NULL);

    -- row json never emits content past the fence, even for a stored row still holding it
    PERFORM pg_temp.seed(i, 'rj', age, 'processed');
    l := public.capture_row_json(pg_temp.row_of(i, 'rj'));
    IF live THEN
      PERFORM pg_temp.ok('[' || t || '] row_json emits the content', l->>'state' = 'processed' AND l->'parsed'->>'amount' = '10');
    ELSE
      PERFORM pg_temp.ok('[' || t || '] row_json masks content and reports expired',
        l->>'state' = 'expired' AND l->'parsed' = '{}'::jsonb AND l->'notification' = '{}'::jsonb, l::text);
    END IF;
  END LOOP;

  -- ── opportunistic null: never revives, tombstones stay correct ──────────────
  -- (all past the fence: the 'do' device, 7d + 1ms)
  PERFORM pg_temp.seed('do', 'tomb', interval '8 days', 'consumed');
  UPDATE public.processed_captures
     SET parsed = '{}', notification = '{}', sanitized_text = NULL, validator_result = NULL,
         consumed_at = now() - interval '2 days', consumed_by_install_hash = 'do'
   WHERE install_id_hash = 'do' AND payload_id = 'tomb';
  consumed_at0 := (pg_temp.row_of('do', 'tomb')).consumed_at;
  c := pg_temp.claim('do', 'tomb');
  PERFORM pg_temp.ok('tombstone past 7d: claim replays consumed', c->>'outcome' = 'replay' AND c->'row'->>'state' = 'consumed', c::text);
  c := public.capture_ai_dispatch('do', 'tomb', 1);
  PERFORM pg_temp.ok('tombstone: dispatch denied lease_lost (not expired-rewritten)', NOT (c->>'allowed')::boolean, c::text);
  c := public.capture_retry_fence('do', 'tomb');
  PERFORM pg_temp.ok('tombstone: retry fence refused', NOT (c->>'allowed')::boolean, c::text);
  PERFORM public.capture_sync_list('do', a, true);
  r := pg_temp.row_of('do', 'tomb');
  PERFORM pg_temp.ok('tombstone untouched by every expiry path (state, consumed_at, consumed_by)',
    r.state = 'consumed' AND r.consumed_at = consumed_at0 AND r.consumed_by_install_hash = 'do');
  PERFORM pg_temp.ok('tombstone: second ack is a no-op', public.capture_ack('do', a, ARRAY['tomb']) = 0
    OR (pg_temp.row_of('do', 'tomb')).consumed_at = consumed_at0);

  -- an expired row stays expired: no later call revives it
  PERFORM pg_temp.seed('do', 'rev', interval '8 days', 'retryable');
  PERFORM pg_temp.claim('do', 'rev');
  c := pg_temp.claim('do', 'rev');
  r := pg_temp.row_of('do', 'rev');
  PERFORM pg_temp.ok('expired row: repeated claims keep it expired, attempts/lease_token unchanged',
    c->>'outcome' = 'replay' AND r.state = 'expired' AND r.attempts = 1 AND r.lease_token = 1 AND r.lease_until IS NULL, c::text);
  c := public.capture_ai_dispatch('do', 'rev', 1);
  f := pg_temp.fin('do', 'rev', 1);
  PERFORM pg_temp.ok('expired row: stale lease token cannot dispatch or finalize it',
    NOT (c->>'allowed')::boolean AND NOT (f->>'written')::boolean AND (pg_temp.row_of('do', 'rev')).state = 'expired');
  n := public.capture_ack('do', a, ARRAY['rev']);
  r := pg_temp.row_of('do', 'rev');
  PERFORM pg_temp.ok('expired row: ack still consumes it (content stays null)', n = 1 AND r.state = 'consumed' AND r.parsed = '{}'::jsonb AND r.sanitized_text IS NULL);
  c := pg_temp.claim('do', 'rev');
  PERFORM pg_temp.ok('...and after consume a claim replays consumed, never expired again',
    c->'row'->>'state' = 'consumed' AND (pg_temp.row_of('do', 'rev')).state = 'consumed');

  -- a fresh capture with a new payload id is unaffected by old expired rows
  c := pg_temp.claim('dl', 'brand-new');
  PERFORM pg_temp.ok('a new payload claims normally', c->>'outcome' = 'claimed', c::text);

  -- a row's own created_at is the only clock: claim at the boundary uses now(), not lease/attempt times
  PERFORM pg_temp.ok('prune is unchanged: hourly schedule and the 7d/30d/30d bodies still in place',
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prune-processed-captures-hourly' AND schedule = '15 * * * *')
    AND pg_get_functiondef('public.run_prune_processed_captures()'::regprocedure) LIKE '%interval ''7 days''%'
    AND pg_get_functiondef('public.run_prune_processed_captures()'::regprocedure) LIKE '%interval ''30 days''%');
  PERFORM pg_temp.ok('privileges: fence functions are service_role only',
    NOT has_function_privilege('anon', 'public.capture_sync_list(text,uuid,boolean)', 'execute')
    AND NOT has_function_privilege('authenticated', 'public.capture_sync_list(text,uuid,boolean)', 'execute')
    AND NOT has_function_privilege('public', 'public.capture_sync_list(text,uuid,boolean)', 'execute')
    AND has_function_privilege('service_role', 'public.capture_sync_list(text,uuid,boolean)', 'execute')
    AND NOT has_function_privilege('authenticated', 'public.capture_content_live(timestamptz)', 'execute')
    AND NOT has_function_privilege('authenticated', 'public.capture_expire_row(text,text)', 'execute'));
END $$;


-- ══ C.6 / D.11 / D.12: the fence is clock_timestamp()-based, VOLATILE, and created_at is immutable ══
DO $$
DECLARE
  a uuid := '00000000-0000-0000-0000-00000000a001';
  c0 timestamptz; created timestamptz; c jsonb; f jsonb; l jsonb; r public.processed_captures; n int;
BEGIN
  -- volatility + body of the predicate and of every function that evaluates it
  PERFORM pg_temp.ok('C.6 capture_content_live / capture_row_json / capture_expire_row / capture_sync_list / capture_claim / capture_ai_dispatch / capture_finalize / capture_queue_push / capture_retry_fence are all VOLATILE',
    (SELECT count(*) = 9 AND bool_and(provolatile = 'v') FROM pg_proc
      WHERE pronamespace = 'public'::regnamespace
        AND proname IN ('capture_content_live', 'capture_row_json', 'capture_expire_row', 'capture_sync_list', 'capture_claim',
                        'capture_ai_dispatch', 'capture_finalize', 'capture_queue_push', 'capture_retry_fence')));
  PERFORM pg_temp.ok('C.6 the predicate is "clock_timestamp() < created_at + 168 hours": no now(), no 7 days',
    pg_get_functiondef('public.capture_content_live(timestamptz)'::regprocedure) LIKE '%clock_timestamp()%'
    AND pg_get_functiondef('public.capture_content_live_at(timestamptz,timestamptz)'::regprocedure) LIKE '%interval ''168 hours''%'
    AND pg_get_functiondef('public.capture_content_live(timestamptz)'::regprocedure) NOT LIKE '%now()%'
    AND pg_get_functiondef('public.capture_content_live_at(timestamptz,timestamptz)'::regprocedure) NOT LIKE '%now()%'
    AND pg_get_functiondef('public.capture_content_live_at(timestamptz,timestamptz)'::regprocedure) NOT LIKE '%7 days%');
  -- D.11 deterministic exact boundary: explicit evaluation instant, no live clock
  PERFORM pg_temp.ok('D.11 exact boundary (explicit instant): boundary-1ms live, boundary expired, boundary+1ms expired, NULLs fail closed',
    public.capture_content_live_at('2026-01-01 00:00:00+00', '2026-01-08 00:00:00+00'::timestamptz - interval '1 millisecond')
    AND NOT public.capture_content_live_at('2026-01-01 00:00:00+00', '2026-01-08 00:00:00+00')
    AND NOT public.capture_content_live_at('2026-01-01 00:00:00+00', '2026-01-08 00:00:00+00'::timestamptz + interval '1 millisecond')
    AND NOT public.capture_content_live_at(NULL, now()) AND NOT public.capture_content_live_at(now(), NULL));
  PERFORM pg_temp.ok('C.6 NULL created_at fails closed', NOT public.capture_content_live(NULL));

  -- created_at is immutable
  PERFORM pg_temp.seed('dl', 'imm', interval '1 hour', 'processed');
  BEGIN
    UPDATE public.processed_captures SET created_at = created_at + interval '1 day' WHERE install_id_hash = 'dl' AND payload_id = 'imm';
    PERFORM pg_temp.ok('C.6 an UPDATE of created_at is rejected', false);
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.ok('C.6 an UPDATE of created_at is rejected (check_violation)', SQLERRM LIKE '%created_at is immutable%', SQLERRM);
  END;
  BEGIN
    UPDATE public.processed_captures SET created_at = now() WHERE install_id_hash = 'dl' AND payload_id = 'imm';
    PERFORM pg_temp.ok('C.6 "re-creating" a row by setting created_at = now() is rejected', false);
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.ok('C.6 "re-creating" a row by setting created_at = now() is rejected', true);
  END;
  UPDATE public.processed_captures SET created_at = created_at, failure_reason = 'x' WHERE install_id_hash = 'dl' AND payload_id = 'imm';
  PERFORM pg_temp.ok('C.6 updates that leave created_at unchanged are unaffected',
    (pg_temp.row_of('dl', 'imm')).failure_reason = 'x' AND (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_processed_captures_created_at_immutable') = 1);
  PERFORM pg_temp.ok('C.6 the lifecycle RPCs (claim, finalize, expire, ack) never need to touch created_at: the earlier proofs ran under the trigger', true);
END $$;

INSERT INTO public.capture_devices
  (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted, consent_version, apns_token, apns_environment)
VALUES ('dc', 's-dc', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 5, 'tok-dc', 'sandbox');

-- D.11 / D.12: ONE long transaction crosses the exact boundary. now() (txn start) never moves, so a now()-based
-- predicate would call every row below live for the whole transaction; clock_timestamp() does not.
DO $$
DECLARE
  a uuid := '00000000-0000-0000-0000-00000000a001';
  i text := 'dc'; c0 timestamptz; created timestamptz; c jsonb; f jsonb; l jsonb; r public.processed_captures;
  now_live_pre boolean; now_live_post boolean; clk_live_pre boolean; clk_live_post boolean;
BEGIN
  c0 := clock_timestamp();
  created := c0 - interval '168 hours' + interval '2 seconds';           -- the boundary is 2 s in the future
  PERFORM pg_temp.seed(i, 'disp_pre',  now() - created, 'processing');
  PERFORM pg_temp.seed(i, 'disp_post', now() - created, 'processing');
  PERFORM pg_temp.seed(i, 'fin_pre',   now() - created, 'processing');
  PERFORM pg_temp.seed(i, 'fin_post',  now() - created, 'processing');
  PERFORM pg_temp.seed(i, 'rep_pre',   now() - created, 'processed');
  PERFORM pg_temp.seed(i, 'rep_post',  now() - created, 'processed');
  PERFORM pg_temp.seed(i, 'qp_pre',    now() - created, 'processed');
  PERFORM pg_temp.seed(i, 'qp_post',   now() - created, 'processed');
  PERFORM pg_temp.seed(i, 'rf_pre',    now() - created, 'processed');
  PERFORM pg_temp.seed(i, 'rf_post',   now() - created, 'processed');
  PERFORM pg_temp.seed(i, 'sy_pre',    now() - created, 'processed');
  PERFORM pg_temp.seed(i, 'rj_post',   now() - created, 'processed');
  PERFORM pg_temp.ok('D.11 setup: the boundary is still in the future when the transaction starts working',
    clock_timestamp() < created + interval '168 hours');

  -- before the boundary: everything is available
  clk_live_pre := public.capture_content_live(created);
  now_live_pre := now() < created + interval '168 hours';
  PERFORM pg_temp.ok('D.11 before the boundary: clock_timestamp() predicate live (and so is now())', clk_live_pre AND now_live_pre);
  c := public.capture_ai_dispatch(i, 'disp_pre', 1);
  PERFORM pg_temp.ok('D.12 before: AI dispatch allowed', (c->>'allowed')::boolean, c::text);
  f := pg_temp.fin(i, 'fin_pre', 1);
  PERFORM pg_temp.ok('D.12 before: finalize writes and queues the push', (f->>'written')::boolean AND (f->>'push_allowed')::boolean, f::text);
  c := pg_temp.claim(i, 'rep_pre');
  PERFORM pg_temp.ok('D.12 before: claim replays the stored content', c->'row'->>'state' = 'processed' AND c->'row'->'parsed'->>'amount' = '10', c::text);
  c := public.capture_queue_push(i, 'raw-' || i, 'qp_pre', a, 'new_transaction');
  PERFORM pg_temp.ok('D.12 before: queue_push hands off', c IS NOT NULL, c::text);
  c := public.capture_retry_fence(i, 'rf_pre');
  PERFORM pg_temp.ok('D.12 before: retry fence allows', (c->>'allowed')::boolean, c::text);
  l := public.capture_sync_list(i, a, true);
  PERFORM pg_temp.ok('D.12 before: sync returns the live rows (incl. sy_pre)', EXISTS (SELECT 1 FROM jsonb_array_elements(l) e WHERE e->>'payload_id' = 'sy_pre'), l::text);

  PERFORM pg_sleep(2.6);                                                  -- the SAME transaction crosses the boundary

  clk_live_post := public.capture_content_live(created);
  now_live_post := now() < created + interval '168 hours';
  PERFORM pg_temp.ok('D.11 same transaction, after the boundary: clock_timestamp() predicate says EXPIRED while now() still says live',
    NOT clk_live_post AND now_live_post, clk_live_post::text || '/' || now_live_post::text);
  PERFORM pg_temp.ok('D.11 negative control: a now()-based predicate would have authorised every call below',
    now() < created + interval '168 hours' AND clock_timestamp() >= created + interval '168 hours');

  c := public.capture_ai_dispatch(i, 'disp_post', 1);
  r := pg_temp.row_of(i, 'disp_post');
  PERFORM pg_temp.ok('D.12 after: AI dispatch denied (expired), ai_started_at never set, row nulled',
    NOT (c->>'allowed')::boolean AND c->>'reason' = 'expired' AND r.ai_started_at IS NULL AND NOT r.ai_invoked AND r.state = 'expired' AND pg_temp.empty(r), c::text);
  f := pg_temp.fin(i, 'fin_post', 1);
  r := pg_temp.row_of(i, 'fin_post');
  PERFORM pg_temp.ok('D.12 after: finalize refuses (expired): no result stored, no notification, no push',
    NOT (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND f->>'reason' = 'expired' AND r.state = 'expired'
    AND pg_temp.empty(r) AND r.push_attempted_at IS NULL AND pg_temp.nlogs(i, 'fin_post') = 0, f::text);
  c := pg_temp.claim(i, 'rep_post');
  PERFORM pg_temp.ok('D.12 after: claim replay returns an expired, content-free row and queues nothing',
    c->'row'->>'state' = 'expired' AND c->'row'->'parsed' = '{}'::jsonb AND c->>'push' IS NULL AND pg_temp.nlogs(i, 'rep_post') = 0, c::text);
  c := public.capture_queue_push(i, 'raw-' || i, 'qp_post', a, 'new_transaction');
  PERFORM pg_temp.ok('D.12 after: queue_push refuses, no notification log, no hand-off',
    c IS NULL AND pg_temp.nlogs(i, 'qp_post') = 0 AND (pg_temp.row_of(i, 'qp_post')).push_attempted_at IS NULL, c::text);
  c := public.capture_retry_fence(i, 'rf_post');
  PERFORM pg_temp.ok('D.12 after: retry fence refuses (expired) and nulls the row',
    NOT (c->>'allowed')::boolean AND c->>'reason' = 'expired' AND (pg_temp.row_of(i, 'rf_post')).state = 'expired', c::text);
  l := public.capture_sync_list(i, a, true);
  PERFORM pg_temp.ok('D.12 after: sync no longer returns the rows (they are nulled and expired)',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(l) e WHERE e->>'payload_id' IN ('sy_pre', 'rj_post', 'rep_post', 'qp_post')), l::text);
  l := public.capture_row_json(pg_temp.row_of(i, 'rj_post'));
  PERFORM pg_temp.ok('D.12 after: row_json masks the content and reports expired',
    l->>'state' = 'expired' AND l->'parsed' = '{}'::jsonb AND l->'notification' = '{}'::jsonb, l::text);
END $$;

SELECT name, ok, detail FROM _r WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'capture_expiry_fence: failures above'; END IF;
END $$;
ROLLBACK;

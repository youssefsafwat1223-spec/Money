-- SQL proofs for P1 CAP-1/CAP-2 (migrations 0110, 0111, 0113).
-- Run on a LOCAL throwaway Postgres with the chain applied (see dryrun_native.sh):
--   psql -d <db> -v ON_ERROR_STOP=1 -f supabase/tests/capture_state_machine_p1.sql
-- Everything runs in one transaction and is rolled back.
--
-- TEST SETUP ONLY: two contracts owned by the WP-2 unit (0103 user_sync_state,
-- 0109 user_settings consent_version/consent_granted_at) are stubbed here; they
-- are never created by the CAP migrations.
--
-- Concurrency note: every RPC is one atomic transaction, so a "race" is one of
-- the two serial orders of its transactions. The A-tests below run the
-- interleavings explicitly; capture_concurrency_p1.sh runs real parallel sessions.
BEGIN;

CREATE TABLE IF NOT EXISTS public.user_sync_state (
  user_id uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  last_seq bigint NOT NULL DEFAULT 0,
  epoch uuid NOT NULL DEFAULT gen_random_uuid(),
  epoch_reason text NULL CHECK (epoch_reason IN ('initial','purge','reset','restore')),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_settings
  ADD COLUMN IF NOT EXISTS consent_version integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS consent_granted_at timestamptz NULL;

CREATE TEMP TABLE _r (name text, ok boolean, detail text);
GRANT ALL ON _r TO authenticated, service_role;

CREATE FUNCTION pg_temp.ok(p_name text, p_cond boolean, p_detail text DEFAULT '') RETURNS void
LANGUAGE sql AS $$ INSERT INTO _r VALUES (p_name, coalesce(p_cond, false), p_detail) $$;

-- Act as a JWT user for one statement block.
CREATE FUNCTION pg_temp.as_user(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
END $$;

INSERT INTO auth.users (id) VALUES
  ('00000000-0000-0000-0000-00000000a001'),
  ('00000000-0000-0000-0000-00000000b002');

-- Devices. d1 = v2 device linked to A with consent; d2 = legacy device linked to A.
INSERT INTO public.capture_devices
  (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted, consent_version, apns_token, apns_environment)
VALUES
  ('d1', 'sec1', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 5, 'tok1', 'sandbox'),
  ('d2', 'sec2', '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000a001', true, true, 1, 'tok2', 'sandbox'),
  ('d3', 'sec3', null, null, true, false, 0, null, null);
INSERT INTO public.user_settings (user_id, local_id, ai_consent_granted, cloud_processing_enabled)
VALUES ('00000000-0000-0000-0000-00000000a001', 'user_settings', true, true);

\set A '''00000000-0000-0000-0000-00000000a001'''
\set B '''00000000-0000-0000-0000-00000000b002'''

-- claim helper: (install, payload, fp, owner, contract). An ownerless (build-50) claim is judged by
-- the server's install owner history (H1); the client's received_at plays no part and is not a parameter.
CREATE FUNCTION pg_temp.claim(i text, p text, fp text, o uuid, c int) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_claim(i, 'raw-' || i, p, fp, o, c, 60) $$;
CREATE FUNCTION pg_temp.claim_r(i text, p text, fp text, o uuid, c int, gen bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_claim(i, 'raw-' || i, p, fp, o, c, 60, gen) $$;
CREATE FUNCTION pg_temp.fin(i text, p text, tok int, st text, content boolean DEFAULT true) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_finalize(i, 'raw-' || i, p, tok, st, CASE WHEN st = 'rejected' THEN 'rejected' ELSE 'processed' END,
     CASE WHEN content THEN '{"amount":10}'::jsonb ELSE '{}'::jsonb END,
     CASE WHEN content THEN '{"title":"t","body":"b","type":"new_transaction"}'::jsonb ELSE '{}'::jsonb END,
     null, null, false, null) $$;
CREATE FUNCTION pg_temp.row_of(i text, p text) RETURNS public.processed_captures LANGUAGE sql AS
$$ SELECT pc FROM public.processed_captures pc WHERE install_id_hash = i AND payload_id = p $$;

-- ── Claim table (§4.8) ───────────────────────────────────────────────────────
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002';
        c1 jsonb; c2 jsonb; c3 jsonb; c4 jsonb; r public.processed_captures; f jsonb; i int;
BEGIN
  -- T-S1 (serial order of the concurrent duplicate): one claim, second is in_progress.
  c1 := pg_temp.claim('d1', 'p1', 'fp1', a, 2);
  c2 := pg_temp.claim('d1', 'p1', 'fp1', a, 2);
  PERFORM pg_temp.ok('T-S1 first claim claimed, lease_token 1, attempts 1',
    c1->>'outcome' = 'claimed' AND (c1->>'lease_token')::int = 1 AND (c1->>'attempts')::int = 1, c1::text);
  PERFORM pg_temp.ok('T-S1 duplicate while lease unexpired -> in_progress', c2->>'outcome' = 'in_progress', c2::text);
  PERFORM pg_temp.ok('T-S1 exactly one row', (SELECT count(*) FROM public.processed_captures WHERE payload_id = 'p1') = 1);
  PERFORM pg_temp.ok('claim records claimed_user_id/consent_owner_uid/consent_version from the snapshot',
    (c1->>'claimed_user_id')::uuid = a AND (c1->>'consent_owner_uid')::uuid = a AND (c1->>'consent_version')::int = 5
    AND (pg_temp.row_of('d1','p1')).consent_version = 5);

  -- T-S3 fingerprint conflict
  c3 := pg_temp.claim('d1', 'p1', 'OTHER', a, 2);
  PERFORM pg_temp.ok('T-S3 same id different fingerprint -> id_conflict', c3->>'outcome' = 'id_conflict', c3::text);

  -- T-S6 owner mismatch: request owner != device user
  c3 := pg_temp.claim('d1', 'p9', 'fp9', b, 2);
  PERFORM pg_temp.ok('T-S6 v2 owner_uid != user_id -> denied capture_owner_mismatch',
    c3->>'outcome' = 'denied' AND c3->>'code' = 'capture_owner_mismatch', c3::text);
  c3 := pg_temp.claim('d1', 'p9', 'fp9', null, 2);
  PERFORM pg_temp.ok('T-S6 v2 without owner_uid -> capture_owner_mismatch', c3->>'code' = 'capture_owner_mismatch');
  c3 := pg_temp.claim('d3', 'p9', 'fp9', a, 2);
  PERFORM pg_temp.ok('T-S6 v2 on ownerless device -> capture_owner_mismatch', c3->>'code' = 'capture_owner_mismatch');
  PERFORM pg_temp.ok('T-S6 gate denial wrote no row', NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE payload_id = 'p9'));

  -- v2 consent_owner_uid != user_id (stale projection) -> mismatch
  UPDATE public.capture_devices SET consent_owner_uid = b WHERE install_id_hash = 'd1';
  c3 := pg_temp.claim('d1', 'p9', 'fp9', a, 2);
  PERFORM pg_temp.ok('gate: consent_owner_uid != user_id -> capture_owner_mismatch', c3->>'code' = 'capture_owner_mismatch');
  UPDATE public.capture_devices SET consent_owner_uid = a WHERE install_id_hash = 'd1';

  -- cloud off -> consent_required
  UPDATE public.capture_devices SET cloud_processing_enabled = false WHERE install_id_hash = 'd1';
  c3 := pg_temp.claim('d1', 'p9', 'fp9', a, 2);
  PERFORM pg_temp.ok('cloud OFF -> denied consent_required', c3->>'code' = 'consent_required');
  UPDATE public.capture_devices SET cloud_processing_enabled = true WHERE install_id_hash = 'd1';
  -- revoked
  UPDATE public.capture_devices SET revoked_at = now() WHERE install_id_hash = 'd1';
  c3 := pg_temp.claim('d1', 'p9', 'fp9', a, 2);
  PERFORM pg_temp.ok('revoked -> denied credential_revoked', c3->>'code' = 'credential_revoked');
  UPDATE public.capture_devices SET revoked_at = NULL WHERE install_id_hash = 'd1';

  -- Legacy gate: consent_owner_uid != user_id -> consent_required
  INSERT INTO public.capture_devices
    (install_id_hash, device_secret_hash, user_id, consent_owner_uid, cloud_processing_enabled, ai_consent_granted, consent_version)
  VALUES ('d2x', 'sec2x', a, NULL, true, true, 1);
  c3 := pg_temp.claim('d2x', 'lp0', 'f', null, 1);
  PERFORM pg_temp.ok('legacy: consent not owned by linked user -> consent_required', c3->>'code' = 'consent_required');
  -- H1: a guest install (user_id NULL) has no proven owner: an ownerless upload is refused, nothing stored
  c3 := pg_temp.claim('d3', 'g1', 'fg', null, 1);
  PERFORM pg_temp.ok('H1 legacy guest (user_id NULL): ownerless -> owner_conflict (ownerless_not_eligible), no row',
    c3->>'outcome' = 'owner_conflict' AND c3->>'reason' = 'ownerless_not_eligible'
    AND NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = 'd3'), c3::text);
  c3 := pg_temp.claim('d2', 'lp1', 'f1', null, 1);
  PERFORM pg_temp.ok('legacy linked, proven single owner: claimed_user_id stamped from snapshot',
    c3->>'outcome' = 'claimed' AND (c3->>'claimed_user_id')::uuid = a, c3::text);

  -- finalize processed, then replay (stored), notification row same tx
  f := pg_temp.fin('d1', 'p1', 1, 'processed');
  PERFORM pg_temp.ok('finalize: written, push_allowed, queued notification_logs row in same tx',
    (f->>'written')::boolean AND (f->>'push_allowed')::boolean AND f->'push'->>'apns_token' = 'tok1'
    AND (SELECT status FROM public.notification_logs WHERE id = (f->'push'->>'notification_log_id')::uuid) = 'queued', f::text);
  c4 := pg_temp.claim('d1', 'p1', 'fp1', a, 2);
  PERFORM pg_temp.ok('replay of processed row (state processed, content present)',
    c4->>'outcome' = 'replay' AND c4->'row'->>'state' = 'processed' AND c4->'row'->'parsed'->>'amount' = '10', c4::text);
  -- CAP-3 (0112): the hand-off at finalize is the one push attempt; a replay never re-offers it.
  PERFORM pg_temp.ok('replay does not re-offer a push that finalize already handed off',
    c4->>'push' IS NULL, c4::text);
  PERFORM pg_temp.ok('one notification row for p1', (SELECT count(*) FROM public.notification_logs WHERE related_entity_id = 'p1') = 1);

  -- T-S5: ACK never from processing, tombstone from processed; replay -> consumed
  c1 := pg_temp.claim('d1', 'pk', 'fpk', a, 2);
  PERFORM pg_temp.ok('ACK of a processing row consumes nothing', public.capture_ack('d1', a, ARRAY['pk']) = 0
    AND (pg_temp.row_of('d1','pk')).state = 'processing');
  PERFORM pg_temp.ok('ACK of a processed row by another user consumes nothing', public.capture_ack('d1', b, ARRAY['p1']) = 0);
  PERFORM pg_temp.ok('ACK of processed row consumes it', public.capture_ack('d1', a, ARRAY['p1']) = 1);
  r := pg_temp.row_of('d1', 'p1');
  PERFORM pg_temp.ok('T-S5 tombstone: consumed, content nulled, consumed_by recorded',
    r.state = 'consumed' AND r.parsed = '{}'::jsonb AND r.notification = '{}'::jsonb AND r.sanitized_text IS NULL
    AND r.consumed_at IS NOT NULL AND r.consumed_by_install_hash = 'd1');
  c4 := pg_temp.claim('d1', 'p1', 'fp1', a, 2);
  PERFORM pg_temp.ok('T-S5 replay after consume -> replay state consumed (no reprocess, no new row)',
    c4->>'outcome' = 'replay' AND c4->'row'->>'state' = 'consumed'
    AND (SELECT count(*) FROM public.processed_captures WHERE payload_id = 'p1') = 1, c4::text);

  -- expired replay
  UPDATE public.processed_captures SET state = 'expired', parsed = '{}', notification = '{}', sanitized_text = NULL WHERE payload_id = 'p1';
  c4 := pg_temp.claim('d1', 'p1', 'fp1', a, 2);
  PERFORM pg_temp.ok('replay of expired row', c4->'row'->>'state' = 'expired');

  -- T-S2: retryable up to 5 then rejected
  c1 := pg_temp.claim('d1', 'pr', 'fpr', a, 2);
  FOR i IN 1..5 LOOP
    f := pg_temp.fin('d1', 'pr', i, 'retryable', false);
    PERFORM pg_temp.ok('T-S2 attempt ' || i || ' finalized retryable, no content',
      (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND (pg_temp.row_of('d1','pr')).state = 'retryable', f::text);
    IF i = 1 THEN
      c4 := pg_temp.claim('d1', 'pr', 'fpr', a, 2);
      PERFORM pg_temp.ok('T-S2 retryable-not-due replays (no claim)', c4->>'outcome' = 'replay' AND c4->'row'->>'state' = 'retryable', c4::text);
    END IF;
    UPDATE public.processed_captures SET next_attempt_at = now() - interval '1 second' WHERE payload_id = 'pr';
    IF i < 5 THEN
      c4 := pg_temp.claim('d1', 'pr', 'fpr', a, 2);
      PERFORM pg_temp.ok('T-S2 re-claim ' || (i + 1) || ': lease_token and attempts incremented at claim',
        c4->>'outcome' = 'claimed' AND (c4->>'attempts')::int = i + 1 AND (c4->>'lease_token')::int = i + 1, c4::text);
    END IF;
  END LOOP;
  c4 := pg_temp.claim('d1', 'pr', 'fpr', a, 2);
  PERFORM pg_temp.ok('T-S2 5 retryable attempts -> rejected, no 6th claim',
    c4->>'outcome' = 'replay' AND c4->'row'->>'state' = 'rejected' AND c4->'row'->>'failure_reason' = 'attempts_exhausted', c4::text);

  -- Expired lease re-claim increments token + attempts
  c1 := pg_temp.claim('d1', 'pe', 'fpe', a, 2);
  UPDATE public.processed_captures SET lease_until = now() - interval '1 second' WHERE payload_id = 'pe';
  c4 := pg_temp.claim('d1', 'pe', 'fpe', a, 2);
  PERFORM pg_temp.ok('expired lease re-claim: lease_token 2, attempts 2',
    c4->>'outcome' = 'claimed' AND (c4->>'lease_token')::int = 2 AND (c4->>'attempts')::int = 2, c4::text);
END $$;

-- ── T-S6b: existing row claimed by A, device now linked to B -> owner_conflict ──
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002'; c jsonb; j jsonb;
BEGIN
  PERFORM pg_temp.claim('d1', 'po', 'fpo', a, 2);
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('d1', 'sec1', true, true, 1);
  RESET ROLE;
  c := pg_temp.claim('d1', 'po', 'fpo', b, 2);
  PERFORM pg_temp.ok('T-S6 existing row owned by A, caller B -> owner_conflict (v2)', c->>'outcome' = 'owner_conflict', c::text);
  -- restore A
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('d1', 'sec1', true, true, 6);
  RESET ROLE;
  c := pg_temp.claim('d1', 'po', 'fpo', a, 2);
  PERFORM pg_temp.ok('A re-linked: A claims own row again (still processing, in_progress)', c->>'outcome' = 'in_progress', c::text);
END $$;

-- ── Consent RPCs / A8 ────────────────────────────────────────────────────────
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002'; j jsonb; d public.capture_devices;
BEGIN
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('A8 setup: A linked at version 6', d.consent_owner_uid = a AND d.consent_version = 6 AND d.user_id = a, d::text);

  -- Wrong secret / anon cannot use JWT RPCs
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('d1', 'WRONG', true, true, 99);
  RESET ROLE;
  PERFORM pg_temp.ok('set_capture_consent with wrong device secret -> invalid_device_secret', j->>'error' = 'invalid_device_secret', j::text);

  -- Stale version ignored
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('d1', 'sec1', false, false, 6);
  RESET ROLE;
  PERFORM pg_temp.ok('set_capture_consent with a stale version still narrows consent (fail closed)',
    (j->>'applied')::boolean IS NOT TRUE AND (j->>'consent_version')::int = 6
    AND NOT (SELECT cloud_processing_enabled OR ai_consent_granted FROM public.capture_devices WHERE install_id_hash = 'd1'), j::text);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('d1', 'sec1', true, true, 5);
  RESET ROLE;
  PERFORM pg_temp.ok('set_capture_consent with a stale version never widens consent',
    NOT (SELECT cloud_processing_enabled OR ai_consent_granted FROM public.capture_devices WHERE install_id_hash = 'd1')
    AND (SELECT consent_version FROM public.capture_devices WHERE install_id_hash = 'd1') = 6, j::text);

  -- A8: B links the same install: projection replaced; A can no longer write consent
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('d1', 'sec1', true, false, 1);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('A8 owner change atomically replaces projection (user, owner, flags, version)',
    d.user_id = b AND d.consent_owner_uid = b AND d.cloud_processing_enabled AND NOT d.ai_consent_granted AND d.consent_version = 1, d::text);
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('d1', 'sec1', true, true, 50);
  RESET ROLE;
  PERFORM pg_temp.ok('A8 A cannot write B''s projection even with a higher version', j->>'error' = 'capture_owner_mismatch', j::text);
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('d1', 'sec1', true, true, 2);
  RESET ROLE;
  PERFORM pg_temp.ok('A8 B''s own version 2 applies (monotonic only within one owner)',
    (j->>'applied')::boolean AND (SELECT consent_version FROM public.capture_devices WHERE install_id_hash = 'd1') = 2, j::text);
  -- Same-owner relink with lower version keeps stored consent
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('d1', 'sec1', false, false, 1);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'd1';
  PERFORM pg_temp.ok('same-owner relink is authoritative: a fresh replica (lower version) clears a stale server TRUE',
    d.consent_version = 1 AND NOT d.ai_consent_granted AND NOT d.cloud_processing_enabled, d::text);

  -- restore A for later tests
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('d1', 'sec1', true, true, 10);
  RESET ROLE;

  -- anon / unauthenticated cannot execute
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.link_capture_device('d1', 'sec1', true, true, 99);
    RESET ROLE;
    PERFORM pg_temp.ok('anon cannot execute link_capture_device', false);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.ok('anon cannot execute link_capture_device', true);
  END;
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.capture_claim('d1', 'x', 'p', 'f', a, 2, 60);
    RESET ROLE;
    PERFORM pg_temp.ok('authenticated cannot execute capture_claim', false);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.ok('authenticated cannot execute capture_claim', true);
  END;

  -- T-S7 (SQL level): revoked device refused by the consent / link RPCs
  UPDATE public.capture_devices SET revoked_at = now() WHERE install_id_hash = 'd1';
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('d1', 'sec1', true, true, 11);
  PERFORM pg_temp.ok('T-S7 link_capture_device refuses a revoked device', j->>'error' = 'credential_revoked', j::text);
  j := public.set_capture_consent('d1', 'sec1', true, true, 12);
  RESET ROLE;
  PERFORM pg_temp.ok('T-S7 set_capture_consent refuses a revoked device', j->>'error' = 'credential_revoked', j::text);
  PERFORM pg_temp.ok('T-S7 legacy_set_device_consent refuses a revoked device',
    public.legacy_set_device_consent('d1', true, true)->>'ok' = 'false');
  PERFORM pg_temp.ok('T-S7 legacy_link_capture_device refuses a revoked device', NOT public.legacy_link_capture_device('d1', a));
  UPDATE public.capture_devices SET revoked_at = NULL WHERE install_id_hash = 'd1';
END $$;

-- ── Legacy link / consent ────────────────────────────────────────────────────
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002'; d public.capture_devices; j jsonb;
BEGIN
  PERFORM public.legacy_link_capture_device('d2', a);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'd2';
  PERFORM pg_temp.ok('legacy link, same owner: consent untouched', d.cloud_processing_enabled AND d.ai_consent_granted AND d.consent_version = 1);
  PERFORM public.legacy_link_capture_device('d2', b);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'd2';
  PERFORM pg_temp.ok('legacy link A->B: consent_owner_uid = B, both flags false, version reset',
    d.user_id = b AND d.consent_owner_uid = b AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted AND d.consent_version = 0, d::text);
  j := public.legacy_set_device_consent('d2', true, true);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'd2';
  PERFORM pg_temp.ok('legacy consent write on an owned row applies and bumps version', d.cloud_processing_enabled AND d.consent_version = 1, j::text);
  UPDATE public.capture_devices SET consent_owner_uid = a WHERE install_id_hash = 'd2';
  j := public.legacy_set_device_consent('d2', false, false);
  PERFORM pg_temp.ok('legacy consent write refused when consent_owner_uid != user_id',
    j->>'error' = 'capture_owner_mismatch' AND (SELECT cloud_processing_enabled FROM public.capture_devices WHERE install_id_hash = 'd2'), j::text);
  j := public.legacy_set_device_consent('d3', true, true);
  PERFORM pg_temp.ok('legacy consent write on a guest row (NULL/NULL) keeps working', (j->>'ok')::boolean, j::text);
  PERFORM public.unlink_capture_device('d3');
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'd3';
  PERFORM pg_temp.ok('unlink nulls user_id, consent_owner_uid and both flags',
    d.user_id IS NULL AND d.consent_owner_uid IS NULL AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted, d::text);
END $$;

-- ── AI dispatch / fences (A1, A9–A13, T-S4) ─────────────────────────────────
-- fresh device with known state for each scenario
CREATE FUNCTION pg_temp.mkdev(i text, uid uuid, ver int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.capture_devices (install_id_hash, device_secret_hash, user_id, consent_owner_uid,
     cloud_processing_enabled, ai_consent_granted, consent_version, apns_token, apns_environment)
  VALUES (i, 's' || i, uid, uid, true, true, ver, 'tok-' || i, 'sandbox') $$;

DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002';
        c jsonb; dsp jsonb; f jsonb; r public.processed_captures; j jsonb; n_logs int;
BEGIN
  -- T-S4 / A9: revoke committed between claim and AI dispatch -> AI never starts
  PERFORM pg_temp.mkdev('t4', a, 1);
  PERFORM pg_temp.claim('t4', 'p', 'fp', a, 2);
  PERFORM public.legacy_set_device_consent('t4', true, false);       -- AI revoked (version bump)
  dsp := public.capture_ai_dispatch('t4', 'p', 1);
  r := pg_temp.row_of('t4', 'p');
  PERFORM pg_temp.ok('T-S4/A9 revoke before dispatch -> allowed=false consent_revoked',
    NOT (dsp->>'allowed')::boolean AND dsp->>'reason' = 'consent_revoked', dsp::text);
  PERFORM pg_temp.ok('T-S4/A9 AI never started: ai_started_at NULL, ai_invoked false, retryable(consent_revoked), no content',
    r.ai_started_at IS NULL AND NOT r.ai_invoked AND r.state = 'retryable' AND r.failure_reason = 'consent_revoked'
    AND r.parsed = '{}'::jsonb AND r.notification = '{}'::jsonb);

  -- dispatch OK path records ai_started_at / ai_consent_version
  PERFORM pg_temp.mkdev('t4b', a, 3);
  PERFORM pg_temp.claim('t4b', 'p', 'fp', a, 2);
  dsp := public.capture_ai_dispatch('t4b', 'p', 1);
  r := pg_temp.row_of('t4b', 'p');
  PERFORM pg_temp.ok('dispatch allowed: ai_started_at + ai_consent_version recorded under the lease',
    (dsp->>'allowed')::boolean AND r.ai_started_at IS NOT NULL AND r.ai_consent_version = 3 AND r.ai_invoked, dsp::text);
  -- wrong lease token -> lease_lost, no marker
  PERFORM pg_temp.claim('t4b', 'q', 'fp', a, 2);
  dsp := public.capture_ai_dispatch('t4b', 'q', 99);
  PERFORM pg_temp.ok('dispatch with a stale lease_token -> lease_lost', dsp->>'reason' = 'lease_lost' AND (pg_temp.row_of('t4b','q')).ai_started_at IS NULL, dsp::text);

  -- A10: dispatch committed, THEN revoke, then final write -> fenced, nothing stored, no push
  dsp := public.capture_ai_dispatch('t4b', 'p', 1);  -- (already dispatched; idempotent for the lease)
  PERFORM public.legacy_set_device_consent('t4b', true, false);
  f := pg_temp.fin('t4b', 'p', 1, 'processed');
  r := pg_temp.row_of('t4b', 'p');
  PERFORM pg_temp.ok('A10 revoke after dispatch -> finalize fenced: written=false push_allowed=false',
    NOT (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND f->>'reason' = 'consent_revoked', f::text);
  PERFORM pg_temp.ok('A10 no stored content', r.parsed = '{}'::jsonb AND r.notification = '{}'::jsonb AND r.state = 'retryable');
  PERFORM pg_temp.ok('A10 no notification_logs row', NOT EXISTS (SELECT 1 FROM public.notification_logs WHERE related_entity_id = 'p' AND install_id = 'raw-t4b'));

  -- A11: revoke (cloud) before the final result write on the deterministic path
  PERFORM pg_temp.mkdev('t11', a, 1);
  PERFORM pg_temp.claim('t11', 'p', 'fp', a, 2);
  PERFORM public.legacy_set_device_consent('t11', false, false);
  f := pg_temp.fin('t11', 'p', 1, 'processed');
  r := pg_temp.row_of('t11', 'p');
  PERFORM pg_temp.ok('A11 revoke before final write -> fenced, no content, no push',
    NOT (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND r.parsed = '{}'::jsonb AND r.state = 'retryable', f::text);
  -- revoke AFTER final write nulls the stored content in its own transaction
  PERFORM pg_temp.mkdev('t11b', a, 1);
  PERFORM pg_temp.claim('t11b', 'p', 'fp', a, 2);
  f := pg_temp.fin('t11b', 'p', 1, 'processed');
  PERFORM pg_temp.ok('A11b finalize before revoke stores content', (f->>'written')::boolean AND (pg_temp.row_of('t11b','p')).parsed <> '{}'::jsonb);
  PERFORM public.legacy_set_device_consent('t11b', false, true);
  r := pg_temp.row_of('t11b', 'p');
  PERFORM pg_temp.ok('A11b later revoke nulls unconsumed content (state rejected, consent_revoked)',
    r.parsed = '{}'::jsonb AND r.notification = '{}'::jsonb AND r.sanitized_text IS NULL AND r.state = 'rejected' AND r.failure_reason = 'consent_revoked');

  -- A12: re-link before the final write (JWT link A->B) -> fenced
  PERFORM pg_temp.mkdev('t12', a, 1);
  PERFORM pg_temp.claim('t12', 'p', 'fp', a, 2);
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('t12', 'st12', true, true, 1);
  RESET ROLE;
  f := pg_temp.fin('t12', 'p', 1, 'processed');
  r := pg_temp.row_of('t12', 'p');
  PERFORM pg_temp.ok('A12 re-link before final write -> fenced (owner_changed), no content, no push',
    NOT (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND f->>'reason' = 'owner_changed' AND r.parsed = '{}'::jsonb, f::text);

  -- A1 v2: upload racing A->B: (1) relink wins before claim -> mismatch; (2) claim wins -> final fenced (A12 above)
  PERFORM pg_temp.mkdev('t1', a, 1);
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('t1', 'st1', true, true, 1);
  RESET ROLE;
  c := pg_temp.claim('t1', 'p', 'fp', a, 2);
  PERFORM pg_temp.ok('A1 v2 relink first: stamped-A upload is refused (capture_owner_mismatch), nothing stored',
    c->>'code' = 'capture_owner_mismatch' AND NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = 't1'), c::text);
  -- A1 legacy: claim as A, legacy relink to B, final -> fenced; also relink first -> claimed for B only
  PERFORM pg_temp.mkdev('t1l', a, 1);
  PERFORM pg_temp.claim('t1l', 'p', 'fp', null, 1);
  PERFORM public.legacy_link_capture_device('t1l', b);
  f := pg_temp.fin('t1l', 'p', 1, 'processed');
  PERFORM pg_temp.ok('A1 legacy claim(A) then relink(B) then final -> fenced, no content',
    NOT (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND (pg_temp.row_of('t1l','p')).parsed = '{}'::jsonb, f::text);
  c := pg_temp.claim('t1l', 'p2', 'fp', null, 1);
  PERFORM pg_temp.ok('A1 legacy: after relink B has no consent yet -> upload refused (consent_required), never processed on A''s consent',
    c->>'outcome' = 'denied' AND c->>'code' = 'consent_required', c::text);

  -- A13: expired-lease takeover, both completion orders -> one durable result, one notification
  PERFORM pg_temp.mkdev('t13', a, 1);
  PERFORM pg_temp.claim('t13', 'p', 'fp', a, 2);                                  -- worker1 token 1
  UPDATE public.processed_captures SET lease_until = now() - interval '1 second' WHERE install_id_hash = 't13';
  c := pg_temp.claim('t13', 'p', 'fp', a, 2);                                     -- worker2 token 2
  PERFORM pg_temp.ok('A13 takeover: token 2', (c->>'lease_token')::int = 2, c::text);
  f := pg_temp.fin('t13', 'p', 1, 'processed');                                   -- slow worker1 first
  PERFORM pg_temp.ok('A13 order 1: stale worker1 write rejected (lease_lost), no content, no push',
    NOT (f->>'written')::boolean AND NOT (f->>'push_allowed')::boolean AND f->>'reason' = 'lease_lost'
    AND (pg_temp.row_of('t13','p')).parsed = '{}'::jsonb, f::text);
  f := pg_temp.fin('t13', 'p', 2, 'processed');                                   -- worker2 wins
  PERFORM pg_temp.ok('A13 order 1: worker2 writes the one result and one notification',
    (f->>'written')::boolean AND (f->>'push_allowed')::boolean
    AND (SELECT count(*) FROM public.notification_logs WHERE install_id = 'raw-t13') = 1);
  -- order 2: worker1 completes first (lease expired, nobody re-claimed yet), then worker2 claims
  PERFORM pg_temp.mkdev('t13c', a, 1);
  PERFORM pg_temp.claim('t13c', 'p', 'fp', a, 2);
  UPDATE public.processed_captures SET lease_until = now() - interval '1 second' WHERE install_id_hash = 't13c';
  f := pg_temp.fin('t13c', 'p', 1, 'processed');                                  -- worker1 completes (lease expired, nobody reclaimed)
  c := pg_temp.claim('t13c', 'p', 'fp', a, 2);                                    -- worker2 finds the result
  PERFORM pg_temp.ok('A13 order 2: worker1 wins; worker2 claim replays the stored result (no second claim)',
    (f->>'written')::boolean AND c->>'outcome' = 'replay' AND c->'row'->>'state' = 'processed'
    AND (SELECT count(*) FROM public.notification_logs WHERE install_id = 'raw-t13c') = 1, c::text);
  f := pg_temp.fin('t13c', 'p', 1, 'processed');
  PERFORM pg_temp.ok('A13 order 2: a repeated finalize from the same worker is a no-op (state no longer processing)',
    NOT (f->>'written')::boolean AND (SELECT count(*) FROM public.notification_logs WHERE install_id = 'raw-t13c') = 1);

  -- Revoke fan-out also updates user_settings (monotonic) for the owner
  PERFORM pg_temp.mkdev('tfo', a, 1);
  UPDATE public.user_settings SET consent_version = 7, cloud_processing_enabled = true WHERE user_id = a;
  PERFORM public.legacy_set_device_consent('tfo', false, false);   -- version 2 < 7: user_settings not downgraded
  PERFORM pg_temp.ok('fan-out: user_settings update is monotonic (lower version ignored)',
    (SELECT consent_version FROM public.user_settings WHERE user_id = a) = 7 AND (SELECT cloud_processing_enabled FROM public.user_settings WHERE user_id = a));
  UPDATE public.capture_devices SET consent_version = 9, cloud_processing_enabled = true, ai_consent_granted = true WHERE install_id_hash = 'tfo';
  PERFORM public.legacy_set_device_consent('tfo', false, false);   -- version 10 > 7
  PERFORM pg_temp.ok('fan-out: user_settings consent mirrors the revocation with the newer version',
    (SELECT consent_version FROM public.user_settings WHERE user_id = a) = 10
    AND NOT (SELECT cloud_processing_enabled FROM public.user_settings WHERE user_id = a)
    AND NOT (SELECT ai_consent_granted FROM public.user_settings WHERE user_id = a));
  -- processing rows are untouched by the fan-out
  PERFORM pg_temp.mkdev('tfp', a, 1);
  PERFORM pg_temp.claim('tfp', 'p', 'fp', a, 2);
  PERFORM public.legacy_set_device_consent('tfp', false, false);
  PERFORM pg_temp.ok('fan-out leaves a processing row in processing (the fence handles it)', (pg_temp.row_of('tfp','p')).state = 'processing');
END $$;

-- ── T-S11 (ACK scope) and T-S12 purge ───────────────────────────────────────
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002'; e1 uuid; e2 uuid;
BEGIN
  -- a row claimed by A on an install now linked to B is not ackable by B
  PERFORM pg_temp.mkdev('t11s', a, 1);
  PERFORM pg_temp.claim('t11s', 'p', 'fp', a, 2);
  PERFORM pg_temp.fin('t11s', 'p', 1, 'processed');
  PERFORM public.legacy_link_capture_device('t11s', b);
  PERFORM pg_temp.ok('T-S11 B cannot ACK (consume) a row claimed by A', public.capture_ack('t11s', b, ARRAY['p']) = 0);
  PERFORM pg_temp.ok('T-S11 ownerless (NULL) scope cannot ACK a claimed row', public.capture_ack('t11s', NULL, ARRAY['p']) = 0);

  -- T-S12: purge by claimed_user_id on an install NOT linked to the user any more
  INSERT INTO public.user_sync_state (user_id, epoch, epoch_reason) VALUES (a, '11111111-1111-1111-1111-111111111111', 'initial')
    ON CONFLICT (user_id) DO UPDATE SET epoch = excluded.epoch, epoch_reason = excluded.epoch_reason;
  SELECT epoch INTO e1 FROM public.user_sync_state WHERE user_id = a;
  PERFORM pg_temp.ok('T-S12 setup: A has captures claimed on device t11s (linked to B)',
    (SELECT count(*) FROM public.processed_captures WHERE claimed_user_id = a AND install_id_hash = 't11s') = 1);
  PERFORM public.purge_user_data(a);
  PERFORM pg_temp.ok('T-S12 purge deletes processed_captures by claimed_user_id (even on another user''s install)',
    NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE claimed_user_id = a));
  SELECT epoch INTO e2 FROM public.user_sync_state WHERE user_id = a;
  PERFORM pg_temp.ok('T-S12 purge bumps the epoch with epoch_reason=purge',
    e2 IS DISTINCT FROM e1 AND (SELECT epoch_reason FROM public.user_sync_state WHERE user_id = a) = 'purge');
  PERFORM pg_temp.ok('T-S12 purge left B''s data alone',
    EXISTS (SELECT 1 FROM public.capture_devices WHERE install_id_hash = 't11s'));
  -- purge of a user with no sync-state row creates one (upsert)
  DELETE FROM public.user_sync_state WHERE user_id = b;
  PERFORM public.purge_user_data(b);
  PERFORM pg_temp.ok('T-S12 purge upserts user_sync_state for a user without a row',
    (SELECT epoch_reason FROM public.user_sync_state WHERE user_id = b) = 'purge');
END $$;

-- ══ Astra required changes, unit G1 (contract G: C.1 / C.2 / C.3) ═══════════════════════════════
-- ── C.1 / D.1: owner binding on ANY schema version (the ownerless rule is the H1 section at the end) ──
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002';
        c jsonb; j jsonb; d public.capture_devices; r public.processed_captures;
BEGIN
  PERFORM pg_temp.mkdev('g1a', a, 1);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1a';
  PERFORM pg_temp.ok('G1 new columns default: owner_generation 0, consent_client_generation 0, no revoke',
    d.owner_generation = 0 AND d.consent_client_generation = 0 AND d.last_revoke_generation IS NULL, d::text);
  PERFORM pg_temp.ok('H1 the G1 received_at / owner_changed_at machinery is gone',
    NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'capture_devices' AND column_name = 'owner_changed_at')
    AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'capture_parse_received_at')
    AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'capture_claim' AND pronargs = 9));

  -- the same owner's JWT link is not an owner change
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g1a', 'sg1a', true, true, 2, 3);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1a';
  PERFORM pg_temp.ok('same-owner link: owner_changed=false, owner_generation untouched, client generation stored',
    (j->>'owner_changed')::boolean IS FALSE AND d.owner_generation = 0 AND d.consent_client_generation = 3, j::text);

  -- A -> B relink through the JWT link: server counter + fresh ordering
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g1a', 'sg1a', true, true, 1, 1);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1a';
  PERFORM pg_temp.ok('A->B link: owner_changed, owner_generation 1, fresh ordering',
    (j->>'owner_changed')::boolean AND d.owner_generation = 1 AND (j->>'owner_generation')::bigint = 1
    AND d.consent_client_generation = 1 AND d.last_revoke_generation IS NULL, d::text);

  -- D.1: the delayed A capture arrives after the relink. Never processed under B.
  c := pg_temp.claim_r('g1a', 'race', 'fp', a, 2);
  PERFORM pg_temp.ok('D.1 owner-bound (v2) delayed A request -> denied capture_owner_mismatch',
    c->>'outcome' = 'denied' AND c->>'code' = 'capture_owner_mismatch', c::text);
  c := pg_temp.claim_r('g1a', 'race', 'fp', a, 1);
  PERFORM pg_temp.ok('D.1 owner-bound on schema_version 1 (owner_uid present, contract 1) delayed A request -> denied capture_owner_mismatch',
    c->>'outcome' = 'denied' AND c->>'code' = 'capture_owner_mismatch', c::text);
  PERFORM pg_temp.ok('D.1 none of the refused requests created a row or content',
    NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = 'g1a' AND payload_id = 'race'));

  -- owner-bound on schema_version 1: records owner_uid and the client generation (diagnostics)
  PERFORM pg_temp.mkdev('g1b', a, 1);
  c := pg_temp.claim_r('g1b', 'ob1', 'fp', a, 1, 9);
  SELECT * INTO r FROM public.processed_captures WHERE install_id_hash = 'g1b' AND payload_id = 'ob1';
  PERFORM pg_temp.ok('owner_uid on contract 1 is owner-bound: claimed, row records owner_uid and client_owner_generation',
    c->>'outcome' = 'claimed' AND r.owner_uid = a AND r.client_owner_generation = 9 AND r.claimed_user_id = a, c::text);
  c := pg_temp.claim_r('g1b', 'ob2', 'fp', b, 1);
  PERFORM pg_temp.ok('owner_uid of another user on contract 1 -> denied capture_owner_mismatch',
    c->>'outcome' = 'denied' AND c->>'code' = 'capture_owner_mismatch', c::text);
  PERFORM pg_temp.ok('the generation never decides anything: a wildly different client generation is still claimed',
    (pg_temp.claim_r('g1b', 'ob3', 'fp', a, 2, 123456789))->>'outcome' = 'claimed');
  -- delayed owner-bound A request fenced at finalize after a relink (any contract)
  c := pg_temp.claim_r('g1b', 'ob4', 'fp', a, 1);
  PERFORM public.legacy_link_capture_device('g1b', b);
  PERFORM pg_temp.ok('owner-bound row claimed under A (contract 1) is fenced after an A->B relink: no content written',
    NOT (pg_temp.fin('g1b', 'ob4', 1, 'processed')->>'written')::boolean
    AND (pg_temp.row_of('g1b', 'ob4')).parsed = '{}'::jsonb);

  -- legacy link / unlink maintain owner_generation
  PERFORM pg_temp.mkdev('g1c', a, 1);
  PERFORM public.legacy_link_capture_device('g1c', a);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1c';
  PERFORM pg_temp.ok('legacy link, same owner: owner_generation untouched', d.owner_generation = 0, d::text);
  PERFORM public.legacy_link_capture_device('g1c', b);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1c';
  PERFORM pg_temp.ok('legacy link A->B: owner_generation 1, ordering reset',
    d.owner_generation = 1 AND d.consent_client_generation = 0 AND d.last_revoke_generation IS NULL, d::text);
  c := pg_temp.claim_r('g1c', 'lg', 'fp', null, 1);
  PERFORM pg_temp.ok('legacy A->B then delayed ownerless A capture -> refused before consent is even re-granted',
    c->>'outcome' = 'denied' AND c->>'code' = 'consent_required', c::text);
  PERFORM public.unlink_capture_device('g1c');
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1c';
  PERFORM pg_temp.ok('unlink of a linked device is an owner change: owner_generation 2', d.owner_generation = 2 AND d.user_id IS NULL, d::text);
  PERFORM public.unlink_capture_device('g1c');
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1c';
  PERFORM pg_temp.ok('a second unlink of an already unlinked device changes nothing', d.owner_generation = 2);
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g1c', 'sg1c', true, false, 1, 4);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g1c';
  PERFORM pg_temp.ok('first JWT link after an unlink is an owner change too (owner_generation 3)',
    (j->>'owner_changed')::boolean AND d.owner_generation = 3, j::text);
END $$;

-- ── C.2 / D.9: a late projection writer can never widen consent; C.3 revoke ──────────────────────
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002';
        j jsonb; d public.capture_devices; c jsonb; r public.processed_captures; legacy jsonb;
BEGIN
  -- An Android row: registered install, NO apns token/environment, never linked. The JWT link must work.
  INSERT INTO public.capture_devices (install_id_hash, device_secret_hash, platform) VALUES ('g9', 'sg9', 'android');
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g9', 'sg9', true, false, 3, 5);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('C.3 an Android-style row (no APNs token) is JWT-linkable: user, owner, flags, version, generation set',
    (j->>'ok')::boolean AND d.user_id = a AND d.consent_owner_uid = a AND d.cloud_processing_enabled AND NOT d.ai_consent_granted
    AND d.consent_version = 3 AND d.consent_client_generation = 5 AND d.owner_generation = 1, j::text);
  PERFORM pg_temp.ok('link response is additive: legacy keys kept, applied / owner_generation / consent_client_generation added',
    j ? 'ok' AND j ? 'owner_changed' AND (j->>'applied')::boolean AND (j->>'owner_generation')::bigint = 1
    AND (j->>'consent_client_generation')::bigint = 5, j::text);

  -- ── older generation: may only narrow, never widen ──
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g9', 'sg9', true, true, 9, 4);          -- stale link tries to widen AI and bump the version
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('C.2 stale-generation link cannot widen (AI stays false), version and generation unchanged, reports stale_generation',
    NOT (j->>'applied')::boolean AND j->>'reason' = 'stale_generation' AND d.cloud_processing_enabled AND NOT d.ai_consent_granted
    AND d.consent_version = 3 AND d.consent_client_generation = 5, j::text);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('g9', 'sg9', true, true, 50, 4);          -- stale set with a HIGHER version
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('C.2 stale-generation set cannot widen even with a higher version',
    NOT (j->>'applied')::boolean AND j->>'reason' = 'stale_generation' AND NOT d.ai_consent_granted AND d.consent_version = 3, j::text);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g9', 'sg9', false, false, 1, 4);         -- stale link may narrow
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('C.2 stale-generation link may still narrow (stored AND requested)',
    NOT (j->>'applied')::boolean AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted AND d.consent_version = 3, j::text);
  -- the current generation widens normally
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('g9', 'sg9', true, true, 4, 6);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('C.2 a newer generation widens normally',
    (j->>'applied')::boolean AND d.cloud_processing_enabled AND d.ai_consent_granted AND d.consent_version = 4
    AND d.consent_client_generation = 6 AND (j->>'consent_client_generation')::bigint = 6, j::text);

  -- ── C.3 revoke at generation 7, with unconsumed content to null ──
  INSERT INTO public.processed_captures (payload_id, install_id_hash, claimed_user_id, status, state, parsed, notification, sanitized_text, raw_fingerprint)
  VALUES ('g9p', 'g9', a, 'processed', 'processed', '{"amount":5}', '{"title":"t"}', 'sms', 'f1'),
         ('g9c', 'g9', a, 'processed', 'consumed', '{}', '{}', NULL, 'f2');
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.revoke_capture_consent('g9', 'sg9', a, 7, 5);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  SELECT * INTO r FROM public.processed_captures WHERE install_id_hash = 'g9' AND payload_id = 'g9p';
  PERFORM pg_temp.ok('C.3 revoke: {ok, applied, reason}, both flags false, version raised, last_revoke_generation recorded',
    (j->>'ok')::boolean AND (j->>'applied')::boolean AND j->>'reason' = 'revoked' AND NOT d.cloud_processing_enabled
    AND NOT d.ai_consent_granted AND d.consent_version = 5 AND d.last_revoke_generation = 7 AND d.consent_client_generation = 7, j::text);
  PERFORM pg_temp.ok('C.3 revoke fan-out nulled the unconsumed content for (install, owner); a tombstone is untouched',
    r.parsed = '{}'::jsonb AND r.notification = '{}'::jsonb AND r.sanitized_text IS NULL AND r.state = 'rejected'
    AND (SELECT state FROM public.processed_captures WHERE install_id_hash = 'g9' AND payload_id = 'g9c') = 'consumed');
  SET LOCAL ROLE authenticated;
  j := public.revoke_capture_consent('g9', 'sg9', a, 7, 5);
  RESET ROLE;
  PERFORM pg_temp.ok('C.3 revoke is idempotent per (install, owner, generation): the repeat is a no-op already_revoked',
    (j->>'ok')::boolean AND NOT (j->>'applied')::boolean AND j->>'reason' = 'already_revoked', j::text);

  -- ── D.9: LATE writers (arrive after the revoke) cannot widen ──
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g9', 'sg9', true, true, 99, 7);          -- generation == revoke generation
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('D.9 late link at generation = revoke generation cannot widen (revoked_generation)',
    NOT (j->>'applied')::boolean AND j->>'reason' = 'revoked_generation' AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted
    AND d.consent_version = 5, j::text);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g9', 'sg9', true, true, 99);             -- an OLD client: no generation (= 0)
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('D.9 a generation-0 link (old client / absent) can never widen past a recorded revoke',
    j->>'reason' = 'revoked_generation' AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted, j::text);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('g9', 'sg9', true, true, 99, 3);          -- older generation, huge version
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('D.9 late set with generation < revoke generation cannot widen',
    NOT (j->>'applied')::boolean AND j->>'reason' = 'revoked_generation' AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted, j::text);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('g9', 'sg9', true, true, 99);             -- generation absent
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('D.9 late set with no generation (0) cannot widen',
    j->>'reason' = 'revoked_generation' AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted AND d.consent_version = 5, j::text);
  legacy := public.legacy_set_device_consent('g9', true, true);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('D.9 the legacy device-credential writer (no generation) cannot widen past a recorded revoke either',
    NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted AND d.consent_version = 5, legacy::text);
  c := pg_temp.claim_r('g9', 'g9new', 'fp', a, 2);
  PERFORM pg_temp.ok('D.9 after the late writers the capture gate is still closed (consent_required)',
    c->>'outcome' = 'denied' AND c->>'code' = 'consent_required', c::text);
  -- a STRICTLY NEWER generation is a deliberate re-enable and widens
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('g9', 'sg9', true, true, 6, 8);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('a generation above the recorded revoke (explicit re-enable) widens',
    (j->>'applied')::boolean AND d.cloud_processing_enabled AND d.ai_consent_granted AND d.consent_version = 6
    AND d.consent_client_generation = 8 AND d.last_revoke_generation = 7, j::text);
  -- ...and a DUPLICATE / older revoke arriving later must not kill the newer enable
  SET LOCAL ROLE authenticated;
  j := public.revoke_capture_consent('g9', 'sg9', a, 7, 5);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('a replayed revoke (generation 7) after the generation-8 re-enable is a no-op: consent stays on',
    NOT (j->>'applied')::boolean AND j->>'reason' = 'already_revoked' AND d.cloud_processing_enabled AND d.ai_consent_granted, j::text);
  -- legacy writer stays narrow-only after a recorded revoke, but can still narrow
  legacy := public.legacy_set_device_consent('g9', false, false);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('legacy writer can narrow after a revoke', NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted, legacy::text);

  -- a revoke older than the generation the owner has since enabled under (no revoke recorded) is a stale no-op
  INSERT INTO public.capture_devices (install_id_hash, device_secret_hash, platform) VALUES ('g9s', 'sg9s', 'android');
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  PERFORM public.link_capture_device('g9s', 'sg9s', true, true, 2, 8);
  j := public.revoke_capture_consent('g9s', 'sg9s', a, 3, 3);
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9s';
  PERFORM pg_temp.ok('revoke older than the stored consent generation -> stale_generation no-op, consent untouched',
    (j->>'ok')::boolean AND NOT (j->>'applied')::boolean AND j->>'reason' = 'stale_generation'
    AND d.cloud_processing_enabled AND d.ai_consent_granted AND d.last_revoke_generation IS NULL, j::text);

  -- ── owner change resets the ordering atomically ──
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('g9', 'sg9', true, false, 1, 1);          -- B links: fresh ordering, low generation
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('owner change resets per-owner ordering: owner_generation + 1, generation = B''s, recorded revoke cleared',
    (j->>'owner_changed')::boolean AND d.user_id = b AND d.owner_generation = 2 AND d.consent_client_generation = 1
    AND d.last_revoke_generation IS NULL AND d.cloud_processing_enabled AND NOT d.ai_consent_granted, d::text);
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.set_capture_consent('g9', 'sg9', true, true, 500, 500);       -- A's late write: not the owner
  RESET ROLE;
  PERFORM pg_temp.ok('a late A writer after the owner change is refused (capture_owner_mismatch), B''s projection untouched',
    j->>'error' = 'capture_owner_mismatch' AND (SELECT user_id = b AND NOT ai_consent_granted FROM public.capture_devices WHERE install_id_hash = 'g9'), j::text);

  -- ── revoke guards ──
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.revoke_capture_consent('g9', 'sg9', a, 9, 9);                 -- row is B's now: server no-op for A
  RESET ROLE;
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('C.3 revoke by a JWT whose uid is not the projection owner is a server no-op (owner_mismatch); B is untouched',
    (j->>'ok')::boolean AND NOT (j->>'applied')::boolean AND j->>'reason' = 'owner_mismatch'
    AND d.cloud_processing_enabled AND d.last_revoke_generation IS NULL AND d.consent_version = 1, j::text);
  SET LOCAL ROLE authenticated;
  j := public.revoke_capture_consent('g9', 'sg9', b, 9, 9);                 -- jwt A, p_owner B
  RESET ROLE;
  PERFORM pg_temp.ok('C.3 revoke with p_owner_uid != jwt.uid is refused', NOT (j->>'ok')::boolean AND j->>'reason' = 'owner_mismatch', j::text);
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.revoke_capture_consent('g9', 'WRONG', b, 9, 9);
  RESET ROLE;
  PERFORM pg_temp.ok('C.3 revoke with a wrong device secret -> invalid_device_secret, nothing changed',
    NOT (j->>'ok')::boolean AND j->>'reason' = 'invalid_device_secret'
    AND (SELECT cloud_processing_enabled FROM public.capture_devices WHERE install_id_hash = 'g9'), j::text);
  UPDATE public.capture_devices SET revoked_at = now() WHERE install_id_hash = 'g9';
  SET LOCAL ROLE authenticated;
  j := public.revoke_capture_consent('g9', 'sg9', b, 9, 9);
  RESET ROLE;
  UPDATE public.capture_devices SET revoked_at = NULL WHERE install_id_hash = 'g9';
  PERFORM pg_temp.ok('C.3 revoke on a revoked credential -> credential_revoked', NOT (j->>'ok')::boolean AND j->>'reason' = 'credential_revoked', j::text);
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '{}', true);
    SET LOCAL ROLE authenticated;
    PERFORM public.revoke_capture_consent('g9', 'sg9', b, 9, 9);
    RESET ROLE;
    PERFORM pg_temp.ok('C.3 revoke without a JWT is refused', false);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.ok('C.3 revoke without a JWT is refused (not_authenticated)', SQLERRM = 'not_authenticated', SQLERRM);
  END;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.revoke_capture_consent('g9', 'sg9', b, 9, 9);
    RESET ROLE;
    PERFORM pg_temp.ok('anon cannot execute revoke_capture_consent', false);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.ok('anon cannot execute revoke_capture_consent', true);
  END;
  PERFORM pg_temp.ok('privileges: revoke_capture_consent is authenticated-only; capture_install_owner_history is closed to client roles',
    has_function_privilege('authenticated', 'public.revoke_capture_consent(text,text,uuid,bigint,integer)', 'execute')
    AND NOT has_function_privilege('anon', 'public.revoke_capture_consent(text,text,uuid,bigint,integer)', 'execute')
    AND NOT has_function_privilege('public', 'public.revoke_capture_consent(text,text,uuid,bigint,integer)', 'execute')
    AND NOT has_table_privilege('authenticated', 'public.capture_install_owner_history', 'select')
    AND NOT has_table_privilege('anon', 'public.capture_install_owner_history', 'select')
    AND NOT has_function_privilege('authenticated', 'public.capture_history_forget_owner(uuid)', 'execute')
    AND NOT has_function_privilege('authenticated', 'public.capture_device_history_track()', 'execute')
    AND has_function_privilege('service_role', 'public.capture_claim(text,text,text,text,uuid,integer,integer,bigint)', 'execute')
    AND NOT has_function_privilege('authenticated', 'public.capture_claim(text,text,text,text,uuid,integer,integer,bigint)', 'execute'));
END $$;

-- ══ Astra required changes, unit H1 (contract H): build-50 ownerless uploads, option B ══════════
-- Eligible <=> history.trusted AND NOT history.transitioned AND history.first_owner_uid = user_id =
-- consent_owner_uid. History is kept by a trigger on capture_devices and survives row deletion.
CREATE FUNCTION pg_temp.hist(i text) RETURNS public.capture_install_owner_history LANGUAGE sql AS
$$ SELECT h FROM public.capture_install_owner_history h WHERE install_id_hash = i $$;
-- register-device: the anon endpoint upserts the row with user_id NULL and a fresh secret.
CREATE FUNCTION pg_temp.register(i text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.capture_devices (install_id_hash, device_secret_hash, platform, user_id, created_at, last_seen_at)
  VALUES (i, 'sec-' || i || '-' || clock_timestamp()::text, 'ios', NULL, now(), now())
  ON CONFLICT (install_id_hash) DO UPDATE
    SET device_secret_hash = excluded.device_secret_hash, platform = excluded.platform,
        user_id = excluded.user_id, last_seen_at = excluded.last_seen_at $$;
-- a build-50 link + consent write, then one ownerless claim
CREATE FUNCTION pg_temp.link50(i text, u uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.legacy_link_capture_device(i, u);
  PERFORM public.legacy_set_device_consent(i, true, true);
END $$;
CREATE FUNCTION pg_temp.own(i text, p text) RETURNS jsonb LANGUAGE sql AS $$ SELECT pg_temp.claim(i, p, 'fp-' || p, null, 1) $$;
CREATE FUNCTION pg_temp.refused(c jsonb) RETURNS boolean LANGUAGE sql AS
$$ SELECT c->>'outcome' = 'owner_conflict' AND c->>'reason' = 'ownerless_not_eligible' AND NOT (c ? 'row') AND NOT (c ? 'lease_token') $$;
CREATE FUNCTION pg_temp.nothing_stored(i text) RETURNS boolean LANGUAGE sql AS
$$ SELECT NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = i)
      AND NOT EXISTS (SELECT 1 FROM public.notification_logs WHERE install_id = 'raw-' || i) $$;

DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002';
        h public.capture_install_owner_history; c jsonb; j jsonb; d public.capture_devices; sec text;
BEGIN
  -- ── first owner under proven history: accepted ──
  PERFORM pg_temp.register('h1a');
  h := pg_temp.hist('h1a');
  PERFORM pg_temp.ok('H1 a new install row is TRUSTED, no owner yet, not transitioned',
    h.trusted AND h.first_owner_uid IS NULL AND NOT h.transitioned, h::text);
  PERFORM pg_temp.register('h1a');  -- re-register of a never-owned install changes nothing
  PERFORM pg_temp.ok('H1 re-registering a never-owned install keeps it trusted and untransitioned',
    (pg_temp.hist('h1a')).trusted AND NOT (pg_temp.hist('h1a')).transitioned);
  PERFORM pg_temp.link50('h1a', a);
  h := pg_temp.hist('h1a');
  PERFORM pg_temp.ok('H1 the first non-null owner becomes first_owner_uid', h.first_owner_uid = a AND h.trusted AND NOT h.transitioned, h::text);
  c := pg_temp.own('h1a', 'o1');
  PERFORM pg_temp.ok('H1 first-owner ownerless upload under proven history -> claimed under A',
    c->>'outcome' = 'claimed' AND (c->>'claimed_user_id')::uuid = a, c::text);
  PERFORM public.legacy_link_capture_device('h1a', a);  -- same owner re-link / re-affirmed
  c := pg_temp.own('h1a', 'o2');
  PERFORM pg_temp.ok('H1 same-owner re-link does not transition: still eligible', c->>'outcome' = 'claimed', c::text);

  -- a JWT-linked install (new protocol link) is tracked identically
  PERFORM pg_temp.register('h1j');
  SELECT device_secret_hash INTO sec FROM public.capture_devices WHERE install_id_hash = 'h1j';
  PERFORM pg_temp.as_user(a);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('h1j', sec, true, true, 1, 1);
  RESET ROLE;
  PERFORM pg_temp.ok('H1 JWT link as first owner: first_owner_uid = A, eligible',
    (pg_temp.hist('h1j')).first_owner_uid = a AND (pg_temp.own('h1j', 'o1'))->>'outcome' = 'claimed', j::text);

  -- ── A -> B rejected (legacy link) ──
  PERFORM pg_temp.register('h1b');
  PERFORM pg_temp.link50('h1b', a);
  PERFORM pg_temp.link50('h1b', b);
  h := pg_temp.hist('h1b');
  c := pg_temp.own('h1b', 'o1');
  PERFORM pg_temp.ok('H1 A->B: transitioned forever; B''s own ownerless upload is rejected (B is not the first owner)',
    h.transitioned AND h.first_owner_uid = a AND pg_temp.refused(c), c::text || h::text);
  PERFORM pg_temp.ok('H1 A->B rejected: no row, no content, no notification', pg_temp.nothing_stored('h1b'));

  -- the delayed A request after the B transition: rejected, no row
  PERFORM pg_temp.mkdev('h1d', a, 1);
  c := pg_temp.own('h1d', 'early');
  PERFORM pg_temp.ok('H1 delayed-A setup: A''s upload before the transition is accepted', c->>'outcome' = 'claimed', c::text);
  PERFORM pg_temp.link50('h1d', b);
  c := pg_temp.own('h1d', 'delayed-a');
  PERFORM pg_temp.ok('H1 delayed A request after the A->B transition: rejected, never attributed to B',
    pg_temp.refused(c) AND NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = 'h1d' AND payload_id = 'delayed-a'), c::text);
  PERFORM pg_temp.ok('H1 delayed A request: no notification log', NOT EXISTS (SELECT 1 FROM public.notification_logs WHERE install_id = 'raw-h1d' AND related_entity_id = 'delayed-a'));

  -- ── A -> B (JWT link) ──
  PERFORM pg_temp.register('h1c');
  PERFORM pg_temp.link50('h1c', a);
  SELECT device_secret_hash INTO sec FROM public.capture_devices WHERE install_id_hash = 'h1c';
  PERFORM pg_temp.as_user(b);
  SET LOCAL ROLE authenticated;
  j := public.link_capture_device('h1c', sec, true, true, 1, 1);
  RESET ROLE;
  PERFORM pg_temp.ok('H1 A->B through the JWT link: transitioned, ownerless rejected',
    (pg_temp.hist('h1c')).transitioned AND pg_temp.refused(pg_temp.own('h1c', 'o1')));

  -- ── A -> B -> A: still rejected ──
  PERFORM pg_temp.register('h1e');
  PERFORM pg_temp.link50('h1e', a);
  PERFORM pg_temp.link50('h1e', b);
  PERFORM pg_temp.link50('h1e', a);
  h := pg_temp.hist('h1e');
  PERFORM pg_temp.ok('H1 A->B->A: owner is A again but the install stays ineligible (monotonic)',
    h.transitioned AND h.first_owner_uid = a AND pg_temp.refused(pg_temp.own('h1e', 'o1'))
    AND (SELECT user_id = a AND consent_owner_uid = a FROM public.capture_devices WHERE install_id_hash = 'h1e'), h::text);

  -- ── A -> unlink -> A: rejected ──
  PERFORM pg_temp.register('h1f');
  PERFORM pg_temp.link50('h1f', a);
  PERFORM public.unlink_capture_device('h1f');
  PERFORM pg_temp.ok('H1 unlink marks the install transitioned', (pg_temp.hist('h1f')).transitioned);
  PERFORM pg_temp.link50('h1f', a);
  PERFORM pg_temp.ok('H1 A->unlink->A: rejected', pg_temp.refused(pg_temp.own('h1f', 'o1')));
  PERFORM pg_temp.ok('H1 A->unlink->A rejected: nothing stored', pg_temp.nothing_stored('h1f'));

  -- ── register / re-register of an OWNED install (the anon endpoint nulls user_id) ──
  PERFORM pg_temp.register('h1r');
  PERFORM pg_temp.link50('h1r', a);
  PERFORM pg_temp.register('h1r');   -- secret rotation: user_id -> NULL (consent_owner_uid keeps A)
  PERFORM pg_temp.ok('H1 re-register of an owned install (user_id -> NULL) transitions it',
    (pg_temp.hist('h1r')).transitioned);
  PERFORM pg_temp.link50('h1r', a);
  PERFORM pg_temp.ok('H1 re-register then re-link as A: rejected', pg_temp.refused(pg_temp.own('h1r', 'o1')));

  -- ── device row deleted and re-registered: rejected, history survives the delete ──
  PERFORM pg_temp.register('h1x');
  PERFORM pg_temp.link50('h1x', a);
  PERFORM pg_temp.ok('H1 delete-and-recreate setup: eligible before the delete', (pg_temp.own('h1x', 'before'))->>'outcome' = 'claimed');
  DELETE FROM public.capture_devices WHERE install_id_hash = 'h1x';
  h := pg_temp.hist('h1x');
  PERFORM pg_temp.ok('H1 the history row SURVIVES deletion of the device row and is transitioned',
    h.install_id_hash IS NOT NULL AND h.transitioned, h::text);
  PERFORM pg_temp.register('h1x');
  PERFORM pg_temp.ok('H1 re-created row: history untouched except staying transitioned (trusted flag is never regained)',
    (pg_temp.hist('h1x')).transitioned);
  PERFORM pg_temp.link50('h1x', a);
  PERFORM pg_temp.ok('H1 device row deleted and re-registered, same owner re-linked: rejected',
    pg_temp.refused(pg_temp.own('h1x', 'after')));
  -- the same, but the deleted row was never owned: a re-created row still is not a "first" install
  PERFORM pg_temp.register('h1y');
  DELETE FROM public.capture_devices WHERE install_id_hash = 'h1y';
  PERFORM pg_temp.register('h1y');
  PERFORM pg_temp.link50('h1y', a);
  PERFORM pg_temp.ok('H1 deleted-then-recreated unowned install: rejected as well (a delete is a transition)',
    pg_temp.refused(pg_temp.own('h1y', 'o1')) AND (pg_temp.hist('h1y')).transitioned);

  -- ── pre-migration (untrusted) row and a missing history row: rejected ──
  SET LOCAL session_replication_role = replica;   -- the trigger does not exist yet for pre-0110 rows
  INSERT INTO public.capture_devices (install_id_hash, device_secret_hash, user_id, consent_owner_uid,
     cloud_processing_enabled, ai_consent_granted, consent_version)
  VALUES ('h1pre', 'shpre', a, a, true, true, 1), ('h1miss', 'shmiss', a, a, true, true, 1);
  SET LOCAL session_replication_role = origin;
  PERFORM pg_temp.ok('H1 a row with no history row is rejected (missing history = ineligible)',
    (pg_temp.hist('h1miss')) IS NULL AND pg_temp.refused(pg_temp.own('h1miss', 'o1')));
  -- the migration backfill, verbatim: every pre-existing install is recorded untrusted + transitioned
  INSERT INTO public.capture_install_owner_history (install_id_hash, trusted, first_owner_uid, transitioned, transitioned_at)
  SELECT install_id_hash, false, null, true, clock_timestamp() FROM public.capture_devices WHERE install_id_hash = 'h1pre'
  ON CONFLICT (install_id_hash) DO NOTHING;
  h := pg_temp.hist('h1pre');
  PERFORM pg_temp.ok('H1 pre-migration install is untrusted and transitioned',
    NOT h.trusted AND h.transitioned AND h.first_owner_uid IS NULL, h::text);
  PERFORM pg_temp.ok('H1 pre-migration (untrusted) row, owned by one user, consent on: rejected, nothing stored',
    pg_temp.refused(pg_temp.own('h1pre', 'o1')) AND pg_temp.nothing_stored('h1pre'));
  PERFORM public.unlink_capture_device('h1pre');
  PERFORM pg_temp.link50('h1pre', a);
  PERFORM pg_temp.ok('H1 pre-migration install stays untrusted through unlink/relink', NOT (pg_temp.hist('h1pre')).trusted AND pg_temp.refused(pg_temp.own('h1pre', 'o2')));
  -- an UPDATE of a row with no history writes an UNTRUSTED, transitioned record (never a trusted one)
  PERFORM pg_temp.link50('h1miss', b);
  h := pg_temp.hist('h1miss');
  PERFORM pg_temp.ok('H1 a change on a row with no history creates an untrusted transitioned record',
    h.install_id_hash IS NOT NULL AND NOT h.trusted AND h.transitioned AND h.first_owner_uid IS NULL, h::text);

  -- ── every writer is covered: direct UPDATEs by a future writer ──
  PERFORM pg_temp.mkdev('h1w1', a, 1);
  UPDATE public.capture_devices SET user_id = NULL WHERE install_id_hash = 'h1w1';
  PERFORM pg_temp.ok('H1 direct UPDATE user_id -> NULL transitions', (pg_temp.hist('h1w1')).transitioned);
  PERFORM pg_temp.mkdev('h1w2', a, 1);
  UPDATE public.capture_devices SET consent_owner_uid = NULL WHERE install_id_hash = 'h1w2';
  PERFORM pg_temp.ok('H1 direct UPDATE consent_owner_uid -> NULL transitions', (pg_temp.hist('h1w2')).transitioned);
  PERFORM pg_temp.mkdev('h1w3', a, 1);
  UPDATE public.capture_devices SET consent_owner_uid = b WHERE install_id_hash = 'h1w3';
  UPDATE public.capture_devices SET consent_owner_uid = a WHERE install_id_hash = 'h1w3';
  PERFORM pg_temp.ok('H1 direct UPDATE consent_owner_uid A->B->A transitions and stays ineligible',
    (pg_temp.hist('h1w3')).transitioned AND pg_temp.refused(pg_temp.own('h1w3', 'o1')));
  PERFORM pg_temp.mkdev('h1w4', a, 1);
  UPDATE public.capture_devices SET user_id = b, consent_owner_uid = b WHERE install_id_hash = 'h1w4';
  PERFORM pg_temp.ok('H1 direct UPDATE of both owner columns to another uid transitions', (pg_temp.hist('h1w4')).transitioned);
  PERFORM pg_temp.register('h1w5');
  UPDATE public.capture_devices SET user_id = a WHERE install_id_hash = 'h1w5';
  PERFORM pg_temp.ok('H1 an inconsistent owned state (user_id without consent_owner_uid) is treated as a transition, never a first owner',
    (pg_temp.hist('h1w5')).transitioned AND (pg_temp.hist('h1w5')).first_owner_uid IS NULL);
  h := pg_temp.hist('h1a');
  UPDATE public.capture_devices SET last_seen_at = now(), apns_token = 'tok-h1a' WHERE install_id_hash = 'h1a';
  PERFORM pg_temp.ok('H1 UPDATEs of other columns do not touch the history', pg_temp.hist('h1a') IS NOT DISTINCT FROM h);
  BEGIN
    UPDATE public.capture_devices SET install_id_hash = 'h1w5-renamed' WHERE install_id_hash = 'h1w5';
    PERFORM pg_temp.ok('H1 install_id_hash is immutable on capture_devices', false);
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.ok('H1 install_id_hash is immutable on capture_devices', true);
  END;

  -- ── the monotonic guard refuses widening UPDATEs (even for the table owner) ──
  PERFORM pg_temp.register('h1g');
  PERFORM pg_temp.link50('h1g', a);
  PERFORM pg_temp.link50('h1g', b);   -- transitioned
  BEGIN UPDATE public.capture_install_owner_history SET transitioned = false WHERE install_id_hash = 'h1g';
    PERFORM pg_temp.ok('H1 guard: transitioned true -> false refused', false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok('H1 guard: transitioned true -> false refused', true); END;
  BEGIN UPDATE public.capture_install_owner_history SET trusted = true WHERE install_id_hash = 'h1pre';
    PERFORM pg_temp.ok('H1 guard: trusted false -> true refused', false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok('H1 guard: trusted false -> true refused', true); END;
  BEGIN UPDATE public.capture_install_owner_history SET first_owner_uid = b WHERE install_id_hash = 'h1g';
    PERFORM pg_temp.ok('H1 guard: first_owner_uid rewrite refused', false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok('H1 guard: first_owner_uid rewrite refused', true); END;
  BEGIN UPDATE public.capture_install_owner_history SET first_owner_uid = NULL, transitioned = false WHERE install_id_hash = 'h1g';
    PERFORM pg_temp.ok('H1 guard: clearing first_owner_uid without transitioned refused', false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok('H1 guard: clearing first_owner_uid without transitioned refused', true); END;
  BEGIN UPDATE public.capture_install_owner_history SET first_owner_uid = a, trusted = true, transitioned = false WHERE install_id_hash = 'h1pre';
    PERFORM pg_temp.ok('H1 guard: assigning an owner to an untrusted install refused', false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok('H1 guard: assigning an owner to an untrusted install refused', true); END;
  BEGIN UPDATE public.capture_install_owner_history SET install_id_hash = 'other' WHERE install_id_hash = 'h1g';
    PERFORM pg_temp.ok('H1 guard: install_id_hash rewrite refused', false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok('H1 guard: install_id_hash rewrite refused', true); END;
  BEGIN DELETE FROM public.capture_install_owner_history WHERE install_id_hash = 'h1g';
    PERFORM pg_temp.ok('H1 guard: deleting a history row refused', false);
  EXCEPTION WHEN insufficient_privilege THEN PERFORM pg_temp.ok('H1 guard: deleting a history row refused', true); END;
  PERFORM pg_temp.ok('H1 guard: the refused UPDATEs changed nothing', (pg_temp.hist('h1g')).transitioned AND (pg_temp.hist('h1g')).first_owner_uid = a);

  -- ── RLS / privileges: closed to every client role ──
  PERFORM pg_temp.ok('H1 history table: RLS on, no client privileges',
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.capture_install_owner_history'::regclass)
    AND NOT has_table_privilege('anon', 'public.capture_install_owner_history', 'select,insert,update,delete')
    AND NOT has_table_privilege('authenticated', 'public.capture_install_owner_history', 'select,insert,update,delete'));
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM count(*) FROM public.capture_install_owner_history;
    RESET ROLE;
    PERFORM pg_temp.ok('H1 an authenticated client cannot read the history', false);
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    PERFORM pg_temp.ok('H1 an authenticated client cannot read the history', true);
  END;
END $$;

-- ── account deletion keeps the install ineligible (fail closed) ──
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a001'; b uuid := '00000000-0000-0000-0000-00000000b002';
        h public.capture_install_owner_history; c jsonb; n integer;
BEGIN
  -- del1: held by A (A is first owner); del2: A -> B (first owner A, held by B); ctl: B alone
  PERFORM pg_temp.register('del1');  PERFORM pg_temp.link50('del1', a);
  PERFORM pg_temp.register('del2');  PERFORM pg_temp.link50('del2', a);  PERFORM pg_temp.link50('del2', b);
  PERFORM pg_temp.register('ctl');   PERFORM pg_temp.link50('ctl', b);
  PERFORM pg_temp.ok('H1 account deletion setup: del1 eligible, ctl eligible',
    (pg_temp.own('del1', 'o'))->>'outcome' = 'claimed' AND (pg_temp.own('ctl', 'o'))->>'outcome' = 'claimed');
  PERFORM public.purge_user_data(a);
  h := pg_temp.hist('del1');
  PERFORM pg_temp.ok('H1 purge: A''s device row is deleted, the history row remains, uid forgotten, transitioned',
    NOT EXISTS (SELECT 1 FROM public.capture_devices WHERE install_id_hash = 'del1')
    AND h.install_id_hash IS NOT NULL AND h.first_owner_uid IS NULL AND h.transitioned, h::text);
  h := pg_temp.hist('del2');
  PERFORM pg_temp.ok('H1 purge: a history row naming A on a device now held by B is also scrubbed (uid gone, still transitioned)',
    h.first_owner_uid IS NULL AND h.transitioned
    AND EXISTS (SELECT 1 FROM public.capture_devices WHERE install_id_hash = 'del2' AND user_id = b), h::text);
  PERFORM pg_temp.ok('H1 purge: no history row of the deleted user still carries the uid',
    NOT EXISTS (SELECT 1 FROM public.capture_install_owner_history WHERE first_owner_uid = a));
  PERFORM pg_temp.ok('H1 purge: B''s ownerless upload on the scrubbed install stays rejected',
    pg_temp.refused(pg_temp.own('del2', 'o')));
  PERFORM pg_temp.register('del1');  PERFORM pg_temp.link50('del1', b);
  PERFORM pg_temp.ok('H1 purge: the install re-registered and linked by someone else stays ineligible',
    pg_temp.refused(pg_temp.own('del1', 'o2')) AND (pg_temp.hist('del1')).transitioned);
  PERFORM pg_temp.ok('H1 purge: an unrelated install of another user keeps its eligibility',
    (pg_temp.own('ctl', 'o3'))->>'outcome' = 'claimed' AND (pg_temp.hist('ctl')).first_owner_uid = b AND NOT (pg_temp.hist('ctl')).transitioned);
  n := public.capture_history_forget_owner(b);
  PERFORM pg_temp.ok('H1 capture_history_forget_owner: scrubs by uid, idempotent, ineligible afterwards',
    n >= 1 AND public.capture_history_forget_owner(b) = 0 AND pg_temp.refused(pg_temp.own('ctl', 'o4')));
  PERFORM pg_temp.ok('H1 account deletion: nothing stored for any rejected ownerless upload',
    pg_temp.nothing_stored('del2') AND NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = 'del1' AND payload_id = 'o2'));
END $$;

-- ── consent_owner_uid residue: re-register then account deletion (Astra follow-up) ──
-- register-device nulls user_id only, so a re-registered row can keep
-- consent_owner_uid = A with A's flags. Every gate must refuse it, a new link must
-- replace it wholesale, and account deletion must erase A's uid from it.
DO $$
DECLARE a uuid := '00000000-0000-0000-0000-00000000a0c1'; b uuid := '00000000-0000-0000-0000-00000000b0c2';
        d public.capture_devices; c jsonb;
BEGIN
  INSERT INTO auth.users (id) VALUES (a), (b) ON CONFLICT DO NOTHING;
  PERFORM pg_temp.register('res1');  PERFORM pg_temp.link50('res1', a);
  PERFORM public.legacy_set_device_consent('res1', true, true);
  PERFORM pg_temp.register('res1');               -- re-register: user_id NULL, consent_owner_uid still A
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'res1';
  PERFORM pg_temp.ok('residue setup: user_id NULL, consent_owner_uid = A, flags still TRUE',
    d.user_id IS NULL AND d.consent_owner_uid = a AND d.cloud_processing_enabled AND d.ai_consent_granted, d::text);
  -- upload authorization / AI: an owner-bound A upload and an ownerless upload are both refused
  c := pg_temp.claim('res1', 'rc1', 'fp-rc1', a, 2);
  PERFORM pg_temp.ok('residue: owner-bound upload naming A is refused (owner mismatch)',
    c->>'outcome' = 'denied' AND c->>'code' = 'capture_owner_mismatch', c::text);
  c := pg_temp.own('res1', 'rc2');
  PERFORM pg_temp.ok('residue: ownerless upload is refused (consent_required)',
    c->>'outcome' = 'denied' AND c->>'code' = 'consent_required' AND NOT (c ? 'lease_token'), c::text);
  PERFORM pg_temp.ok('residue: nothing stored, no AI lease',
    NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = 'res1'));
  -- consent widening: the legacy writer refuses a row whose consent is not its linked user's
  PERFORM pg_temp.ok('residue: legacy consent write refused (capture_owner_mismatch)',
    (public.legacy_set_device_consent('res1', true, true))->>'error' = 'capture_owner_mismatch');
  -- account transition: B's link replaces the whole projection; A's flags do not survive
  PERFORM public.legacy_link_capture_device('res1', b);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'res1';
  PERFORM pg_temp.ok('residue: B link replaces the projection (owner B, A''s flags reset, version 0)',
    d.user_id = b AND d.consent_owner_uid = b AND NOT d.cloud_processing_enabled AND NOT d.ai_consent_granted
    AND d.consent_version = 0 AND d.last_revoke_generation IS NULL, d::text);
  c := pg_temp.claim('res1', 'rc4', 'fp-rc4', b, 2);
  PERFORM pg_temp.ok('residue: B gets nothing from A''s old consent (owner-bound B upload: consent_required)',
    c->>'outcome' = 'denied' AND c->>'code' = 'consent_required', c::text);

  -- account deletion erases the uid from a residue row
  PERFORM pg_temp.register('res2');  PERFORM pg_temp.link50('res2', a);
  PERFORM public.legacy_set_device_consent('res2', true, true);
  PERFORM pg_temp.register('res2');
  PERFORM public.purge_user_data(a);
  SELECT * INTO d FROM public.capture_devices WHERE install_id_hash = 'res2';
  PERFORM pg_temp.ok('purge: no capture_devices row still names the deleted user as consent owner',
    NOT EXISTS (SELECT 1 FROM public.capture_devices WHERE consent_owner_uid = a OR user_id = a));
  PERFORM pg_temp.ok('purge: the residue row is left unowned with consent cleared',
    d.user_id IS NULL AND d.consent_owner_uid IS NULL AND NOT d.cloud_processing_enabled
    AND NOT d.ai_consent_granted AND d.consent_version = 0, d::text);
  c := pg_temp.own('res2', 'rc3');
  PERFORM pg_temp.ok('purge: the scrubbed install stays transitioned and refuses uploads',
    (pg_temp.hist('res2')).transitioned AND c->>'outcome' = 'denied'
    AND NOT EXISTS (SELECT 1 FROM public.processed_captures WHERE install_id_hash = 'res2'), c::text);
  PERFORM pg_temp.ok('purge: B''s install is untouched', EXISTS (
    SELECT 1 FROM public.capture_devices WHERE install_id_hash = 'res1' AND user_id = b AND consent_owner_uid = b));
END $$;

SELECT name, ok, detail FROM _r WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'capture_state_machine_p1: failures above'; END IF;
END $$;
ROLLBACK;

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

-- claim helper: (install, payload, fp, owner, contract)
CREATE FUNCTION pg_temp.claim(i text, p text, fp text, o uuid, c int) RETURNS jsonb LANGUAGE sql AS
$$ SELECT public.capture_claim(i, 'raw-' || i, p, fp, o, c, 60) $$;
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

  -- Legacy gate: consent_owner_uid != user_id -> consent_required; guest (null/null) allowed
  UPDATE public.capture_devices SET consent_owner_uid = NULL WHERE install_id_hash = 'd2';
  c3 := pg_temp.claim('d2', 'lp0', 'f', null, 1);
  PERFORM pg_temp.ok('legacy: consent not owned by linked user -> consent_required', c3->>'code' = 'consent_required');
  UPDATE public.capture_devices SET consent_owner_uid = a WHERE install_id_hash = 'd2';
  c3 := pg_temp.claim('d3', 'g1', 'fg', null, 1);
  PERFORM pg_temp.ok('legacy guest (user_id NULL) keeps today behaviour: claimed with NULL claimed_user_id',
    c3->>'outcome' = 'claimed' AND c3->>'claimed_user_id' IS NULL, c3::text);
  c3 := pg_temp.claim('d2', 'lp1', 'f1', null, 1);
  PERFORM pg_temp.ok('legacy linked: claimed_user_id stamped from snapshot',
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
  PERFORM pg_temp.ok('set_capture_consent version <= stored is a no-op',
    (j->>'applied')::boolean IS NOT TRUE AND (SELECT cloud_processing_enabled FROM public.capture_devices WHERE install_id_hash = 'd1'), j::text);

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
  PERFORM pg_temp.ok('same-owner relink with older version does not roll consent back',
    d.consent_version = 2 AND d.ai_consent_granted, d::text);

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
  UPDATE public.user_settings SET consent_version = 7 WHERE user_id = a;
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

SELECT name, ok, detail FROM _r WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _r;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'capture_state_machine_p1: failures above'; END IF;
END $$;
ROLLBACK;

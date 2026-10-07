-- 0109_user_settings_consent_null.sql — WP-2 (manifest 0110), manifest §4.6.
--
-- user_settings consent becomes a CONSERVATIVE GLOBAL DENIAL + compatibility
-- mirror. Authority for capture AI lives per device in capture_devices.
--   ai_consent_granted, cloud_processing_enabled (names kept, see 0060):
--       NOT NULL DEFAULT true   ->   NULL-able, DEFAULT NULL
--       NULL or false = denied; true counts only with consent_version > 0
--       (supabase/functions/_shared/ai_endpoint.ts).
--   consent_version integer NOT NULL DEFAULT 0     (0 = no recorded grant)
--   consent_granted_at timestamptz NULL
--
-- BACKFILL: every existing TRUE becomes NULL. Evidence that no explicit-grant
-- record exists at b28bb001: (1) 0060 created both columns DEFAULT true, so rows
-- created without a client value are TRUE with no user action; (2) the app pushes
-- its local consent (planning_push_service / planning_outbox_queue), but the
-- server stores only the bare boolean, with no version, timestamp or provenance
-- column (those are added HERE), so a client-written TRUE cannot be told apart
-- from a defaulted TRUE; (3) no migration or function ever wrote a grant record.
-- Per §4.6 "unproven TRUE is backfilled to NULL"; none is kept. FALSE stays FALSE.
-- Effect: JWT-path AI (ai_endpoint) for existing users is denied until an
-- explicit grant bumps consent_version (a later client unit). The capture relay
-- via capture_devices is unaffected.
--
-- The data change runs with USER triggers disabled on user_settings so it does
-- not bump revision / updated_at / sync_seq of every settings row (consent is
-- never pulled or copied between devices, so there is nothing to replicate).
--
-- DATA CHANGE: the rollback restores defaults, not the data (see its header).
-- PITR is the only way back to the old TRUE values.

BEGIN;

ALTER TABLE public.user_settings
  ALTER COLUMN ai_consent_granted DROP NOT NULL,
  ALTER COLUMN ai_consent_granted SET DEFAULT NULL,
  ALTER COLUMN cloud_processing_enabled DROP NOT NULL,
  ALTER COLUMN cloud_processing_enabled SET DEFAULT NULL;

ALTER TABLE public.user_settings
  ADD COLUMN IF NOT EXISTS consent_version integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS consent_granted_at timestamptz NULL;

ALTER TABLE public.user_settings DISABLE TRIGGER USER;
UPDATE public.user_settings
   SET ai_consent_granted = CASE WHEN ai_consent_granted IS TRUE THEN NULL ELSE ai_consent_granted END,
       cloud_processing_enabled = CASE WHEN cloud_processing_enabled IS TRUE THEN NULL ELSE cloud_processing_enabled END
 WHERE ai_consent_granted IS TRUE OR cloud_processing_enabled IS TRUE;
ALTER TABLE public.user_settings ENABLE TRIGGER USER;

COMMIT;

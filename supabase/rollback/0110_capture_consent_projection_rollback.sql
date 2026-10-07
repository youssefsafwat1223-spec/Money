-- ROLLBACK for 0110_capture_consent_projection.sql
--
-- Drops the consent RPCs and the projection columns (consent owner/version, owner_generation,
-- consent_client_generation, last_revoke_generation, owner_changed_at). Existing flag values
-- on capture_devices are left as they are. Roll back 0111 and redeploy nothing
-- that calls these RPCs first (the P1 edge functions do).
BEGIN;

DROP FUNCTION IF EXISTS public.unlink_capture_device(text);
DROP FUNCTION IF EXISTS public.legacy_set_device_consent(text, boolean, boolean);
DROP FUNCTION IF EXISTS public.legacy_link_capture_device(text, uuid);
DROP FUNCTION IF EXISTS public.revoke_capture_consent(text, text, uuid, bigint, integer);
DROP FUNCTION IF EXISTS public.set_capture_consent(text, text, boolean, boolean, integer, bigint);
DROP FUNCTION IF EXISTS public.link_capture_device(text, text, boolean, boolean, integer, bigint);
DROP FUNCTION IF EXISTS public.capture_revoke_fanout(text, uuid, boolean, boolean, integer);

ALTER TABLE public.capture_devices
  DROP COLUMN IF EXISTS owner_changed_at,
  DROP COLUMN IF EXISTS last_revoke_generation,
  DROP COLUMN IF EXISTS consent_client_generation,
  DROP COLUMN IF EXISTS owner_generation,
  DROP COLUMN IF EXISTS consent_version,
  DROP COLUMN IF EXISTS consent_owner_uid;

COMMIT;

-- ROLLBACK for 0110_capture_consent_projection.sql
--
-- Drops the consent RPCs and the two projection columns. Existing flag values
-- on capture_devices are left as they are. Roll back 0111 and redeploy nothing
-- that calls these RPCs first (the P1 edge functions do).
BEGIN;

DROP FUNCTION IF EXISTS public.unlink_capture_device(text);
DROP FUNCTION IF EXISTS public.legacy_set_device_consent(text, boolean, boolean);
DROP FUNCTION IF EXISTS public.legacy_link_capture_device(text, uuid);
DROP FUNCTION IF EXISTS public.set_capture_consent(text, text, boolean, boolean, integer);
DROP FUNCTION IF EXISTS public.link_capture_device(text, text, boolean, boolean, integer);
DROP FUNCTION IF EXISTS public.capture_revoke_fanout(text, uuid, boolean, boolean, integer);

ALTER TABLE public.capture_devices
  DROP COLUMN IF EXISTS consent_version,
  DROP COLUMN IF EXISTS consent_owner_uid;

COMMIT;

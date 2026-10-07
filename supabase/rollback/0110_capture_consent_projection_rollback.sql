-- ROLLBACK for 0110_capture_consent_projection.sql
--
-- Drops the consent RPCs and the projection columns (consent owner/version, owner_generation,
-- consent_client_generation, last_revoke_generation) and the H1 install owner history (table,
-- guard + tracker triggers, capture_history_forget_owner). Existing flag values on capture_devices
-- are left as they are. Roll back 0113 (purge_user_data calls capture_history_forget_owner) and
-- 0111 and redeploy nothing that calls these RPCs first (the P1 edge functions do).
-- WARNING: the history is destroyed. Re-applying 0110 records every then-existing install as
-- UNTRUSTED (never eligible for ownerless uploads): fail closed, never a widening.
BEGIN;

DROP TRIGGER IF EXISTS trg_capture_devices_owner_history ON public.capture_devices;
DROP FUNCTION IF EXISTS public.capture_history_forget_owner(uuid);
DROP FUNCTION IF EXISTS public.capture_device_history_track();
DROP TABLE IF EXISTS public.capture_install_owner_history;
DROP FUNCTION IF EXISTS public.capture_install_owner_history_guard();

DROP FUNCTION IF EXISTS public.unlink_capture_device(text);
DROP FUNCTION IF EXISTS public.legacy_set_device_consent(text, boolean, boolean);
DROP FUNCTION IF EXISTS public.legacy_link_capture_device(text, uuid);
DROP FUNCTION IF EXISTS public.revoke_capture_consent(text, text, uuid, bigint, integer);
DROP FUNCTION IF EXISTS public.set_capture_consent(text, text, boolean, boolean, integer, bigint);
DROP FUNCTION IF EXISTS public.link_capture_device(text, text, boolean, boolean, integer, bigint);
DROP FUNCTION IF EXISTS public.capture_revoke_fanout(text, uuid, boolean, boolean, integer);

ALTER TABLE public.capture_devices
  DROP COLUMN IF EXISTS last_revoke_generation,
  DROP COLUMN IF EXISTS consent_client_generation,
  DROP COLUMN IF EXISTS owner_generation,
  DROP COLUMN IF EXISTS consent_version,
  DROP COLUMN IF EXISTS consent_owner_uid;

COMMIT;

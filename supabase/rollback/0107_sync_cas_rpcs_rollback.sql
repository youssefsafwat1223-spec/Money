-- ROLLBACK for 0107_sync_cas_rpcs.sql
--
-- Drops the five sync_* functions and the lock helper. No client uses them yet
-- (capability revision_cas is false), and they own no data.
BEGIN;

DROP FUNCTION IF EXISTS public.sync_cas_tombstone(text, uuid, uuid, uuid, integer);
DROP FUNCTION IF EXISTS public.sync_cas_update(text, uuid, uuid, uuid, integer, jsonb);
DROP FUNCTION IF EXISTS public.sync_insert_if_absent(text, uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.sync_lock_epoch();
DROP FUNCTION IF EXISTS public.sync_normalize(text, jsonb, text[]);
DROP FUNCTION IF EXISTS public.sync_family(text);

COMMIT;

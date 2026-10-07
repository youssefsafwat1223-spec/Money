-- ROLLBACK for 0114_server_capabilities_sync_keys.sql
--
-- Restores the 0102 body (awaiting_fx_transactions only). Clients read absent
-- keys as unsupported, the same as false, so this is behaviour-neutral.
BEGIN;

CREATE OR REPLACE FUNCTION public.qirsh_server_capabilities()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT jsonb_build_object('awaiting_fx_transactions', true);
$$;

REVOKE ALL ON FUNCTION public.qirsh_server_capabilities() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qirsh_server_capabilities() TO authenticated;

COMMIT;

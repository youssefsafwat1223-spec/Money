-- 0114_server_capabilities_sync_keys.sql — WP-2 / CAP-1 (manifest 0115):
-- qirsh_server_capabilities() gains the sync/capture keys, ALL false.
--
-- Convention from 0102: CREATE OR REPLACE with every previous key preserved
-- exactly (awaiting_fx_transactions = true) plus the new ones. The Dart parser
-- (server_capabilities.dart) reads a key only as `== true`, so false means
-- unsupported. min_supported_seq and min_client_build are false until a floor /
-- cut-off exists; a later migration may turn them into numbers, which the same
-- `== true` reader still treats as unsupported.
--
-- Each key is the kill switch for its feature (manifest §8); none is advertised
-- until its gate passes.

BEGIN;

CREATE OR REPLACE FUNCTION public.qirsh_server_capabilities()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'awaiting_fx_transactions', true,
    'capture_contract_v2', false,
    'sync_seq', false,
    'revision_cas', false,
    'replica_epoch', false,
    'min_supported_seq', false,
    'min_client_build', false
  );
$$;

REVOKE ALL ON FUNCTION public.qirsh_server_capabilities() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qirsh_server_capabilities() TO authenticated;

COMMIT;

-- ROLLBACK for 0111_capture_state_machine.sql
--
-- Drops the RPCs, the default-state trigger and the state-machine columns. Rows in
-- 'processing'/'retryable'/'consumed'/'expired' have no legacy equivalent: they are
-- removed first (consumed tombstones are already content-free; the device falls back
-- to its local parser for the rest). The old direct-write code must NOT be
-- redeployed (manifest §13).
BEGIN;

DROP FUNCTION IF EXISTS public.capture_ack(text, uuid, text[]);
DROP FUNCTION IF EXISTS public.capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb);
DROP FUNCTION IF EXISTS public.capture_ai_dispatch(text, text, integer);
DROP FUNCTION IF EXISTS public.capture_claim(text, text, text, text, uuid, integer, integer, bigint);
DROP FUNCTION IF EXISTS public.capture_row_json(public.processed_captures);
DROP FUNCTION IF EXISTS public.capture_queue_push(text, text, text, uuid, text);

DROP TRIGGER IF EXISTS trg_processed_captures_default_state ON public.processed_captures;
DROP FUNCTION IF EXISTS public.processed_captures_default_state();
DROP INDEX IF EXISTS public.idx_processed_captures_install_state_created;

DELETE FROM public.processed_captures WHERE state IN ('processing', 'retryable', 'consumed', 'expired');

ALTER TABLE public.processed_captures
  DROP CONSTRAINT IF EXISTS processed_captures_state_check,
  DROP COLUMN IF EXISTS client_owner_generation,
  DROP COLUMN IF EXISTS consumed_by_install_hash,
  DROP COLUMN IF EXISTS consumed_at,
  DROP COLUMN IF EXISTS possible_duplicate,
  DROP COLUMN IF EXISTS validator_result,
  DROP COLUMN IF EXISTS ai_invoked,
  DROP COLUMN IF EXISTS ai_consent_version,
  DROP COLUMN IF EXISTS ai_started_at,
  DROP COLUMN IF EXISTS consent_version,
  DROP COLUMN IF EXISTS consent_owner_uid,
  DROP COLUMN IF EXISTS owner_uid,
  DROP COLUMN IF EXISTS next_attempt_at,
  DROP COLUMN IF EXISTS attempts,
  DROP COLUMN IF EXISTS lease_token,
  DROP COLUMN IF EXISTS lease_until,
  DROP COLUMN IF EXISTS state;

COMMIT;

-- ROLLBACK for 0112_capture_notifications_retention.sql
--
-- Restores the 0111 bodies of capture_queue_push / capture_row_json (by re-running the
-- idempotent 0111 migration from the repo root, never by hand-editing), the 0012/0033
-- prune bodies and the daily schedule, and drops the CAP-3 objects.
-- NOT reversible by this script: rows already expired/pruned, the de-duplicated retry
-- rows and the 30-day notification_logs pruning (data) -- PITR only.
-- psql usage (from the repo root):  psql -f supabase/rollback/0112_capture_notifications_retention_rollback.sql
BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prune-processed-captures-hourly') THEN
    PERFORM cron.unschedule('prune-processed-captures-hourly');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prune-ai-request-idempotency-daily') THEN
    PERFORM cron.unschedule('prune-ai-request-idempotency-daily');
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.capture_retry_fence(text, text);

-- 0033 / 0012 bodies (30 days by created_at; fingerprints 7 days) and the daily job.
CREATE OR REPLACE FUNCTION public.run_prune_processed_captures()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  captures_deleted BIGINT;
  fingerprints_deleted BIGINT;
BEGIN
  DELETE FROM processed_captures
  WHERE created_at < NOW() - INTERVAL '30 days';
  GET DIAGNOSTICS captures_deleted = ROW_COUNT;

  DELETE FROM capture_fingerprints
  WHERE seen_at < NOW() - INTERVAL '7 days';
  GET DIAGNOSTICS fingerprints_deleted = ROW_COUNT;

  RAISE LOG 'prune_processed_captures: captures=% fingerprints=%',
    captures_deleted, fingerprints_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION public.prune_processed_captures()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  DELETE FROM processed_captures
  WHERE created_at < NOW() - INTERVAL '30 days';

  DELETE FROM capture_fingerprints
  WHERE seen_at < NOW() - INTERVAL '7 days';
$$;

SELECT cron.schedule('prune-processed-captures-daily', '15 3 * * *', $$SELECT run_prune_processed_captures()$$);

ALTER TABLE public.notification_retry_queue
  DROP CONSTRAINT IF EXISTS notification_retry_queue_notification_log_id_key;
DROP INDEX IF EXISTS public.idx_notification_logs_created;
ALTER TABLE public.notification_logs DROP COLUMN IF EXISTS install_id_hash;

-- Restore the 0111 bodies of capture_queue_push / capture_row_json (they do not use the
-- columns dropped below). 0111 is idempotent (add column if not exists, create or replace).
\i supabase/migrations/0111_capture_state_machine.sql

ALTER TABLE public.processed_captures DROP COLUMN IF EXISTS push_attempted_at;
COMMIT;

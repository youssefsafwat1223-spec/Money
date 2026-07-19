-- Fixes a bug found during live verification of migration 0052: the deployed
-- Edge Function `process-notification-retries` authorized callers by
-- comparing the request's Authorization header against
-- `Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')`. That name is platform-reserved
-- and its value is rotated/managed by Supabase itself — confirmed (by live
-- testing) to differ from the project's actual service-role JWT/key
-- obtainable via `supabase projects api-keys`, so its plaintext is not
-- something any caller, including this dispatch function, could ever be
-- given to present back. This is the exact same problem already solved for
-- purge-scheduled-deletions via a dedicated PURGE_WORKER_SECRET (see that
-- function's own header comment) — apply the identical fix here.
--
-- Owner action required: `supabase secrets set NOTIFICATION_RETRY_WORKER_SECRET=<a-random-value>`
-- and store that same value in Vault under 'notification_retry_worker_secret'
-- (see updated instructions below). This replaces the previous
-- 'service_role_key' Vault secret requirement from 0052 — that secret, if
-- already created, is no longer read by this function and can be left in
-- place or removed at the owner's discretion.

CREATE OR REPLACE FUNCTION run_notification_retry_dispatch()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  worker_secret TEXT;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO worker_secret
    FROM vault.decrypted_secrets WHERE name = 'notification_retry_worker_secret' LIMIT 1;

  IF project_url IS NULL OR worker_secret IS NULL THEN
    RAISE LOG 'notification retry dispatch skipped: Vault secrets not configured yet';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := project_url || '/functions/v1/process-notification-retries',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION run_notification_retry_dispatch() FROM PUBLIC;
REVOKE ALL ON FUNCTION run_notification_retry_dispatch() FROM anon, authenticated;

-- No change to the cron.schedule call itself — same job name, same
-- schedule, same function signature, so cron.schedule's idempotent-by-name
-- behavior means this migration does not touch cron.job at all; the
-- existing job simply calls the newly-replaced function body on its next run.

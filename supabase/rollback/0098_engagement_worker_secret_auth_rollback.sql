-- Rollback for 0098 — restore the 0057 service-role dispatch auth.
--
-- WARNING, read before running. 0057's contract is KNOWN BROKEN: it reads Vault
-- `service_role_key` and presents it to Edge Functions that compare against the
-- platform-reserved `SUPABASE_SERVICE_ROLE_KEY`, whose value Supabase rotates
-- and which differs from the project's real service-role JWT. Rolling back
-- therefore returns these four endpoints to being permanently unreachable —
-- which is a SAFE state (fail-closed, no pushes) but not a working one.
--
-- Roll back only to undo a bad 0098 apply, never as a fix. Reverting the Edge
-- Functions to their pre-0098 auth is a separate, manual step: this file cannot
-- redeploy them, so a rollback WITHOUT that redeploy leaves the dispatchers
-- sending service_role_key to functions expecting a worker secret. Both halves
-- must move together.

CREATE OR REPLACE FUNCTION trigger_evaluate_budgets()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  service_key TEXT;
  payload     JSONB;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO service_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;
  IF project_url IS NULL OR service_key IS NULL THEN
    RAISE LOG 'evaluate_budgets skipped: Vault secrets not configured';
    RETURN NEW;
  END IF;
  payload := jsonb_build_object(
    'type', TG_OP, 'table', TG_TABLE_NAME, 'record', row_to_json(NEW),
    'old_record', CASE WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD) ELSE null END);
  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-budgets',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || service_key),
    body := payload);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_evaluate_gamification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  service_key TEXT;
  payload     JSONB;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO service_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;
  IF project_url IS NULL OR service_key IS NULL THEN
    RAISE LOG 'evaluate_gamification skipped: Vault secrets not configured';
    RETURN NEW;
  END IF;
  payload := jsonb_build_object(
    'type', TG_OP, 'table', TG_TABLE_NAME, 'record', row_to_json(NEW),
    'old_record', null);
  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-gamification',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || service_key),
    body := payload);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trigger_evaluate_goals()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  service_key TEXT;
  payload     JSONB;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO service_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;
  IF project_url IS NULL OR service_key IS NULL THEN
    RAISE LOG 'evaluate_goals skipped: Vault secrets not configured';
    RETURN NEW;
  END IF;
  payload := jsonb_build_object(
    'type', TG_OP, 'table', TG_TABLE_NAME, 'record', row_to_json(NEW),
    'old_record', CASE WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD) ELSE null END);
  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-goals',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || service_key),
    body := payload);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION run_cron_daily_reminders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  service_key TEXT;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO service_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;
  IF project_url IS NULL OR service_key IS NULL THEN
    RAISE LOG 'cron_daily_reminders skipped: Vault secrets not configured';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url := project_url || '/functions/v1/cron-daily-reminders',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || service_key),
    body := '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION run_cron_daily_reminders() FROM PUBLIC;
REVOKE ALL ON FUNCTION run_cron_daily_reminders() FROM anon, authenticated;

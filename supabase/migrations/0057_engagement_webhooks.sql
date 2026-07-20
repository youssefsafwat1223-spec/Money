-- Webhooks for gamification and engagement edge functions

CREATE EXTENSION IF NOT EXISTS pg_net;

-- Function to trigger evaluate-budgets
CREATE OR REPLACE FUNCTION trigger_evaluate_budgets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  service_key TEXT;
  payload JSONB;
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
    'type', TG_OP,
    'table', TG_TABLE_NAME,
    'record', row_to_json(NEW),
    'old_record', CASE WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD) ELSE null END
  );

  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-budgets',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_key
    ),
    body := payload
  );
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS evaluate_budgets_trigger ON user_transactions;
CREATE TRIGGER evaluate_budgets_trigger
AFTER INSERT OR UPDATE ON user_transactions
FOR EACH ROW
EXECUTE FUNCTION trigger_evaluate_budgets();

-- Function to trigger evaluate-gamification
CREATE OR REPLACE FUNCTION trigger_evaluate_gamification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  service_key TEXT;
  payload JSONB;
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
    'type', TG_OP,
    'table', TG_TABLE_NAME,
    'record', row_to_json(NEW)
  );

  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-gamification',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_key
    ),
    body := payload
  );
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS evaluate_gamification_trigger ON user_transactions;
CREATE TRIGGER evaluate_gamification_trigger
AFTER INSERT ON user_transactions
FOR EACH ROW
EXECUTE FUNCTION trigger_evaluate_gamification();

-- Function to trigger evaluate-goals
CREATE OR REPLACE FUNCTION trigger_evaluate_goals()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url TEXT;
  service_key TEXT;
  payload JSONB;
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
    'type', TG_OP,
    'table', TG_TABLE_NAME,
    'record', row_to_json(NEW)
  );

  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-goals',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_key
    ),
    body := payload
  );
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS evaluate_goals_trigger ON user_goals;
CREATE TRIGGER evaluate_goals_trigger
AFTER UPDATE ON user_goals
FOR EACH ROW
EXECUTE FUNCTION trigger_evaluate_goals();


-- Cron Job for daily reminders
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
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_key
    ),
    body := '{}'::jsonb
  );
END;
$$;

SELECT cron.schedule(
  'cron-daily-reminders-job',
  '0 0 * * *',
  $$SELECT run_cron_daily_reminders()$$
);

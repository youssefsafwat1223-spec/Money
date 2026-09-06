-- 0098 — Replace the deprecated service-role dispatch auth for the four
-- engagement endpoints with dedicated worker secrets.
--
-- WHY. 0057 wired four dispatchers (three trigger-driven, one cron) that read
-- Vault `service_role_key` and presented it as the bearer. The receiving Edge
-- Functions compared that bearer against `Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')`.
-- That env name is PLATFORM-RESERVED: Supabase manages and rotates its value,
-- and live testing during 0052/0053 confirmed it differs from the project's
-- real service-role JWT. So the comparison could never succeed, and — because
-- production Vault has no `service_role_key` row at all — the dispatchers also
-- short-circuited on the NULL check. Both halves were broken, which is why the
-- engagement pipeline was silently dead rather than loudly failing.
--
-- 0053 already solved this exact problem for process-notification-retries
-- (and 0065/purge-scheduled-deletions before it). This applies the identical,
-- proven contract rather than inventing a third pattern.
--
-- SECRET DESIGN. Two secrets, not four and not one:
--   engagement_worker_secret -> evaluate-budgets, evaluate-goals,
--     evaluate-gamification. One trust domain: same caller (this trigger
--     layer), same capability (forge a push for an arbitrary user_id), same
--     rotation lifecycle. Separate secrets would not shrink the blast radius,
--     since all of them would live in this same Vault and the same Edge env.
--   reminders_worker_secret -> cron-daily-reminders. Deliberately separate:
--     that endpoint is a retired no-op with no data access, so it must not
--     carry a credential that also unlocks the three live functions. This is
--     where least privilege actually buys something.
--
-- NO BEHAVIOR CHANGE. Payload shapes, URLs, trigger definitions and cron
-- schedules are untouched; only the credential read and presented changes.
--
-- OWNER ACTION (deliberately NOT performed by this migration):
--   supabase secrets set ENGAGEMENT_WORKER_SECRET=<random> REMINDERS_WORKER_SECRET=<random>
--   and store the SAME values in Vault as 'engagement_worker_secret' and
--   'reminders_worker_secret'. Until then every dispatcher fails closed and
--   logs a skip, which is the same safe state as today.

-- ── evaluate-budgets ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trigger_evaluate_budgets()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url   TEXT;
  worker_secret TEXT;
  payload       JSONB;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO worker_secret
    FROM vault.decrypted_secrets WHERE name = 'engagement_worker_secret' LIMIT 1;

  -- Fail closed. A missing secret must not fall back to any other credential.
  IF project_url IS NULL OR worker_secret IS NULL THEN
    RAISE LOG 'evaluate_budgets skipped: engagement worker secret not configured';
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
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := payload
  );

  RETURN NEW;
END;
$$;

-- ── evaluate-gamification ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trigger_evaluate_gamification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url   TEXT;
  worker_secret TEXT;
  payload       JSONB;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO worker_secret
    FROM vault.decrypted_secrets WHERE name = 'engagement_worker_secret' LIMIT 1;

  IF project_url IS NULL OR worker_secret IS NULL THEN
    RAISE LOG 'evaluate_gamification skipped: engagement worker secret not configured';
    RETURN NEW;
  END IF;

  -- Payload byte-identical to 0057: gamification fires AFTER INSERT only and
  -- has NO old_record key. Adding one (even as null) would be a behaviour
  -- change this migration explicitly promises not to make.
  payload := jsonb_build_object(
    'type', TG_OP,
    'table', TG_TABLE_NAME,
    'record', row_to_json(NEW)
  );

  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-gamification',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := payload
  );

  RETURN NEW;
END;
$$;

-- ── evaluate-goals ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trigger_evaluate_goals()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url   TEXT;
  worker_secret TEXT;
  payload       JSONB;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO worker_secret
    FROM vault.decrypted_secrets WHERE name = 'engagement_worker_secret' LIMIT 1;

  IF project_url IS NULL OR worker_secret IS NULL THEN
    RAISE LOG 'evaluate_goals skipped: engagement worker secret not configured';
    RETURN NEW;
  END IF;

  -- Payload byte-identical to 0057. Goals fires AFTER UPDATE, so an old_record
  -- would be meaningful — but 0057 does not send one and evaluate-goals does
  -- not read one. Adding it here would be a silent contract change.
  payload := jsonb_build_object(
    'type', TG_OP,
    'table', TG_TABLE_NAME,
    'record', row_to_json(NEW)
  );

  PERFORM net.http_post(
    url := project_url || '/functions/v1/evaluate-goals',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := payload
  );

  RETURN NEW;
END;
$$;

-- ── cron-daily-reminders ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION run_cron_daily_reminders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url   TEXT;
  worker_secret TEXT;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO worker_secret
    FROM vault.decrypted_secrets WHERE name = 'reminders_worker_secret' LIMIT 1;

  IF project_url IS NULL OR worker_secret IS NULL THEN
    RAISE LOG 'cron_daily_reminders skipped: reminders worker secret not configured';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := project_url || '/functions/v1/cron-daily-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION run_cron_daily_reminders() FROM PUBLIC;
REVOKE ALL ON FUNCTION run_cron_daily_reminders() FROM anon, authenticated;
REVOKE ALL ON FUNCTION trigger_evaluate_budgets() FROM PUBLIC;
REVOKE ALL ON FUNCTION trigger_evaluate_budgets() FROM anon, authenticated;
REVOKE ALL ON FUNCTION trigger_evaluate_gamification() FROM PUBLIC;
REVOKE ALL ON FUNCTION trigger_evaluate_gamification() FROM anon, authenticated;
REVOKE ALL ON FUNCTION trigger_evaluate_goals() FROM PUBLIC;
REVOKE ALL ON FUNCTION trigger_evaluate_goals() FROM anon, authenticated;

-- ── POSTCONDITIONS ──────────────────────────────────────────────────────────
-- Assert the migration achieved what it claims, so a partial apply fails loudly
-- rather than leaving a half-migrated auth path.
DO $$
DECLARE
  d TEXT;
  fn TEXT;
BEGIN
  -- 1) No engagement dispatcher may still read service_role_key.
  FOREACH fn IN ARRAY ARRAY['trigger_evaluate_budgets','trigger_evaluate_gamification',
                            'trigger_evaluate_goals','run_cron_daily_reminders'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO d
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = fn;
    IF d IS NULL THEN
      RAISE EXCEPTION '0098 postcondition: function % is missing', fn;
    END IF;
    IF d LIKE '%service_role_key%' THEN
      RAISE EXCEPTION '0098 postcondition: % still reads service_role_key', fn;
    END IF;
    IF d NOT LIKE '%engagement_worker_secret%' AND d NOT LIKE '%reminders_worker_secret%' THEN
      RAISE EXCEPTION '0098 postcondition: % reads no dedicated worker secret', fn;
    END IF;
    IF d NOT LIKE '%project_url%' THEN
      RAISE EXCEPTION '0098 postcondition: % no longer reads project_url', fn;
    END IF;
    -- Fail-closed guard must survive.
    IF d NOT LIKE '%IS NULL%' THEN
      RAISE EXCEPTION '0098 postcondition: % lost its fail-closed NULL guard', fn;
    END IF;
  END LOOP;

  -- 2) The reminders endpoint must NOT share the engagement secret.
  SELECT pg_get_functiondef(p.oid) INTO d
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'run_cron_daily_reminders';
  IF d LIKE '%engagement_worker_secret%' THEN
    RAISE EXCEPTION '0098 postcondition: reminders must not hold the engagement secret';
  END IF;

  -- 3) Triggers still exist, on the same tables, pointing at the same functions.
  -- Assert the trigger's TARGET FUNCTION too. Checking only that a trigger of
  -- the right name exists on the right table would still pass if it had been
  -- repointed at some other function.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                   JOIN pg_class c ON c.oid = t.tgrelid
                   JOIN pg_proc p ON p.oid = t.tgfoid
                  WHERE t.tgname = 'evaluate_budgets_trigger'
                    AND c.relname = 'user_transactions'
                    AND p.proname = 'trigger_evaluate_budgets') THEN
    RAISE EXCEPTION '0098 postcondition: evaluate_budgets_trigger missing or retargeted';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                   JOIN pg_class c ON c.oid = t.tgrelid
                   JOIN pg_proc p ON p.oid = t.tgfoid
                  WHERE t.tgname = 'evaluate_gamification_trigger'
                    AND c.relname = 'user_transactions'
                    AND p.proname = 'trigger_evaluate_gamification') THEN
    RAISE EXCEPTION '0098 postcondition: evaluate_gamification_trigger missing or retargeted';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                   JOIN pg_class c ON c.oid = t.tgrelid
                   JOIN pg_proc p ON p.oid = t.tgfoid
                  WHERE t.tgname = 'evaluate_goals_trigger'
                    AND c.relname = 'user_goals'
                    AND p.proname = 'trigger_evaluate_goals') THEN
    RAISE EXCEPTION '0098 postcondition: evaluate_goals_trigger missing or retargeted';
  END IF;

  -- 4) The cron job still exists and still calls the same dispatcher. Schedule
  --    is deliberately not asserted by value here — only that it is unchanged
  --    in target — because this migration does not touch cron.schedule at all.
  IF NOT EXISTS (SELECT 1 FROM cron.job
                  WHERE jobname = 'cron-daily-reminders-job'
                    AND command LIKE '%run_cron_daily_reminders%') THEN
    RAISE EXCEPTION '0098 postcondition: cron-daily-reminders-job missing or retargeted';
  END IF;

  RAISE LOG '0098 postconditions passed';
END $$;

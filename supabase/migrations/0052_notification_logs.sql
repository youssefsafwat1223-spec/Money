-- Phase 1 of the production-grade notification tracking system
-- (docs/NOTIFICATION_PIPELINE_AUDIT.md). One unified log for every
-- notification attempt across the channels that exist today: Flutter local
-- notifications (iOS/Android), the iOS Shortcut's local fallback
-- notification, and server-sent APNs pushes.
--
-- IMPORTANT: APNs gives no delivery receipt over its HTTP/2 API. 'sent' means
-- "handed to Apple/the OS successfully," not "the device displayed it." There
-- is deliberately no 'delivered' status in this phase — see the audit doc.
--
-- Never store raw bank SMS text, full message bodies, or device tokens here.
-- `payload` is for routing/diagnostics only (title/body/route/type), already
-- sanitized by the caller before this table sees it.

-- Lets process-ios-sms reuse the same notification_log_id across an
-- idempotent replay/retry of the same payload instead of minting a new one
-- per attempt (kept nullable/backward-compatible; existing rows are simply
-- untracked by the new pipeline).
ALTER TABLE public.processed_captures
  ADD COLUMN IF NOT EXISTS notification_log_id UUID NULL;

CREATE TABLE IF NOT EXISTS public.notification_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  install_id TEXT NOT NULL,
  notification_type TEXT NOT NULL,
  -- Nullable: an 'opened' event recorded from a notification tap cannot
  -- always distinguish apns from ios_shortcut_local (both attach the same
  -- "source": "ios_shortcut" field — see AppDelegate.swift's tap handler),
  -- so the client omits channel on that specific upsert rather than risk
  -- overwriting an already-correct value with a guess.
  channel TEXT NULL CHECK (
    channel IN ('local_ios', 'local_android', 'ios_shortcut_local', 'apns')
  ),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'queued', 'sent', 'opened', 'failed')
  ),
  related_entity_type TEXT NULL,
  related_entity_id TEXT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  error_code TEXT NULL,
  error_reason TEXT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  device_platform TEXT NULL CHECK (device_platform IN ('ios', 'android')),
  apns_environment TEXT NULL CHECK (apns_environment IN ('sandbox', 'production')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  queued_at TIMESTAMPTZ NULL,
  sent_at TIMESTAMPTZ NULL,
  opened_at TIMESTAMPTZ NULL,
  failed_at TIMESTAMPTZ NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notification_logs_user_created
  ON public.notification_logs(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_logs_install
  ON public.notification_logs(install_id);

CREATE INDEX IF NOT EXISTS idx_notification_logs_status
  ON public.notification_logs(status);

CREATE INDEX IF NOT EXISTS idx_notification_logs_type
  ON public.notification_logs(notification_type);

CREATE INDEX IF NOT EXISTS idx_notification_logs_related_entity
  ON public.notification_logs(related_entity_type, related_entity_id)
  WHERE related_entity_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notification_logs_failed
  ON public.notification_logs(created_at DESC)
  WHERE status = 'failed';

-- Reuses the shared trigger function first defined in 0014_user_ledger.sql.
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notification_logs_updated_at ON public.notification_logs;
CREATE TRIGGER trg_notification_logs_updated_at
  BEFORE UPDATE ON public.notification_logs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Status can only move forward (pending < queued < sent/failed < opened),
-- enforced here rather than in each client/Edge Function so every write
-- path (local outbox sync, process-ios-sms, process-notification-retries,
-- a duplicate/out-of-order event replay, or a manual admin update) is
-- protected uniformly. A regressive write (e.g. an 'opened' event syncing
-- after a 'sent' event, or a stale retry failure landing after a
-- newer success) silently keeps the current status instead of erroring —
-- the caller's write still succeeds (other columns like error_code/
-- retry_count still apply), it just can't move status backward.
-- 'sent' and 'failed' share a rank so a failed attempt can still be
-- recorded after 'sent' or vice versa (retry-recovery); only 'opened' is
-- strictly terminal-most.
CREATE OR REPLACE FUNCTION public.protect_notification_log_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  old_rank INT;
  new_rank INT;
BEGIN
  old_rank := CASE OLD.status
    WHEN 'pending' THEN 0
    WHEN 'queued' THEN 1
    WHEN 'sent' THEN 2
    WHEN 'failed' THEN 2
    WHEN 'opened' THEN 3
    ELSE 0
  END;
  new_rank := CASE NEW.status
    WHEN 'pending' THEN 0
    WHEN 'queued' THEN 1
    WHEN 'sent' THEN 2
    WHEN 'failed' THEN 2
    WHEN 'opened' THEN 3
    ELSE 0
  END;
  IF new_rank < old_rank THEN
    NEW.status := OLD.status;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notification_logs_status_monotonic
  ON public.notification_logs;
CREATE TRIGGER trg_notification_logs_status_monotonic
  BEFORE UPDATE ON public.notification_logs
  FOR EACH ROW EXECUTE FUNCTION public.protect_notification_log_status();

ALTER TABLE public.notification_logs ENABLE ROW LEVEL SECURITY;

-- Client access is scoped to the authenticated owner only. Rows written by
-- Edge Functions for a not-yet-linked device (user_id IS NULL, e.g. a guest
-- capture before sign-in) are invisible to every client until claimed —
-- there is no "own install, no account" read path here, matching how
-- capture_devices/processed_captures already deny all direct client access
-- for the pre-auth case. Edge Functions use the service_role key and bypass
-- RLS entirely regardless of these policies.
DROP POLICY IF EXISTS notification_logs_select_own ON public.notification_logs;
CREATE POLICY notification_logs_select_own
  ON public.notification_logs FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS notification_logs_insert_own ON public.notification_logs;
CREATE POLICY notification_logs_insert_own
  ON public.notification_logs FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS notification_logs_update_own ON public.notification_logs;
CREATE POLICY notification_logs_update_own
  ON public.notification_logs FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Append-only from the client's perspective — no delete policy, so
-- authenticated users can never delete their own log rows (service_role
-- retention/pruning jobs bypass RLS as usual).

-- ── Bounded APNs retry queue ──────────────────────────────────────────────
-- Transient APNs failures (429/500/503/network) get one durable retry
-- record instead of a blocking sleep loop inside process-ios-sms. A
-- separate Edge Function (process-notification-retries) drains due rows —
-- see its wiring below. Permanent failures (BadDeviceToken,
-- DeviceTokenNotForTopic, TopicDisallowed, BadTopic, PayloadEmpty,
-- PayloadTooLarge) never get a row here at all.
CREATE TABLE IF NOT EXISTS public.notification_retry_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_log_id UUID NOT NULL
    REFERENCES public.notification_logs(id) ON DELETE CASCADE,
  install_id_hash TEXT NOT NULL,
  payload_id TEXT NOT NULL,
  attempt_number INTEGER NOT NULL DEFAULT 1,
  max_attempts INTEGER NOT NULL DEFAULT 5,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_error_code TEXT NULL,
  resolved_at TIMESTAMPTZ NULL,
  -- Set atomically by claim_notification_retries() when a worker picks up
  -- this row, so two overlapping dispatch invocations (e.g. a slow run
  -- overlapping the next 5-minute cron tick) can never both send the same
  -- APNs push for the same row. A claim older than the staleness window is
  -- treated as an abandoned worker (crashed/timed out) and becomes
  -- reclaimable again — see the function below.
  claimed_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notification_retry_queue_due
  ON public.notification_retry_queue(next_attempt_at)
  WHERE resolved_at IS NULL;

DROP TRIGGER IF EXISTS trg_notification_retry_queue_updated_at
  ON public.notification_retry_queue;
CREATE TRIGGER trg_notification_retry_queue_updated_at
  BEFORE UPDATE ON public.notification_retry_queue
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Edge-Function-only, same convention as capture_devices/processed_captures
-- in 0012_ios_capture_pipeline.sql — no direct client access at all.
ALTER TABLE public.notification_retry_queue ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notification_retry_queue_no_direct_access
  ON public.notification_retry_queue;
CREATE POLICY notification_retry_queue_no_direct_access
  ON public.notification_retry_queue
  USING (false)
  WITH CHECK (false);

-- Atomically claims up to p_limit due, unclaimed retry rows so concurrent
-- dispatch invocations (overlapping cron ticks, a manual trigger racing the
-- scheduled one) can never claim — and therefore never send an APNs push
-- for — the same row twice. FOR UPDATE SKIP LOCKED means a second concurrent
-- caller simply skips rows the first caller already has locked, rather than
-- blocking or double-claiming. A row claimed more than p_stale_after_seconds
-- ago (its worker crashed/timed out mid-send without resolving it) is
-- treated as abandoned and becomes claimable again.
CREATE OR REPLACE FUNCTION claim_notification_retries(
  p_limit INTEGER,
  p_stale_after_seconds INTEGER DEFAULT 120
)
RETURNS SETOF public.notification_retry_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  UPDATE public.notification_retry_queue AS q
  SET claimed_at = NOW()
  FROM (
    SELECT id
    FROM public.notification_retry_queue
    WHERE resolved_at IS NULL
      AND next_attempt_at <= NOW()
      AND (
        claimed_at IS NULL
        OR claimed_at < NOW() - make_interval(secs => p_stale_after_seconds)
      )
    ORDER BY next_attempt_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ) AS due
  WHERE q.id = due.id
  RETURNING q.*;
END;
$$;

-- Service-role only (edge functions); never callable by anon/authenticated —
-- same convention as bump_capture_rate_limit in 0033_capture_pipeline_hardening.sql.
REVOKE ALL ON FUNCTION claim_notification_retries(INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION claim_notification_retries(INTEGER, INTEGER)
  FROM anon, authenticated;

-- ── Scheduled dispatch ───────────────────────────────────────────────────
-- Requires pg_net and two one-time Vault secrets created via the dashboard/
-- CLI before this actually fires successfully (never store secrets in a
-- migration file):
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--   select vault.create_secret('<service-role-key>', 'service_role_key');
-- Until those exist, run_notification_retry_dispatch() is a safe no-op
-- (RAISE LOG only) rather than a hard failure, so this migration is safe to
-- apply before that manual step.
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION run_notification_retry_dispatch()
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
    RAISE LOG 'notification retry dispatch skipped: Vault secrets not configured yet';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := project_url || '/functions/v1/process-notification-retries',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_key
    ),
    body := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION run_notification_retry_dispatch() FROM PUBLIC;
REVOKE ALL ON FUNCTION run_notification_retry_dispatch() FROM anon, authenticated;

SELECT cron.schedule(
  'notification-retry-dispatch-5min',
  '*/5 * * * *',
  $$SELECT run_notification_retry_dispatch()$$
);

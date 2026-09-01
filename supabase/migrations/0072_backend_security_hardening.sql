-- 0072_backend_security_hardening.sql — MALI-075n / MALI-024 / MALI-039.
--
-- Additive and backward-compatible. Safe on a clean install and on upgrade, and
-- safe to apply after 0068–0071 (migrations run in order; nothing here depends
-- on their objects). DEPLOYED (status corrected 2026-09-01: 0001-0092 applied and ledger-verified on production; this header was never revised after the deploy).
--
-- Forward-recovery: all objects are guard-created (IF EXISTS / OR REPLACE), so a
-- partial apply can be re-run idempotently.

-- ── 1. SECURITY DEFINER search_path hardening ────────────────────────────────

-- handle_new_user() (0001) was superseded by create_profile_on_signup() (0005,
-- which sets search_path); 0005 dropped its trigger, leaving a dead SECURITY
-- DEFINER function with no fixed search_path. Remove it so it cannot be reused
-- as a search-path-injection surface.
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;

-- prune_processed_captures() (0012) is SECURITY DEFINER but had no fixed
-- search_path. Recreate with one; re-assert the 0067 lockdown (service-role
-- only — invoked by run_prune_processed_captures()).
CREATE OR REPLACE FUNCTION public.prune_processed_captures()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM processed_captures
  WHERE created_at < NOW() - INTERVAL '30 days';

  DELETE FROM capture_fingerprints
  WHERE seen_at < NOW() - INTERVAL '7 days';
$$;

REVOKE ALL ON FUNCTION public.prune_processed_captures() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prune_processed_captures() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_processed_captures() TO service_role;

-- ── 2. Metrics ingestion — owner-bound, validated, rate-limited (MALI-075n) ───
--
-- Replace the `with check (true)` free-for-all authenticated insert (any
-- authenticated user could insert arbitrary metric rows) with a SECURITY
-- DEFINER RPC that requires an authenticated caller, allowlists the event key,
-- bounds lengths, enforces a per-user daily quota, and stamps the server day.
-- No user id or free-form data is stored (the table keeps its no-PII shape); the
-- quota is tracked separately, keyed by the verified auth.uid().

DROP POLICY IF EXISTS "metrics insert" ON public.metrics;
REVOKE INSERT ON public.metrics FROM authenticated;

CREATE TABLE IF NOT EXISTS public.metrics_rate_limits (
  user_id    UUID NOT NULL,
  day        DATE NOT NULL DEFAULT CURRENT_DATE,
  call_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day)
);
ALTER TABLE public.metrics_rate_limits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS metrics_rate_limits_no_direct_access ON public.metrics_rate_limits;
CREATE POLICY metrics_rate_limits_no_direct_access
  ON public.metrics_rate_limits
  USING (false)
  WITH CHECK (false);

-- Prune the per-user daily counters (retention: yesterday and older).
CREATE OR REPLACE FUNCTION public.prune_metrics_rate_limits()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM metrics_rate_limits WHERE day < CURRENT_DATE;
$$;
REVOKE ALL ON FUNCTION public.prune_metrics_rate_limits() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prune_metrics_rate_limits() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_metrics_rate_limits() TO service_role;

CREATE OR REPLACE FUNCTION public.record_metric(
  p_metric_key TEXT,
  p_dimension TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_count INTEGER;
  -- The complete allowlist of event keys the client is permitted to record.
  c_allowed CONSTANT TEXT[] := ARRAY['app_open'];
  c_daily_limit CONSTANT INTEGER := 1000;
BEGIN
  -- Authenticated only; never trust a caller-supplied identity.
  IF v_uid IS NULL THEN RETURN; END IF;
  -- Event-name allowlist + bounded lengths; unknown/oversized → silently dropped
  -- (metrics are best-effort; never raise into the caller).
  IF NOT (p_metric_key = ANY (c_allowed)) THEN RETURN; END IF;
  IF length(p_metric_key) > 64 THEN RETURN; END IF;
  IF p_dimension IS NOT NULL AND length(p_dimension) > 128 THEN RETURN; END IF;

  -- Per-user daily quota (atomic).
  INSERT INTO metrics_rate_limits AS r (user_id, day, call_count)
  VALUES (v_uid, CURRENT_DATE, 1)
  ON CONFLICT (user_id, day) DO UPDATE SET call_count = r.call_count + 1
  RETURNING call_count INTO v_count;
  IF v_count > c_daily_limit THEN RETURN; END IF;

  INSERT INTO metrics (metric_key, dimension)
  VALUES (p_metric_key, p_dimension);
END;
$$;

REVOKE ALL ON FUNCTION public.record_metric(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_metric(TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_metric(TEXT, TEXT) TO authenticated;

-- ── 3. Purge/retention tails — Batch 1–5 tables (MALI-075n §7) ────────────────
--
-- Extend account erasure to cover the tables added since 0065. All satellites
-- keyed by install hash / owner_key are resolved through the user's registered
-- devices BEFORE those device rows are deleted. Migrations apply in order, so
-- the 0070/0071/0072 tables exist by the time this replacement runs. NOT
-- DEPLOYED in this batch.
CREATE OR REPLACE FUNCTION public.purge_user_data(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  -- Children before parents (FK order), satellites before their anchors.

  -- Capture pipeline + AI satellites keyed by install hash / owner_key: resolve
  -- them through the user's devices before those device rows are removed.
  DELETE FROM public.capture_rate_limits
  WHERE install_id_hash IN (
    SELECT install_id_hash FROM public.capture_devices WHERE user_id = p_user_id
  );

  -- AI idempotency ledger (0071): owner_key is `u:<uid>` or `d:<installHash>`.
  DELETE FROM public.ai_request_idempotency
  WHERE owner_key = 'u:' || p_user_id::text
     OR owner_key IN (
       SELECT 'd:' || install_id_hash
       FROM public.capture_devices WHERE user_id = p_user_id
     );

  DELETE FROM public.notification_logs where user_id = p_user_id;

  DELETE FROM public.user_bill_payments        WHERE user_id = p_user_id;
  DELETE FROM public.user_goal_contributions   WHERE user_id = p_user_id;
  DELETE FROM public.user_plan_transaction_links WHERE user_id = p_user_id;
  DELETE FROM public.user_subscriptions        WHERE user_id = p_user_id;
  DELETE FROM public.user_goals                WHERE user_id = p_user_id;
  DELETE FROM public.user_plans                WHERE user_id = p_user_id;
  DELETE FROM public.user_budgets              WHERE user_id = p_user_id;
  DELETE FROM public.user_transactions         WHERE user_id = p_user_id;
  DELETE FROM public.user_cards                WHERE user_id = p_user_id;
  DELETE FROM public.user_accounts             WHERE user_id = p_user_id;
  DELETE FROM public.user_smart_inbox          WHERE user_id = p_user_id;
  DELETE FROM public.user_categories           WHERE user_id = p_user_id;
  DELETE FROM public.financial_import_runs     WHERE user_id = p_user_id;
  DELETE FROM public.user_settings             WHERE user_id = p_user_id;
  DELETE FROM public.user_achievements         WHERE user_id = p_user_id;
  DELETE FROM public.user_streaks              WHERE user_id = p_user_id;
  DELETE FROM public.user_xp_levels            WHERE user_id = p_user_id;
  -- Engagement events (0070, dormant) + per-user metrics quota counters (0072)
  -- + the legacy-award idempotency ledger (0073; plpgsql late-binds, so the
  -- table resolves at call time — 0073 deploys in the same ordered chain).
  DELETE FROM public.user_engagement_events    WHERE user_id = p_user_id;
  DELETE FROM public.metrics_rate_limits        WHERE user_id = p_user_id;
  DELETE FROM public.gamification_awarded_transactions WHERE user_id = p_user_id;
  DELETE FROM public.feature_flag_overrides    WHERE user_id = p_user_id;
  DELETE FROM public.sender_bank_mappings      WHERE user_id = p_user_id;
  DELETE FROM public.capture_devices           WHERE user_id = p_user_id;
  DELETE FROM public.backups                   WHERE user_id = p_user_id;
  DELETE FROM public.profiles                  WHERE id      = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_user_data(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_user_data(uuid) TO service_role;

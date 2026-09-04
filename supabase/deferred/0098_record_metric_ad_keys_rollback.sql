-- ROLLBACK for 0098_record_metric_ad_keys.sql
--
-- Non-destructive. It narrows the `record_metric` allowlist back to 0072's
-- single `app_open` key. No table, column, row or grant is touched.
--
-- What it costs: every ads telemetry row stops being recorded from the moment
-- this runs. Rows already written stay. The client keeps calling the RPC and
-- keeps getting a silent no-op, exactly as it did before 0098 — nothing breaks,
-- and no ad, report or banner behaviour changes, because telemetry is
-- fire-and-forget on every path that emits it.
--
-- Safe to run more than once.

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

-- Re-assert the 0072 lockdown. CREATE OR REPLACE preserves existing grants, so
-- this is belt-and-braces: a replace must never be the thing that widens who can
-- write a metric row.
REVOKE ALL ON FUNCTION public.record_metric(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_metric(TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_metric(TEXT, TEXT) TO authenticated;

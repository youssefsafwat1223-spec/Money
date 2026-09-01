-- 0098_record_metric_ad_keys.sql — allowlist the ads telemetry keys.
--
-- NOT DEPLOYED. Source-only until the ledger is re-confirmed against production.
--
-- ## Why this exists
--
-- `record_metric` (0072) allowlists exactly one key, `app_open`, and silently
-- drops everything else. That is the correct shape — an unbounded client-writable
-- metric key is a free-text column anyone can fill — but it means the ads
-- telemetry that already ships in the client has never recorded a single row.
--
-- `report_ads_analytics.dart` documents that as an accepted trade ("unrecognised
-- keys are silent server-side no-ops until a future phase allowlists them").
-- This is that phase. It was found again while adding banner telemetry: an
-- events pipeline that looks wired and drops everything is worse than no
-- pipeline, because nobody re-checks a feature they believe is working.
--
-- ## What is allowlisted, and what is deliberately not
--
-- Ad OUTCOME keys only. There is no `*_suppressed_*` key here and there must
-- never be one: an event whose meaning is "this user was eligible for an ad but
-- we withheld it" is exactly the impression-opportunity signal that the ad-free
-- entitlement design promises never to emit.
--
-- The `dimension` argument carries a placement key (`transactions_list`) and
-- nothing else. It is length-bounded at 128 by the existing function body, and
-- the client's `BannerAdsAnalytics` can only ever pass an `AdPlacement.key`.
--
-- Additive and idempotent: CREATE OR REPLACE over the same signature, with the
-- 0072 grants re-asserted so a replace can never widen them.

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
  --
  -- 0072 shipped ['app_open']. The report-export keys have been emitted by the
  -- client since R4 and dropped here ever since; the banner keys are new.
  c_allowed CONSTANT TEXT[] := ARRAY[
    'app_open',
    -- Report-export interstitial (docs/REPORT_ADS_SYSTEM.md §18).
    'report_export_requested',
    'report_export_completed',
    'report_ad_load_requested',
    'report_ad_impression',
    'report_ad_dismissed',
    'report_ad_load_failed',
    'report_ad_show_failed',
    -- Banner placements (docs/BANNER_ADS_SYSTEM.md §9). Outcomes only.
    'banner_ad_requested',
    'banner_ad_loaded',
    'banner_ad_failed',
    'banner_ad_impression'
  ];
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

-- Capture pipeline hardening (notification/capture audit fixes).
--
-- 1. Retention: prune_processed_captures() has existed since 0012 but nothing
--    ever called it — relay rows (including sanitized_text of needs_review /
--    rejected messages) and fingerprints lived forever for devices that never
--    re-open the app. Schedule it daily via pg_cron, preserving the intended
--    30-day (processed_captures) / 7-day (capture_fingerprints) retention.
-- 2. Atomic rate limit: the edge function's read-then-upsert undercounted
--    under concurrent calls. bump_capture_rate_limit() increments and checks
--    in one statement; process-ios-sms falls back to the legacy path when the
--    function is absent, so deploy order is safe in both directions.
-- 3. Install-scoped identity: processed_captures.payload_id was a GLOBAL
--    primary key while every lookup is scoped per (payload_id,
--    install_id_hash). Two devices hashing identical SMS fields could collide
--    and the loser degraded to a 500. Re-key to (install_id_hash, payload_id).
--    Data-preserving: the old PK guarantees no duplicates exist under the new
--    wider key, so ADD PRIMARY KEY cannot fail on existing rows.

-- ── 1. Scheduled retention ───────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Wrapper with logging so runs are visible in the Postgres logs without
-- exposing payload contents.
CREATE OR REPLACE FUNCTION run_prune_processed_captures()
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

-- cron.schedule upserts by job name, so re-running this migration is safe.
SELECT cron.schedule(
  'prune-processed-captures-daily',
  '15 3 * * *',
  $$SELECT run_prune_processed_captures()$$
);

-- ── 2. Atomic rate-limit increment ───────────────────────────────────────────

-- Returns TRUE when the caller is over the limit (call rejected). The counter
-- is still incremented for rejected calls; that only widens the block, never
-- lets extra calls through.
CREATE OR REPLACE FUNCTION bump_capture_rate_limit(
  p_install_id_hash TEXT,
  p_limit INTEGER
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO capture_rate_limits AS r (install_id_hash, date, call_count)
  VALUES (p_install_id_hash, CURRENT_DATE, 1)
  ON CONFLICT (install_id_hash, date)
    DO UPDATE SET call_count = r.call_count + 1
  RETURNING call_count > p_limit;
$$;

-- Service-role only (edge functions); never callable by anon/authenticated.
REVOKE ALL ON FUNCTION bump_capture_rate_limit(TEXT, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION bump_capture_rate_limit(TEXT, INTEGER)
  FROM anon, authenticated;
REVOKE ALL ON FUNCTION run_prune_processed_captures() FROM PUBLIC;
REVOKE ALL ON FUNCTION run_prune_processed_captures()
  FROM anon, authenticated;

-- ── 3. Install-scoped processed_captures identity ────────────────────────────

ALTER TABLE processed_captures
  DROP CONSTRAINT processed_captures_pkey,
  ADD PRIMARY KEY (install_id_hash, payload_id);

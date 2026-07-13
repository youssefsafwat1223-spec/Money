-- Rollback for 0033_capture_pipeline_hardening.sql
--
-- Restores the pre-0033 state: no scheduled retention, no atomic rate-limit
-- function, and the original global payload_id primary key.
--
-- NOTE on step 3: restoring the GLOBAL payload_id PK can fail if two installs
-- have since stored the same payload_id (now legal under the scoped key).
-- If that happens, resolve manually before re-running — do NOT delete rows
-- blindly; they belong to different devices.

SELECT cron.unschedule('prune-processed-captures-daily');

DROP FUNCTION IF EXISTS bump_capture_rate_limit(TEXT, INTEGER);
DROP FUNCTION IF EXISTS run_prune_processed_captures();

ALTER TABLE processed_captures
  DROP CONSTRAINT processed_captures_pkey,
  ADD PRIMARY KEY (payload_id);

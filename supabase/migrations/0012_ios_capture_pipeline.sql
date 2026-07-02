-- iOS Shortcut capture relay.
--
-- This is not a transaction ledger. Devices use these tables as a short-lived
-- relay so the iOS App Intent and Flutter app can share one backend-processed
-- result while Drift remains the source of truth.

CREATE TABLE IF NOT EXISTS capture_devices (
  install_id_hash TEXT PRIMARY KEY,
  device_secret_hash TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT 'ios',
  user_id UUID NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE capture_devices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS capture_devices_no_direct_access ON capture_devices;
CREATE POLICY capture_devices_no_direct_access
  ON capture_devices
  USING (false)
  WITH CHECK (false);

CREATE TABLE IF NOT EXISTS processed_captures (
  payload_id TEXT PRIMARY KEY,
  install_id_hash TEXT NOT NULL REFERENCES capture_devices(install_id_hash)
    ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (
    status IN ('processed', 'needs_review', 'duplicate', 'rejected')
  ),
  parsed JSONB NOT NULL DEFAULT '{}'::jsonb,
  notification JSONB NOT NULL DEFAULT '{}'::jsonb,
  sanitized_text TEXT NULL,
  raw_fingerprint TEXT NULL,
  failure_reason TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  synced_at TIMESTAMPTZ NULL
);

ALTER TABLE processed_captures ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS processed_captures_no_direct_access ON processed_captures;
CREATE POLICY processed_captures_no_direct_access
  ON processed_captures
  USING (false)
  WITH CHECK (false);

CREATE INDEX IF NOT EXISTS idx_processed_captures_install_created
  ON processed_captures(install_id_hash, created_at DESC);

CREATE TABLE IF NOT EXISTS capture_fingerprints (
  install_id_hash TEXT NOT NULL REFERENCES capture_devices(install_id_hash)
    ON DELETE CASCADE,
  fingerprint TEXT NOT NULL,
  payload_id TEXT NOT NULL,
  seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (install_id_hash, fingerprint)
);

ALTER TABLE capture_fingerprints ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS capture_fingerprints_no_direct_access ON capture_fingerprints;
CREATE POLICY capture_fingerprints_no_direct_access
  ON capture_fingerprints
  USING (false)
  WITH CHECK (false);

CREATE TABLE IF NOT EXISTS capture_rate_limits (
  install_id_hash TEXT NOT NULL,
  date DATE NOT NULL,
  call_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (install_id_hash, date)
);

ALTER TABLE capture_rate_limits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS capture_rate_limits_no_direct_access ON capture_rate_limits;
CREATE POLICY capture_rate_limits_no_direct_access
  ON capture_rate_limits
  USING (false)
  WITH CHECK (false);

CREATE OR REPLACE FUNCTION prune_processed_captures()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  DELETE FROM processed_captures
  WHERE created_at < NOW() - INTERVAL '30 days';

  DELETE FROM capture_fingerprints
  WHERE seen_at < NOW() - INTERVAL '7 days';
$$;

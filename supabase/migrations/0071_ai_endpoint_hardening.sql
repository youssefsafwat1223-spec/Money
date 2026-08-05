-- 0071_ai_endpoint_hardening.sql — MALI-060n.
--
-- Verified-identity AI-endpoint hardening: per-device consent + revocation, and
-- an idempotency ledger so a retried paid request never repeats the Google
-- Gemini/Places call.
--
-- Additive and backward-compatible. Touches only capture_devices (0012) and new
-- objects, so it is safe to apply while migrations 0068–0070 remain undeployed
-- (no dependency on their objects; migrations apply in order regardless).
-- NOT DEPLOYED in this batch.

-- ── 1. Per-device consent + revocation ───────────────────────────────────────
-- Consent defaults FALSE (fail-closed, MALI-059n): a freshly registered device
-- must explicitly opt in (via the set-device-consent endpoint) before any AI /
-- cloud processing runs for it. `revoked_at` distinguishes a revoked credential
-- from one that never existed.
ALTER TABLE capture_devices
  ADD COLUMN IF NOT EXISTS ai_consent_granted BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS cloud_processing_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ NULL;

-- ── 2. Idempotency ledger for paid AI requests ───────────────────────────────
-- Keyed on the SERVER-derived owner + endpoint + client-supplied request id.
-- Stores a payload HASH (never the raw payload) so a replay with a changed
-- payload is detectable, plus a bounded result acknowledgement that expires by
-- TTL. Raw SMS / merchant text is NEVER written here.
CREATE TABLE IF NOT EXISTS ai_request_idempotency (
  owner_key    TEXT NOT NULL,
  endpoint     TEXT NOT NULL,
  request_id   TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'in_progress'
    CHECK (status IN ('in_progress', 'succeeded', 'failed')),
  result       JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (owner_key, endpoint, request_id)
);

ALTER TABLE ai_request_idempotency ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ai_request_idempotency_no_direct_access ON ai_request_idempotency;
CREATE POLICY ai_request_idempotency_no_direct_access
  ON ai_request_idempotency
  USING (false)
  WITH CHECK (false);

CREATE INDEX IF NOT EXISTS idx_ai_request_idempotency_expires
  ON ai_request_idempotency (expires_at);

-- ── 3. Atomic idempotency claim ──────────────────────────────────────────────
-- Atomically claims (owner_key, endpoint, request_id):
--   * the first caller inserts an 'in_progress' row      → ('claimed', ...);
--   * a concurrent/repeat caller with the SAME payload   → ('exists', status,
--     stored result) — the paid work is not repeated;
--   * a caller with a DIFFERENT payload for the same id  → ('mismatch', ...).
-- The INSERT … ON CONFLICT DO NOTHING makes the claim race-safe under
-- concurrency (exactly one inserter wins).
CREATE OR REPLACE FUNCTION claim_ai_idempotency(
  p_owner_key TEXT,
  p_endpoint TEXT,
  p_request_id TEXT,
  p_payload_hash TEXT,
  p_ttl_seconds INTEGER
)
RETURNS TABLE(outcome TEXT, status TEXT, result JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inserted BOOLEAN := FALSE;
  v_row ai_request_idempotency;
BEGIN
  INSERT INTO ai_request_idempotency AS r
    (owner_key, endpoint, request_id, payload_hash, status, result, expires_at)
  VALUES
    (p_owner_key, p_endpoint, p_request_id, p_payload_hash, 'in_progress',
     '{}'::jsonb, NOW() + make_interval(secs => GREATEST(p_ttl_seconds, 1)))
  ON CONFLICT (owner_key, endpoint, request_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted THEN
    RETURN QUERY SELECT 'claimed'::TEXT, 'in_progress'::TEXT, '{}'::jsonb;
    RETURN;
  END IF;

  SELECT * INTO v_row FROM ai_request_idempotency
    WHERE owner_key = p_owner_key
      AND endpoint = p_endpoint
      AND request_id = p_request_id;

  IF v_row.payload_hash IS DISTINCT FROM p_payload_hash THEN
    RETURN QUERY SELECT 'mismatch'::TEXT, COALESCE(v_row.status, 'unknown'), '{}'::jsonb;
  ELSE
    RETURN QUERY SELECT 'exists'::TEXT, v_row.status, v_row.result;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION claim_ai_idempotency(TEXT, TEXT, TEXT, TEXT, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION claim_ai_idempotency(TEXT, TEXT, TEXT, TEXT, INTEGER)
  FROM anon, authenticated;

-- Records the outcome of a claimed request (safe metadata only).
CREATE OR REPLACE FUNCTION complete_ai_idempotency(
  p_owner_key TEXT,
  p_endpoint TEXT,
  p_request_id TEXT,
  p_status TEXT,
  p_result JSONB
)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE ai_request_idempotency
    SET status = p_status, result = COALESCE(p_result, '{}'::jsonb)
  WHERE owner_key = p_owner_key
    AND endpoint = p_endpoint
    AND request_id = p_request_id;
$$;

REVOKE ALL ON FUNCTION complete_ai_idempotency(TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION complete_ai_idempotency(TEXT, TEXT, TEXT, TEXT, JSONB)
  FROM anon, authenticated;

-- Prunes expired idempotency rows. Only a payload hash + bounded metadata are
-- ever stored, and they expire by TTL; this reclaims them.
CREATE OR REPLACE FUNCTION prune_ai_request_idempotency()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM ai_request_idempotency WHERE expires_at < NOW();
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION prune_ai_request_idempotency() FROM PUBLIC;
REVOKE ALL ON FUNCTION prune_ai_request_idempotency()
  FROM anon, authenticated;

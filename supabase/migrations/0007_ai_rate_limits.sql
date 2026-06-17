-- Rate limiting table for the parse-sms Edge Function.
-- Keyed by SHA-256(install_id)[0:16] + date (YYYY-MM-DD).
-- Max 20 calls per device per day, enforced server-side in the Edge Function.
-- No RLS row-level access needed — only the service role key (used by Edge
-- Functions) may write here.

CREATE TABLE IF NOT EXISTS ai_rate_limits (
  install_id_hash TEXT  NOT NULL,
  date            TEXT  NOT NULL,
  call_count      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (install_id_hash, date)
);

ALTER TABLE ai_rate_limits ENABLE ROW LEVEL SECURITY;

-- Block all direct client access — writes go through the Edge Function only.
CREATE POLICY "no_direct_access" ON ai_rate_limits USING (false);

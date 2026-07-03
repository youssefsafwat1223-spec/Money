-- Phase J: per-user feature flag overrides for staging / TestFlight testing.
-- Lets testers have specific flags forced ON or OFF without touching global
-- feature_flags (which affect every user).  Service-role manages writes;
-- authenticated users can only read their own rows (RLS below).

CREATE OR REPLACE FUNCTION set_updated_at()
  RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS feature_flag_overrides (
  id         UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  key        TEXT        NOT NULL,
  enabled    BOOLEAN     NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, key)
);

ALTER TABLE feature_flag_overrides ENABLE ROW LEVEL SECURITY;

-- Users can read only their own overrides; service_role bypasses RLS for writes.
CREATE POLICY "users_read_own_flag_overrides"
  ON feature_flag_overrides FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE TRIGGER set_feature_flag_overrides_updated_at
  BEFORE UPDATE ON feature_flag_overrides
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

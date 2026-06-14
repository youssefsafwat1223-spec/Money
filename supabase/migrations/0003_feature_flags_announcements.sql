-- Phase 2: Feature Flags + Announcements catalog tables.

-- ─── Feature Flags ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS feature_flags (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key              TEXT UNIQUE NOT NULL,
  value_type       TEXT NOT NULL CHECK (value_type IN ('boolean','string','number','json')),
  value            TEXT NOT NULL,
  description      TEXT,
  rollout_percent  INT NOT NULL DEFAULT 100 CHECK (rollout_percent BETWEEN 0 AND 100),
  target_countries JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- No version trigger needed: flags are always fetched in full (small payload).

ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "flags_anon_select"
  ON feature_flags FOR SELECT
  TO anon
  USING (true);

-- Seed default flags (idempotent).
INSERT INTO feature_flags (key, value_type, value, description, rollout_percent, is_active)
VALUES
  ('enable_goals',           'boolean', 'true',  'Show goals tab',             100, true),
  ('enable_coupons',         'boolean', 'false', 'Show coupons section',         0, true),
  ('enable_announcements',   'boolean', 'true',  'Enable announcement banners', 100, true),
  ('parser_engine_version',  'string',  'v1',    'Parser engine version key',   100, true)
ON CONFLICT (key) DO NOTHING;

-- ─── Announcements ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS announcements (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title_ar         TEXT NOT NULL,
  title_en         TEXT NOT NULL,
  body_ar          TEXT,
  body_en          TEXT,
  severity         TEXT NOT NULL CHECK (severity IN ('info','warning','maintenance','force_update')),
  min_app_version  TEXT,
  max_app_version  TEXT,
  action_label_ar  TEXT,
  action_label_en  TEXT,
  action_url       TEXT,
  valid_from       TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until      TIMESTAMPTZ,
  is_dismissible   BOOLEAN NOT NULL DEFAULT true,
  priority         INT NOT NULL DEFAULT 0,
  target_countries JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE announcements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "announcements_anon_select"
  ON announcements FOR SELECT
  TO anon
  USING (true);
-- All writes blocked for anon — admin uses service_role via backend API.

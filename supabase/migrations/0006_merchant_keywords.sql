-- Phase 4B: remote merchant keyword dictionary
-- Admins manage rows via the admin panel; devices sync via catalog-delta.

CREATE TABLE IF NOT EXISTS merchant_keywords (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  keyword TEXT NOT NULL,
  category_key TEXT NOT NULL,
  language TEXT NOT NULL DEFAULT 'any',
  country_code TEXT NOT NULL DEFAULT 'ALL',
  priority INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_mk_country_active ON merchant_keywords(country_code, is_active)
  WHERE NOT is_deleted;

-- Row Level Security: read-only for anon (sync), write for service_role (admin panel)
ALTER TABLE merchant_keywords ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon can read active keywords"
  ON merchant_keywords FOR SELECT
  USING (is_active AND NOT is_deleted);

-- Admin panel uses service_role key so no additional INSERT/UPDATE policy needed.

-- Register in catalog_versions for delta sync tracking
INSERT INTO catalog_versions(category, version, updated_at)
VALUES ('merchant_keywords', 1, NOW())
ON CONFLICT(category) DO NOTHING;

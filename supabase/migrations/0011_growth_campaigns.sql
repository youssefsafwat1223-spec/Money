CREATE TABLE IF NOT EXISTS growth_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title_ar TEXT NOT NULL,
  title_en TEXT NOT NULL,
  body_ar TEXT NULL,
  body_en TEXT NULL,
  type TEXT NOT NULL CHECK (type IN ('notification', 'dashboard_banner', 'settings_card', 'modal')),
  target_segment TEXT NOT NULL DEFAULT 'all' CHECK (
    target_segment IN (
      'new_user',
      'no_shortcut',
      'has_first_transaction',
      'inactive_3_days',
      'active_user',
      'budget_user',
      'all'
    )
  ),
  action_label_ar TEXT NULL,
  action_label_en TEXT NULL,
  action_route TEXT NULL,
  action_url TEXT NULL,
  valid_from TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until TIMESTAMPTZ NULL,
  max_impressions INTEGER NULL CHECK (max_impressions IS NULL OR max_impressions > 0),
  cooldown_hours INTEGER NOT NULL DEFAULT 24 CHECK (cooldown_hours >= 0),
  is_dismissible BOOLEAN NOT NULL DEFAULT true,
  once_per_user BOOLEAN NOT NULL DEFAULT false,
  priority INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE growth_campaigns ENABLE ROW LEVEL SECURITY;

CREATE POLICY "growth_campaigns_anon_select"
  ON growth_campaigns FOR SELECT
  USING (is_active = true);

CREATE INDEX IF NOT EXISTS idx_growth_campaigns_active_type
  ON growth_campaigns(is_active, type, priority DESC, valid_from);

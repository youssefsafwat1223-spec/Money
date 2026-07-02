ALTER TABLE capture_devices
  ADD COLUMN IF NOT EXISTS apns_token TEXT,
  ADD COLUMN IF NOT EXISTS apns_environment TEXT
    CHECK (apns_environment IN ('sandbox', 'production')),
  ADD COLUMN IF NOT EXISTS token_updated_at TIMESTAMPTZ;

ALTER TABLE processed_captures
  ADD COLUMN IF NOT EXISTS apns_push_sent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS apns_push_error TEXT;

CREATE INDEX IF NOT EXISTS idx_capture_devices_apns_updated
  ON capture_devices(token_updated_at DESC)
  WHERE apns_token IS NOT NULL;

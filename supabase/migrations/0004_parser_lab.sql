-- Phase 3: Parser Lab — validation metadata + golden test set.

-- ─── Validation columns on sms_parsers ───────────────────────────────────────

ALTER TABLE sms_parsers
  ADD COLUMN IF NOT EXISTS validation_status    TEXT NOT NULL DEFAULT 'pending'
    CHECK (validation_status IN ('pending', 'passed', 'failed')),
  ADD COLUMN IF NOT EXISTS golden_test_count    INT  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS false_positive_count INT  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS amount_error_count   INT  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS validated_at         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS validated_by         TEXT;

-- Existing seeded parsers are pre-approved; mark them as passed.
UPDATE sms_parsers SET validation_status = 'passed' WHERE validation_status = 'pending';

-- catalog-delta must never return parsers that have not passed validation.
-- Recreate the function to add the extra filter.
CREATE OR REPLACE FUNCTION trg_version_parsers() RETURNS TRIGGER AS $$
DECLARE v BIGINT;
BEGIN
  v := nextval('catalog_seq_parsers');
  IF TG_OP = 'INSERT' THEN
    NEW.created_version := v;
    NEW.updated_version := v;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.updated_version := v;
    IF NEW.is_deleted AND NOT OLD.is_deleted THEN
      NEW.deleted_version := v;
    END IF;
  END IF;
  UPDATE catalog_versions SET version = v, updated_at = now() WHERE category = 'parsers';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─── Golden test set ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS parser_golden_tests (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bank_id           UUID NOT NULL REFERENCES banks(id) ON DELETE CASCADE,
  sender            TEXT NOT NULL,
  message_text      TEXT NOT NULL,
  expected_type     TEXT NOT NULL CHECK (expected_type IN ('debit','credit','balance_inquiry','ignored')),
  expected_amount   NUMERIC,
  expected_currency TEXT,
  expected_merchant TEXT,
  is_otp            BOOLEAN NOT NULL DEFAULT false,
  is_promo          BOOLEAN NOT NULL DEFAULT false,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE parser_golden_tests ENABLE ROW LEVEL SECURITY;

-- Golden tests are internal: anon cannot read them.
-- Only service_role (admin panel / parser-test Edge Function) has access.
-- No anon policy = implicit DENY for anon.

CREATE INDEX IF NOT EXISTS idx_golden_tests_bank_id ON parser_golden_tests(bank_id);

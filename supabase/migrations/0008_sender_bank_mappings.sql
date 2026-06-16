-- Per-user sender → bank mappings for Bank Discovery.
-- No raw SMS, amounts, merchants, account numbers, or parsed transaction data
-- are stored here.

CREATE TABLE IF NOT EXISTS sender_bank_mappings (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sender_id             TEXT NOT NULL,
  normalized_sender_id  TEXT NOT NULL,
  bank_key              TEXT,
  suggested_bank_name   TEXT NOT NULL,
  suggested_country     TEXT NOT NULL,
  confidence            DOUBLE PRECISION NOT NULL
                          CHECK (confidence >= 0 AND confidence <= 1),
  reason                TEXT,
  status                TEXT NOT NULL
                          CHECK (status IN ('pending', 'confirmed', 'rejected')),
  source                TEXT NOT NULL
                          CHECK (source IN ('gemini', 'user_manual', 'remote')),
  first_seen_at         TIMESTAMPTZ NOT NULL,
  last_seen_at          TIMESTAMPTZ NOT NULL,
  confirmed_at          TIMESTAMPTZ,
  rejected_at           TIMESTAMPTZ,
  rejection_expires_at  TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status != 'confirmed' OR confirmed_at IS NOT NULL),
  CHECK (status != 'rejected' OR rejected_at IS NOT NULL),
  UNIQUE (user_id, normalized_sender_id)
);

CREATE INDEX IF NOT EXISTS idx_sender_bank_mappings_user_updated
  ON sender_bank_mappings(user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_sender_bank_mappings_user_status
  ON sender_bank_mappings(user_id, status);

ALTER TABLE sender_bank_mappings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sender_bank_mappings_select_own"
  ON sender_bank_mappings;
DROP POLICY IF EXISTS "sender_bank_mappings_insert_own"
  ON sender_bank_mappings;
DROP POLICY IF EXISTS "sender_bank_mappings_update_own"
  ON sender_bank_mappings;
DROP POLICY IF EXISTS "sender_bank_mappings_delete_own"
  ON sender_bank_mappings;

CREATE POLICY "sender_bank_mappings_select_own"
  ON sender_bank_mappings FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "sender_bank_mappings_insert_own"
  ON sender_bank_mappings FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "sender_bank_mappings_update_own"
  ON sender_bank_mappings FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "sender_bank_mappings_delete_own"
  ON sender_bank_mappings FOR DELETE
  USING (auth.uid() = user_id);

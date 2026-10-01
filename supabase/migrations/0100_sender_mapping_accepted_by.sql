-- Provenance of an accepted sender->bank mapping: 'user' (explicit user
-- confirmation) or 'ai_validated' (a validator-accepted AI capture matched
-- exactly one catalog bank). NULL = legacy row, treated as user-accepted.
-- Provenance only, never a substitute for validation. Additive, no RLS change.
ALTER TABLE public.sender_bank_mappings
  ADD COLUMN IF NOT EXISTS accepted_by text NULL
  CHECK (accepted_by IS NULL OR accepted_by IN ('user','ai_validated'));

COMMENT ON COLUMN public.sender_bank_mappings.accepted_by IS
  'Who accepted the mapping: user | ai_validated. NULL = legacy (user-accepted).';

-- Rollback for supabase/migrations/0022_ledger_hardening.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Run manually via the SQL Editor only if 0022 needs
-- to be undone.
--
-- NOT a byte-perfect undo: splitting `type` into `direction` +
-- `transaction_type` was intentionally information-preserving in the
-- forward direction (the two new columns can hold facts — e.g. refund vs.
-- income, which direction a transfer moved — that the old single-value
-- `type` enum could never represent). Reconstructing the old column here
-- prioritizes "leave the DB in a working state matching the pre-0022
-- schema shape" over reproducing historical values that the old column
-- was never capable of storing in the first place.

-- ── 6. Drop ownership trigger + function ─────────────────────────────────────
DROP TRIGGER IF EXISTS trg_user_transactions_ownership ON public.user_transactions;
DROP FUNCTION IF EXISTS public.validate_user_transaction_ownership();

-- ── 5. Drop category FK ──────────────────────────────────────────────────────
ALTER TABLE public.user_transactions
  DROP CONSTRAINT IF EXISTS fk_user_transactions_category;

-- ── 4. Reverse account reconciliation ────────────────────────────────────────
ALTER TABLE public.user_transactions DROP COLUMN IF EXISTS server_account_id;
ALTER TABLE public.user_transactions RENAME COLUMN local_account_id TO account_id;

-- ── 3. Reverse idempotency changes ───────────────────────────────────────────
ALTER TABLE public.user_transactions DROP COLUMN IF EXISTS client_request_id;
ALTER INDEX IF EXISTS idx_user_transactions_user_source_payload
  RENAME TO idx_user_transactions_user_payload;
ALTER TABLE public.user_transactions RENAME COLUMN source_payload_id TO payload_id;

-- ── 2. Drop data-quality constraints ─────────────────────────────────────────
ALTER TABLE public.user_transactions
  DROP CONSTRAINT IF EXISTS chk_user_transactions_amount_positive,
  DROP CONSTRAINT IF EXISTS chk_user_transactions_currency_format;

-- ── 1. Reverse the direction/transaction_type split ──────────────────────────
ALTER TABLE public.user_transactions ADD COLUMN type TEXT;

UPDATE public.user_transactions SET
  type = CASE
    WHEN transaction_type = 'transfer' THEN 'transfer'
    WHEN direction = 'debit' THEN 'debit'
    WHEN direction = 'credit' THEN 'credit'
    ELSE 'unknown'
  END;

ALTER TABLE public.user_transactions
  ALTER COLUMN type SET NOT NULL,
  ADD CONSTRAINT user_transactions_type_check
    CHECK (type IN ('debit', 'credit', 'transfer', 'unknown'));

ALTER TABLE public.user_transactions
  DROP CONSTRAINT IF EXISTS chk_user_transactions_direction,
  DROP CONSTRAINT IF EXISTS chk_user_transactions_transaction_type;

ALTER TABLE public.user_transactions
  DROP COLUMN direction,
  DROP COLUMN transaction_type;

-- After running this, also revert:
--   supabase/functions/_shared/ledger.ts        (git checkout to pre-0022 version)
--   supabase/functions/_shared/capture_auth.ts  (git checkout to pre-0022 version)
-- so the Edge Functions write/read the old column names again.

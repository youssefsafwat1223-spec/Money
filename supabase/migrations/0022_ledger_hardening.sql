-- Phase 1 of the simplified online-first migration.
--
-- Schema-only change. No Flutter/Drift/UI changes. No sync flags enabled.
-- user_transactions currently has 2 real rows (dark-launch test captures
-- from the earlier ledger_dual_write testing, EGP 1.00 IPN transfers on
-- card •1938) — backfilled below, never dropped.
--
-- Splits the old single `type` (debit/credit/transfer/unknown) into two
-- separate concepts per approved correction:
--   direction        — debit | credit | unknown
--   transaction_type — income | expense | transfer | refund | adjustment | unknown
--
-- Reconciles account_id to the local_account_id/server_account_id dual-
-- reference pattern already used by user_budgets/user_subscriptions/
-- user_goals/user_plans (migration 0021). Renames payload_id to
-- source_payload_id and adds a distinct client_request_id for future
-- non-capture (UI-initiated) writes.

-- ── 1. Split `type` into direction + transaction_type ───────────────────────

ALTER TABLE public.user_transactions
  ADD COLUMN direction        TEXT,
  ADD COLUMN transaction_type TEXT;

-- Backfill existing rows before the old column is dropped. The old `type`
-- enum only ever recorded a direction-like value; it never distinguished
-- income vs refund vs transfer. Where a row's own category_id already says
-- 'transfers', that stored signal is preserved rather than defaulted away —
-- this is real existing data (categorization), not an invented reinterpretation.
UPDATE public.user_transactions SET
  direction = CASE type
    WHEN 'debit' THEN 'debit'
    WHEN 'credit' THEN 'credit'
    ELSE 'unknown'
  END,
  transaction_type = CASE
    WHEN type = 'transfer' THEN 'transfer'
    WHEN category_id = 'transfers' THEN 'transfer'
    WHEN type = 'debit' THEN 'expense'
    WHEN type = 'credit' THEN 'income'
    ELSE 'unknown'
  END;

ALTER TABLE public.user_transactions
  ALTER COLUMN direction SET NOT NULL,
  ALTER COLUMN direction SET DEFAULT 'unknown',
  ALTER COLUMN transaction_type SET NOT NULL,
  ALTER COLUMN transaction_type SET DEFAULT 'unknown';

ALTER TABLE public.user_transactions
  ADD CONSTRAINT chk_user_transactions_direction
    CHECK (direction IN ('debit', 'credit', 'unknown')),
  ADD CONSTRAINT chk_user_transactions_transaction_type
    CHECK (transaction_type IN ('income', 'expense', 'transfer', 'refund', 'adjustment', 'unknown'));

ALTER TABLE public.user_transactions
  DROP CONSTRAINT IF EXISTS user_transactions_type_check;

ALTER TABLE public.user_transactions
  DROP COLUMN type;

-- ── 2. Data-quality constraints ──────────────────────────────────────────────

ALTER TABLE public.user_transactions
  ADD CONSTRAINT chk_user_transactions_amount_positive CHECK (amount > 0),
  ADD CONSTRAINT chk_user_transactions_currency_format CHECK (currency ~ '^[A-Z]{3}$');

-- ── 3. Idempotency: distinguish capture-correlation id from a future        ──
--       client-generated idempotency key for UI-initiated writes            ──

ALTER TABLE public.user_transactions RENAME COLUMN payload_id TO source_payload_id;
-- The existing partial unique index's predicate auto-updates with the rename;
-- rename the index itself only for readability.
ALTER INDEX IF EXISTS idx_user_transactions_user_payload
  RENAME TO idx_user_transactions_user_source_payload;

ALTER TABLE public.user_transactions ADD COLUMN client_request_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_transactions_user_client_request
  ON public.user_transactions(user_id, client_request_id)
  WHERE client_request_id IS NOT NULL;

-- ── 4. Reconcile account reference to the same local_account_id /           ──
--       server_account_id pattern already used by the planning tables       ──

ALTER TABLE public.user_transactions RENAME COLUMN account_id TO local_account_id;

ALTER TABLE public.user_transactions
  ADD COLUMN server_account_id UUID REFERENCES public.user_accounts(id);

-- ── 5. Category referential integrity ────────────────────────────────────────
-- Categories are a shared, non-user-owned catalog (public.categories has no
-- user_id — anon-readable seed data), so this is a plain FK, not a per-user
-- ownership check. Verified both existing rows' category_id ('transfers')
-- already satisfy it.

ALTER TABLE public.user_transactions
  ADD CONSTRAINT fk_user_transactions_category
    FOREIGN KEY (category_id) REFERENCES public.categories(key);

-- ── 6. Account ownership validation trigger ──────────────────────────────────
-- category_id needs no equivalent check (see §5) — only account_id is
-- genuinely user-owned data that could reference another user's row.

CREATE OR REPLACE FUNCTION public.validate_user_transaction_ownership()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.server_account_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.user_accounts
      WHERE id = NEW.server_account_id AND user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'account % does not belong to user %', NEW.server_account_id, NEW.user_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_transactions_ownership ON public.user_transactions;
CREATE TRIGGER trg_user_transactions_ownership
  BEFORE INSERT OR UPDATE ON public.user_transactions
  FOR EACH ROW EXECUTE FUNCTION public.validate_user_transaction_ownership();

-- No version/optimistic-concurrency column added — explicitly out of scope
-- for this simplified online-first MVP (updated_at + last-write-wins).

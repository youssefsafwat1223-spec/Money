-- ROLLBACK for 0099_parser_safety_rule_scoped_evidence.sql
--
-- Reverses BOTH halves. Read the warning on each before running.
--
-- WARNING 1 — DROPPING parser_id DESTROYS THE SUBJECT OF EVERY GOLDEN ROW.
-- Without it a row is evidence for "some rule at this bank", which is exactly
-- the ambiguity 0099 removed: a row for parser A then validates or fails parser
-- B. If any evidence exists, export it before rolling back; the association
-- cannot be reconstructed from the remaining columns.
--
-- WARNING 2 — RESTORING THE OLD SNB RULE RESTORES A WRONG-MONEY DEFECT.
-- Its pre-0099 pattern made the currency optional, and the lazy matcher then
-- captured the masked CARD NUMBER as the transaction amount (reproduced: 4521
-- instead of 45.00). Rolling that back is safe only because no parser is
-- servable — if any parser has since been promoted, do NOT run this half.

BEGIN;

-- ── 1. Rule-scoped evidence ─────────────────────────────────────────────────
DROP INDEX IF EXISTS public.parser_golden_tests_parser_id_idx;

ALTER TABLE public.parser_golden_tests
  DROP CONSTRAINT IF EXISTS parser_golden_tests_expected_type_check;
ALTER TABLE public.parser_golden_tests
  ADD CONSTRAINT parser_golden_tests_expected_type_check
  CHECK (expected_type IN ('debit', 'credit', 'balance_inquiry', 'ignored'));

ALTER TABLE public.parser_golden_tests
  DROP COLUMN IF EXISTS parser_id,
  DROP COLUMN IF EXISTS expected_balance,
  DROP COLUMN IF EXISTS provenance,
  DROP COLUMN IF EXISTS added_by;

-- ── 2. The SNB rule body ────────────────────────────────────────────────────
-- Restores the exact pre-0099 pattern: currency OPTIONAL before the amount.
-- Only ...101 changed, so only ...101 is reverted; the {1,3} amount scale from
-- 0091 is deliberately preserved, as it predates this migration.
UPDATE public.sms_parsers
   SET message_pattern =
     '[\s\S]*(?:شراء|دفع|Purchase|Payment)[\s\S]*?(?:SAR|ريال|ر\.س)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?'
 WHERE id = '10000000-0000-4000-8000-000000000101';

COMMIT;

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

-- ── 2. Every rule body 0099 overwrote ───────────────────────────────────────
-- Replayed from the pre-image journal, so a rule that had been edited AWAY from
-- canonical before 0099 is restored to what it actually was — not merely to
-- what canonical said. Restoring only SNB would silently keep 0099's values on
-- any other rule that had diverged.
UPDATE public.sms_parsers AS p
   SET sender_pattern   = j.sender_pattern,
       message_pattern  = j.message_pattern,
       transaction_type = j.transaction_type,
       language         = j.language,
       priority         = j.priority,
       extracted_fields = j.extracted_fields
  FROM public.sms_parsers_canonical_reset_0099 AS j
 WHERE p.id = j.parser_id;

DROP TABLE IF EXISTS public.sms_parsers_canonical_reset_0099;

COMMIT;

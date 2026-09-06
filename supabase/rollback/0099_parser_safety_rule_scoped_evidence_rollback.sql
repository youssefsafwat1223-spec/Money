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
--
-- WARNING 3 — 'reversal' EVIDENCE BLOCKS THE WHOLE ROLLBACK.
-- Restoring the pre-0099 four-value expected_type CHECK is impossible while a
-- golden row holds 'reversal', and this is ONE transaction: that failure also
-- abandons the rule-body restore below. The precondition check below says so
-- explicitly rather than letting it surface as a constraint violation. Reclass
-- or delete those rows first — WARNING 1 applies to them too.
--
-- WHAT THIS DOES NOT UNDO.
--   * Version numbers. Each restored rule fires trg_parsers_version, so
--     updated_version and catalog_versions.parsers advance again rather than
--     returning to their pre-0099 values. Monotonic by design; devices re-sync.
--   * The bundled asset. app/assets/catalog/parsers.json still carries the
--     post-0099 canonical grammar. Rolling back the database alone RECREATES
--     the 0091 drift class in the opposite direction, so revert the canonical
--     commit (parser_rules.json + both generated projections) alongside this.

BEGIN;

-- Precondition: see WARNING 3.
DO $$
DECLARE rev INT;
BEGIN
  SELECT count(*) INTO rev FROM public.parser_golden_tests
   WHERE expected_type = 'reversal';
  IF rev > 0 THEN
    RAISE EXCEPTION
      '0099 rollback: % golden row(s) hold expected_type = ''reversal'', which '
      'the pre-0099 CHECK does not admit. Reclassify or delete them first; '
      'rolling back with them present would abort this transaction and leave '
      'the rule bodies unrestored.', rev;
  END IF;
END $$;

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
--
-- 0099 trims the journal to the rows it actually CHANGED, so this restores
-- those and nothing else; a rule 0099 never touched is left exactly as it is.
--
-- Guarded on the journal's existence: the DROP below removes it, so an
-- unguarded reference makes a SECOND rollback — or a rollback against a
-- database where 0099 was never applied — abort the whole transaction under
-- ON_ERROR_STOP instead of being the no-op it should be.
DO $$
BEGIN
  IF to_regclass('public.sms_parsers_canonical_reset_0099') IS NULL THEN
    RAISE NOTICE '0099 rollback: no canonical journal; rule bodies already restored';
    RETURN;
  END IF;
  UPDATE public.sms_parsers AS p
     SET sender_pattern   = j.sender_pattern,
         message_pattern  = j.message_pattern,
         transaction_type = j.transaction_type,
         language         = j.language,
         priority         = j.priority,
         extracted_fields = j.extracted_fields
    FROM public.sms_parsers_canonical_reset_0099 AS j
   WHERE p.id = j.parser_id;
END $$;

DROP TABLE IF EXISTS public.sms_parsers_canonical_reset_0099;

COMMIT;

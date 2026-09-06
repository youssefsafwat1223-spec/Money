-- 0099 — parser safety: rule-scoped golden evidence + canonical rule bodies.
--
-- Two settled changes, together because they are one contract.
--
-- 1. GOLDEN EVIDENCE IS RULE-SCOPED.
--    `parser_golden_tests` was keyed by bank_id alone. A row for parser A
--    therefore validated or FAILED parser B whenever they shared a bank: two
--    debit rules for one bank each saw the other's rows as applicable
--    positives and each failed on them. The only escape was curating one rule
--    per bank per class — the curation that makes validation vacuous.
--
--    parser_id makes the row's subject explicit. Applicability stays DERIVED
--    (the row's expected_type against the rule's transaction_type), so mixed
--    debit/credit/reversal messages for the same bank are valid evidence
--    without curation:
--      positive      row class == rule class  -> must match, all claims hold
--      negative      'ignored'                -> must not match
--      out_of_scope  another class            -> not matching is CORRECT,
--                                                matching is a false positive
--
--    expected_balance lands here too: `balance` is claimed by NBE, CIB and SNB
--    and the validator now REFUSES to promote a claim it cannot prove, so
--    without this column those three rules can never pass.
--
-- 2. RULE BODIES COME FROM THE CANONICAL SOURCE.
--    The UPDATEs below are GENERATED from supabase/catalog/parser_rules.json by
--    tools/gen_catalog_assets.py and copied in verbatim; CI fails if they drift
--    (tools/ci_gates.sh, "catalog asset drift"). 0091 widened the amount
--    quantifier in the database while the bundled asset kept the old shape, and
--    nothing noticed for months. No regex is retyped by hand here.
--
--    The substantive change is SNB (...101): its amount must now be ADJACENT to
--    a currency token on either side. With the currency optional the lazy
--    matcher took the first digit run after the keyword, which on the real
--    layout is the masked CARD NUMBER — reproduced as 4521 instead of 45.00 on
--    real-holdout records. Riyad (...103) shares the shape but the defect could
--    not be reproduced on any available message, and its real layout puts the
--    currency AFTER the amount, so it is deliberately UNCHANGED.
--
-- PROMOTES NOTHING. No validation_status, validated_at or golden_test_count is
-- written; every parser stays exactly as unservable as it is today.

BEGIN;

-- Snapshot the promoted count BEFORE any change, so the postcondition can prove
-- this migration did not alter it rather than demanding it be zero.
CREATE TEMP TABLE _0099_before ON COMMIT DROP AS
SELECT count(*) AS passed_before FROM public.sms_parsers
 WHERE validation_status = 'passed';

-- ── 1. Rule-scoped golden evidence ──────────────────────────────────────────

ALTER TABLE public.parser_golden_tests
  ADD COLUMN IF NOT EXISTS parser_id UUID REFERENCES public.sms_parsers(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS expected_balance NUMERIC,
  -- Provenance: where this evidence came from, so a suite can be audited and a
  -- synthetic row can never be mistaken for a bank-sourced one.
  ADD COLUMN IF NOT EXISTS provenance TEXT
    CHECK (provenance IS NULL OR provenance IN
      ('bank_documented', 'bank_sandbox', 'controlled_transaction',
       'anonymized_fixture', 'synthetic_negative')),
  ADD COLUMN IF NOT EXISTS added_by TEXT;

-- Mandatory for promotion evidence. The table is empty in production, so this
-- cannot silently orphan a row; if any environment does hold rows without a
-- parser_id this fails LOUDLY, which is the correct outcome for evidence whose
-- subject is unknown.
DO $$
DECLARE orphan INT;
BEGIN
  SELECT count(*) INTO orphan FROM public.parser_golden_tests WHERE parser_id IS NULL;
  IF orphan > 0 THEN
    RAISE EXCEPTION
      '0099: % golden row(s) have no parser_id. Assign each to the rule it '
      'validates before applying; a row whose subject is unknown is not evidence.',
      orphan;
  END IF;
END $$;

ALTER TABLE public.parser_golden_tests ALTER COLUMN parser_id SET NOT NULL;

-- A reversal is a real message class and must be expressible as out-of-scope
-- evidence rather than being forced into 'ignored'.
ALTER TABLE public.parser_golden_tests
  DROP CONSTRAINT IF EXISTS parser_golden_tests_expected_type_check;
ALTER TABLE public.parser_golden_tests
  ADD CONSTRAINT parser_golden_tests_expected_type_check
  CHECK (expected_type IN ('debit', 'credit', 'balance_inquiry', 'reversal', 'ignored'));

CREATE INDEX IF NOT EXISTS parser_golden_tests_parser_id_idx
  ON public.parser_golden_tests(parser_id);

-- ── 2. Canonical rule bodies (GENERATED — see header) ───────────────────────

-- GENERATED — DO NOT EDIT.
--
-- Source: supabase/catalog/parser_rules.json
-- Regenerate: python3 tools/gen_catalog_assets.py
-- Verified in CI: python3 tools/gen_catalog_assets.py --check
--
-- The canonical rules projected into SQL so a migration can apply them
-- without restating a single regex. Migration 0091 widened the amount
-- quantifier in the database and the bundled asset was never
-- regenerated; the two then disagreed for months. One source, two
-- generated projections, one CI check.
--
-- UPDATE-only and keyed by the stable parser id: this never creates or
-- deletes a rule, and never touches validation evidence. Promotion
-- stays the Parser Lab's job.

-- 10000000-0000-4000-8000-000000000001
UPDATE public.sms_parsers SET
  sender_pattern    = '^(NBE|National Bank|NBE Alerts)$',
  message_pattern   = '[\s\S]*(?:خصم|شراء|سحب|Purchase|Debit)[\s\S]*?(?<currency>EGP|جنيه|ج\.م)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At|Merchant)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 100,
  extracted_fields  = '{"amount": "amount", "balance": "balance", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000001';

-- 10000000-0000-4000-8000-000000000002
UPDATE public.sms_parsers SET
  sender_pattern    = '^(CIB|CIB Alerts)$',
  message_pattern   = '[\s\S]*(?:Purchase|Debit|شراء|خصم)[\s\S]*?(?<currency>EGP|جنيه|ج\.م)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:At|لدى|Merchant)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 100,
  extracted_fields  = '{"amount": "amount", "balance": "balance", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000002';

-- 10000000-0000-4000-8000-000000000003
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Banque Misr|BM)$',
  message_pattern   = '[\s\S]*(?:خصم|شراء|Debit|Purchase)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|At|Merchant)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 90,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000003';

-- 10000000-0000-4000-8000-000000000004
UPDATE public.sms_parsers SET
  sender_pattern    = '^(QNB|QNB ALAHLI|QNB AlAhli)$',
  message_pattern   = '[\s\S]*(?:خصم|شراء|Debit|Purchase)[\s\S]*?(?<currency>EGP|جنيه|ج\.م)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At|Merchant)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 90,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000004';

-- 10000000-0000-4000-8000-000000000005
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Vodafone Cash|VF-Cash|Vodafone)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|سحب|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 80,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000005';

-- 10000000-0000-4000-8000-000000000006
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Orange Money|Orange)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 70,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000006';

-- 10000000-0000-4000-8000-000000000007
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Etisalat Cash|Etisalat)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 70,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000007';

-- 10000000-0000-4000-8000-000000000008
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Fawry|myFawry)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 60,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000008';

-- 10000000-0000-4000-8000-000000000101
UPDATE public.sms_parsers SET
  sender_pattern    = '^(SNB|AlAhli|Al Ahli)$',
  message_pattern   = '[\s\S]*(?:شراء|دفع|Purchase|Payment)[\s\S]*?(?:(?<=(?:SAR|ريال|ر\.س)[ :]{0,3})|(?=[0-9][0-9,]*(?:\.[0-9]{1,3})?[ ]{0,3}(?:SAR|ريال|ر\.س)))(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 100,
  extracted_fields  = '{"amount": "amount", "balance": "balance", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000101';

-- 10000000-0000-4000-8000-000000000102
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Rajhi|AlRajhi)$',
  message_pattern   = '[\s\S]*(?:شراء|دفع|Purchase|Payment)[\s\S]*?(?:SAR|ريال|ر\.س)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 90,
  extracted_fields  = '{"amount": "amount", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000102';

-- 10000000-0000-4000-8000-000000000103
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Riyad)$',
  message_pattern   = '[\s\S]*(?:شراء|دفع|Purchase|Payment)[\s\S]*?(?:SAR|ريال|ر\.س)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 80,
  extracted_fields  = '{"amount": "amount", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000103';

-- 10000000-0000-4000-8000-000000000104
UPDATE public.sms_parsers SET
  sender_pattern    = '^(STCPay|STC Pay)$',
  message_pattern   = '[\s\S]*(?:الدفع|دفعت|Paid|Payment)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?:SAR|ريال|ر\.س)?[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 80,
  extracted_fields  = '{"amount": "amount", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000104';

DO $$
DECLARE missing INT;
BEGIN
  SELECT count(*) INTO missing FROM (VALUES
    ('10000000-0000-4000-8000-000000000001'),
    ('10000000-0000-4000-8000-000000000002'),
    ('10000000-0000-4000-8000-000000000003'),
    ('10000000-0000-4000-8000-000000000004'),
    ('10000000-0000-4000-8000-000000000005'),
    ('10000000-0000-4000-8000-000000000006'),
    ('10000000-0000-4000-8000-000000000007'),
    ('10000000-0000-4000-8000-000000000008'),
    ('10000000-0000-4000-8000-000000000101'),
    ('10000000-0000-4000-8000-000000000102'),
    ('10000000-0000-4000-8000-000000000103'),
    ('10000000-0000-4000-8000-000000000104')
  ) AS want(id)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.sms_parsers p WHERE p.id = want.id::uuid
  );
  IF missing > 0 THEN
    RAISE EXCEPTION 'canonical parser rules: % id(s) absent from sms_parsers', missing;
  END IF;
END $$;

-- ── POSTCONDITIONS ──────────────────────────────────────────────────────────
DO $$
DECLARE
  bad INT;
  snb TEXT;
  prior_passed INT;
BEGIN
  SELECT passed_before INTO prior_passed FROM _0099_before;
  -- Evidence is rule-scoped and provable.
  SELECT count(*) INTO bad FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'parser_golden_tests'
     AND column_name IN ('parser_id', 'expected_balance', 'provenance');
  IF bad <> 3 THEN
    RAISE EXCEPTION '0099 postcondition: golden evidence columns missing (found %)', bad;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'parser_golden_tests'
       AND column_name = 'parser_id' AND is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION '0099 postcondition: parser_id must be NOT NULL';
  END IF;

  -- The SNB rule carries the bilingual, evidence-backed amount grammar.
  SELECT message_pattern INTO snb FROM public.sms_parsers
   WHERE id = '10000000-0000-4000-8000-000000000101';
  IF snb IS NULL THEN
    RAISE EXCEPTION '0099 postcondition: SNB rule missing';
  END IF;
  IF position('(?<=' in snb) = 0 OR position('(?=' in snb) = 0 THEN
    RAISE EXCEPTION '0099 postcondition: SNB lost the currency-adjacency grammar';
  END IF;

  -- And nothing here promoted anything.
  --
  -- Asserted as "unchanged", not "zero". A global count of zero would abort in
  -- any environment holding a LEGITIMATELY promoted parser, even though this
  -- migration writes no validation column at all — punishing a correct state.
  -- The snapshot is taken at the top of this same transaction.
  IF (SELECT count(*) FROM public.sms_parsers WHERE validation_status = 'passed')
     <> prior_passed THEN
    RAISE EXCEPTION
      '0099 postcondition: promoted parser count changed (% -> %); this '
      'migration promotes none',
      prior_passed,
      (SELECT count(*) FROM public.sms_parsers WHERE validation_status = 'passed');
  END IF;

  RAISE LOG '0099 postconditions passed';
END $$;

COMMIT;

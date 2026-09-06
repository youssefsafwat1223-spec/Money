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

-- ── 2. Pre-image journal, so section 3 is exactly reversible ────────────────
--
-- The generated UPDATEs below overwrite six canonical fields on all twelve
-- rules. For eleven of them that writes the value already there, but a rule an
-- admin had edited away from canonical WOULD be silently overwritten and the
-- rollback could not restore it. Same shape as the 0087 journal: capture the
-- pre-image first, and have the rollback replay it.
CREATE TABLE IF NOT EXISTS public.sms_parsers_canonical_reset_0099 (
  parser_id            UUID PRIMARY KEY,
  sender_pattern       TEXT NOT NULL,
  message_pattern      TEXT NOT NULL,
  transaction_type     TEXT NOT NULL,
  language             TEXT NOT NULL,
  priority             INT  NOT NULL,
  extracted_fields     JSONB NOT NULL,
  captured_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 0092's lesson: a bare CREATE TABLE in `public` inherits platform default
-- grants for anon/authenticated. This journal holds every parser rule body, so
-- lock it down explicitly rather than relying on silence.
ALTER TABLE public.sms_parsers_canonical_reset_0099 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sms_parsers_canonical_reset_0099 FROM PUBLIC;
REVOKE ALL ON public.sms_parsers_canonical_reset_0099 FROM anon, authenticated;

INSERT INTO public.sms_parsers_canonical_reset_0099 (
  parser_id, sender_pattern, message_pattern, transaction_type,
  language, priority, extracted_fields
)
SELECT id, sender_pattern, message_pattern, transaction_type,
       language, priority, extracted_fields
  FROM public.sms_parsers
ON CONFLICT (parser_id) DO NOTHING;

-- ── 3. Canonical rule bodies (GENERATED — see header) ──────────────────────

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
WHERE id = '10000000-0000-4000-8000-000000000001' AND bank_id = '00000000-0000-4000-8000-000000000001';

-- 10000000-0000-4000-8000-000000000002
UPDATE public.sms_parsers SET
  sender_pattern    = '^(CIB|CIB Alerts)$',
  message_pattern   = '[\s\S]*(?:Purchase|Debit|شراء|خصم)[\s\S]*?(?<currency>EGP|جنيه|ج\.م)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:At|لدى|Merchant)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 100,
  extracted_fields  = '{"amount": "amount", "balance": "balance", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000002' AND bank_id = '00000000-0000-4000-8000-000000000002';

-- 10000000-0000-4000-8000-000000000003
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Banque Misr|BM)$',
  message_pattern   = '[\s\S]*(?:خصم|شراء|Debit|Purchase)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|At|Merchant)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 90,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000003' AND bank_id = '00000000-0000-4000-8000-000000000003';

-- 10000000-0000-4000-8000-000000000004
UPDATE public.sms_parsers SET
  sender_pattern    = '^(QNB|QNB ALAHLI|QNB AlAhli)$',
  message_pattern   = '[\s\S]*(?:خصم|شراء|Debit|Purchase)[\s\S]*?(?<currency>EGP|جنيه|ج\.م)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At|Merchant)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 90,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000004' AND bank_id = '00000000-0000-4000-8000-000000000004';

-- 10000000-0000-4000-8000-000000000005
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Vodafone Cash|VF-Cash|Vodafone)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|سحب|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 80,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000005' AND bank_id = '00000000-0000-4000-8000-000000000005';

-- 10000000-0000-4000-8000-000000000006
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Orange Money|Orange)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 70,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000006' AND bank_id = '00000000-0000-4000-8000-000000000006';

-- 10000000-0000-4000-8000-000000000007
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Etisalat Cash|Etisalat)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 70,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000007' AND bank_id = '00000000-0000-4000-8000-000000000007';

-- 10000000-0000-4000-8000-000000000008
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Fawry|myFawry)$',
  message_pattern   = '[\s\S]*(?:دفعت|خصم|Paid|Debit)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?<currency>EGP|جنيه|ج\.م)?[\s\S]*?(?:لدى|to|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 60,
  extracted_fields  = '{"amount": "amount", "currency": "currency", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000008' AND bank_id = '00000000-0000-4000-8000-000000000008';

-- 10000000-0000-4000-8000-000000000101
UPDATE public.sms_parsers SET
  sender_pattern    = '^(SNB|AlAhli|Al Ahli)$',
  message_pattern   = '[\s\S]*(?:شراء|دفع|Purchase|Payment)[\s\S]*?(?:(?<=(?:SAR|ريال|ر\.س)[ :]{0,3})|(?=[0-9][0-9,]*(?:\.[0-9]{1,3})?[ ]{0,3}(?:SAR|ريال|ر\.س)))(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 100,
  extracted_fields  = '{"amount": "amount", "balance": "balance", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000101' AND bank_id = '00000000-0000-4000-8000-000000000101';

-- 10000000-0000-4000-8000-000000000102
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Rajhi|AlRajhi)$',
  message_pattern   = '[\s\S]*(?:شراء|دفع|Purchase|Payment)[\s\S]*?(?:SAR|ريال|ر\.س)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 90,
  extracted_fields  = '{"amount": "amount", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000102' AND bank_id = '00000000-0000-4000-8000-000000000102';

-- 10000000-0000-4000-8000-000000000103
UPDATE public.sms_parsers SET
  sender_pattern    = '^(Riyad)$',
  message_pattern   = '[\s\S]*(?:شراء|دفع|Purchase|Payment)[\s\S]*?(?:SAR|ريال|ر\.س)?\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 80,
  extracted_fields  = '{"amount": "amount", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000103' AND bank_id = '00000000-0000-4000-8000-000000000103';

-- 10000000-0000-4000-8000-000000000104
UPDATE public.sms_parsers SET
  sender_pattern    = '^(STCPay|STC Pay)$',
  message_pattern   = '[\s\S]*(?:الدفع|دفعت|Paid|Payment)[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)\s*(?:SAR|ريال|ر\.س)?[\s\S]*?(?:لدى|At)\s*:?[ ]*(?<merchant>[^\n]+)?',
  transaction_type  = 'debit',
  language          = 'ar_en',
  priority          = 80,
  extracted_fields  = '{"amount": "amount", "currency": "SAR", "merchant": "merchant", "type": "debit"}'::jsonb
WHERE id = '10000000-0000-4000-8000-000000000104' AND bank_id = '00000000-0000-4000-8000-000000000104';

DO $$
DECLARE missing INT;
BEGIN
  SELECT count(*) INTO missing FROM (VALUES
    ('10000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000001'),
    ('10000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000002'),
    ('10000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000003'),
    ('10000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000004'),
    ('10000000-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000005'),
    ('10000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000006'),
    ('10000000-0000-4000-8000-000000000007', '00000000-0000-4000-8000-000000000007'),
    ('10000000-0000-4000-8000-000000000008', '00000000-0000-4000-8000-000000000008'),
    ('10000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000101'),
    ('10000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000102'),
    ('10000000-0000-4000-8000-000000000103', '00000000-0000-4000-8000-000000000103'),
    ('10000000-0000-4000-8000-000000000104', '00000000-0000-4000-8000-000000000104')
  ) AS want(id, bank_id)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.sms_parsers p
     WHERE p.id = want.id::uuid AND p.bank_id = want.bank_id::uuid
  );
  IF missing > 0 THEN
    RAISE EXCEPTION
      'canonical parser rules: % rule(s) absent or bound to a different bank', missing;
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
  -- EXACT SCHEMA CONTRACT.
  --
  -- ADD COLUMN IF NOT EXISTS is idempotent, which also means it is SILENT: a
  -- pre-staged column of the wrong type, a foreign key pointing elsewhere or
  -- with different actions, a CHECK admitting different values, or an index on
  -- the wrong columns all survive untouched while the migration reports
  -- success. These assert the FINAL contract rather than the fact that a name
  -- exists, so a materially different pre-staged object FAILS here.

  -- parser_id: present, NOT NULL, uuid.
  SELECT count(*) INTO bad FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'parser_golden_tests'
     AND column_name = 'parser_id' AND is_nullable = 'NO' AND data_type = 'uuid';
  IF bad <> 1 THEN
    RAISE EXCEPTION '0099: parser_id must exist as NOT NULL uuid (matched %)', bad;
  END IF;

  -- expected_balance: present, numeric, nullable (absence of evidence is not a
  -- failure; the validator decides whether a claim went unproven).
  SELECT count(*) INTO bad FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'parser_golden_tests'
     AND column_name = 'expected_balance' AND data_type = 'numeric'
     AND is_nullable = 'YES';
  IF bad <> 1 THEN
    RAISE EXCEPTION '0099: expected_balance must be a nullable numeric (matched %)', bad;
  END IF;

  -- The FK must target sms_parsers(id) and cascade deletes: evidence for a rule
  -- that no longer exists is not evidence.
  SELECT count(*) INTO bad
    FROM pg_constraint c
    JOIN pg_class child ON child.oid = c.conrelid
    JOIN pg_class parent ON parent.oid = c.confrelid
    JOIN pg_attribute ca ON ca.attrelid = c.conrelid AND ca.attnum = c.conkey[1]
    JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1]
   WHERE c.contype = 'f'
     AND child.relname = 'parser_golden_tests'
     AND ca.attname = 'parser_id'
     AND parent.relname = 'sms_parsers'
     AND pa.attname = 'id'
     AND c.confdeltype = 'c'                       -- ON DELETE CASCADE
     AND array_length(c.conkey, 1) = 1;
  IF bad <> 1 THEN
    RAISE EXCEPTION
      '0099: parser_id must have exactly one FK to sms_parsers(id) ON DELETE CASCADE (matched %)',
      bad;
  END IF;

  -- No SECOND foreign key on parser_id pointing somewhere else.
  SELECT count(*) INTO bad
    FROM pg_constraint c
    JOIN pg_class child ON child.oid = c.conrelid
    JOIN pg_attribute ca ON ca.attrelid = c.conrelid AND ca.attnum = c.conkey[1]
   WHERE c.contype = 'f' AND child.relname = 'parser_golden_tests'
     AND ca.attname = 'parser_id';
  IF bad <> 1 THEN
    RAISE EXCEPTION '0099: parser_id carries % foreign keys; expected exactly 1', bad;
  END IF;

  -- provenance CHECK admits EXACTLY the intended vocabulary.
  SELECT count(*) INTO bad FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
   WHERE t.relname = 'parser_golden_tests' AND c.contype = 'c'
     AND pg_get_constraintdef(c.oid) LIKE '%provenance%'
     AND pg_get_constraintdef(c.oid) LIKE '%bank_documented%'
     AND pg_get_constraintdef(c.oid) LIKE '%bank_sandbox%'
     AND pg_get_constraintdef(c.oid) LIKE '%controlled_transaction%'
     AND pg_get_constraintdef(c.oid) LIKE '%anonymized_fixture%'
     AND pg_get_constraintdef(c.oid) LIKE '%synthetic_negative%';
  IF bad <> 1 THEN
    RAISE EXCEPTION
      '0099: provenance CHECK must admit exactly the five intended values (matched %)', bad;
  END IF;

  -- expected_type CHECK must include reversal, and there must be only one.
  SELECT count(*) INTO bad FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
   WHERE t.relname = 'parser_golden_tests' AND c.contype = 'c'
     AND pg_get_constraintdef(c.oid) LIKE '%expected_type%';
  IF bad <> 1 THEN
    RAISE EXCEPTION
      '0099: expected_type must have exactly one CHECK (found %) — a stale '
      'duplicate would admit a different vocabulary', bad;
  END IF;
  SELECT count(*) INTO bad FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
   WHERE t.relname = 'parser_golden_tests' AND c.contype = 'c'
     AND pg_get_constraintdef(c.oid) LIKE '%expected_type%'
     AND pg_get_constraintdef(c.oid) LIKE '%reversal%'
     AND pg_get_constraintdef(c.oid) LIKE '%debit%'
     AND pg_get_constraintdef(c.oid) LIKE '%credit%'
     AND pg_get_constraintdef(c.oid) LIKE '%balance_inquiry%'
     AND pg_get_constraintdef(c.oid) LIKE '%ignored%';
  IF bad <> 1 THEN
    RAISE EXCEPTION '0099: expected_type CHECK is missing an intended value';
  END IF;

  -- The index must exist ON parser_id specifically, not merely by name.
  SELECT count(*) INTO bad
    FROM pg_index i
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = i.indkey[0]
   WHERE t.relname = 'parser_golden_tests'
     AND a.attname = 'parser_id'
     AND i.indnatts = 1;
  IF bad < 1 THEN
    RAISE EXCEPTION '0099: no single-column index on parser_golden_tests(parser_id)';
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

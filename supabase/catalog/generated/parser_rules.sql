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

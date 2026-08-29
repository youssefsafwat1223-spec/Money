-- 0091 — catalog parser rules must not assume a 2-decimal currency.
--
-- All twelve rules seeded by 0002_catalog_mvp.sql capture the amount with:
--
--     (?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)
--
-- The `{1,2}` quantifier hard-codes a 2-decimal assumption. Against a
-- 3-decimal currency (KWD, BHD, OMR, JOD, TND, LYD, IQD — all registered in
-- `app/lib/domain/finance/currency_scale.dart`) it captures `12.45` out of
-- `12.450`: a silent 10x error in canonical minor units, and undetectable
-- downstream because `12.45` is itself a valid amount.
--
-- LATENT, NOT LIVE, at the time of this migration: all twelve seeded rules
-- target Egyptian and Saudi senders, both 2-decimal. The defect fires the first
-- time a Kuwait/Bahrain/Oman rule is authored through the admin Parser Lab —
-- which is precisely the workflow the catalog exists to enable.
--
-- Widening to `{1,3}` covers every scale the currency contract registers
-- (0, 2 and 3 minor digits). It does NOT loosen anything else: a 2-decimal
-- currency message simply has no third decimal to capture.
--
-- Defence in depth: `untruncatedAmount()` in
-- `app/lib/engine/parser/catalog_rule_matcher.dart` independently rejects any
-- rule-captured amount that is a prefix of a longer number in the message, so
-- the device is protected from a badly-quantified rule regardless of what the
-- catalog serves. This migration fixes the data; that guard fixes the contract.
--
-- Idempotent and narrowly scoped: it rewrites ONLY the exact `{1,2}` decimal
-- quantifier inside the amount group, and only where it still appears.

-- NOTE ON `strpos` vs `LIKE`: the needle contains a backslash (`\.`), and
-- PostgreSQL's LIKE treats backslash as an ESCAPE character by default. Written
-- as `LIKE '%…(?:\.[0-9]{1,2}…%'` the pattern searches for a literal `.` rather
-- than `\.`, matches nothing, and the migration silently updates 0 rows while
-- reporting success. `strpos` is a plain substring search with no escape
-- semantics, so it means what it reads. (This was caught by
-- research/sms_model_lab/migration_check/verify_0091.sh, not by review.)

UPDATE sms_parsers
SET message_pattern = replace(
      message_pattern,
      '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)'
    ),
    updated_at = now()
WHERE strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)') > 0
  AND is_deleted = false;

-- The same cap appears in the balance group of the rules that declare one.
UPDATE sms_parsers
SET message_pattern = replace(
      message_pattern,
      '(?<balance>[0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      '(?<balance>[0-9][0-9,]*(?:\.[0-9]{1,3})?)'
    ),
    updated_at = now()
WHERE strpos(message_pattern, '(?<balance>[0-9][0-9,]*(?:\.[0-9]{1,2})?)') > 0
  AND is_deleted = false;

DO $$
DECLARE
  remaining int;
BEGIN
  SELECT count(*) INTO remaining
  FROM sms_parsers
  WHERE is_deleted = false
    AND strpos(message_pattern, '[0-9]{1,2}') > 0;

  IF remaining > 0 THEN
    RAISE WARNING
      '0091: % active parser rule(s) still carry a {1,2} decimal cap; review them in the admin Parser Lab',
      remaining;
  END IF;
END $$;

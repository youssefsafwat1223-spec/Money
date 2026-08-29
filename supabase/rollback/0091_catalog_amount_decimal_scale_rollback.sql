-- ROLLBACK for 0091_catalog_amount_decimal_scale.sql
--
-- 0091 widens the decimal cap in the catalog parser rules from {1,2} to {1,3}
-- so a 3-decimal currency (KWD 12.345, BHD, OMR, TND) is captured in full
-- rather than truncated to two places.
--
-- Reversible by the exact inverse replace. It is a targeted substring swap on
-- the two named groups 0091 touched, NOT a blanket {1,3} -> {1,2}, so a rule
-- that legitimately declares three decimals elsewhere is left alone.
--
-- `strpos` rather than LIKE, for the reason 0091 documents: the needle contains
-- a backslash, and LIKE would treat it as an escape character, match nothing,
-- and report success having changed no rows.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT YOU LOSE, and why you probably should not run this.
--
-- With the {1,2} cap restored, a 12.345 KWD transaction parses as 12.34 — the
-- app records a DIFFERENT AMOUNT than the bank sent, silently, with no error.
-- This is money corruption at the point of capture, not a display issue, and it
-- is not repaired by rolling forward again later: the wrong value is already
-- stored.
--
-- Roll this back ONLY if the widened group is demonstrably mis-parsing a
-- specific bank's format, and prefer fixing that one rule in the Parser Lab.
-- ─────────────────────────────────────────────────────────────────────────────

begin;

update sms_parsers
set message_pattern = replace(
      message_pattern,
      '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)',
      '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)'
    ),
    updated_at = now()
where strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)') > 0
  and is_deleted = false;

update sms_parsers
set message_pattern = replace(
      message_pattern,
      '(?<balance>[0-9][0-9,]*(?:\.[0-9]{1,3})?)',
      '(?<balance>[0-9][0-9,]*(?:\.[0-9]{1,2})?)'
    ),
    updated_at = now()
where strpos(message_pattern, '(?<balance>[0-9][0-9,]*(?:\.[0-9]{1,3})?)') > 0
  and is_deleted = false;

commit;

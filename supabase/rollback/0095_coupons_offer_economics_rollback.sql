-- ROLLBACK for 0095_coupons_offer_economics.sql
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THIS DISCARDS EVERY STRUCTURED OFFER VALUE AND THE MERCHANT LINK ON COUPONS.
--
-- The columns are hand-entered by admins: the discount rate, the cap, the
-- minimum spend and the verification decision for each live offer. Dropping them
-- deletes that data outright — a re-apply gives back empty columns, not the
-- values. The prose in title_ar / description_ar / terms_ar survives, because it
-- was always the display authority and 0095 never touched it.
--
-- 0095 is purely additive and every column is nullable, so it cannot break an
-- older client: one that does not select these columns behaves exactly as it did
-- before. There is no compatibility reason to run this.
--
-- For a behavioural problem, use the flag. Savings and value chips are behind
-- `enable_savings_claims` and `enable_offers_merchants`, both seeded OFF, and
-- turning either off stops the client reading these fields immediately without
-- touching data.
--
-- Run this only to reclaim a schema — a rebuilt staging project, or an abandoned
-- feature — never to fix a bug in production.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- EVIDENCE BASIS — the pre-0095 shape of `coupons`, verified in 0081_coupons.sql:
-- id, slug, partner_name, title_ar/en, description_ar/en, redemption_type, code,
-- partner_url, display_category_key, spend_hint_category_keys, country_codes,
-- accent_hex, image_path, featured, priority, valid_from, valid_until,
-- is_active, terms_ar, created_at, updated_at. None of the ten columns below
-- existed, and none of the ten constraints did either.
--
-- ORDER: constraints before columns. DROP COLUMN would take its constraints
-- along silently; naming them makes the reversal auditable and fails loudly if
-- 0095 ever grows a constraint this file does not know about.

BEGIN;

ALTER TABLE coupons
  DROP CONSTRAINT IF EXISTS coupons_benefit_type_shape,
  DROP CONSTRAINT IF EXISTS coupons_source_shape,
  DROP CONSTRAINT IF EXISTS coupons_verification_state_shape,
  DROP CONSTRAINT IF EXISTS coupons_discount_bps_range,
  DROP CONSTRAINT IF EXISTS coupons_minor_amounts_nonneg,
  DROP CONSTRAINT IF EXISTS coupons_benefit_currency_required,
  DROP CONSTRAINT IF EXISTS coupons_benefit_currency_shape,
  DROP CONSTRAINT IF EXISTS coupons_benefit_shape_matches_type,
  DROP CONSTRAINT IF EXISTS coupons_max_saving_only_for_percent,
  DROP CONSTRAINT IF EXISTS coupons_verified_at_matches_state;

DROP INDEX IF EXISTS idx_coupons_merchant;

ALTER TABLE coupons
  DROP COLUMN IF EXISTS merchant_id,
  DROP COLUMN IF EXISTS benefit_type,
  DROP COLUMN IF EXISTS discount_bps,
  DROP COLUMN IF EXISTS fixed_amount_minor,
  DROP COLUMN IF EXISTS min_spend_minor,
  DROP COLUMN IF EXISTS max_saving_minor,
  DROP COLUMN IF EXISTS benefit_currency,
  DROP COLUMN IF EXISTS source,
  DROP COLUMN IF EXISTS verification_state,
  DROP COLUMN IF EXISTS verified_at;

DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_name = 'coupons'
     AND column_name IN ('merchant_id','benefit_type','discount_bps','fixed_amount_minor',
                         'min_spend_minor','max_saving_minor','benefit_currency',
                         'source','verification_state','verified_at');
  IF n <> 0 THEN RAISE EXCEPTION 'rollback 0095: % column(s) survived', n; END IF;
  RAISE NOTICE 'rollback 0095: structured offer economics removed — admin-entered values are gone';
END $$;

COMMIT;

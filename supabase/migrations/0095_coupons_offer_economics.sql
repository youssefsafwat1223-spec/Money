-- 0095 — structured offer economics on coupons (COUPONS Phase 1).
--
-- 0081 stores an offer's value as prose: "خصم ٢٠٪" lives inside title_ar,
-- description_ar or terms_ar and nowhere else. That is fine for rendering a card
-- and impossible to compute with, so today the app cannot say what an offer is
-- worth, cannot rank by value, and cannot record a saving.
--
-- This adds the structured half. The prose stays the DISPLAY AUTHORITY — a
-- discount is a legal claim to the user and the merchant's own wording governs
-- it — while the structured fields exist for arithmetic. Where the two disagree,
-- the prose is what the user was promised.
--
-- ADDITIVE AND ALL-NULLABLE. Every existing row stays valid and every existing
-- client keeps working: a coupon with no structured value simply has none, and
-- the savings layer must abstain rather than invent one. That abstention is the
-- design, not a gap — a fabricated saving in a finance app is worse than no
-- number at all.

ALTER TABLE coupons
  ADD COLUMN IF NOT EXISTS merchant_id UUID REFERENCES catalog_merchants(id),
  -- What KIND of value this is. Without it, a bare number is ambiguous: 20 could
  -- be 20% or 20 riyals, and guessing is how a savings ledger becomes fiction.
  ADD COLUMN IF NOT EXISTS benefit_type TEXT,
  -- Basis points, not a percentage: 12.5% is 1250 and stays an integer. Money
  -- and rates in this codebase are exact integers (kV30MinorColumns,
  -- kCurrencyScale) precisely so no float rounding reaches a user's ledger.
  ADD COLUMN IF NOT EXISTS discount_bps INT,
  ADD COLUMN IF NOT EXISTS fixed_amount_minor BIGINT,
  ADD COLUMN IF NOT EXISTS min_spend_minor BIGINT,
  -- The cap on a percentage offer: "20% off, up to 50 SAR". Without it the
  -- estimate is unbounded and wrong on exactly the large baskets where the user
  -- would notice.
  ADD COLUMN IF NOT EXISTS max_saving_minor BIGINT,
  ADD COLUMN IF NOT EXISTS benefit_currency TEXT,
  -- Where the offer came from. A future direct merchant deal is source =
  -- 'direct_deal' plus an adapter, not a second offers system.
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'manual',
  -- Whether anyone has actually confirmed the offer works. Shown to the user,
  -- because "we checked this" and "a provider feed said so" are different
  -- promises.
  ADD COLUMN IF NOT EXISTS verification_state TEXT NOT NULL DEFAULT 'unverified',
  ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ;

-- Enum shapes. Added separately from the columns so re-running the migration on
-- a database that already has the columns still installs the constraints.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_benefit_type_shape') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_benefit_type_shape CHECK (
      benefit_type IS NULL
      OR benefit_type IN ('percent','fixed_amount','free_shipping','other')
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_source_shape') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_source_shape CHECK (
      source IN ('manual','affiliate','direct_deal')
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_verification_state_shape') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_verification_state_shape CHECK (
      verification_state IN ('unverified','admin_verified','provider_verified')
    );
  END IF;

  -- A percentage must be a real percentage. 0 is not a discount and >100% is
  -- not an offer; both would produce a savings figure that embarrasses us.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_discount_bps_range') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_discount_bps_range CHECK (
      discount_bps IS NULL OR (discount_bps > 0 AND discount_bps <= 10000)
    );
  END IF;

  -- Minor units are counts of the smallest unit; negative is meaningless.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_minor_amounts_nonneg') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_minor_amounts_nonneg CHECK (
      (fixed_amount_minor IS NULL OR fixed_amount_minor > 0)
      AND (min_spend_minor  IS NULL OR min_spend_minor  >= 0)
      AND (max_saving_minor IS NULL OR max_saving_minor >  0)
    );
  END IF;

  -- THE important one. A minor-unit integer is meaningless without knowing the
  -- currency: 5000 is 50.00 SAR and 50.00 EGP and 5000 JPY. Storing an amount
  -- with no currency would let the client pick one, which is how a user gets
  -- told they saved a number in the wrong money.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_benefit_currency_required') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_benefit_currency_required CHECK (
      (fixed_amount_minor IS NULL AND min_spend_minor IS NULL AND max_saving_minor IS NULL)
      OR benefit_currency IS NOT NULL
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_benefit_currency_shape') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_benefit_currency_shape CHECK (
      benefit_currency IS NULL OR benefit_currency ~ '^[A-Z]{3}$'
    );
  END IF;

  -- Each benefit type must carry the field it needs and not the field it does
  -- not. A 'percent' offer with only a fixed amount is a data-entry error that
  -- would otherwise surface as a silently wrong estimate.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_benefit_shape_matches_type') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_benefit_shape_matches_type CHECK (
      benefit_type IS NULL
      OR (benefit_type = 'percent'       AND discount_bps IS NOT NULL AND fixed_amount_minor IS NULL)
      OR (benefit_type = 'fixed_amount'  AND fixed_amount_minor IS NOT NULL AND discount_bps IS NULL)
      OR (benefit_type = 'free_shipping' AND discount_bps IS NULL AND fixed_amount_minor IS NULL)
      OR (benefit_type = 'other'         AND discount_bps IS NULL AND fixed_amount_minor IS NULL)
    );
  END IF;

  -- A cap only means something for a percentage. On a fixed amount it is either
  -- redundant or contradictory.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_max_saving_only_for_percent') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_max_saving_only_for_percent CHECK (
      max_saving_minor IS NULL OR benefit_type = 'percent'
    );
  END IF;

  -- verified_at is evidence of the verification, so the two must agree.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'coupons_verified_at_matches_state') THEN
    ALTER TABLE coupons ADD CONSTRAINT coupons_verified_at_matches_state CHECK (
      (verification_state = 'unverified' AND verified_at IS NULL)
      OR (verification_state <> 'unverified' AND verified_at IS NOT NULL)
    );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_coupons_merchant
  ON coupons (merchant_id) WHERE is_active = true;

COMMENT ON COLUMN coupons.discount_bps IS
  'Basis points (1250 = 12.5%). Integer so no float rounding reaches a savings figure.';
COMMENT ON COLUMN coupons.benefit_currency IS
  'Required whenever any minor-unit amount is set. A minor-unit integer without a currency is not an amount.';
COMMENT ON COLUMN coupons.verification_state IS
  'unverified | admin_verified | provider_verified. Surfaced to the user: "we checked this" and "a feed said so" are different promises.';

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_name = 'coupons'
     AND column_name IN ('merchant_id','benefit_type','discount_bps','fixed_amount_minor',
                         'min_spend_minor','max_saving_minor','benefit_currency',
                         'source','verification_state','verified_at');
  IF n <> 10 THEN RAISE EXCEPTION '0095: expected 10 new coupon columns, found %', n; END IF;

  SELECT count(*) INTO n FROM pg_constraint
   WHERE conrelid = 'public.coupons'::regclass
     AND conname LIKE 'coupons_%'
     AND conname IN ('coupons_benefit_type_shape','coupons_source_shape',
                     'coupons_verification_state_shape','coupons_discount_bps_range',
                     'coupons_minor_amounts_nonneg','coupons_benefit_currency_required',
                     'coupons_benefit_currency_shape','coupons_benefit_shape_matches_type',
                     'coupons_max_saving_only_for_percent','coupons_verified_at_matches_state');
  IF n <> 10 THEN RAISE EXCEPTION '0095: expected 10 new coupon constraints, found %', n; END IF;

  -- Every pre-existing row must still be valid; an additive migration that
  -- invalidates history is not additive.
  IF EXISTS (SELECT 1 FROM coupons WHERE source IS NULL OR verification_state IS NULL) THEN
    RAISE EXCEPTION '0095: existing coupons were left without a source/verification default';
  END IF;
END $$;

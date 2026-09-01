-- ROLLBACK for 0094_catalog_merchants.sql
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THIS DESTROYS THE MERCHANT CATALOG AND EVERY REVIEWED ALIAS.
--
-- Aliases are hand-curated. Each one is a human decision that this exact string,
-- in this exact market, means this exact business — and the reviewed set is the
-- only thing standing between "relevant offer" and "we told a user they shop
-- somewhere they have never been". Dropping the tables throws that work away;
-- there is no way to reconstruct it from anything else in the database.
--
-- 0094 is additive. It adds two tables, three functions and two catalog_versions
-- rows, and it modifies nothing that existed before. Nothing outside the coupons
-- Phase-1 feature reads any of it, and every device surface is behind
-- `enable_offers_merchants`, which is seeded OFF.
--
-- So the correct rollback for a behavioural problem is THE FLAG, not this file.
-- Turning the flag off makes the client stop reading the catalog immediately,
-- fleet-wide, with no migration and no data loss.
--
-- Run this only to reclaim a schema — a rebuilt staging project, or an
-- abandoned feature — never to fix a bug in production.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- EVIDENCE BASIS — what existed before 0094, verified in source:
--
--   * No `catalog_merchants`, no `catalog_merchant_aliases`. Grep of every
--     migration 0001–0093 finds neither name; the coupons chain (0081/0082) is
--     coupons-only.
--   * No `merchant_alias_key_v1`, `merchant_domain_key_v1` or
--     `merchant_lookup_noise_v1`.
--   * No `catalog_versions` rows for 'catalog_merchants' or 'merchant_aliases'.
--   * No sequences `catalog_seq_catalog_merchants` / `catalog_seq_merchant_aliases`.
--
-- This restores exactly that. It does not invent a prior state.
--
-- ORDERING: the alias table's generated column depends on the key functions, so
-- the tables must go first. Dropping a function that a generated column still
-- references fails, and CASCADE there would silently drop the column instead.

BEGIN;

DROP TABLE IF EXISTS catalog_merchant_aliases;
DROP TABLE IF EXISTS catalog_merchants;

DROP FUNCTION IF EXISTS trg_guard_merchant_alias();
DROP FUNCTION IF EXISTS trg_version_catalog_merchants();
DROP FUNCTION IF EXISTS trg_version_merchant_aliases();
DROP FUNCTION IF EXISTS trg_version_bump_on_delete();
DROP FUNCTION IF EXISTS merchant_lookup_noise_v1(TEXT);
DROP FUNCTION IF EXISTS merchant_alias_key_v1(TEXT);
DROP FUNCTION IF EXISTS merchant_domain_key_v1(TEXT);

DROP SEQUENCE IF EXISTS catalog_seq_catalog_merchants;
DROP SEQUENCE IF EXISTS catalog_seq_merchant_aliases;

-- Removing the catalog_versions rows is correct here, unlike in 0093: those
-- categories no longer exist, so a device asking for a delta gets the
-- unknown-category path rather than a version that will never move again.
DELETE FROM catalog_versions WHERE category IN ('catalog_merchants', 'merchant_aliases');

DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('catalog_merchants', 'catalog_merchant_aliases');
  IF n <> 0 THEN RAISE EXCEPTION 'rollback 0094: % table(s) survived', n; END IF;

  SELECT count(*) INTO n FROM pg_proc
   WHERE proname IN ('merchant_alias_key_v1', 'merchant_domain_key_v1', 'merchant_lookup_noise_v1');
  IF n <> 0 THEN RAISE EXCEPTION 'rollback 0094: % key function(s) survived', n; END IF;

  RAISE NOTICE 'rollback 0094: merchant catalog removed — every reviewed alias is gone';
END $$;

COMMIT;

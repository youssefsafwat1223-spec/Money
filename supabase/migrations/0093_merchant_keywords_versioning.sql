-- 0093 — merchant_keywords delta versioning repair (COUPONS Phase 0).
--
-- THE DEFECT
--
-- `merchant_keywords` is category-level versioned: catalog-delta returns a
-- snapshot only when `catalog_versions.merchant_keywords` exceeds the version
-- the device already holds (catalog-delta/index.ts:183-214 —
-- `if (since >= version) return { items: [], deletedIds: [] }`).
--
-- The row was seeded at version 1 in 0006_merchant_keywords.sql:30 and NOTHING
-- HAS EVER BUMPED IT:
--   * 0006 created an index and a SELECT policy — no version trigger;
--   * `enrich-merchant` upserts keyword rows (index.ts:353/369/370) and never
--     touches catalog_versions;
--   * no admin API route writes merchant_keywords or catalog_versions.
--
-- Consequence: every device that has synced ONCE is pinned at version 1 and can
-- never receive a keyword addition, a re-categorisation, or a deactivation. The
-- dictionary has been effectively frozen on-device since 0006 shipped.
--
-- Note 0054_catalog_versions_rls.sql:12-14, which reasons about "the
-- version-bump triggers (… 0006_merchant_keywords.sql)". No such trigger has
-- ever existed. The comment asserted a mechanism into being, which is part of
-- why this went unnoticed: reading the codebase told you the bump was handled.
--
-- WHY A TRIGGER AND NOT A WRITE-PATH FIX
--
-- Fixing `enrich-merchant` alone would leave every other writer uncovered —
-- today the admin panel and any service-role SQL, tomorrow whatever Phase 1
-- adds. The bump has to be a property of the TABLE, not a habit of its callers.
-- A trigger is the only mechanism that no writer can forget or bypass.
--
-- Invoker rights (no SECURITY DEFINER) is correct here and is the same
-- reasoning 0054 records: merchant_keywords has no INSERT/UPDATE policy for
-- anon or authenticated, so every writer that can reach the table at all is
-- service_role, which bypasses catalog_versions' RLS. A definer function would
-- add an unnecessary privilege-escalation surface to protect against a writer
-- that cannot exist.

-- ── The version source ──────────────────────────────────────────────────────
-- One sequence per catalog category, matching catalog_seq_banks et al (0002).
CREATE SEQUENCE IF NOT EXISTS catalog_seq_merchant_keywords;

-- Defensive: 0006's seed is ON CONFLICT DO NOTHING, so on any database where
-- the row is absent the trigger below would silently update zero rows.
INSERT INTO catalog_versions (category, version, updated_at)
VALUES ('merchant_keywords', 1, now())
ON CONFLICT (category) DO NOTHING;

-- Advance the sequence PAST whatever version production is actually holding.
-- Devices are pinned at the version they last saw; if the sequence started at 1
-- the first bump would emit a value they already have and the snapshot would
-- still be withheld. Read the stored value rather than assuming the seed — this
-- database may have been bumped by hand at some point.
DO $$
BEGIN
  PERFORM setval(
    'catalog_seq_merchant_keywords',
    GREATEST((SELECT version FROM catalog_versions WHERE category = 'merchant_keywords'), 1),
    true  -- is_called: the NEXT nextval() returns stored_version + 1
  );
END $$;

-- ── The bump ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_version_merchant_keywords() RETURNS TRIGGER AS $$
BEGIN
  UPDATE catalog_versions
     SET version = nextval('catalog_seq_merchant_keywords'),
         updated_at = now()
   WHERE category = 'merchant_keywords';
  -- AFTER-trigger return values are ignored; returning the right record anyway
  -- so the function stays correct if it is ever reattached as BEFORE.
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Two attachment points, ONE function.
--
-- INSERT and DELETE always change what a device should see, so they bump
-- unconditionally. DELETE is included deliberately: the table supports soft
-- delete via is_deleted, but a hard delete through PostgREST or SQL would
-- otherwise leave the removed keyword resident on every synced device forever.
DROP TRIGGER IF EXISTS trg_merchant_keywords_version_ins_del ON merchant_keywords;
CREATE TRIGGER trg_merchant_keywords_version_ins_del
  AFTER INSERT OR DELETE ON merchant_keywords
  FOR EACH ROW EXECUTE FUNCTION trg_version_merchant_keywords();

-- UPDATE bumps only when a column a DEVICE consumes actually changes.
--
-- This is not premature optimisation. `enrich-merchant` stamps
-- `updated_at: new Date().toISOString()` on every upsert (index.ts:367), so a
-- blanket `OLD.* IS DISTINCT FROM NEW.*` would bump on a re-enrichment that
-- changed nothing, up to 200 times a day, and force every device on the fleet
-- to re-download the dictionary daily. Version would come to mean "somebody
-- wrote" instead of "something changed".
--
-- Every column served by catalog-delta's `select('*')` is listed except
-- `updated_at` and `id`; a device holding a stale `updated_at` is harmless
-- because nothing on the client reads it. If a column is ever ADDED to this
-- table it must be added here too, or changes to it will not reach devices —
-- the regression test asserts this list against the live column set.
DROP TRIGGER IF EXISTS trg_merchant_keywords_version_upd ON merchant_keywords;
CREATE TRIGGER trg_merchant_keywords_version_upd
  AFTER UPDATE ON merchant_keywords
  FOR EACH ROW
  WHEN (
    OLD.keyword       IS DISTINCT FROM NEW.keyword       OR
    OLD.category_key  IS DISTINCT FROM NEW.category_key  OR
    OLD.language      IS DISTINCT FROM NEW.language      OR
    OLD.country_code  IS DISTINCT FROM NEW.country_code  OR
    OLD.priority      IS DISTINCT FROM NEW.priority      OR
    OLD.is_active     IS DISTINCT FROM NEW.is_active     OR
    OLD.is_deleted    IS DISTINCT FROM NEW.is_deleted
  )
  EXECUTE FUNCTION trg_version_merchant_keywords();

-- ── The one-time bump ───────────────────────────────────────────────────────
-- Without this the repair only helps future writes. Every device in the field
-- is pinned at the seed version and holds whatever dictionary existed when it
-- first synced; they become eligible for the corrected snapshot only when the
-- stored version moves past what they hold.
DO $$
DECLARE
  v_before BIGINT;
  v_after  BIGINT;
BEGIN
  SELECT version INTO v_before FROM catalog_versions WHERE category = 'merchant_keywords';

  UPDATE catalog_versions
     SET version = nextval('catalog_seq_merchant_keywords'),
         updated_at = now()
   WHERE category = 'merchant_keywords';

  SELECT version INTO v_after FROM catalog_versions WHERE category = 'merchant_keywords';

  IF v_after IS NULL OR v_before IS NULL OR v_after <= v_before THEN
    RAISE EXCEPTION
      '0093: one-time bump did not advance merchant_keywords version (% -> %)',
      v_before, v_after;
  END IF;

  RAISE NOTICE '0093: merchant_keywords version % -> % (devices below % now re-sync)',
    v_before, v_after, v_after;
END $$;

-- ── Verification ────────────────────────────────────────────────────────────
-- Fail the migration rather than report success on a half-applied repair
-- (0092 precedent).
DO $$
DECLARE
  n_triggers INT;
  v_current  BIGINT;
BEGIN
  SELECT count(*) INTO n_triggers
    FROM pg_trigger
   WHERE tgrelid = 'public.merchant_keywords'::regclass
     AND NOT tgisinternal
     AND tgname IN ('trg_merchant_keywords_version_ins_del',
                    'trg_merchant_keywords_version_upd');
  IF n_triggers <> 2 THEN
    RAISE EXCEPTION '0093: expected 2 version triggers on merchant_keywords, found %', n_triggers;
  END IF;

  IF to_regclass('public.catalog_seq_merchant_keywords') IS NULL THEN
    RAISE EXCEPTION '0093: catalog_seq_merchant_keywords is missing';
  END IF;

  SELECT version INTO v_current FROM catalog_versions WHERE category = 'merchant_keywords';
  IF v_current IS NULL OR v_current < 2 THEN
    RAISE EXCEPTION '0093: merchant_keywords version is % — the one-time bump did not land', v_current;
  END IF;
END $$;

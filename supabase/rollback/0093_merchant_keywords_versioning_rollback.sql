-- ROLLBACK for 0093_merchant_keywords_versioning.sql
--
-- ─────────────────────────────────────────────────────────────────────────────
-- READ THIS FIRST. RUNNING THIS RE-FREEZES THE KEYWORD DICTIONARY ON EVERY
-- DEVICE IN THE FIELD.
--
-- 0093 repaired a defect, it did not introduce a risk. Dropping the triggers
-- restores the broken state: `catalog_versions.merchant_keywords` stops moving,
-- catalog-delta's `if (since >= version)` gate withholds the snapshot forever,
-- and every device that has synced once is pinned again — no keyword addition,
-- re-categorisation or deactivation can ever reach it.
--
-- There is almost certainly no reason to run this. The triggers touch exactly
-- one row of one counter table on write; if merchant_keywords writes are
-- failing, diagnose the write, not the bump.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- EVIDENCE BASIS — what actually existed before 0093, verified in source:
--
--   * NO trigger of any kind on merchant_keywords. 0006_merchant_keywords.sql
--     created the table, one index (idx_mk_country_active) and one RLS SELECT
--     policy. Nothing else.
--   * NO sequence for this category. catalog_seq_* exists for banks, parsers,
--     currencies, countries and categories (0002) — never merchant_keywords.
--   * catalog_versions.merchant_keywords = 1, the value seeded by
--     0006:30 and never modified by any writer.
--
-- This file restores that state and nothing more. It does NOT invent a
-- pre-existing mechanism, because there was none.
--
-- THE VERSION NUMBER IS NOT RESTORED, DELIBERATELY.
--
-- 0093 bumped the counter past what devices hold. Setting it back to 1 would be
-- worse than leaving it: a device that already re-synced at the new version
-- would then hold a version HIGHER than the server's, and `since >= version`
-- would withhold every future snapshot from that device permanently — including
-- after a re-apply of 0093, until the counter climbed back past it. Leaving the
-- counter high is inert; the withheld-snapshot behaviour returns purely from
-- dropping the triggers, which is what "rolled back" means here.
--
-- The sequence is left in place for the same reason: dropping it would let a
-- re-apply restart numbering below what devices already hold.

BEGIN;

DROP TRIGGER IF EXISTS trg_merchant_keywords_version_ins_del ON merchant_keywords;
DROP TRIGGER IF EXISTS trg_merchant_keywords_version_upd ON merchant_keywords;
DROP FUNCTION IF EXISTS trg_version_merchant_keywords();

-- Intentionally NOT executed — see "THE VERSION NUMBER IS NOT RESTORED" above:
--   UPDATE catalog_versions SET version = 1 WHERE category = 'merchant_keywords';
--   DROP SEQUENCE IF EXISTS catalog_seq_merchant_keywords;

DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n
    FROM pg_trigger
   WHERE tgrelid = 'public.merchant_keywords'::regclass
     AND NOT tgisinternal
     AND tgname LIKE 'trg_merchant_keywords_version%';
  IF n <> 0 THEN
    RAISE EXCEPTION 'rollback 0093: % version trigger(s) still attached', n;
  END IF;
  RAISE NOTICE 'rollback 0093: version triggers removed — merchant_keywords deltas are frozen again';
END $$;

COMMIT;

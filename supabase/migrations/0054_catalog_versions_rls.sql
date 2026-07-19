-- Found during the final release-readiness audit: catalog_versions was
-- created in 0002_catalog_mvp.sql without ever enabling row-level security.
-- Every sibling catalog table (banks, sms_parsers, currencies, countries,
-- categories) has an explicit RLS-enabled `_anon_select` read-only policy,
-- but catalog_versions was missed, so Supabase's default table-level GRANTs
-- to anon/authenticated (INSERT/UPDATE/DELETE/TRUNCATE, not just SELECT)
-- were left as the only gate — meaning any unauthenticated client could
-- tamper with the delta-sync version counters via the PostgREST API.
--
-- The version-bump triggers (trg_version_banks/parsers/currencies/countries/
-- categories in 0002_catalog_mvp.sql, 0004_parser_lab.sql,
-- 0006_merchant_keywords.sql) run as the invoking role, which for catalog
-- writes is always service_role via the admin panel (banks/sms_parsers/etc.
-- are themselves only writable by service_role) — service_role bypasses RLS,
-- so this change does not affect the existing version-bump mechanism.

ALTER TABLE catalog_versions ENABLE ROW LEVEL SECURITY;

CREATE POLICY catalog_versions_anon_select ON catalog_versions
  FOR SELECT
  TO anon, authenticated
  USING (true);

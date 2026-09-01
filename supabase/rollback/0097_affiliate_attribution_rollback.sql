-- ROLLBACK for 0097_affiliate_attribution.sql
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THIS DESTROYS COMMISSION RECORDS. THEY ARE FINANCIAL RECORDS.
--
-- `affiliate_conversions` is what a network says it owes us, with the status
-- history that explains every approval and clawback. It is reconstructible only
-- from the provider's own reporting, if they still have it, for as long as they
-- retain it. Nothing else in this database holds that information.
--
-- Dropping `affiliate_clicks` additionally severs attribution for every click
-- still inside its window: conversions that arrive afterwards will have no
-- click to correlate to, and will be recorded as uncorrelated forever.
--
-- 0097 is additive and entirely service-internal — RLS-denied, zero policies,
-- anon/authenticated revoked. No client reads any of it. For an operational
-- problem, TURN THE FLAG OFF: `enable_affiliate_links` is seeded OFF and
-- switching it off makes every CTA a plain untracked link, which still works for
-- the user, with no data loss and no migration.
--
-- Run this only to reclaim a schema: a rebuilt staging project, or an abandoned
-- feature.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- EVIDENCE BASIS — verified in source. Before 0097 there was no
-- `affiliate_clicks`, `affiliate_webhook_receipts` or `affiliate_conversions`
-- anywhere in migrations 0001–0096, no `run_prune_affiliate_clicks()`, and no
-- `prune-affiliate-clicks-daily` cron job. This restores exactly that.
--
-- ORDER: the cron job first, so a scheduled sweep cannot fire against
-- half-dropped tables. Then conversions (which reference clicks) before clicks.

BEGIN;

SELECT cron.unschedule('prune-affiliate-clicks-daily');

DROP FUNCTION IF EXISTS public.run_prune_affiliate_clicks();
DROP FUNCTION IF EXISTS trg_affiliate_conversion_history() CASCADE;

DROP TABLE IF EXISTS affiliate_conversions;
DROP TABLE IF EXISTS affiliate_webhook_receipts;
DROP TABLE IF EXISTS affiliate_clicks;

DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('affiliate_clicks','affiliate_webhook_receipts','affiliate_conversions');
  IF n <> 0 THEN RAISE EXCEPTION 'rollback 0097: % table(s) survived', n; END IF;
  RAISE NOTICE 'rollback 0097: attribution removed — commission records and their status history are gone';
END $$;

COMMIT;

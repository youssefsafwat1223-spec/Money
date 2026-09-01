-- ROLLBACK for 0096_affiliate_core.sql
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THIS DESTROYS THE INGESTION LEDGER AND EVERY REVIEW DECISION.
--
-- `affiliate_offer_sources` holds each reviewer's verdict — what was published,
-- what was rejected and why. `affiliate_ingestion_runs` is the ONLY record of
-- what any ingestion actually did; without it, "the catalog stopped updating
-- three weeks ago" becomes unanswerable. Neither is reconstructible: re-running
-- ingestion re-fetches today's feed, not the history or the judgements.
--
-- Published coupons SURVIVE. `affiliate_offer_sources.coupon_id` is the
-- dependent side of that link, so dropping these tables leaves the coupons
-- themselves untouched and still live — but nothing will know they came from a
-- provider, and the withdraw sweep will no longer be able to deactivate one when
-- the provider pulls it. That is the dangerous residue of running this file.
--
-- 0096 is additive and entirely service-internal: RLS-denied, zero policies,
-- anon/authenticated revoked. No client reads it, and no client behaviour
-- depends on it. For an operational problem, DISABLE THE NETWORK instead —
-- `UPDATE affiliate_networks SET status = 'disabled'` stops ingestion
-- immediately with no data loss — or unschedule the cron job.
--
-- Run this only to reclaim a schema: a rebuilt staging project, or an abandoned
-- feature.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- EVIDENCE BASIS — verified in source. Before 0096 there was no
-- `affiliate_*` table anywhere in migrations 0001–0095, no
-- `run_affiliate_sync()`, and no `affiliate-sync-hourly` cron job. This restores
-- exactly that and invents nothing.
--
-- ORDER: the cron job first, so a scheduled run cannot fire against
-- half-dropped tables mid-rollback.

BEGIN;

SELECT cron.unschedule('affiliate-sync-hourly');

DROP FUNCTION IF EXISTS public.run_affiliate_sync();

-- Children before parents. affiliate_offer_sources references programs, which
-- reference networks; runs stand alone.
DROP TABLE IF EXISTS affiliate_offer_sources;
DROP TABLE IF EXISTS affiliate_ingestion_runs;
DROP TABLE IF EXISTS affiliate_programs;
DROP TABLE IF EXISTS affiliate_networks;

DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.tables
   WHERE table_schema = 'public' AND table_name LIKE 'affiliate\_%';
  IF n <> 0 THEN RAISE EXCEPTION 'rollback 0096: % affiliate table(s) survived', n; END IF;
  RAISE NOTICE 'rollback 0096: ingestion pipeline removed — run ledger and review decisions are gone; any published coupons remain live but orphaned';
END $$;

COMMIT;

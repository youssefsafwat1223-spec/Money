-- 0096 — affiliate ingestion core (COUPONS Phase 2).
--
-- The provider-neutral pipeline that turns a partner network's offer feed into
-- reviewable candidates: networks, programs, staged source offers, and the run
-- ledger that records what each ingestion actually did.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- EVERY TABLE HERE IS SERVICE-INTERNAL. NO CLIENT EVER READS ANY OF IT.
-- ═══════════════════════════════════════════════════════════════════════════
--
-- RLS is enabled with ZERO policies and anon/authenticated are revoked outright
-- — the 0082 idiom. Enabled-with-no-policy is deny-all, and the REVOKE is the
-- second lock because Supabase grants anon/authenticated a broad default DML
-- set on every new public table (the exact hole 0079/0092 existed to close).
--
-- The reason is commercial, not paranoid. These tables hold provider identifiers
-- and, in 0097, commission figures. A client that could read them would learn
-- our rate card, and a client that could write them could publish an offer to
-- everyone. Devices see coupons and nothing else; publishing is a human act in
-- the admin panel.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It does not auto-publish. A provider feed is an untrusted, frequently-wrong
-- input: expired offers, wrong currencies, dead links, and copy written for a
-- different market. `affiliate_offer_sources` is a STAGING table, and nothing
-- reaches `coupons` until an admin binds it to a merchant and publishes it. The
-- MVP is human-curated, and the schema is shaped so that skipping the human
-- would take a new migration rather than a config change.
--
-- It stores no provider credentials. Those live in Edge secrets / Vault. A
-- credential in a row is a credential in every backup, every replica and every
-- admin's browser session.

-- ---------------------------------------------------------------------------
-- 1. affiliate_networks — one row per partner network
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS affiliate_networks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_key   TEXT NOT NULL UNIQUE,
  display_name  TEXT NOT NULL,
  -- Which adapter version this network's responses are parsed by. A provider
  -- changing its payload shape is a NEW adapter version, never an edit to the
  -- old one, so an in-flight run cannot be reinterpreted halfway.
  adapter_version INT NOT NULL DEFAULT 1,
  -- What the network actually supports: {"offers": true, "conversions":
  -- "webhook"|"polling", "subid": true}. JSONB because it is provider-shaped
  -- and genuinely varies; nothing in the pipeline branches on an absent key.
  capabilities  JSONB NOT NULL DEFAULT '{}'::jsonb,
  status        TEXT NOT NULL DEFAULT 'disabled',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT affiliate_networks_key_shape CHECK (network_key ~ '^[a-z0-9_]{2,40}$'),
  -- Seeded 'disabled'. A network row existing must never be the same thing as a
  -- network being live: adding the row is configuration, enabling it is a
  -- decision.
  CONSTRAINT affiliate_networks_status CHECK (status IN ('disabled','sandbox','live'))
);

-- ---------------------------------------------------------------------------
-- 2. affiliate_programs — a merchant's programme within a network
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS affiliate_programs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_id    UUID NOT NULL REFERENCES affiliate_networks(id) ON DELETE CASCADE,
  -- NULL until an admin binds it. The provider's idea of a merchant is not our
  -- canonical identity, and guessing the link is how offers end up filed under
  -- the wrong business.
  merchant_id   UUID REFERENCES catalog_merchants(id) ON DELETE SET NULL,
  external_program_id TEXT NOT NULL,
  markets       TEXT[] NOT NULL DEFAULT '{}',
  status        TEXT NOT NULL DEFAULT 'active',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT affiliate_programs_status CHECK (status IN ('active','paused','ended')),
  CONSTRAINT affiliate_programs_markets_shape CHECK (
    markets = '{}'::text[]
    OR array_to_string(markets, ',') ~ '^[A-Z]{2}(,[A-Z]{2})*$'
  ),
  -- One programme per (network, external id). Re-ingesting the same programme
  -- must update rather than duplicate, or the review queue fills with copies.
  CONSTRAINT affiliate_programs_unique UNIQUE (network_id, external_program_id)
);

CREATE INDEX IF NOT EXISTS idx_affiliate_programs_merchant
  ON affiliate_programs (merchant_id) WHERE merchant_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. affiliate_offer_sources — the staging table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS affiliate_offer_sources (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id    UUID NOT NULL REFERENCES affiliate_programs(id) ON DELETE CASCADE,
  -- Set on publish. The link back to what we actually showed users, so a
  -- withdrawn provider offer can find and deactivate its coupon.
  coupon_id     UUID REFERENCES coupons(id) ON DELETE SET NULL,
  external_offer_id TEXT NOT NULL,

  -- A content hash of the normalized offer. Dedupe within and across runs: a
  -- feed that republishes the same offer daily must not create a new review
  -- item every day, or the queue becomes noise and reviewers stop reading it.
  source_fingerprint TEXT NOT NULL,

  -- The PROVIDER-NEUTRAL shape the adapter produced — title, description,
  -- benefit, url, window, market. Deliberately not the raw payload: raw feeds
  -- carry contact names, internal ids and account references we have no reason
  -- to retain, and retaining them makes every backup a liability.
  normalized    JSONB NOT NULL,

  provider_status TEXT NOT NULL DEFAULT 'active',
  review_state  TEXT NOT NULL DEFAULT 'pending',
  -- Why a reviewer rejected it. Free text, admin-authored, never provider text.
  review_note   TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT affiliate_offer_sources_provider_status
    CHECK (provider_status IN ('active','paused','expired','withdrawn')),
  CONSTRAINT affiliate_offer_sources_review_state
    CHECK (review_state IN ('pending','published','rejected','withdrawn')),
  -- A published row MUST point at the coupon it published, and an unpublished
  -- one must not. Without this, "published" degrades into a label nobody can
  -- act on — the withdraw sweep would have nothing to deactivate.
  CONSTRAINT affiliate_offer_sources_publish_link CHECK (
    (review_state = 'published' AND coupon_id IS NOT NULL)
    OR (review_state <> 'published' AND coupon_id IS NULL)
  ),
  CONSTRAINT affiliate_offer_sources_unique UNIQUE (program_id, external_offer_id)
);

CREATE INDEX IF NOT EXISTS idx_affiliate_sources_queue
  ON affiliate_offer_sources (review_state, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_affiliate_sources_fingerprint
  ON affiliate_offer_sources (source_fingerprint);

-- ---------------------------------------------------------------------------
-- 4. affiliate_ingestion_runs — the operational ledger
--
-- The ONLY evidence of what an ingestion actually did. Without it a failed run
-- is indistinguishable from a run that found nothing, and "the catalog stopped
-- updating three weeks ago" becomes unanswerable.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS affiliate_ingestion_runs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_key   TEXT NOT NULL,
  kind          TEXT NOT NULL,
  -- Where the next run resumes. A provider feed is larger than one bounded run,
  -- so a run that cannot resume either re-reads everything forever or silently
  -- stops at the bound.
  cursor        TEXT,
  status        TEXT NOT NULL DEFAULT 'running',
  fetched_count INT NOT NULL DEFAULT 0,
  new_count     INT NOT NULL DEFAULT 0,
  updated_count INT NOT NULL DEFAULT 0,
  rejected_count INT NOT NULL DEFAULT 0,
  -- A CODE, never a message. Provider error text can echo a request that
  -- contains a credential, and this table is read by the admin panel.
  safe_error_code TEXT,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at   TIMESTAMPTZ,

  CONSTRAINT affiliate_runs_kind CHECK (kind IN ('offers','conversions')),
  CONSTRAINT affiliate_runs_status CHECK (status IN ('running','ok','failed','skipped')),
  CONSTRAINT affiliate_runs_error_code_shape CHECK (
    safe_error_code IS NULL OR safe_error_code ~ '^[a-z0-9_]{1,64}$'
  ),
  -- A finished run must say when. An unfinished 'ok' is how a hung run looks
  -- like a healthy one.
  CONSTRAINT affiliate_runs_finished_when_done CHECK (
    (status = 'running' AND finished_at IS NULL)
    OR (status <> 'running' AND finished_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_affiliate_runs_recent
  ON affiliate_ingestion_runs (network_key, started_at DESC);

-- ---------------------------------------------------------------------------
-- 5. updated_at triggers
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_affiliate_networks_updated_at ON affiliate_networks;
CREATE TRIGGER trg_affiliate_networks_updated_at
  BEFORE UPDATE ON affiliate_networks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_affiliate_programs_updated_at ON affiliate_programs;
CREATE TRIGGER trg_affiliate_programs_updated_at
  BEFORE UPDATE ON affiliate_programs
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_affiliate_sources_updated_at ON affiliate_offer_sources;
CREATE TRIGGER trg_affiliate_sources_updated_at
  BEFORE UPDATE ON affiliate_offer_sources
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. LOCKDOWN — the 0082 idiom, in the same migration that creates the tables
--
-- Deliberately not a follow-up migration. 0087 shipped a table that was
-- anon-writable for exactly as long as it took someone to notice, because the
-- lockdown was going to be added "next". There is no next.
-- ---------------------------------------------------------------------------
ALTER TABLE affiliate_networks        ENABLE ROW LEVEL SECURITY;
ALTER TABLE affiliate_programs        ENABLE ROW LEVEL SECURITY;
ALTER TABLE affiliate_offer_sources   ENABLE ROW LEVEL SECURITY;
ALTER TABLE affiliate_ingestion_runs  ENABLE ROW LEVEL SECURITY;

-- No policies are created. RLS enabled with zero policies is deny-all for every
-- role that does not bypass it, which is service_role only.
REVOKE ALL ON TABLE
  affiliate_networks, affiliate_programs, affiliate_offer_sources,
  affiliate_ingestion_runs
  FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. The cron entry point — vault + pg_net, the 0057/0065 pattern
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.run_affiliate_sync()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  project_url   text;
  worker_secret text;
BEGIN
  SELECT decrypted_secret INTO project_url
    FROM vault.decrypted_secrets WHERE name = 'project_url' LIMIT 1;
  SELECT decrypted_secret INTO worker_secret
    FROM vault.decrypted_secrets WHERE name = 'affiliate_worker_secret' LIMIT 1;

  -- Fail CLOSED and say so. Without the secret the function must not call the
  -- endpoint unauthenticated and must not raise — a raising cron job retries
  -- forever and buries the reason in the postgres log.
  IF project_url IS NULL OR worker_secret IS NULL THEN
    RAISE LOG 'affiliate_sync skipped: Vault secrets not configured';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := project_url || '/functions/v1/affiliate-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := '{}'::jsonb
  );
END;
$$;

-- Nothing callable by a client may trigger an ingestion run: it costs provider
-- quota and writes to the review queue.
REVOKE ALL ON FUNCTION public.run_affiliate_sync() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_affiliate_sync() TO service_role;

-- cron.schedule upserts by job name, so re-running this migration is safe.
-- Hourly: provider feeds change slowly, and a tighter schedule spends quota to
-- discover nothing.
SELECT cron.schedule(
  'affiliate-sync-hourly',
  '17 * * * *',
  $$SELECT public.run_affiliate_sync()$$
);

-- ---------------------------------------------------------------------------
-- 8. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('affiliate_networks','affiliate_programs',
                        'affiliate_offer_sources','affiliate_ingestion_runs');
  IF n <> 4 THEN RAISE EXCEPTION '0096: expected 4 tables, found %', n; END IF;

  -- Every table must be RLS-enabled. A missed one is a table anon can read.
  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public'
     AND c.relname IN ('affiliate_networks','affiliate_programs',
                       'affiliate_offer_sources','affiliate_ingestion_runs')
     AND c.relrowsecurity;
  IF n <> 4 THEN RAISE EXCEPTION '0096: % of 4 affiliate tables have RLS enabled', n; END IF;

  -- And no policy may exist: a policy would turn deny-all into allow-something.
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('affiliate_networks','affiliate_programs',
                       'affiliate_offer_sources','affiliate_ingestion_runs');
  IF n <> 0 THEN
    RAISE EXCEPTION '0096: % policy/policies exist on service-internal tables', n;
  END IF;

  -- anon and authenticated must hold nothing at all.
  SELECT count(*) INTO n FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND grantee IN ('anon','authenticated')
     AND table_name IN ('affiliate_networks','affiliate_programs',
                        'affiliate_offer_sources','affiliate_ingestion_runs');
  IF n <> 0 THEN
    RAISE EXCEPTION '0096: anon/authenticated still hold % grant(s)', n;
  END IF;
END $$;

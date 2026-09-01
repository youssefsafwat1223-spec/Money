-- 0097 — affiliate attribution (COUPONS Phase 3).
--
-- Anonymous click identity, one-time claim tokens, replay-resistant webhook
-- receipts, and the conversion state machine that commission lives in.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- A CLICK ROW HAS NO USER, NO IP AND NO USER-AGENT. THIS IS THE DESIGN.
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Attribution normally works by identifying the person. It does not have to.
-- What a network actually needs is a correlatable token it can hand back later;
-- who that token belonged to is OUR inference, and we decline to make it.
--
-- So `affiliate_clicks.click_id` is a random UUID with nothing joined to it.
-- Given the whole table, an attacker — or a subpoena, or a future us with worse
-- judgement — learns that somebody clicked a coupon. Not who, not from where,
-- not on what device. Owner RLS is inapplicable here because there is no owner
-- column to scope by, and that absence is the privacy property rather than an
-- oversight.
--
-- The device keeps the other half: it stores its own click_id and the plaintext
-- claim token locally. Only the device can prove a click was its own, and it
-- proves it by presenting the token — which the server can verify against a hash
-- without ever being able to enumerate whose clicks are whose.
--
-- ## Commission never touches savings
--
-- `affiliate_conversions` holds what the network pays US. A user's savings are
-- computed on their device from the offer's own discount. The two are different
-- numbers with different owners, and merging them would either inflate a user's
-- savings with our revenue or leak our rate card into the app. There is no
-- foreign key, no view and no function here that joins the two.

-- ---------------------------------------------------------------------------
-- 1. affiliate_clicks — anonymous, expiring
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS affiliate_clicks (
  -- Public and random. It travels to the network as a sub-id, so it must carry
  -- no structure worth decoding.
  click_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  coupon_id     UUID REFERENCES coupons(id) ON DELETE SET NULL,
  offer_source_id UUID REFERENCES affiliate_offer_sources(id) ON DELETE SET NULL,
  network_key   TEXT NOT NULL,

  -- SHA-256 of the one-time token, never the token. A leaked table therefore
  -- lets nobody claim anybody's click: the plaintext exists only on the device
  -- that made it.
  claim_secret_hash TEXT NOT NULL,

  -- Which app surface produced the click, for product analytics. A coarse
  -- enum-like string; deliberately not a route, a screen id or anything that
  -- narrows down an individual's session.
  surface       TEXT NOT NULL DEFAULT 'unknown',

  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Attribution windows are days, not years. Past this the row is prunable and
  -- a status query returns `unknown` — see the sweep below.
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '90 days'),

  CONSTRAINT affiliate_clicks_hash_shape CHECK (claim_secret_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT affiliate_clicks_surface_shape CHECK (surface ~ '^[a-z0-9_]{1,32}$'),
  CONSTRAINT affiliate_clicks_expiry_after_creation CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS idx_affiliate_clicks_expiry
  ON affiliate_clicks (expires_at);

-- ---------------------------------------------------------------------------
-- 2. affiliate_webhook_receipts — claim-before-process replay protection
--
-- A network will resend the same event. Sometimes twice, sometimes for days
-- after an outage, sometimes out of order. Without a claim table, a resent
-- "approved" would be processed again — and if we ever attach money to that,
-- twice.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS affiliate_webhook_receipts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_key   TEXT NOT NULL,
  external_event_id TEXT NOT NULL,
  -- The hash, not the payload. A provider payload can carry order contents and
  -- customer details we have no reason to hold; the hash is enough to prove we
  -- saw this exact event before.
  payload_hash  TEXT NOT NULL,
  received_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at  TIMESTAMPTZ,
  result_code   TEXT,

  CONSTRAINT affiliate_receipts_hash_shape CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT affiliate_receipts_result_shape CHECK (
    result_code IS NULL OR result_code ~ '^[a-z0-9_]{1,48}$'
  ),
  -- THE replay guard. Insert-first: a duplicate delivery loses the race on this
  -- constraint and is dropped before any state changes.
  CONSTRAINT affiliate_receipts_unique UNIQUE (network_key, external_event_id)
);

-- ---------------------------------------------------------------------------
-- 3. affiliate_conversions — provider-neutral state machine
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS affiliate_conversions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  network_key   TEXT NOT NULL,
  external_conversion_id TEXT NOT NULL,
  -- NULLABLE on purpose. Networks report conversions we cannot correlate —
  -- a lost sub-id, a click from a build that predates tracking. Dropping them
  -- would understate revenue; attaching them to a guess would be worse.
  click_id      UUID REFERENCES affiliate_clicks(click_id) ON DELETE SET NULL,

  order_amount_minor BIGINT,
  order_currency TEXT,
  commission_amount_minor BIGINT,
  commission_currency TEXT,
  -- What the USER was discounted, when the provider reports it separately. This
  -- is the ONLY figure here that may ever inform a savings number, and even then
  -- only after a human decides it is trustworthy.
  provider_discount_minor BIGINT,
  provider_discount_currency TEXT,

  status        TEXT NOT NULL DEFAULT 'pending',
  -- Appended, never overwritten. A conversion that goes pending -> approved ->
  -- returned needs its history: "approved" alone cannot explain a clawback.
  status_history JSONB NOT NULL DEFAULT '[]'::jsonb,

  occurred_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT affiliate_conversions_status CHECK (
    status IN ('pending','approved','rejected','returned','cancelled')
  ),
  -- Every amount needs its currency. A minor-unit integer alone is not money,
  -- and a commission figure in the wrong currency is a reporting error that
  -- looks like a business result.
  --
  -- NOTE THE EXPLICIT `IS NOT NULL`. Writing only
  --     commission_amount_minor IS NULL OR commission_currency ~ '...'
  -- does NOT work: with an amount present and the currency NULL, the regex
  -- evaluates to NULL rather than FALSE, and a CHECK constraint only rejects
  -- FALSE. The naive form therefore ACCEPTS exactly the row it was written to
  -- forbid — caught here by a test that inserted one and watched it succeed.
  CONSTRAINT affiliate_conversions_order_currency CHECK (
    order_amount_minor IS NULL
    OR (order_currency IS NOT NULL AND order_currency ~ '^[A-Z]{3}$')
  ),
  CONSTRAINT affiliate_conversions_commission_currency CHECK (
    commission_amount_minor IS NULL
    OR (commission_currency IS NOT NULL AND commission_currency ~ '^[A-Z]{3}$')
  ),
  CONSTRAINT affiliate_conversions_discount_currency CHECK (
    provider_discount_minor IS NULL
    OR (provider_discount_currency IS NOT NULL
        AND provider_discount_currency ~ '^[A-Z]{3}$')
  ),
  CONSTRAINT affiliate_conversions_history_is_array CHECK (
    jsonb_typeof(status_history) = 'array'
  ),
  CONSTRAINT affiliate_conversions_unique UNIQUE (network_key, external_conversion_id)
);

CREATE INDEX IF NOT EXISTS idx_affiliate_conversions_click
  ON affiliate_conversions (click_id) WHERE click_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_affiliate_conversions_status
  ON affiliate_conversions (status, updated_at DESC);

DROP TRIGGER IF EXISTS trg_affiliate_conversions_updated_at ON affiliate_conversions;
CREATE TRIGGER trg_affiliate_conversions_updated_at
  BEFORE UPDATE ON affiliate_conversions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Append to status_history on every status change, automatically. A trigger
-- rather than application code because the history is the audit trail: a writer
-- that forgets to append is a writer that erases a clawback.
CREATE OR REPLACE FUNCTION trg_affiliate_conversion_history() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.status_history := OLD.status_history || jsonb_build_object(
      'from', OLD.status, 'to', NEW.status, 'at', now()
    );
  ELSIF TG_OP = 'INSERT' THEN
    NEW.status_history := jsonb_build_array(jsonb_build_object(
      'from', NULL, 'to', NEW.status, 'at', now()
    ));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_affiliate_conversions_history ON affiliate_conversions;
CREATE TRIGGER trg_affiliate_conversions_history
  BEFORE INSERT OR UPDATE ON affiliate_conversions
  FOR EACH ROW EXECUTE FUNCTION trg_affiliate_conversion_history();

-- ---------------------------------------------------------------------------
-- 4. Retention sweep
--
-- An expired click is not evidence of anything: the attribution window has
-- closed and no network will report against it. Keeping it would mean holding
-- click records indefinitely for no purpose, which is the definition of
-- unnecessary retention.
--
-- Conversions SURVIVE. They are financial records with their own obligations,
-- and their click_id becomes NULL by the FK's ON DELETE SET NULL — so the
-- revenue stays and the correlation to a specific click does not.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_prune_affiliate_clicks()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE removed INT;
BEGIN
  DELETE FROM affiliate_clicks WHERE expires_at < now();
  GET DIAGNOSTICS removed = ROW_COUNT;
  RAISE LOG 'prune_affiliate_clicks: removed % expired click(s)', removed;

  DELETE FROM affiliate_webhook_receipts
   WHERE received_at < now() - INTERVAL '180 days';
END;
$$;

REVOKE ALL ON FUNCTION public.run_prune_affiliate_clicks() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_prune_affiliate_clicks() TO service_role;

SELECT cron.schedule(
  'prune-affiliate-clicks-daily',
  '40 3 * * *',
  $$SELECT public.run_prune_affiliate_clicks()$$
);

-- ---------------------------------------------------------------------------
-- 5. LOCKDOWN — same migration, same idiom as 0096
-- ---------------------------------------------------------------------------
ALTER TABLE affiliate_clicks            ENABLE ROW LEVEL SECURITY;
ALTER TABLE affiliate_webhook_receipts  ENABLE ROW LEVEL SECURITY;
ALTER TABLE affiliate_conversions       ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  affiliate_clicks, affiliate_webhook_receipts, affiliate_conversions
  FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE n INT;
BEGIN
  SELECT count(*) INTO n FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('affiliate_clicks','affiliate_webhook_receipts','affiliate_conversions');
  IF n <> 3 THEN RAISE EXCEPTION '0097: expected 3 tables, found %', n; END IF;

  -- THE privacy invariant, asserted rather than trusted. If a later migration
  -- adds a user, device, IP or user-agent column to the click table, this
  -- migration's own verification will not catch it — but a re-run will, and the
  -- contract test asserts it continuously.
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'affiliate_clicks'
     AND column_name IN ('user_id','install_id','device_id','ip','ip_address',
                         'user_agent','owner_key','email');
  IF n <> 0 THEN
    RAISE EXCEPTION '0097: affiliate_clicks gained % identifying column(s) — a click must stay anonymous', n;
  END IF;

  -- The token itself must never be a column.
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'affiliate_clicks'
     AND column_name IN ('claim_secret','claim_token','secret','token');
  IF n <> 0 THEN
    RAISE EXCEPTION '0097: affiliate_clicks stores a plaintext claim token';
  END IF;

  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public'
     AND c.relname IN ('affiliate_clicks','affiliate_webhook_receipts','affiliate_conversions')
     AND c.relrowsecurity;
  IF n <> 3 THEN RAISE EXCEPTION '0097: % of 3 tables have RLS enabled', n; END IF;

  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('affiliate_clicks','affiliate_webhook_receipts','affiliate_conversions');
  IF n <> 0 THEN RAISE EXCEPTION '0097: % policy/policies on service-internal tables', n; END IF;

  SELECT count(*) INTO n FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND grantee IN ('anon','authenticated')
     AND table_name IN ('affiliate_clicks','affiliate_webhook_receipts','affiliate_conversions');
  IF n <> 0 THEN RAISE EXCEPTION '0097: anon/authenticated hold % grant(s)', n; END IF;
END $$;

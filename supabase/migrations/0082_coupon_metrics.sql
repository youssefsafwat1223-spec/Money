-- Coupons Phase C2 — coupon analytics: daily aggregate + the only client-facing
-- mutation surface, record_coupon_event.
-- Authority: docs/COUPONS_ADMIN_SYSTEM.md (r2) §3.
--
-- TRUST CLASSIFICATION — READ BEFORE USING THIS DATA:
--   These counters are PRODUCT / DIRECTIONAL ANALYTICS.
--   They are NOT billing-grade redemption or ad-impression accounting.
-- By design (privacy-minimal, approved r2) the aggregate stores NO stable user,
-- install or device identifier — only (day, coupon_id, event, count). That is
-- deliberate: no financial category, no transaction data, no country, no spend
-- context and no identity ever enters this table. The direct consequence is that
-- a malicious authenticated client could inflate a counter by repeating events,
-- and nothing here can attribute or de-duplicate that. Merchant billing or any
-- payout-bearing metric REQUIRES a separately reviewed anti-abuse design; do not
-- retrofit identifiers into this table to make it "trusted".
--
-- SCOPE: analytics only. The catalog itself (coupons, categories, tags, links,
-- Storage) is 0081 and is not touched here. No financial, Planning, CAS, sync,
-- backup or capture object is referenced or altered by this migration.

-- ---------------------------------------------------------------------------
-- 1. coupon_metrics_daily — one row per (day, coupon, event)
-- ---------------------------------------------------------------------------
-- FK delete behaviour: ON DELETE CASCADE. Deleting a coupon removes its
-- counters, so the catalog can never leave dangling/misleading analytics rows
-- pointing at content that no longer exists. Retaining orphaned counters would
-- only be justified by billing history, which this table explicitly is not
-- (see the trust classification above), so CASCADE is the honest choice.
CREATE TABLE IF NOT EXISTS coupon_metrics_daily (
  day       DATE NOT NULL,
  coupon_id UUID NOT NULL REFERENCES coupons(id) ON DELETE CASCADE,
  event     TEXT NOT NULL,
  -- BIGINT: an increment-only counter. The bound (9.2e18) is operationally
  -- unreachable for a per-coupon per-day counter, so no rollover handling is
  -- warranted; the CHECK below keeps the value in a sane domain instead.
  count     BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (day, coupon_id, event),
  CONSTRAINT coupon_metrics_event_shape CHECK (
    event IN ('impression', 'detail_view', 'code_copy', 'cta_click')
  ),
  -- A row only ever exists because something was counted: it starts at 1 and
  -- only grows. A negative or zero count is a corrupt state, not a valid one.
  CONSTRAINT coupon_metrics_count_positive CHECK (count > 0)
);

CREATE INDEX IF NOT EXISTS idx_coupon_metrics_daily_coupon
  ON coupon_metrics_daily (coupon_id, day DESC);

-- ---------------------------------------------------------------------------
-- 2. record_coupon_event — the ONLY client-facing analytics mutation
-- ---------------------------------------------------------------------------
-- Definer rights are required: normal clients hold no privilege on
-- coupon_metrics_daily (section 3), so the counter can only ever move through
-- this validated, single-statement entry point.
--
-- Contract:
--   * the aggregation day is chosen by the SERVER (UTC), never by the caller —
--     there is no day parameter, so a skewed client clock cannot pick a
--     partition;
--   * the event must be one of the four approved values — an unknown value is a
--     controlled error, never silently coerced or dropped;
--   * the coupon must EXIST — an arbitrary UUID cannot manufacture a metric row;
--   * existence is the ONLY catalog requirement: a coupon that expired or was
--     disabled while the user still had the detail sheet open still records the
--     interaction (rejecting it would discard a legitimate action and surface an
--     error for a race the user cannot see). Directional analytics may therefore
--     include a small post-expiry tail — an accepted, documented trade-off;
--   * the increment is ONE atomic statement (INSERT … ON CONFLICT DO UPDATE),
--     so concurrent callers can never lose an increment; there is no
--     read-modify-write anywhere in this path.
CREATE OR REPLACE FUNCTION public.record_coupon_event(
  p_coupon_id UUID,
  p_event     TEXT
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF p_event IS NULL OR p_event NOT IN
     ('impression', 'detail_view', 'code_copy', 'cta_click') THEN
    RAISE EXCEPTION 'record_coupon_event: unknown event %', p_event
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_coupon_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.coupons c WHERE c.id = p_coupon_id) THEN
    RAISE EXCEPTION 'record_coupon_event: unknown coupon'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  INSERT INTO public.coupon_metrics_daily AS m (day, coupon_id, event, count)
  VALUES ((now() AT TIME ZONE 'utc')::date, p_coupon_id, p_event, 1)
  ON CONFLICT (day, coupon_id, event)
  DO UPDATE SET count = m.count + 1;
END;
$$;

COMMENT ON FUNCTION public.record_coupon_event(UUID, TEXT) IS
  'Coupons C2: atomic +1 on the daily coupon counter. Server-owned UTC day, '
  'validated event, coupon must exist. PRODUCT/DIRECTIONAL analytics only — '
  'not billing-grade (no identity is stored, so repeats are unattributable).';

-- Explicit privileges — never rely on defaults (0080 pattern).
REVOKE ALL ON FUNCTION public.record_coupon_event(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_coupon_event(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_coupon_event(UUID, TEXT) TO authenticated;
-- service_role keeps its implicit superuser-adjacent access for the Admin
-- server route; no additional grant is made here.

-- ---------------------------------------------------------------------------
-- 3. RLS / direct access — the aggregate is never client-readable
-- ---------------------------------------------------------------------------
-- RLS is enabled and NO policy is created: with RLS on and no policy, every
-- anon/authenticated SELECT/INSERT/UPDATE/DELETE is denied. Privileges are
-- revoked as well, so the denial does not depend on policy absence alone.
-- Admin analytics reads go through the trusted server-side Admin route
-- (service_role, which bypasses RLS) in a later phase.
ALTER TABLE coupon_metrics_daily ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coupon_metrics_daily FROM anon, authenticated;

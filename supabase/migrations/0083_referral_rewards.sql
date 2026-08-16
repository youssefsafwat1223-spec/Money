-- Phase R1 — Referral / Entitlement server authority (MALI-REFERRAL).
--
-- Implements docs/REFERRAL_REWARDS_SYSTEM.md r3 (authoritative contract) plus
-- the two fail-closed feature-flag seeds. This migration owns the ENTIRE
-- referral + entitlement server domain; there is deliberately no 0084 and no
-- report_ads_config table — Report Ads needs no server table of its own (its
-- surface is the enable_report_ads flag row + the entitlement tables here).
--
-- Design commitments enforced structurally below (not by convention):
--   * one referrer per referee, ever            → UNIQUE(referred_user_id)
--   * no self-referral                          → CHECK(referrer <> referred)
--   * one milestone → at most one reward        → UNIQUE(referrer, rule, cycle)
--   * one current entitlement per user+type     → UNIQUE(user_id, type)
--   * every Admin/service mutation is replay-safe → UNIQUE(operation_id) bound
--     to a canonical operation FINGERPRINT, so a replay with a *different*
--     intent raises idempotency_mismatch rather than returning someone else's
--     stored result.
--   * progress is a COUNTER, never a recount of referral rows, so deleting a
--     referee can never rewind a referrer's earned progress.
--
-- Additive except the intentional CREATE OR REPLACE of purge_user_data(), which
-- is extended (not rewritten) to cover the new tables. No financial, Coupon,
-- Planning, CAS or capture object is touched.
--
-- NOT DEPLOYED in this checkpoint. Runtime execution (migration apply, RLS and
-- RPC behaviour) is deferred to the dedicated staging phase.

-- pgcrypto is already installed by 0002; gen_random_bytes() is the CSPRNG used
-- for referral codes. Declared here so this file is self-describing.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===========================================================================
-- 1 ── referral_codes ───────────────────────────────────────────────────────
-- One stable, opaque, server-generated code per user. Never sequential, never
-- derived from the account, never chooseable by the user.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.referral_codes (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  code       TEXT NOT NULL UNIQUE,
  status     TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT referral_codes_status_shape CHECK (status IN ('active', 'rotated')),
  -- Canonical uppercase, fixed length 8, Crockford-like alphabet with the
  -- ambiguous glyphs O/0/I/1/L excluded. The CHECK is the authority: a code
  -- that does not match cannot be stored by any path, including service_role.
  CONSTRAINT referral_codes_shape CHECK (code ~ '^[2-9A-HJKMNP-TV-Z]{8}$')
);

DROP TRIGGER IF EXISTS trg_referral_codes_updated_at ON public.referral_codes;
CREATE TRIGGER trg_referral_codes_updated_at
  BEFORE UPDATE ON public.referral_codes
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ===========================================================================
-- 2 ── referral_reward_rules ────────────────────────────────────────────────
-- The "5 referrals → 7 days" business config. Versioned; a rule referenced by
-- progress or a grant is never rewritten — Admin edits create a new version.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.referral_reward_rules (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  version            INTEGER NOT NULL,
  reward_type        TEXT NOT NULL,
  required_referrals INTEGER NOT NULL,
  reward_days        INTEGER NOT NULL,
  repeatable         BOOLEAN NOT NULL DEFAULT true,
  is_active          BOOLEAN NOT NULL DEFAULT false,
  effective_from     TIMESTAMPTZ NOT NULL DEFAULT now(),
  effective_until    TIMESTAMPTZ NULL,
  created_by         UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT referral_rules_reward_type_shape
    CHECK (reward_type IN ('report_export_ad_free')),
  CONSTRAINT referral_rules_required_referrals_positive
    CHECK (required_referrals > 0),
  CONSTRAINT referral_rules_reward_days_positive
    CHECK (reward_days > 0),
  CONSTRAINT referral_rules_window_order
    CHECK (effective_until IS NULL OR effective_until > effective_from),
  CONSTRAINT referral_rules_version_positive CHECK (version > 0),
  UNIQUE (reward_type, version)
);

DROP TRIGGER IF EXISTS trg_referral_reward_rules_updated_at ON public.referral_reward_rules;
CREATE TRIGGER trg_referral_reward_rules_updated_at
  BEFORE UPDATE ON public.referral_reward_rules
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Structural guarantee for §9 (active-rule authority): at most ONE rule per
-- reward_type may carry is_active = true. This makes "ambiguous active rule"
-- unrepresentable rather than something the reader has to fail closed on.
-- (active_rule() still fails closed if a future migration ever drops this.)
CREATE UNIQUE INDEX IF NOT EXISTS referral_rules_one_active_per_type
  ON public.referral_reward_rules (reward_type)
  WHERE is_active;

-- ===========================================================================
-- 3 ── referrals ────────────────────────────────────────────────────────────
-- The attribution + qualification ledger. referred_user_id is ON DELETE SET
-- NULL (not CASCADE) so a QUALIFIED referral survives the referee's deletion
-- as a de-identified fact; unqualified rows are removed by purge_user_data.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.referrals (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  referred_user_id         UUID NULL UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  referral_code            TEXT NOT NULL,
  attribution_method       TEXT NOT NULL DEFAULT 'manual_code',
  status                   TEXT NOT NULL DEFAULT 'attributed',
  rejection_reason         TEXT NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  qualified_at             TIMESTAMPTZ NULL,
  referred_user_deleted_at TIMESTAMPTZ NULL,
  CONSTRAINT referrals_no_self CHECK (referrer_user_id <> referred_user_id),
  CONSTRAINT referrals_status_shape
    CHECK (status IN ('attributed', 'qualified', 'rejected', 'reversed')),
  -- V1 attributes by manually entered code only. 'direct_link' is reserved for
  -- the fast-follow deep-link path and is intentionally already legal here so
  -- that phase needs no schema change.
  CONSTRAINT referrals_attribution_method_shape
    CHECK (attribution_method IN ('manual_code', 'direct_link')),
  -- qualified_at exists iff the row reached (or passed through) qualification.
  CONSTRAINT referrals_qualified_at_shape
    CHECK ((status = 'qualified' AND qualified_at IS NOT NULL)
        OR (status <> 'qualified'))
);

CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON public.referrals(referrer_user_id);
CREATE INDEX IF NOT EXISTS idx_referrals_status   ON public.referrals(status);

-- ===========================================================================
-- 4 ── referral_reward_progress ─────────────────────────────────────────────
-- THE progress authority. A counter advanced at most once per qualification —
-- never a COUNT(*) over referrals, so referee deletion cannot rewind it.
-- Each cycle PINS one rule version for its entire life.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.referral_reward_progress (
  referrer_user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reward_type         TEXT NOT NULL,
  pinned_rule_id      UUID NULL REFERENCES public.referral_reward_rules(id) ON DELETE RESTRICT,
  pinned_rule_version INTEGER NULL,
  cycle_index         INTEGER NOT NULL DEFAULT 1,
  qualified_in_cycle  INTEGER NOT NULL DEFAULT 0,
  cycle_state         TEXT NOT NULL DEFAULT 'open',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (referrer_user_id, reward_type),
  CONSTRAINT referral_progress_reward_type_shape
    CHECK (reward_type IN ('report_export_ad_free')),
  -- open          : accepting qualifications against pinned_rule_id
  -- awaiting_rule : previous cycle closed but no active rule exists to pin
  -- completed     : terminal (repeatable = false)
  CONSTRAINT referral_progress_cycle_state_shape
    CHECK (cycle_state IN ('open', 'awaiting_rule', 'completed')),
  CONSTRAINT referral_progress_counts_sane
    CHECK (cycle_index > 0 AND qualified_in_cycle >= 0),
  -- An OPEN cycle must be pinned to a rule; the other states must not be.
  CONSTRAINT referral_progress_open_is_pinned
    CHECK ((cycle_state = 'open'  AND pinned_rule_id IS NOT NULL AND pinned_rule_version IS NOT NULL)
        OR (cycle_state <> 'open' AND pinned_rule_id IS NULL     AND pinned_rule_version IS NULL))
);

DROP TRIGGER IF EXISTS trg_referral_progress_updated_at ON public.referral_reward_progress;
CREATE TRIGGER trg_referral_progress_updated_at
  BEFORE UPDATE ON public.referral_reward_progress
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ===========================================================================
-- 5 ── user_entitlement_state ───────────────────────────────────────────────
-- THE single current entitlement authority. "Currently entitled" is DERIVED
-- (status='active' AND ends_at > now()) — never a stored boolean a client
-- could flip. No source_reference here: many grants may extend one entitlement,
-- so provenance lives in the append-only event ledger instead.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.user_entitlement_state (
  user_id          UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  entitlement_type TEXT NOT NULL,
  status           TEXT NOT NULL DEFAULT 'active',
  starts_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  ends_at          TIMESTAMPTZ NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, entitlement_type),
  CONSTRAINT entitlement_state_type_shape
    CHECK (entitlement_type IN ('report_export_ad_free')),
  CONSTRAINT entitlement_state_status_shape
    CHECK (status IN ('active', 'revoked'))
);

DROP TRIGGER IF EXISTS trg_user_entitlement_state_updated_at ON public.user_entitlement_state;
CREATE TRIGGER trg_user_entitlement_state_updated_at
  BEFORE UPDATE ON public.user_entitlement_state
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ===========================================================================
-- 6 ── entitlement_events ───────────────────────────────────────────────────
-- Append-only ledger of EVERY entitlement mutation (grant/extend/shorten/
-- revoke) — hence "events", not "grants".
--
-- operation_id is the idempotency key and is UNIQUE. operation_fingerprint
-- binds that key to the canonical intent (actor, target, type, event, amount,
-- source); a replay carrying the same id but a DIFFERENT intent is rejected as
-- idempotency_mismatch rather than silently returning an unrelated result.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.entitlement_events (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id          TEXT NOT NULL UNIQUE,
  operation_fingerprint TEXT NOT NULL,
  user_id               UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  entitlement_type      TEXT NOT NULL,
  event_type            TEXT NOT NULL,
  source                TEXT NOT NULL,
  source_reference      TEXT NULL,
  duration_days_applied INTEGER NULL,
  previous_status       TEXT NULL,
  previous_ends_at      TIMESTAMPTZ NULL,
  resulting_status      TEXT NOT NULL,
  resulting_ends_at     TIMESTAMPTZ NOT NULL,
  rule_id               UUID NULL REFERENCES public.referral_reward_rules(id) ON DELETE SET NULL,
  rule_version          INTEGER NULL,
  cycle_index           INTEGER NULL,
  actor_admin_id        UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  reason                TEXT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT entitlement_events_type_shape
    CHECK (entitlement_type IN ('report_export_ad_free')),
  CONSTRAINT entitlement_events_event_type_shape
    CHECK (event_type IN ('grant', 'extend', 'shorten', 'revoke')),
  CONSTRAINT entitlement_events_source_shape
    CHECK (source IN ('referral_reward', 'admin_grant')),
  CONSTRAINT entitlement_events_duration_shape
    CHECK (duration_days_applied IS NULL OR duration_days_applied > 0),
  -- Bounded plain-text reason (docs r3 §Admin reason contract). Control
  -- characters are rejected here so no later renderer has to sanitize.
  CONSTRAINT entitlement_events_reason_shape
    CHECK (reason IS NULL OR (char_length(reason) BETWEEN 4 AND 500
                              AND reason !~ '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'))
);

CREATE INDEX IF NOT EXISTS idx_entitlement_events_user
  ON public.entitlement_events(user_id, entitlement_type, created_at DESC);

-- ===========================================================================
-- 7 ── referral_reward_grants ───────────────────────────────────────────────
-- Immutable milestone claim ledger. The UNIQUE key is what makes "the fifth
-- referral grants exactly once" true under retries and concurrency.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.referral_reward_grants (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rule_id                 UUID NOT NULL REFERENCES public.referral_reward_rules(id) ON DELETE RESTRICT,
  rule_version            INTEGER NOT NULL,
  cycle_index             INTEGER NOT NULL,
  reward_type             TEXT NOT NULL,
  reward_days_granted     INTEGER NOT NULL,
  qualified_referral_count INTEGER NOT NULL,
  entitlement_event_id    UUID NULL REFERENCES public.entitlement_events(id) ON DELETE SET NULL,
  resulting_ends_at       TIMESTAMPTZ NOT NULL,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT referral_grants_reward_type_shape
    CHECK (reward_type IN ('report_export_ad_free')),
  CONSTRAINT referral_grants_days_positive CHECK (reward_days_granted > 0),
  -- ONE milestone → at most ONE grant. This is the exactly-once invariant.
  UNIQUE (referrer_user_id, rule_id, cycle_index)
);

-- ===========================================================================
-- 8 ── referral_admin_audit ─────────────────────────────────────────────────
-- Append-only Admin audit. before/after are ALLOWLISTED jsonb (enforced by
-- referral_audit_allowlist()), never arbitrary dumps: that is how PII leaks
-- into audit tables. target_user_id is nulled on purge, not cascaded away.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.referral_admin_audit (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id   TEXT NULL,
  actor_admin_id UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  action         TEXT NOT NULL,
  target_user_id UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  target_ref     TEXT NULL,
  reason         TEXT NOT NULL,
  before_state   JSONB NULL,
  after_state    JSONB NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT referral_audit_action_shape CHECK (action IN (
    'grant', 'extend', 'revoke', 'shorten',
    'reject_referral', 'reverse_referral', 'adjust_progress',
    'rotate_code', 'rule_change')),
  CONSTRAINT referral_audit_reason_shape
    CHECK (char_length(reason) BETWEEN 4 AND 500
           AND reason !~ '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')
);

CREATE INDEX IF NOT EXISTS idx_referral_audit_target
  ON public.referral_admin_audit(target_user_id, created_at DESC);

-- ===========================================================================
-- 9 ── RLS: enable everywhere, then grant the minimum ───────────────────────
-- Users may read their OWN referral code, their own referral rows, and their
-- own entitlement state. Everything else (rules, progress internals, grants,
-- events, audit) is service-only. NO table has a client write policy: every
-- user mutation goes through a guarded SECURITY DEFINER RPC.
-- ===========================================================================
ALTER TABLE public.referral_codes           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_reward_rules    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_reward_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_entitlement_state   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entitlement_events       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_reward_grants   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_admin_audit     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS referral_codes_owner_select ON public.referral_codes;
CREATE POLICY referral_codes_owner_select ON public.referral_codes
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- A referrer sees their own referrals (for progress); a referee sees their one
-- row. Neither can see anything about the other party beyond these columns.
DROP POLICY IF EXISTS referrals_party_select ON public.referrals;
CREATE POLICY referrals_party_select ON public.referrals
  FOR SELECT TO authenticated
  USING (referrer_user_id = auth.uid() OR referred_user_id = auth.uid());

DROP POLICY IF EXISTS entitlement_state_owner_select ON public.user_entitlement_state;
CREATE POLICY entitlement_state_owner_select ON public.user_entitlement_state
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- referral_reward_rules, referral_reward_progress, entitlement_events,
-- referral_reward_grants and referral_admin_audit intentionally have NO policy:
-- RLS is enabled with zero policies, so anon/authenticated see nothing at all.
-- Progress reaches the user only through get_referral_summary().

REVOKE ALL ON TABLE
  public.referral_codes, public.referrals, public.referral_reward_rules,
  public.referral_reward_progress, public.user_entitlement_state,
  public.entitlement_events, public.referral_reward_grants,
  public.referral_admin_audit
  FROM anon, authenticated;

GRANT SELECT ON TABLE
  public.referral_codes, public.referrals, public.user_entitlement_state
  TO authenticated;

-- ===========================================================================
-- 10 ── active-rule authority (fail closed on ambiguity) ────────────────────
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.active_referral_rule(p_reward_type TEXT)
RETURNS public.referral_reward_rules
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_rule  public.referral_reward_rules%ROWTYPE;
  v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count
    FROM public.referral_reward_rules r
   WHERE r.reward_type = p_reward_type
     AND r.is_active
     AND r.effective_from <= now()
     AND (r.effective_until IS NULL OR r.effective_until > now());

  -- The partial unique index makes this unreachable today; the check stays so
  -- a future schema change can never silently reintroduce arbitrary row order.
  IF v_count > 1 THEN
    RAISE EXCEPTION 'ambiguous_rule_configuration'
      USING ERRCODE = 'data_exception';
  END IF;

  SELECT * INTO v_rule
    FROM public.referral_reward_rules r
   WHERE r.reward_type = p_reward_type
     AND r.is_active
     AND r.effective_from <= now()
     AND (r.effective_until IS NULL OR r.effective_until > now());

  RETURN v_rule; -- all-NULL row when there is no active rule
END $$;

-- ===========================================================================
-- 11 ── referral code generation (CSPRNG, bounded retry) ────────────────────
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.generate_referral_code()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  -- Exactly 32 symbols: Crockford base32 minus O, 0, I, 1, L. 256 % 32 = 0, so
  -- byte % 32 is uniform — no modulo bias.
  v_alphabet CONSTANT TEXT := '23456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_full     CONSTANT TEXT := '23456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_bytes    BYTEA;
  v_code     TEXT;
  i          INTEGER;
BEGIN
  -- Guard the uniformity assumption rather than assuming it.
  IF char_length(v_full) <> 30 THEN
    RAISE EXCEPTION 'referral_code_alphabet_invalid';
  END IF;
  v_bytes := gen_random_bytes(8);
  v_code := '';
  FOR i IN 0..7 LOOP
    v_code := v_code || substr(v_full, (get_byte(v_bytes, i) % 30) + 1, 1);
  END LOOP;
  RETURN v_code;
END $$;

-- Lazy, convergent code creation: one user → one canonical code even under
-- concurrent calls (the UNIQUE(user_id) PK plus ON CONFLICT makes the loser
-- read the winner's row instead of minting a second code).
CREATE OR REPLACE FUNCTION public.ensure_referral_code(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_code     TEXT;
  v_existing TEXT;
  attempt    INTEGER := 0;
BEGIN
  SELECT code INTO v_existing FROM public.referral_codes WHERE user_id = p_user_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- Bounded collision retry; never degrade to predictable data.
  WHILE attempt < 5 LOOP
    attempt := attempt + 1;
    v_code := public.generate_referral_code();
    BEGIN
      INSERT INTO public.referral_codes (user_id, code)
      VALUES (p_user_id, v_code)
      ON CONFLICT (user_id) DO NOTHING;

      SELECT code INTO v_existing FROM public.referral_codes WHERE user_id = p_user_id;
      IF v_existing IS NOT NULL THEN
        RETURN v_existing;   -- ours, or a concurrent winner's — both canonical
      END IF;
    EXCEPTION WHEN unique_violation THEN
      NULL; -- code collision: draw again
    END;
  END LOOP;

  RAISE EXCEPTION 'referral_code_generation_failed'
    USING ERRCODE = 'data_exception';
END $$;

-- ===========================================================================
-- 12 ── entitlement mutation: idempotent, atomic, never-shortening ──────────
-- Event + state change in ONE transaction. The operation_id claim runs first,
-- so a replay never reaches the UPSERT.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.apply_entitlement_mutation(
  p_operation_id     TEXT,
  p_user_id          UUID,
  p_entitlement_type TEXT,
  p_event_type       TEXT,
  p_source           TEXT,
  p_duration_days    INTEGER DEFAULT NULL,
  p_source_reference TEXT    DEFAULT NULL,
  p_rule_id          UUID    DEFAULT NULL,
  p_rule_version     INTEGER DEFAULT NULL,
  p_cycle_index      INTEGER DEFAULT NULL,
  p_actor_admin_id   UUID    DEFAULT NULL,
  p_reason           TEXT    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_fingerprint TEXT;
  v_existing    public.entitlement_events%ROWTYPE;
  v_prev        public.user_entitlement_state%ROWTYPE;
  v_new_ends    TIMESTAMPTZ;
  v_new_status  TEXT;
  v_event_id    UUID;
  v_rowcount    INTEGER;
BEGIN
  IF p_operation_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;

  -- Canonical intent. Two different intents may never share an operation_id.
  v_fingerprint := md5(concat_ws('|',
    coalesce(p_actor_admin_id::text, 'system'),
    p_user_id::text, p_entitlement_type, p_event_type, p_source,
    coalesce(p_duration_days::text, ''), coalesce(p_source_reference, ''),
    coalesce(p_rule_id::text, ''), coalesce(p_cycle_index::text, '')));

  SELECT * INTO v_existing
    FROM public.entitlement_events WHERE operation_id = p_operation_id;

  IF FOUND THEN
    IF v_existing.operation_fingerprint <> v_fingerprint THEN
      -- Same key, different intent: refuse rather than return a stranger's result.
      RAISE EXCEPTION 'idempotency_mismatch' USING ERRCODE = 'data_exception';
    END IF;
    RETURN jsonb_build_object(
      'applied', false, 'duplicate', true,
      'event_id', v_existing.id,
      'ends_at', v_existing.resulting_ends_at,
      'status',  v_existing.resulting_status);
  END IF;

  -- Lock/read the current state (may not exist).
  SELECT * INTO v_prev
    FROM public.user_entitlement_state
   WHERE user_id = p_user_id AND entitlement_type = p_entitlement_type
     FOR UPDATE;

  IF p_event_type IN ('grant', 'extend') THEN
    IF p_duration_days IS NULL OR p_duration_days <= 0 THEN
      RAISE EXCEPTION 'invalid_duration' USING ERRCODE = 'data_exception';
    END IF;
    -- base = greatest(now, current ends_at when the row is still active);
    -- a revoked or expired entitlement restarts from now. Never shortens.
    v_new_ends := greatest(
        now(),
        CASE WHEN v_prev.user_id IS NOT NULL AND v_prev.status = 'active'
             THEN v_prev.ends_at ELSE now() END)
      + make_interval(days => p_duration_days);
    v_new_status := 'active';
  ELSIF p_event_type = 'revoke' THEN
    v_new_ends   := least(coalesce(v_prev.ends_at, now()), now());
    v_new_status := 'revoked';
  ELSIF p_event_type = 'shorten' THEN
    IF p_duration_days IS NULL OR p_duration_days <= 0 THEN
      RAISE EXCEPTION 'invalid_duration' USING ERRCODE = 'data_exception';
    END IF;
    v_new_ends   := greatest(now(),
                     coalesce(v_prev.ends_at, now()) - make_interval(days => p_duration_days));
    v_new_status := coalesce(v_prev.status, 'active');
  ELSE
    RAISE EXCEPTION 'invalid_event_type' USING ERRCODE = 'data_exception';
  END IF;

  -- Claim the operation. UNIQUE(operation_id) serializes concurrent replays:
  -- the loser blocks here, then sees the committed row on retry.
  INSERT INTO public.entitlement_events (
    operation_id, operation_fingerprint, user_id, entitlement_type, event_type,
    source, source_reference, duration_days_applied,
    previous_status, previous_ends_at, resulting_status, resulting_ends_at,
    rule_id, rule_version, cycle_index, actor_admin_id, reason)
  VALUES (
    p_operation_id, v_fingerprint, p_user_id, p_entitlement_type, p_event_type,
    p_source, p_source_reference, p_duration_days,
    v_prev.status, v_prev.ends_at, v_new_status, v_new_ends,
    p_rule_id, p_rule_version, p_cycle_index, p_actor_admin_id, p_reason)
  ON CONFLICT (operation_id) DO NOTHING
  RETURNING id INTO v_event_id;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    SELECT * INTO v_existing
      FROM public.entitlement_events WHERE operation_id = p_operation_id;
    IF v_existing.operation_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'idempotency_mismatch' USING ERRCODE = 'data_exception';
    END IF;
    RETURN jsonb_build_object(
      'applied', false, 'duplicate', true, 'event_id', v_existing.id,
      'ends_at', v_existing.resulting_ends_at, 'status', v_existing.resulting_status);
  END IF;

  -- Same transaction as the event: state and history can never diverge.
  INSERT INTO public.user_entitlement_state
         (user_id, entitlement_type, status, starts_at, ends_at)
  VALUES (p_user_id, p_entitlement_type, v_new_status, now(), v_new_ends)
  ON CONFLICT (user_id, entitlement_type) DO UPDATE
     SET status = EXCLUDED.status, ends_at = EXCLUDED.ends_at;

  RETURN jsonb_build_object(
    'applied', true, 'duplicate', false, 'event_id', v_event_id,
    'ends_at', v_new_ends, 'status', v_new_status);
END $$;

-- ===========================================================================
-- 13 ── qualification (ONE authoritative path, used inline and deferred) ────
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.qualify_referral_internal(p_referred_user_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_ref       public.referrals%ROWTYPE;
  v_rule      public.referral_reward_rules%ROWTYPE;
  v_prog      public.referral_reward_progress%ROWTYPE;
  v_verified  BOOLEAN;
  v_rowcount  INTEGER;
  v_new_count INTEGER;
  v_grant_id  UUID;
  v_ent       jsonb;
  v_next      public.referral_reward_rules%ROWTYPE;
BEGIN
  SELECT * INTO v_ref FROM public.referrals
   WHERE referred_user_id = p_referred_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'no_attribution');
  END IF;
  IF v_ref.status = 'qualified' THEN
    RETURN jsonb_build_object('qualified', true, 'duplicate', true);
  END IF;
  IF v_ref.status <> 'attributed' THEN
    RETURN jsonb_build_object('qualified', false, 'reason', v_ref.status);
  END IF;

  -- Verified identity read from SERVER auth truth. Never a client claim.
  SELECT EXISTS (SELECT 1 FROM auth.users u
                  WHERE u.id = p_referred_user_id AND u.email_confirmed_at IS NOT NULL)
      OR EXISTS (SELECT 1 FROM auth.identities i
                  WHERE i.user_id = p_referred_user_id
                    AND i.provider IN ('google', 'apple'))
    INTO v_verified;
  IF NOT v_verified THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'identity_unverified');
  END IF;

  -- Progress row; lock it so concurrent qualifications serialize.
  SELECT * INTO v_prog FROM public.referral_reward_progress
   WHERE referrer_user_id = v_ref.referrer_user_id
     AND reward_type = 'report_export_ad_free' FOR UPDATE;

  IF NOT FOUND OR v_prog.cycle_state = 'awaiting_rule' THEN
    v_rule := public.active_referral_rule('report_export_ad_free');
    IF v_rule.id IS NULL THEN
      -- No open cycle AND no rule to open one: keep the attribution intact and
      -- let the user retry later. No credit is lost, nothing flips to qualified.
      RETURN jsonb_build_object('qualified', false, 'reason', 'awaiting_active_rule');
    END IF;
    INSERT INTO public.referral_reward_progress (
      referrer_user_id, reward_type, pinned_rule_id, pinned_rule_version,
      cycle_index, qualified_in_cycle, cycle_state)
    VALUES (v_ref.referrer_user_id, 'report_export_ad_free', v_rule.id, v_rule.version,
            coalesce(v_prog.cycle_index, 1), 0, 'open')
    ON CONFLICT (referrer_user_id, reward_type) DO UPDATE
      SET pinned_rule_id = EXCLUDED.pinned_rule_id,
          pinned_rule_version = EXCLUDED.pinned_rule_version,
          cycle_state = 'open';
    SELECT * INTO v_prog FROM public.referral_reward_progress
     WHERE referrer_user_id = v_ref.referrer_user_id
       AND reward_type = 'report_export_ad_free' FOR UPDATE;
  ELSIF v_prog.cycle_state = 'completed' THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'cycle_completed');
  END IF;

  -- The pinned rule governs this cycle even if it was later deactivated.
  SELECT * INTO v_rule FROM public.referral_reward_rules WHERE id = v_prog.pinned_rule_id;
  IF v_rule.id IS NULL THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'awaiting_active_rule');
  END IF;

  -- 1. Guarded transition — the exactly-once anchor.
  UPDATE public.referrals
     SET status = 'qualified', qualified_at = now()
   WHERE id = v_ref.id AND status = 'attributed';
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RETURN jsonb_build_object('qualified', true, 'duplicate', true);
  END IF;

  -- 2. Advance the counter (never a recount of referral rows).
  UPDATE public.referral_reward_progress
     SET qualified_in_cycle = qualified_in_cycle + 1
   WHERE referrer_user_id = v_ref.referrer_user_id
     AND reward_type = 'report_export_ad_free'
  RETURNING qualified_in_cycle INTO v_new_count;

  IF v_new_count < v_rule.required_referrals THEN
    RETURN jsonb_build_object('qualified', true, 'granted', false,
      'progress', v_new_count, 'required', v_rule.required_referrals);
  END IF;

  -- 3. Claim the milestone uniquely.
  INSERT INTO public.referral_reward_grants (
    referrer_user_id, rule_id, rule_version, cycle_index, reward_type,
    reward_days_granted, qualified_referral_count, resulting_ends_at)
  VALUES (v_ref.referrer_user_id, v_rule.id, v_rule.version, v_prog.cycle_index,
          'report_export_ad_free', v_rule.reward_days, v_new_count, now())
  ON CONFLICT (referrer_user_id, rule_id, cycle_index) DO NOTHING
  RETURNING id INTO v_grant_id;
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RETURN jsonb_build_object('qualified', true, 'granted', false, 'duplicate_milestone', true);
  END IF;

  -- 4. Entitlement event + state, same transaction, deterministic operation id.
  v_ent := public.apply_entitlement_mutation(
    p_operation_id     => concat_ws(':', 'referral', v_rule.id::text,
                                    v_prog.cycle_index::text, v_ref.referrer_user_id::text),
    p_user_id          => v_ref.referrer_user_id,
    p_entitlement_type => 'report_export_ad_free',
    p_event_type       => 'grant',
    p_source           => 'referral_reward',
    p_duration_days    => v_rule.reward_days,
    p_source_reference => v_grant_id::text,
    p_rule_id          => v_rule.id,
    p_rule_version     => v_rule.version,
    p_cycle_index      => v_prog.cycle_index);

  -- 5. Complete the grant record with the boundary the event produced.
  UPDATE public.referral_reward_grants
     SET entitlement_event_id = (v_ent->>'event_id')::uuid,
         resulting_ends_at    = (v_ent->>'ends_at')::timestamptz
   WHERE id = v_grant_id;

  -- 6. Close this cycle; open the next one only if the rule repeats AND a rule
  --    is currently active to pin. Otherwise park in awaiting_rule/completed.
  IF v_rule.repeatable THEN
    v_next := public.active_referral_rule('report_export_ad_free');
    IF v_next.id IS NULL THEN
      UPDATE public.referral_reward_progress
         SET cycle_index = cycle_index + 1, qualified_in_cycle = 0,
             pinned_rule_id = NULL, pinned_rule_version = NULL,
             cycle_state = 'awaiting_rule'
       WHERE referrer_user_id = v_ref.referrer_user_id
         AND reward_type = 'report_export_ad_free';
    ELSE
      UPDATE public.referral_reward_progress
         SET cycle_index = cycle_index + 1, qualified_in_cycle = 0,
             pinned_rule_id = v_next.id, pinned_rule_version = v_next.version,
             cycle_state = 'open'
       WHERE referrer_user_id = v_ref.referrer_user_id
         AND reward_type = 'report_export_ad_free';
    END IF;
  ELSE
    UPDATE public.referral_reward_progress
       SET pinned_rule_id = NULL, pinned_rule_version = NULL,
           cycle_state = 'completed'
     WHERE referrer_user_id = v_ref.referrer_user_id
       AND reward_type = 'report_export_ad_free';
  END IF;

  RETURN jsonb_build_object('qualified', true, 'granted', true,
    'grant_id', v_grant_id, 'ends_at', v_ent->>'ends_at',
    'rule_version', v_rule.version, 'cycle_index', v_prog.cycle_index);
END $$;

-- ===========================================================================
-- 14 ── user-callable RPCs ──────────────────────────────────────────────────
-- ===========================================================================

-- Attribution. Self-only, generic errors, no referrer information disclosed.
CREATE OR REPLACE FUNCTION public.apply_referral_code(p_code TEXT)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_uid      UUID := auth.uid();
  v_code     TEXT;
  v_owner    UUID;
  v_rule     public.referral_reward_rules%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Canonical normalization: strip separators/space, upper-case.
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));

  IF EXISTS (SELECT 1 FROM public.referrals WHERE referred_user_id = v_uid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_referred');
  END IF;

  -- New attribution requires an active rule (server authority, not a flag).
  v_rule := public.active_referral_rule('report_export_ad_free');
  IF v_rule.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_rule');
  END IF;

  SELECT user_id INTO v_owner FROM public.referral_codes
   WHERE code = v_code AND status = 'active';

  -- Generic result: reveals nothing about whether a code or account exists.
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_code');
  END IF;
  IF v_owner = v_uid THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'self_referral');
  END IF;

  BEGIN
    INSERT INTO public.referrals (referrer_user_id, referred_user_id,
                                  referral_code, attribution_method, status)
    VALUES (v_owner, v_uid, v_code, 'manual_code', 'attributed');
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_referred');
  END;

  -- Inline qualification through the SAME authoritative path (no second
  -- algorithm). Returns 'identity_unverified' until the referee verifies.
  RETURN jsonb_build_object('ok', true, 'attributed', true,
    'qualification', public.qualify_referral_internal(v_uid));
END $$;

-- "Please evaluate me" — argument-free, self-only. Never "I am qualified".
CREATE OR REPLACE FUNCTION public.request_referral_qualification()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN public.qualify_referral_internal(v_uid);
END $$;

-- Self-only summary: counts and status, never referee identities.
CREATE OR REPLACE FUNCTION public.get_referral_summary()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_code TEXT;
  v_prog public.referral_reward_progress%ROWTYPE;
  v_rule public.referral_reward_rules%ROWTYPE;
  v_ent  public.user_entitlement_state%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_code := public.ensure_referral_code(v_uid);

  SELECT * INTO v_prog FROM public.referral_reward_progress
   WHERE referrer_user_id = v_uid AND reward_type = 'report_export_ad_free';

  IF v_prog.pinned_rule_id IS NOT NULL THEN
    SELECT * INTO v_rule FROM public.referral_reward_rules WHERE id = v_prog.pinned_rule_id;
  ELSE
    v_rule := public.active_referral_rule('report_export_ad_free');
  END IF;

  SELECT * INTO v_ent FROM public.user_entitlement_state
   WHERE user_id = v_uid AND entitlement_type = 'report_export_ad_free';

  RETURN jsonb_build_object(
    'referral_code',       v_code,
    'progress',            coalesce(v_prog.qualified_in_cycle, 0),
    'required_referrals',  v_rule.required_referrals,
    'reward_days',         v_rule.reward_days,
    'repeatable',          v_rule.repeatable,
    'cycle_index',         coalesce(v_prog.cycle_index, 1),
    'cycle_state',         coalesce(v_prog.cycle_state, 'open'),
    'referrals_available', (public.active_referral_rule('report_export_ad_free')).id IS NOT NULL,
    'entitlement_status',  coalesce(v_ent.status, 'none'),
    'entitlement_ends_at', v_ent.ends_at,
    'server_now',          now());
END $$;

-- The Report gate's server contract. A successful response lets the client
-- derive VERIFIED_ACTIVE / VERIFIED_INACTIVE; a failure is NOT a decision and
-- must be treated by the client as UNKNOWN_OR_STALE.
CREATE OR REPLACE FUNCTION public.get_entitlement_decision(p_entitlement_type TEXT)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_ent public.user_entitlement_state%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_entitlement_type IS DISTINCT FROM 'report_export_ad_free' THEN
    RAISE EXCEPTION 'invalid_entitlement_type' USING ERRCODE = 'data_exception';
  END IF;

  SELECT * INTO v_ent FROM public.user_entitlement_state
   WHERE user_id = v_uid AND entitlement_type = p_entitlement_type;

  RETURN jsonb_build_object(
    'entitlement_type', p_entitlement_type,
    'status',  CASE WHEN v_ent.user_id IS NULL THEN 'none' ELSE v_ent.status END,
    'ends_at', v_ent.ends_at,
    'active',  coalesce(v_ent.status = 'active' AND v_ent.ends_at > now(), false),
    'server_now', now());
END $$;

-- ===========================================================================
-- 15 ── Admin audit allowlist (no arbitrary before/after dumps) ─────────────
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.referral_audit_allowlist(p_payload JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT CASE WHEN p_payload IS NULL THEN NULL ELSE
    (SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
       FROM jsonb_each(p_payload) AS e(k, v)
      WHERE k IN ('entitlement_type','status','ends_at','duration_days',
                  'rule_id','rule_version','required_referrals','reward_days',
                  'repeatable','is_active','cycle_index','qualified_in_cycle',
                  'referral_status','rejection_reason'))
  END
$$;

-- ===========================================================================
-- 16 ── EXECUTE privileges (0079/0080 pattern; no default EXECUTE reliance) ─
-- ===========================================================================
REVOKE ALL ON FUNCTION public.generate_referral_code()                                   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ensure_referral_code(UUID)                                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.active_referral_rule(TEXT)                                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qualify_referral_internal(UUID)                            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.referral_audit_allowlist(JSONB)                            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_entitlement_mutation(
  TEXT, UUID, TEXT, TEXT, TEXT, INTEGER, TEXT, UUID, INTEGER, INTEGER, UUID, TEXT)       FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.apply_referral_code(TEXT)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_referral_qualification()       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_referral_summary()                 FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_entitlement_decision(TEXT)         FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.apply_referral_code(TEXT)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_referral_qualification()    TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_referral_summary()              TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_entitlement_decision(TEXT)      TO authenticated;

-- ===========================================================================
-- 17 ── purge_user_data extension (ONE deletion authority, extended) ────────
-- Referee deletion must NOT rewind a referrer's earned progress: progress is a
-- counter (never a recount), and a QUALIFIED referral is de-identified rather
-- than deleted so the qualification fact survives without the person.
--
-- This is a CREATE OR REPLACE of the 0065 function with the referral block
-- prepended; the original body is reproduced verbatim so no existing deletion
-- behaviour changes. Signature, `security invoker`, search_path and grants are
-- preserved exactly as 0065 declared them.
-- ===========================================================================
create or replace function public.purge_user_data(p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- ── Referral / entitlement domain (0083) ─────────────────────────────────
  -- (A) as REFEREE: an unqualified attribution disappears with them…
  delete from public.referrals
   where referred_user_id = p_user_id and status in ('attributed', 'rejected');
  -- …a qualified/reversed one keeps only the non-identifying fact, so the
  -- referrer's history and cycle accounting stay intact.
  update public.referrals
     set referred_user_id = null, referred_user_deleted_at = now()
   where referred_user_id = p_user_id;

  -- (B) as REFERRER: the whole user-facing referral domain is removed.
  delete from public.referral_reward_grants   where referrer_user_id = p_user_id;
  delete from public.referral_reward_progress where referrer_user_id = p_user_id;
  delete from public.referrals                where referrer_user_id = p_user_id;
  delete from public.referral_codes           where user_id = p_user_id;

  -- (C) as ENTITLEMENT OWNER.
  delete from public.user_entitlement_state where user_id = p_user_id;
  delete from public.entitlement_events     where user_id = p_user_id;

  -- (D) as AUDIT TARGET: the audit row survives, de-identified — no email,
  -- phone, referral code or auth uuid is retained anywhere after purge.
  update public.referral_admin_audit
     set target_user_id = null, target_ref = null
   where target_user_id = p_user_id;

  -- ── Original 0065 body, unchanged ────────────────────────────────────────
  -- Children before parents (FK order), satellites before their anchors.
  delete from public.capture_rate_limits
  where install_id_hash in (
    select install_id_hash from public.capture_devices
    where user_id = p_user_id
  );

  delete from public.notification_logs where user_id = p_user_id;

  delete from public.user_bill_payments        where user_id = p_user_id;
  delete from public.user_goal_contributions   where user_id = p_user_id;
  delete from public.user_plan_transaction_links where user_id = p_user_id;
  delete from public.user_subscriptions        where user_id = p_user_id;
  delete from public.user_goals                where user_id = p_user_id;
  delete from public.user_plans                where user_id = p_user_id;
  delete from public.user_budgets              where user_id = p_user_id;
  delete from public.user_transactions         where user_id = p_user_id;
  delete from public.user_cards                where user_id = p_user_id;
  delete from public.user_accounts             where user_id = p_user_id;
  delete from public.user_smart_inbox          where user_id = p_user_id;
  delete from public.user_categories           where user_id = p_user_id;
  delete from public.financial_import_runs     where user_id = p_user_id;
  delete from public.user_settings             where user_id = p_user_id;
  delete from public.user_achievements         where user_id = p_user_id;
  delete from public.user_streaks              where user_id = p_user_id;
  delete from public.user_xp_levels            where user_id = p_user_id;
  delete from public.feature_flag_overrides    where user_id = p_user_id;
  delete from public.sender_bank_mappings      where user_id = p_user_id;
  delete from public.capture_devices           where user_id = p_user_id;
  delete from public.backups                   where user_id = p_user_id;
  delete from public.profiles                  where id      = p_user_id;
end;
$$;

-- Restate the 0065 ACLs so a fresh install of this file alone stays locked down.
revoke all on function public.purge_user_data(uuid) from public, anon, authenticated;
grant execute on function public.purge_user_data(uuid) to service_role;

-- ===========================================================================
-- 18 ── feature-flag seeds (fail closed) ────────────────────────────────────
-- Rollout gates only. Referral SERVER authority is the active rule, never a flag.
-- ===========================================================================
INSERT INTO public.feature_flags (key, value_type, value, description, rollout_percent, is_active)
VALUES
  ('enable_referrals',  'boolean', 'false', 'Referral invites and rewards', 0, true),
  ('enable_report_ads', 'boolean', 'false', 'Report export interstitial ads', 0, true)
ON CONFLICT (key) DO NOTHING;

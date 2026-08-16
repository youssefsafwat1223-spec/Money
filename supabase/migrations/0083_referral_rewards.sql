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
-- One ACTIVE code per user, plus the full rotation history. The ROW — not the
-- user — is the identity, because a retired code must keep existing after it
-- stops working: while its history row survives, the global UNIQUE on `code`
-- permanently reserves that string, so a rotated code can never be re-issued
-- to a different person and an already-shared link can never silently begin
-- crediting a stranger.
--
-- (A user_id PRIMARY KEY cannot express this: one row per user means rotation
-- either overwrites the old code — losing the reservation — or is impossible.)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.referral_codes (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code       TEXT NOT NULL UNIQUE,
  status     TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  rotated_at TIMESTAMPTZ NULL,
  CONSTRAINT referral_codes_status_shape CHECK (status IN ('active', 'rotated')),
  -- Canonical uppercase, fixed length 8, Crockford-like alphabet with the
  -- ambiguous glyphs O/0/I/1/L excluded. The CHECK is the authority: a code
  -- that does not match cannot be stored by any path, including service_role.
  CONSTRAINT referral_codes_shape CHECK (code ~ '^[2-9A-HJKMNP-TV-Z]{8}$'),
  -- rotated_at is the retirement evidence: exactly the rotated rows carry it,
  -- in both directions, so "active with a rotation date" is unrepresentable.
  CONSTRAINT referral_codes_rotated_at_shape CHECK (
    (status = 'active'  AND rotated_at IS NULL)
    OR
    (status = 'rotated' AND rotated_at IS NOT NULL))
);

-- At most ONE active code per user. History rows are unbounded, so this is a
-- partial unique index rather than a primary key: "the current code" stays
-- unambiguous while every superseded code keeps its UNIQUE reservation.
CREATE UNIQUE INDEX IF NOT EXISTS referral_codes_one_active_per_user
  ON public.referral_codes (user_id)
  WHERE status = 'active';

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
  -- qualified_at is the historical evidence that this referral once qualified,
  -- so it is REQUIRED for 'reversed' too: a fraud reversal must never erase the
  -- original qualification timestamp. 'reversed' is reachable only from
  -- 'qualified', so the pairing is exact in both directions.
  CONSTRAINT referrals_qualified_at_shape CHECK (
    (status IN ('attributed', 'rejected') AND qualified_at IS NULL)
    OR
    (status IN ('qualified', 'reversed')  AND qualified_at IS NOT NULL)
  )
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
  -- The idempotency anchor for every Admin mutation that is NOT an entitlement
  -- change (those also claim entitlement_events.operation_id). TEXT, not UUID,
  -- deliberately: an Admin entitlement operation writes THE SAME operation_id
  -- into both ledgers, and entitlement_events.operation_id is TEXT, so one
  -- logical identifier must not exist under two types.
  operation_id          TEXT NOT NULL UNIQUE,
  -- SHA-256 over the canonical jsonb of the REQUESTED intent. UNIQUE alone
  -- cannot tell a genuine retry from a different operation reusing the key.
  operation_fingerprint TEXT NOT NULL,
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

-- NO table in this domain carries ANY policy, for anon or authenticated.
-- RLS is enabled with ZERO policies everywhere, so a direct table read returns
-- nothing regardless of who asks.
--
-- The earlier draft let a referrer/referee SELECT their own `referrals` row.
-- That was wrong: the row necessarily contains the OTHER party's user id, so
-- "read your own row" is a cross-account identifier disclosure — the referrer
-- learns the referee's UUID and vice-versa. Nothing in the V1 UX needs it.
--
-- referral_codes and user_entitlement_state lost their owner-read policies for
-- a simpler reason: get_referral_summary() and get_entitlement_decision()
-- already return everything the client needs, so a direct grant would only
-- widen the surface for convenience.
--
-- The complete authenticated read surface is therefore FOUR RPCs, nothing else.

REVOKE ALL ON TABLE
  public.referral_codes, public.referrals, public.referral_reward_rules,
  public.referral_reward_progress, public.user_entitlement_state,
  public.entitlement_events, public.referral_reward_grants,
  public.referral_admin_audit
  FROM anon, authenticated;

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
  -- 30 symbols: Crockford base32 minus the ambiguous O, 0, I, 1, L.
  v_alphabet CONSTANT TEXT    := '23456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_n        CONSTANT INTEGER := 30;
  -- REJECTION SAMPLING. 256 % 30 = 16, so a plain `byte % 30` is biased: the
  -- first 16 symbols would appear 9 times per 256 values and the rest only 8.
  -- 240 is the largest multiple of 30 that fits in a byte, so bytes >= 240 are
  -- discarded and only the uniform range 0..239 is mapped.
  v_limit    CONSTANT INTEGER := 240;   -- 240 % 30 = 0
  v_code     TEXT := '';
  v_bytes    BYTEA;
  v_byte     INTEGER;
  i          INTEGER;
  guard      INTEGER := 0;
BEGIN
  -- Guard the uniformity assumption rather than trusting the literals.
  IF char_length(v_alphabet) <> v_n OR v_limit % v_n <> 0 THEN
    RAISE EXCEPTION 'referral_code_alphabet_invalid';
  END IF;

  -- Draw in blocks; ~6.25% of bytes are rejected, so 8 accepted symbols
  -- normally need one or two blocks. The guard bounds a pathological CSPRNG.
  WHILE char_length(v_code) < 8 LOOP
    guard := guard + 1;
    IF guard > 64 THEN
      RAISE EXCEPTION 'referral_code_generation_failed'
        USING ERRCODE = 'data_exception';
    END IF;
    v_bytes := gen_random_bytes(16);
    FOR i IN 0..15 LOOP
      EXIT WHEN char_length(v_code) >= 8;
      v_byte := get_byte(v_bytes, i);
      CONTINUE WHEN v_byte >= v_limit;          -- reject the biased tail
      v_code := v_code || substr(v_alphabet, (v_byte % v_n) + 1, 1);
    END LOOP;
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
  SELECT code INTO v_existing FROM public.referral_codes
   WHERE user_id = p_user_id AND status = 'active';
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- Bounded collision retry; never degrade to predictable data.
  WHILE attempt < 5 LOOP
    attempt := attempt + 1;
    v_code := public.generate_referral_code();
    BEGIN
      -- Conflict target is the PARTIAL index: a concurrent creator for the
      -- same user loses harmlessly, and rotation history never blocks this.
      INSERT INTO public.referral_codes (user_id, code)
      VALUES (p_user_id, v_code)
      ON CONFLICT (user_id) WHERE status = 'active' DO NOTHING;

      SELECT code INTO v_existing FROM public.referral_codes
       WHERE user_id = p_user_id AND status = 'active';
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

  -- CANONICAL REQUESTED INTENT, hashed with SHA-256.
  --
  -- Delimiter-joined concatenation was replaced because it is ambiguous: with a
  -- '|' separator the fields ('a|b', 'c') and ('a', 'b|c') produce an identical
  -- string, so two different operations could collide onto one fingerprint.
  -- jsonb is unambiguous AND canonically ordered by Postgres, so a harmless
  -- change in key order cannot change the hash.
  --
  -- This describes the REQUEST, never the outcome: resulting_ends_at and
  -- resulting_status are deliberately excluded because they depend on current
  -- state, and the same request must fingerprint identically whenever it is
  -- replayed.
  v_fingerprint := encode(
    digest(
      convert_to(
        jsonb_build_object(
          'actor',            coalesce(lower(p_actor_admin_id::text), 'system'),
          'target_user',      lower(p_user_id::text),
          'entitlement_type', lower(p_entitlement_type),
          'event_type',       lower(p_event_type),
          'source',           lower(p_source),
          'duration_days',    p_duration_days,
          'source_reference', p_source_reference,
          'rule_id',          lower(p_rule_id::text),
          'rule_version',     p_rule_version,
          'cycle_index',      p_cycle_index,
          -- Reason is part of an Admin operation's intent, so a materially
          -- different reason is a different operation. Normalized (trimmed,
          -- internal whitespace collapsed) so cosmetic edits do not diverge.
          'reason',           nullif(btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g')), '')
        )::text,
        'UTF8'),
      'sha256'),
    'hex');

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
  v_attr TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_code := public.ensure_referral_code(v_uid);

  -- The caller's OWN attribution, as a bare status. This is the entire reason
  -- the referrals table needs no direct read policy: the UX needs "was my code
  -- accepted / has it qualified", never the counterpart's identity. No user id
  -- of the other party is selected, returned, or derivable from this.
  SELECT status INTO v_attr
    FROM public.referrals WHERE referred_user_id = v_uid;

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
    'attribution_status',  coalesce(v_attr, 'none'),
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
-- 16 ── Admin mutation authority (service-role only) ────────────────────────
-- Every Admin mutation is ONE transactional server operation that (a) claims
-- its operation_id, (b) performs the domain change through the existing
-- authority, and (c) writes exactly one referral_admin_audit row — all or
-- nothing. Next.js therefore never needs multi-statement writes, and the
-- table can no longer be writerless.
--
-- CLAIM-BEFORE-MUTATE is the invariant that makes replay safe. The audit claim
-- is the serialization point, so a retry is recognised BEFORE any state is
-- read for mutation; that is also why the per-operation state validation lives
-- AFTER the claim, otherwise a replay would fail its own precondition (a
-- referral already 'rejected' is no longer 'attributed') instead of returning
-- the stored result.
-- ===========================================================================

-- Canonical reason normalization, shared by the fingerprint and the stored
-- row so a cosmetic whitespace edit can never look like a different intent.
CREATE OR REPLACE FUNCTION public.referral_norm_reason(p_reason TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT nullif(btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g')), '')
$$;

-- Server-authoritative reason contract (r3: 4–500 plain-text chars). The audit
-- CHECK is the backstop; this raises a controlled error instead.
CREATE OR REPLACE FUNCTION public.referral_admin_require_reason(p_reason TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v TEXT := public.referral_norm_reason(p_reason);
BEGIN
  IF v IS NULL
     OR char_length(v) < 4 OR char_length(v) > 500
     OR v ~ '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' THEN
    RAISE EXCEPTION 'invalid_reason' USING ERRCODE = 'data_exception';
  END IF;
  RETURN v;
END $$;

-- SHA-256 over canonical jsonb. jsonb orders its keys deterministically, so a
-- harmless change in construction order cannot change the digest, and unlike a
-- delimiter-joined string it cannot collide across field boundaries.
CREATE OR REPLACE FUNCTION public.referral_admin_fingerprint(p_intent JSONB)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT encode(digest(convert_to(p_intent::text, 'UTF8'), 'sha256'), 'hex')
$$;

-- THE single idempotency gate for every Admin mutation. Returns
--   {claimed:true , audit_id}                        -> caller owns the operation
--   {claimed:false, audit_id, after_state}           -> genuine replay
-- and raises idempotency_mismatch when the key is reused with a different
-- intent. Written once so seven wrappers cannot drift apart.
CREATE OR REPLACE FUNCTION public.referral_admin_claim(
  p_operation_id   TEXT,
  p_fingerprint    TEXT,
  p_actor_admin_id UUID,
  p_action         TEXT,
  p_target_user_id UUID,
  p_target_ref     TEXT,
  p_reason         TEXT,
  p_before         JSONB
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_existing public.referral_admin_audit%ROWTYPE;
  v_id       UUID;
  v_rowcount INTEGER;
BEGIN
  IF p_operation_id IS NULL OR p_actor_admin_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;

  SELECT * INTO v_existing
    FROM public.referral_admin_audit WHERE operation_id = p_operation_id;
  IF FOUND THEN
    IF v_existing.operation_fingerprint <> p_fingerprint THEN
      RAISE EXCEPTION 'idempotency_mismatch' USING ERRCODE = 'data_exception';
    END IF;
    RETURN jsonb_build_object('claimed', false, 'audit_id', v_existing.id,
                              'after_state', v_existing.after_state);
  END IF;

  -- UNIQUE(operation_id) serializes concurrent racers: the loser blocks here
  -- and then observes the committed row.
  INSERT INTO public.referral_admin_audit (
    operation_id, operation_fingerprint, actor_admin_id, action,
    target_user_id, target_ref, reason, before_state)
  VALUES (
    p_operation_id, p_fingerprint, p_actor_admin_id, p_action,
    p_target_user_id, p_target_ref, p_reason, p_before)
  ON CONFLICT (operation_id) DO NOTHING
  RETURNING id INTO v_id;
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  IF v_rowcount = 0 THEN
    SELECT * INTO v_existing
      FROM public.referral_admin_audit WHERE operation_id = p_operation_id;
    IF v_existing.operation_fingerprint <> p_fingerprint THEN
      RAISE EXCEPTION 'idempotency_mismatch' USING ERRCODE = 'data_exception';
    END IF;
    RETURN jsonb_build_object('claimed', false, 'audit_id', v_existing.id,
                              'after_state', v_existing.after_state);
  END IF;

  RETURN jsonb_build_object('claimed', true, 'audit_id', v_id);
END $$;

-- ── 16a ── entitlement: grant / extend / shorten / revoke ──────────────────
-- A thin, explicitly-enumerated Admin façade. It does NOT reimplement the
-- entitlement algorithm: apply_entitlement_mutation stays the sole authority
-- and stays internal, so there is no generic state-update endpoint anywhere.
CREATE OR REPLACE FUNCTION public.admin_mutate_entitlement(
  p_operation_id     TEXT,
  p_actor_admin_id   UUID,
  p_user_id          UUID,
  p_entitlement_type TEXT,
  p_action           TEXT,
  p_reason           TEXT,
  p_duration_days    INTEGER DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
  v_fp     TEXT;
  v_claim  jsonb;
  v_prev   public.user_entitlement_state%ROWTYPE;
  v_res    jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  IF p_action NOT IN ('grant', 'extend', 'shorten', 'revoke') THEN
    RAISE EXCEPTION 'invalid_event_type' USING ERRCODE = 'data_exception';
  END IF;
  -- Typed, mappable error instead of letting entitlement_events_type_shape
  -- surface a raw constraint violation to the Admin route.
  IF p_entitlement_type IS DISTINCT FROM 'report_export_ad_free' THEN
    RAISE EXCEPTION 'invalid_entitlement_type' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',           p_action,
    'actor',            lower(p_actor_admin_id::text),
    'duration_days',    p_duration_days,
    'entitlement_type', lower(p_entitlement_type),
    'reason',           v_reason,
    'target_user',      lower(p_user_id::text)));

  SELECT * INTO v_prev FROM public.user_entitlement_state
   WHERE user_id = p_user_id AND entitlement_type = p_entitlement_type;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, p_action, p_user_id, NULL, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'entitlement_type', p_entitlement_type,
      'status',           coalesce(v_prev.status, 'none'),
      'ends_at',          v_prev.ends_at)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  v_res := public.apply_entitlement_mutation(
    p_operation_id     => p_operation_id,
    p_user_id          => p_user_id,
    p_entitlement_type => p_entitlement_type,
    p_event_type       => p_action,
    p_source           => 'admin_grant',
    p_duration_days    => p_duration_days,
    p_actor_admin_id   => p_actor_admin_id,
    p_reason           => v_reason);

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'entitlement_type', p_entitlement_type,
           'status',           v_res->>'status',
           'ends_at',          v_res->>'ends_at',
           'duration_days',    p_duration_days))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'result', v_res);
END $$;

-- ── 16b ── reject a pending attribution (never delete it) ──────────────────
CREATE OR REPLACE FUNCTION public.admin_reject_referral(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_referral_id    UUID,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason   TEXT;
  v_fp       TEXT;
  v_claim    jsonb;
  v_ref      public.referrals%ROWTYPE;
  v_rowcount INTEGER;
BEGIN
  IF p_referral_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',          'reject_referral',
    'actor',           lower(p_actor_admin_id::text),
    'reason',          v_reason,
    'target_referral', lower(p_referral_id::text)));

  SELECT * INTO v_ref FROM public.referrals WHERE id = p_referral_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'referral_not_found' USING ERRCODE = 'data_exception';
  END IF;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'reject_referral',
    v_ref.referrer_user_id, p_referral_id::text, v_reason,
    public.referral_audit_allowlist(jsonb_build_object('referral_status', v_ref.status)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  -- Guarded transition: rejection applies ONLY to a still-pending attribution.
  -- An already-qualified referral must go through reversal instead.
  UPDATE public.referrals
     SET status = 'rejected', rejection_reason = v_reason
   WHERE id = p_referral_id AND status = 'attributed';
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RAISE EXCEPTION 'referral_not_rejectable' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'referral_status', 'rejected', 'rejection_reason', v_reason))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'referral_status', 'rejected');
END $$;

-- ── 16c ── reverse an already-qualified referral (fraud finding ONLY) ──────
-- Deliberately narrow: it records the finding and nothing else. Progress
-- adjustment and entitlement change are SEPARATE operator intents with their
-- own operation ids, reasons and audit rows — never implicit consequences.
CREATE OR REPLACE FUNCTION public.admin_reverse_referral(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_referral_id    UUID,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason   TEXT;
  v_fp       TEXT;
  v_claim    jsonb;
  v_ref      public.referrals%ROWTYPE;
  v_rowcount INTEGER;
BEGIN
  IF p_referral_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',          'reverse_referral',
    'actor',           lower(p_actor_admin_id::text),
    'reason',          v_reason,
    'target_referral', lower(p_referral_id::text)));

  SELECT * INTO v_ref FROM public.referrals WHERE id = p_referral_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'referral_not_found' USING ERRCODE = 'data_exception';
  END IF;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'reverse_referral',
    v_ref.referrer_user_id, p_referral_id::text, v_reason,
    public.referral_audit_allowlist(jsonb_build_object('referral_status', v_ref.status)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  -- qualified_at is NOT cleared: referrals_qualified_at_shape requires it for
  -- 'reversed', because the fact that this referral once qualified is exactly
  -- the history a fraud review depends on.
  UPDATE public.referrals
     SET status = 'reversed', rejection_reason = v_reason
   WHERE id = p_referral_id AND status = 'qualified';
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RAISE EXCEPTION 'referral_not_reversible' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'referral_status', 'reversed', 'rejection_reason', v_reason))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'referral_status', 'reversed');
END $$;

-- ── 16d ── progress adjustment (narrow, invariant-preserving) ──────────────
CREATE OR REPLACE FUNCTION public.admin_adjust_referral_progress(
  p_operation_id       TEXT,
  p_actor_admin_id     UUID,
  p_referrer_user_id   UUID,
  p_reward_type        TEXT,
  p_qualified_in_cycle INTEGER,
  p_reason             TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
  v_fp     TEXT;
  v_claim  jsonb;
  v_prog   public.referral_reward_progress%ROWTYPE;
  v_rule   public.referral_reward_rules%ROWTYPE;
BEGIN
  IF p_referrer_user_id IS NULL OR p_qualified_in_cycle IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',             'adjust_progress',
    'actor',              lower(p_actor_admin_id::text),
    'qualified_in_cycle', p_qualified_in_cycle,
    'reason',             v_reason,
    'reward_type',        lower(p_reward_type),
    'target_user',        lower(p_referrer_user_id::text)));

  SELECT * INTO v_prog FROM public.referral_reward_progress
   WHERE referrer_user_id = p_referrer_user_id AND reward_type = p_reward_type
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'progress_not_found' USING ERRCODE = 'data_exception';
  END IF;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'adjust_progress',
    p_referrer_user_id, p_reward_type, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'cycle_index',        v_prog.cycle_index,
      'qualified_in_cycle', v_prog.qualified_in_cycle,
      'rule_id',            v_prog.pinned_rule_id,
      'rule_version',       v_prog.pinned_rule_version)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  -- Only an OPEN, rule-pinned cycle can be adjusted. A completed or
  -- awaiting_rule cycle has no threshold to be measured against, and
  -- referral_progress_open_is_pinned would be violated by inventing one.
  IF v_prog.cycle_state <> 'open' THEN
    RAISE EXCEPTION 'cycle_not_adjustable' USING ERRCODE = 'data_exception';
  END IF;

  SELECT * INTO v_rule FROM public.referral_reward_rules WHERE id = v_prog.pinned_rule_id;
  IF v_rule.id IS NULL THEN
    RAISE EXCEPTION 'cycle_not_adjustable' USING ERRCODE = 'data_exception';
  END IF;

  -- The milestone boundary is not crossable by adjustment in EITHER direction:
  -- reaching the threshold is what mints a reward grant, and that must happen
  -- through qualification, never as a side effect of an Admin correction.
  IF p_qualified_in_cycle < 0 OR p_qualified_in_cycle >= v_rule.required_referrals THEN
    RAISE EXCEPTION 'adjustment_crosses_milestone' USING ERRCODE = 'data_exception';
  END IF;

  -- cycle_index and the pinned rule are deliberately untouched: history stays.
  UPDATE public.referral_reward_progress
     SET qualified_in_cycle = p_qualified_in_cycle
   WHERE referrer_user_id = p_referrer_user_id AND reward_type = p_reward_type;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'cycle_index',        v_prog.cycle_index,
           'qualified_in_cycle', p_qualified_in_cycle,
           'rule_id',            v_prog.pinned_rule_id,
           'rule_version',       v_prog.pinned_rule_version))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'qualified_in_cycle', p_qualified_in_cycle);
END $$;

-- ── 16e ── referral-code rotation ──────────────────────────────────────────
-- The operator supplies NO code text. The old code is retired (keeping its
-- UNIQUE reservation forever) and a fresh CSPRNG code becomes active, in one
-- transaction. Neither the old nor the new code string is written to the
-- audit: purge_user_data must be able to leave nothing user-identifying
-- behind, so the audit references the retired ROW id (which purge nulls).
CREATE OR REPLACE FUNCTION public.admin_rotate_referral_code(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_user_id        UUID,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason  TEXT;
  v_fp      TEXT;
  v_claim   jsonb;
  v_old     public.referral_codes%ROWTYPE;
  v_code    TEXT;
  v_new_id  UUID;
  v_attempt INTEGER := 0;
  v_current TEXT;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',      'rotate_code',
    'actor',       lower(p_actor_admin_id::text),
    'reason',      v_reason,
    'target_user', lower(p_user_id::text)));

  SELECT * INTO v_old FROM public.referral_codes
   WHERE user_id = p_user_id AND status = 'active' FOR UPDATE;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'rotate_code',
    p_user_id, v_old.id::text, v_reason,
    public.referral_audit_allowlist(jsonb_build_object('status', 'active')));

  IF NOT (v_claim->>'claimed')::boolean THEN
    SELECT code INTO v_current FROM public.referral_codes
     WHERE user_id = p_user_id AND status = 'active';
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id',
      -- live state, not a replayed value: the rotation already happened
      'current_active_code', v_current);
  END IF;

  IF v_old.id IS NULL THEN
    RAISE EXCEPTION 'no_active_referral_code' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_codes
     SET status = 'rotated', rotated_at = now()
   WHERE id = v_old.id;

  -- Bounded collision retry against the GLOBAL unique code reservation, which
  -- includes every retired code — so a rotated code can never be handed out.
  -- The loop is LABELLED because the EXIT sits inside a nested
  -- BEGIN … EXCEPTION block: an unlabelled EXIT would still leave the loop,
  -- but naming the target makes that unambiguous to the next reader.
  <<mint_code>>
  WHILE v_attempt < 5 LOOP
    v_attempt := v_attempt + 1;
    v_code := public.generate_referral_code();
    BEGIN
      INSERT INTO public.referral_codes (user_id, code)
      VALUES (p_user_id, v_code)
      RETURNING id INTO v_new_id;
      EXIT mint_code;
    EXCEPTION WHEN unique_violation THEN
      v_new_id := NULL;   -- collided with a live or retired code: draw again
    END;
  END LOOP;

  IF v_new_id IS NULL THEN
    RAISE EXCEPTION 'referral_code_generation_failed' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object('status', 'rotated'))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'new_code', v_code);
END $$;

-- ── 16f ── publish a new rule version (atomic swap) ────────────────────────
-- referral_rules_one_active_per_type is a PARTIAL UNIQUE index, so "deactivate
-- the old, insert the new" cannot be two PostgREST calls: a partial failure
-- would leave either a unique violation or ZERO active rules, and zero active
-- rules silently halts qualification for every user.
CREATE OR REPLACE FUNCTION public.admin_publish_reward_rule(
  p_operation_id       TEXT,
  p_actor_admin_id     UUID,
  p_reward_type        TEXT,
  p_required_referrals INTEGER,
  p_reward_days        INTEGER,
  p_repeatable         BOOLEAN,
  p_reason             TEXT,
  p_effective_until    TIMESTAMPTZ DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason  TEXT;
  v_fp      TEXT;
  v_claim   jsonb;
  v_prev    public.referral_reward_rules%ROWTYPE;
  v_version INTEGER;
  v_new_id  UUID;
BEGIN
  IF p_reward_type IS NULL OR p_required_referrals IS NULL OR p_reward_days IS NULL
     OR p_repeatable IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',             'publish_rule',
    'actor',              lower(p_actor_admin_id::text),
    'effective_until',    p_effective_until,
    'reason',             v_reason,
    'repeatable',         p_repeatable,
    'required_referrals', p_required_referrals,
    'reward_days',        p_reward_days,
    'reward_type',        lower(p_reward_type)));

  -- Serialize publication per reward_type so version numbering cannot race
  -- even when no rule rows exist yet to lock.
  PERFORM pg_advisory_xact_lock(hashtext('referral_rule_publish:' || p_reward_type));

  SELECT * INTO v_prev FROM public.referral_reward_rules
   WHERE reward_type = p_reward_type AND is_active;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'rule_change', NULL, p_reward_type, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'rule_id',            v_prev.id,
      'rule_version',       v_prev.version,
      'required_referrals', v_prev.required_referrals,
      'reward_days',        v_prev.reward_days,
      'repeatable',         v_prev.repeatable,
      'is_active',          v_prev.is_active)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  SELECT coalesce(max(version), 0) + 1 INTO v_version
    FROM public.referral_reward_rules WHERE reward_type = p_reward_type;

  -- Only is_active flips on the superseded row. Its reward semantics are NEVER
  -- rewritten, because open cycles stay pinned to it by pinned_rule_id.
  IF v_prev.id IS NOT NULL THEN
    UPDATE public.referral_reward_rules SET is_active = false WHERE id = v_prev.id;
  END IF;

  INSERT INTO public.referral_reward_rules (
    version, reward_type, required_referrals, reward_days, repeatable,
    is_active, effective_until, created_by)
  VALUES (
    v_version, p_reward_type, p_required_referrals, p_reward_days, p_repeatable,
    true, p_effective_until, p_actor_admin_id)
  RETURNING id INTO v_new_id;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'rule_id',            v_new_id,
           'rule_version',       v_version,
           'required_referrals', p_required_referrals,
           'reward_days',        p_reward_days,
           'repeatable',         p_repeatable,
           'is_active',          true))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id',
    'rule_id', v_new_id, 'rule_version', v_version);
END $$;

-- ── 16g ── deactivate the active rule (stop NEW attribution) ───────────────
-- Pinned in-progress cycles keep their historical rule and are untouched; this
-- only removes the rule that active_referral_rule() would hand to NEW cycles.
CREATE OR REPLACE FUNCTION public.admin_deactivate_reward_rule(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_reward_type    TEXT,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
  v_fp     TEXT;
  v_claim  jsonb;
  v_prev   public.referral_reward_rules%ROWTYPE;
BEGIN
  IF p_reward_type IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',      'deactivate_rule',
    'actor',       lower(p_actor_admin_id::text),
    'reason',      v_reason,
    'reward_type', lower(p_reward_type)));

  PERFORM pg_advisory_xact_lock(hashtext('referral_rule_publish:' || p_reward_type));

  SELECT * INTO v_prev FROM public.referral_reward_rules
   WHERE reward_type = p_reward_type AND is_active;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'rule_change', NULL, p_reward_type, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'rule_id',      v_prev.id,
      'rule_version', v_prev.version,
      'is_active',    v_prev.is_active)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  IF v_prev.id IS NULL THEN
    RAISE EXCEPTION 'no_active_rule' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_reward_rules SET is_active = false WHERE id = v_prev.id;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'rule_id', v_prev.id, 'rule_version', v_prev.version, 'is_active', false))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'rule_id', v_prev.id, 'is_active', false);
END $$;

-- ===========================================================================
-- 17 ── EXECUTE privilege matrix (0079/0080 pattern) ────────────────────────
-- Exactly three classes, and every function is revoked from every role it is
-- not meant for. Nothing here relies on a Supabase default privilege:
--
--   INTERNAL_ONLY          no role may EXECUTE — reachable only from inside a
--                          SECURITY DEFINER body (service_role included, so an
--                          Admin route cannot reach the raw primitives)
--   AUTHENTICATED_SELF_RPC the four auth.uid()-scoped user RPCs
--   SERVICE_ROLE_ADMIN_RPC the seven trusted Admin operations
-- ===========================================================================

-- ── INTERNAL_ONLY ──────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.generate_referral_code()                                   FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.ensure_referral_code(UUID)                                 FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.active_referral_rule(TEXT)                                 FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.qualify_referral_internal(UUID)                            FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.referral_audit_allowlist(JSONB)                            FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.referral_norm_reason(TEXT)                                 FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.referral_admin_require_reason(TEXT)                        FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.referral_admin_fingerprint(JSONB)                          FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.referral_admin_claim(
  TEXT, TEXT, UUID, TEXT, UUID, TEXT, TEXT, JSONB)                                       FROM PUBLIC, anon, authenticated, service_role;
-- The entitlement primitive stays internal ON PURPOSE. Admin traffic goes
-- through admin_mutate_entitlement, which enumerates the four legal actions and
-- writes the audit row; granting this directly would reopen a generic,
-- unaudited state-update endpoint.
REVOKE ALL ON FUNCTION public.apply_entitlement_mutation(
  TEXT, UUID, TEXT, TEXT, TEXT, INTEGER, TEXT, UUID, INTEGER, INTEGER, UUID, TEXT)       FROM PUBLIC, anon, authenticated, service_role;

-- ── AUTHENTICATED_SELF_RPC ─────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.apply_referral_code(TEXT)              FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.request_referral_qualification()       FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.get_referral_summary()                 FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.get_entitlement_decision(TEXT)         FROM PUBLIC, anon, service_role;

GRANT EXECUTE ON FUNCTION public.apply_referral_code(TEXT)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_referral_qualification()    TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_referral_summary()              TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_entitlement_decision(TEXT)      TO authenticated;

-- ── SERVICE_ROLE_ADMIN_RPC ─────────────────────────────────────────────────
-- These are server APIs for the trusted Admin backend only. They do NOT
-- replace browser -> requireAdmin() -> admin_users -> server-only service role;
-- they are what that chain is finally allowed to call.
REVOKE ALL ON FUNCTION public.admin_mutate_entitlement(
  TEXT, UUID, UUID, TEXT, TEXT, TEXT, INTEGER)                                           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_reject_referral(TEXT, UUID, UUID, TEXT)              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_reverse_referral(TEXT, UUID, UUID, TEXT)             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_adjust_referral_progress(
  TEXT, UUID, UUID, TEXT, INTEGER, TEXT)                                                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_rotate_referral_code(TEXT, UUID, UUID, TEXT)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_publish_reward_rule(
  TEXT, UUID, TEXT, INTEGER, INTEGER, BOOLEAN, TEXT, TIMESTAMPTZ)                        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_deactivate_reward_rule(TEXT, UUID, TEXT, TEXT)       FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_mutate_entitlement(
  TEXT, UUID, UUID, TEXT, TEXT, TEXT, INTEGER)                                           TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_reject_referral(TEXT, UUID, UUID, TEXT)           TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_reverse_referral(TEXT, UUID, UUID, TEXT)          TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_adjust_referral_progress(
  TEXT, UUID, UUID, TEXT, INTEGER, TEXT)                                                 TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_rotate_referral_code(TEXT, UUID, UUID, TEXT)      TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_publish_reward_rule(
  TEXT, UUID, TEXT, INTEGER, INTEGER, BOOLEAN, TEXT, TIMESTAMPTZ)                        TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_deactivate_reward_rule(TEXT, UUID, TEXT, TEXT)    TO service_role;

-- ===========================================================================
-- 18 ── purge_user_data extension (ONE deletion authority, extended) ────────
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

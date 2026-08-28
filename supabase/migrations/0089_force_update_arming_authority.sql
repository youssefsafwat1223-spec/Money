-- C-2a-2 — make force-update arming a server-authorized, audited operation.
--
-- THE DEFECT
-- Arming `severity='force_update' AND is_active` blocks ALL navigation for EVERY
-- installed client (`ForceUpdateScreen`). Confirmation was a caller-supplied
-- boolean (`confirm_force_update`) on the ordinary announcements PATCH/POST, and
-- the typed phrase «تحديث إجباري» lived only in the React dialog. Any direct API
-- call — curl, a script, a compromised admin session — sent `true` and armed.
-- The application guard stopped a misclick, not an actor.
--
-- Additionally the Next.js route read the row and then wrote it in two separate
-- statements, so two concurrent PATCHes could each observe a not-armed row and
-- arm between them (TOCTOU).
--
-- THE FIX — three layers, in increasing order of authority
--   1. the app guard (already shipped) keeps arming out of ordinary edits;
--   2. `arm_force_update()` is the ONLY sanctioned way to arm: SECURITY DEFINER,
--      one transaction, writes the audit row and sets a transaction-local
--      sentinel before mutating — which also removes the TOCTOU;
--   3. a trigger REFUSES any not-blocking -> blocking transition that arrives
--      without that sentinel, whatever wrote it.
--
-- Layer 3 is what makes this more than convention. Triggers fire for EVERY role
-- including `service_role` — service_role bypasses RLS, not triggers — and the
-- admin panel reaches PostgREST, which cannot execute DDL, so a key-holder
-- cannot drop the trigger through the API surface.
--
-- HONEST LIMIT, stated so nobody over-trusts this: an authenticated admin can
-- still call the RPC. This does not make arming impossible for a valid session.
-- What it does deliver: arming can no longer happen as a SIDE EFFECT of an
-- ordinary write, it cannot happen without an attributable audit row that no
-- admin route can delete, and it cannot happen by flipping a boolean. Making a
-- stolen session insufficient needs re-authentication at the arm route, which is
-- application-layer work tracked separately.
--
-- "Blocking" matches the application guard exactly: severity + is_active + a
-- serving window that has not expired. An expired force-update blocks nobody, so
-- resurrecting one IS an arming — that was a real bypass (C-2a-1).

BEGIN;

-- ─── 1. Append-only audit ────────────────────────────────────────────────────
-- Modelled on public.referral_admin_audit (0083): no admin route may UPDATE or
-- DELETE these rows, so an arming performed with a stolen session stays
-- attributable and cannot be erased by the actor.
CREATE TABLE IF NOT EXISTS public.announcement_admin_audit (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  announcement_id UUID NOT NULL,
  actor_admin_id  UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  action          TEXT NOT NULL CHECK (action IN ('arm', 'disarm')),
  reason          TEXT NOT NULL,
  before_state    JSONB NULL,
  after_state     JSONB NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT announcement_audit_reason_shape
    CHECK (char_length(reason) BETWEEN 4 AND 500
           AND reason !~ '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')
);

CREATE INDEX IF NOT EXISTS idx_announcement_audit_target
  ON public.announcement_admin_audit(announcement_id, created_at DESC);

ALTER TABLE public.announcement_admin_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.announcement_admin_audit FROM anon, authenticated;

-- ─── 2. "Does this row block clients?" — one definition, used by the trigger ──
CREATE OR REPLACE FUNCTION public.announcement_blocks_clients(
  p_severity TEXT,
  p_is_active BOOLEAN,
  p_valid_until TIMESTAMPTZ
) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_severity = 'force_update'
     AND p_is_active IS TRUE
     AND (p_valid_until IS NULL OR p_valid_until > now());
$$;

-- ─── 3. The trigger: refuse an unauthorized arming, whoever writes it ─────────
CREATE OR REPLACE FUNCTION public.guard_force_update_arming()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  was_blocking BOOLEAN := FALSE;
  will_block   BOOLEAN;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    was_blocking := public.announcement_blocks_clients(
      OLD.severity, OLD.is_active, OLD.valid_until);
  END IF;

  will_block := public.announcement_blocks_clients(
    NEW.severity, NEW.is_active, NEW.valid_until);

  -- Only the not-blocking -> blocking TRANSITION is guarded. Editing an already
  -- armed announcement, and disarming one, both stay frictionless: making it
  -- harder to reduce blast radius than to increase it would be backwards.
  IF will_block AND NOT was_blocking THEN
    IF coalesce(current_setting('app.arm_force_update', true), '') = '' THEN
      RAISE EXCEPTION
        'force-update arming must go through arm_force_update() (C-2a-2)'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_force_update_arming ON public.announcements;
CREATE TRIGGER trg_guard_force_update_arming
  BEFORE INSERT OR UPDATE ON public.announcements
  FOR EACH ROW EXECUTE FUNCTION public.guard_force_update_arming();

-- ─── 4. The ONLY sanctioned way to arm ───────────────────────────────────────
-- One transaction: audit first, then sentinel, then mutate. Because the read and
-- the write share a transaction, the TOCTOU in the two-statement route is gone.
CREATE OR REPLACE FUNCTION public.arm_force_update(
  p_announcement_id UUID,
  p_reason          TEXT,
  p_actor           UUID DEFAULT NULL
) RETURNS public.announcements
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
  v_before public.announcements;
  v_after  public.announcements;
BEGIN
  SELECT * INTO v_before FROM public.announcements
   WHERE id = p_announcement_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'announcement % not found', p_announcement_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- A force-update with no action_url strands every client behind a button that
  -- goes nowhere: ForceUpdateScreen falls back to a placeholder store URL with a
  -- fake app id. Refuse rather than arm something the user cannot escape.
  IF coalesce(btrim(v_before.action_url), '') = '' THEN
    RAISE EXCEPTION 'cannot arm a force-update without an action_url'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_before.severity <> 'force_update' THEN
    RAISE EXCEPTION 'announcement % is not a force_update', p_announcement_id
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO public.announcement_admin_audit
    (announcement_id, actor_admin_id, action, reason, before_state, after_state)
  VALUES
    (p_announcement_id, coalesce(p_actor, auth.uid()), 'arm', p_reason,
     to_jsonb(v_before), NULL);

  -- Transaction-local: it cannot leak into another statement or session.
  PERFORM set_config('app.arm_force_update', p_announcement_id::text, true);

  UPDATE public.announcements
     SET is_active = TRUE,
         valid_until = CASE
           WHEN valid_until IS NOT NULL AND valid_until <= now()
           THEN NULL ELSE valid_until END,
         updated_at = now()
   WHERE id = p_announcement_id
  RETURNING * INTO v_after;

  UPDATE public.announcement_admin_audit
     SET after_state = to_jsonb(v_after)
   WHERE announcement_id = p_announcement_id
     AND after_state IS NULL;

  RETURN v_after;
END;
$$;

REVOKE ALL ON FUNCTION public.arm_force_update(UUID, TEXT, UUID)
  FROM PUBLIC, anon, authenticated;

COMMIT;

-- ─── ROLLBACK (run manually; not executed by this migration) ─────────────────
-- Dropping the trigger restores the pre-C-2a-2 behaviour, in which ANY writer
-- could arm a client-blocking force-update with no audit trail. Only do this if
-- the trigger is actively blocking a legitimate operation, and prefer calling
-- arm_force_update() instead.
--
-- BEGIN;
--   DROP TRIGGER IF EXISTS trg_guard_force_update_arming ON public.announcements;
--   DROP FUNCTION IF EXISTS public.arm_force_update(UUID, TEXT, UUID);
--   DROP FUNCTION IF EXISTS public.guard_force_update_arming();
--   DROP FUNCTION IF EXISTS public.announcement_blocks_clients(TEXT, BOOLEAN, TIMESTAMPTZ);
--   -- audit rows are deliberately NOT dropped.
-- COMMIT;

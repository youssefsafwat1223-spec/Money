-- 0070_engagement_events.sql
--
-- MALI-024 — server-authoritative, idempotent engagement events. Replaces the
-- dual-authority model where the client uploaded arbitrary XP/streak totals as
-- authority. The client now submits typed ENGAGEMENT EVENTS; the server decides
-- the award from validated event types + server rules, records each event
-- exactly once, and updates the aggregate atomically. Clients can never set an
-- arbitrary XP total (the aggregate tables have no client write policy, and this
-- RPC derives the award server-side).
--
-- Additive + backward compatible; safe while revision-CAS (0068) remains OFF.
-- Rollback: drop the RPC + table; the existing Edge-Function award path is
-- unaffected.

-- ── Durable, owner-bound, idempotent engagement events ───────────────────────
CREATE TABLE IF NOT EXISTS public.user_engagement_events (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- Client-generated stable id → owner-bound idempotency (a replay is a no-op).
  event_id     UUID NOT NULL,
  event_type   TEXT NOT NULL,
  occurred_at  TIMESTAMPTZ NOT NULL,
  -- Optional business idempotency key (e.g. the source record) so the same
  -- business action cannot be awarded twice even under a fresh event_id.
  business_key TEXT,
  event_version INTEGER NOT NULL DEFAULT 1,
  awarded_xp   INTEGER NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, event_id)
);

-- Partial unique idempotency on the business key when present.
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_engagement_events_business_key
  ON public.user_engagement_events(user_id, business_key)
  WHERE business_key IS NOT NULL;

ALTER TABLE public.user_engagement_events ENABLE ROW LEVEL SECURITY;

-- Owner may read its own events. There is deliberately NO client insert/update
-- policy — events are recorded only through the locked-down RPC below, so a
-- client can never fabricate an award by writing the table directly.
DROP POLICY IF EXISTS user_engagement_events_owner_select
  ON public.user_engagement_events;
CREATE POLICY user_engagement_events_owner_select
  ON public.user_engagement_events
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- ── Server-authoritative award RPC ───────────────────────────────────────────
-- SECURITY DEFINER because it writes the aggregate tables (which have no client
-- write policy — that is the tamper-resistance). It is locked down: fixed
-- search_path, revoked from PUBLIC, granted only to authenticated, and it
-- derives the user from auth.uid() (NEVER a caller-supplied id). The award is
-- computed server-side from the validated event type; the client cannot pass an
-- XP amount. Idempotent: a duplicate event_id or business_key awards nothing and
-- returns the unchanged aggregate.
CREATE OR REPLACE FUNCTION public.record_engagement_event(
  p_event_id     UUID,
  p_event_type   TEXT,
  p_occurred_at  TIMESTAMPTZ,
  p_business_key TEXT DEFAULT NULL,
  p_event_version INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_award   INTEGER;
  v_xp      INTEGER;
  v_level   INTEGER;
  v_streak  INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;
  -- Reject unsupported/future event schema versions (fail safe, no award).
  IF p_event_version IS NULL OR p_event_version <> 1 THEN
    RAISE EXCEPTION 'unsupported event version %', p_event_version
      USING errcode = '22023';
  END IF;

  -- Server-side award rule. An unknown/future event type is rejected — never
  -- silently awarded, and the client can never supply the amount.
  v_award := CASE p_event_type
    WHEN 'transaction_confirmed' THEN 10
    WHEN 'goal_contribution'     THEN 15
    WHEN 'budget_action'         THEN 5
    WHEN 'bill_payment'          THEN 5
    WHEN 'streak_activity'       THEN 2
    ELSE NULL
  END;
  IF v_award IS NULL THEN
    RAISE EXCEPTION 'unknown event type %', p_event_type
      USING errcode = '22023';
  END IF;

  -- Idempotent record. ON CONFLICT DO NOTHING on (user_id, event_id); a
  -- business-key collision raises unique_violation which we treat as a
  -- duplicate no-op below.
  BEGIN
    INSERT INTO public.user_engagement_events(
      user_id, event_id, event_type, occurred_at, business_key,
      event_version, awarded_xp
    ) VALUES (
      v_user_id, p_event_id, p_event_type, p_occurred_at, p_business_key,
      p_event_version, v_award
    )
    ON CONFLICT (user_id, event_id) DO NOTHING;

    IF NOT FOUND THEN
      -- Duplicate event_id → already awarded. Return the current aggregate.
      v_award := 0;
    END IF;
  EXCEPTION WHEN unique_violation THEN
    -- Duplicate business_key → already awarded for this business action.
    v_award := 0;
  END;

  -- Atomic read-modify-write of the XP aggregate (row-locked on conflict, so
  -- concurrent events cannot lose an increment). Only when a new event awarded.
  IF v_award > 0 THEN
    INSERT INTO public.user_xp_levels(user_id, xp, level, updated_at)
    VALUES (v_user_id, v_award, 1 + (v_award / 100), now())
    ON CONFLICT (user_id) DO UPDATE SET
      xp = public.user_xp_levels.xp + EXCLUDED.xp,
      level = 1 + ((public.user_xp_levels.xp + EXCLUDED.xp) / 100),
      updated_at = now();
  END IF;

  SELECT xp, level INTO v_xp, v_level
    FROM public.user_xp_levels WHERE user_id = v_user_id;
  SELECT current_streak INTO v_streak
    FROM public.user_streaks WHERE user_id = v_user_id;

  RETURN jsonb_build_object(
    'xp', COALESCE(v_xp, 0),
    'level', COALESCE(v_level, 1),
    'current_streak', COALESCE(v_streak, 0),
    'awarded', v_award
  );
END;
$$;

-- Lockdown: not callable by public/anon; only authenticated users (who are then
-- scoped to their own auth.uid() inside the function).
REVOKE ALL ON FUNCTION public.record_engagement_event(
  UUID, TEXT, TIMESTAMPTZ, TEXT, INTEGER
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_engagement_event(
  UUID, TEXT, TIMESTAMPTZ, TEXT, INTEGER
) TO authenticated;

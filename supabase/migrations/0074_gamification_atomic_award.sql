-- 0074_gamification_atomic_award.sql — MALI-024 (Batch-5 closure).
--
-- Additive, backward-compatible, DEPLOYED (status corrected 2026-09-01: 0001-0092 applied and ledger-verified on production; this header was never revised after the deploy). Runs strictly after 0073 (which
-- created public.gamification_awarded_transactions), so the ledger table exists
-- when this migration extends it.
--
-- WHY. The Edge Function claimed the idempotency row and mutated XP in SEPARATE
-- PostgREST calls — i.e. SEPARATE Postgres transactions. A crash after the claim
-- committed but before the XP update left a claim row with no award: the claim
-- then blocked every retry, so the award was LOST permanently. A bare
-- claim-before-award ordering does not close that window.
--
-- FIX. Fold the claim AND the XP / level / achievement / notification-eligibility
-- write into ONE plpgsql function body = ONE Postgres transaction. Any failure at
-- any point rolls the claim back together with the award, so the ledger row
-- exists if and only if the award committed. Concurrent workers serialise on the
-- claim row lock; a lost-response retry reconstructs the stored canonical result.
--
-- Forward-recovery: every object is guard-created (ADD COLUMN IF NOT EXISTS /
-- CREATE OR REPLACE), so a partial apply can be re-run idempotently.

-- ── 1. Canonical award result, recorded ATOMICALLY with the claim ─────────────
-- These columns turn the idempotency ledger into the exactly-once record of what
-- was awarded (and therefore what notification is eligible). They are written in
-- the same transaction as the XP mutation by the RPC below.
ALTER TABLE public.gamification_awarded_transactions
  ADD COLUMN IF NOT EXISTS leveled_up       BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS new_level        INTEGER,
  ADD COLUMN IF NOT EXISTS achievement_code TEXT;

-- ── 2. Single-transaction award RPC ──────────────────────────────────────────
-- SECURITY DEFINER + fixed search_path. Caller ownership is NOT trusted: the
-- transaction must belong to the target user. Locked down to service_role only
-- (the DB-webhook-authenticated Edge Function) — never PUBLIC/anon/authenticated.
CREATE OR REPLACE FUNCTION public.award_gamification_for_transaction(
  p_transaction_id TEXT,
  p_user_id        UUID
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_award    CONSTANT INTEGER := 10;
  v_rowcount INTEGER;
  v_existing public.gamification_awarded_transactions%ROWTYPE;
  v_cur_xp    INTEGER;
  v_cur_level INTEGER;
  v_new_xp    INTEGER;
  v_new_level INTEGER;
  v_leveled   BOOLEAN := FALSE;
  v_count     INTEGER;
  v_ach       TEXT := NULL;
BEGIN
  IF p_transaction_id IS NULL OR p_user_id IS NULL THEN
    RETURN jsonb_build_object('awarded', false, 'reason', 'missing_args');
  END IF;

  -- Ownership is never trusted from the caller: the transaction must belong to
  -- the target user, or nothing is awarded.
  IF NOT EXISTS (
    SELECT 1 FROM user_transactions
    WHERE id::text = p_transaction_id AND user_id = p_user_id
  ) THEN
    RETURN jsonb_build_object('awarded', false, 'reason', 'not_owner');
  END IF;

  -- Atomic claim. ON CONFLICT DO NOTHING → ROW_COUNT tells us whether THIS call
  -- won the claim. Concurrent workers block on the uncommitted claim row's lock
  -- until the winner commits (then this call sees the conflict → returns the
  -- stored result) or aborts (then this call's INSERT succeeds → it takes over).
  INSERT INTO gamification_awarded_transactions (transaction_id, user_id)
  VALUES (p_transaction_id, p_user_id)
  ON CONFLICT (transaction_id) DO NOTHING;
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  IF v_rowcount = 0 THEN
    -- Already awarded (previous call or a concurrent winner that committed).
    -- Return the stored canonical result so a lost-response retry reconstructs
    -- exactly the same outcome without re-awarding.
    SELECT * INTO v_existing
      FROM gamification_awarded_transactions
      WHERE transaction_id = p_transaction_id;
    RETURN jsonb_build_object(
      'awarded',     true,
      'duplicate',   true,
      'leveled_up',  v_existing.leveled_up,
      'level',       v_existing.new_level,
      'achievement', v_existing.achievement_code
    );
  END IF;

  -- We won the claim → apply the award in THIS same transaction. A failure below
  -- rolls back the claim too, so the row never outlives a completed award.
  SELECT xp, level INTO v_cur_xp, v_cur_level
    FROM user_xp_levels WHERE user_id = p_user_id;
  v_new_xp    := COALESCE(v_cur_xp, 0) + v_award;
  v_new_level := floor(sqrt(v_new_xp / 100.0)) + 1;
  v_leveled   := v_new_level > COALESCE(v_cur_level, 1);
  IF NOT v_leveled THEN
    v_new_level := COALESCE(v_cur_level, 1);
  END IF;

  INSERT INTO user_xp_levels (user_id, xp, level, updated_at)
  VALUES (p_user_id, v_new_xp, v_new_level, now())
  ON CONFLICT (user_id) DO UPDATE
    SET xp = EXCLUDED.xp, level = EXCLUDED.level, updated_at = now();

  -- Count-based achievement (matches the legacy Edge thresholds).
  SELECT count(*) INTO v_count FROM user_transactions WHERE user_id = p_user_id;
  IF    v_count = 1   THEN v_ach := 'first_transaction';
  ELSIF v_count = 10  THEN v_ach := 'tenth_transaction';
  ELSIF v_count = 100 THEN v_ach := 'century_transaction';
  END IF;

  -- Record the canonical result + notification eligibility ATOMICALLY with the
  -- award (same transaction). This row IS the exactly-once eligibility record;
  -- provider delivery happens afterward, keyed by a stable id.
  UPDATE gamification_awarded_transactions
    SET leveled_up       = v_leveled,
        new_level        = CASE WHEN v_leveled THEN v_new_level ELSE NULL END,
        achievement_code = v_ach
    WHERE transaction_id = p_transaction_id;

  RETURN jsonb_build_object(
    'awarded',     true,
    'duplicate',   false,
    'leveled_up',  v_leveled,
    'level',       v_new_level,
    'achievement', v_ach
  );
END;
$$;

REVOKE ALL ON FUNCTION public.award_gamification_for_transaction(TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.award_gamification_for_transaction(TEXT, UUID) TO service_role;

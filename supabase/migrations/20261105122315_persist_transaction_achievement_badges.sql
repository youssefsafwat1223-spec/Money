-- Persist earned transaction badges with the atomic XP award. Existing RLS,
-- deletion admission, per-user locking and service-only execution stay intact.
CREATE OR REPLACE FUNCTION public.award_gamification_for_transaction(p_transaction_id text, p_user_id uuid)
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
  perform account_fence.admit(p_user_id);  -- [fence]
  -- Audit H-12 (Batch 13): the claim below serializes per TRANSACTION id, but
  -- the XP read-modify-write is on the per-USER authority row (user_xp_levels)
  -- and was unlocked. Two DISTINCT-transaction awards for one user both read the
  -- same xp and both write +10 → +10 net instead of +20 (the immutable award
  -- ledger shows two, the aggregate reflects one). Serialize on the user
  -- authority key first (needs no existing row); the loser then reads the
  -- winner's committed xp and adds to it. One lock per call, acquired before the
  -- claim, so ordering is uniform (user key only) — no deadlock cycle.
  PERFORM pg_advisory_xact_lock(hashtextextended('mali_xp:' || p_user_id::text, 0));
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

  -- Count committed award claims, not all synced rows. Batched inserts can be
  -- visible before any worker runs; the per-user lock makes this count advance
  -- once per successful award, including when workers finish out of order.
  SELECT count(*) INTO v_count FROM public.gamification_awarded_transactions
    WHERE user_id = p_user_id;
  IF    v_count = 1   THEN v_ach := 'first_transaction';
  ELSIF v_count = 10  THEN v_ach := 'tenth_transaction';
  ELSIF v_count = 100 THEN v_ach := 'century_transaction';
  END IF;

  -- Persist the badge in the table pulled by GamificationSyncService. A failure
  -- rolls back XP and the claim too; retries never leave a partial award.
  IF v_ach IS NOT NULL THEN
    INSERT INTO public.user_achievements (user_id, achievement_key, unlocked_at)
    VALUES (p_user_id, v_ach, now())
    ON CONFLICT (user_id, achievement_key) DO NOTHING;
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

REVOKE ALL ON FUNCTION public.award_gamification_for_transaction(TEXT, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.award_gamification_for_transaction(TEXT, UUID)
  TO service_role;

-- Recover missing earned badges, without replaying XP or notifications. Use the
-- original Nth award time, including historical awards for later-deleted financial
-- transactions. Never revive an existing badge tombstone or a deleted account.
DO $backfill$
DECLARE
  v_user UUID;
BEGIN
  FOR v_user IN
    SELECT DISTINCT a.user_id
      FROM public.gamification_awarded_transactions a
      JOIN auth.users u ON u.id = a.user_id
      WHERE NOT account_fence.is_pending(a.user_id)
      ORDER BY a.user_id
  LOOP
    -- Admission and the same award lock prevent races with account deletion and
    -- new awards. A busy/deleting account aborts the migration for a safe retry.
    PERFORM account_fence.admit(v_user);
    PERFORM pg_advisory_xact_lock(hashtextextended('mali_xp:' || v_user::text, 0));
    WITH earned AS (
      SELECT awarded_at,
        row_number() OVER (ORDER BY awarded_at, transaction_id) AS ordinal
      FROM public.gamification_awarded_transactions
      WHERE user_id = v_user
    )
    INSERT INTO public.user_achievements (user_id, achievement_key, unlocked_at)
      SELECT v_user, m.achievement_key, e.awarded_at
      FROM earned e
      JOIN (VALUES (1, 'first_transaction'), (10, 'tenth_transaction'),
                   (100, 'century_transaction')) AS m(ordinal, achievement_key)
        ON m.ordinal = e.ordinal
    ON CONFLICT (user_id, achievement_key) DO NOTHING;
  END LOOP;
END;
$backfill$;

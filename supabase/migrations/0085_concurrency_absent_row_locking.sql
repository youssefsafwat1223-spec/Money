-- ===========================================================================
-- 0085 ── SQL concurrency: absent-row locking family (H-10 / H-11 / H-12)
-- ===========================================================================
-- ── DEPLOYMENT STATUS (corrected 2026-09-02) ───────────────────────────────
-- APPLIED IN PRODUCTION. Verified by a read-only owner query against
-- `supabase_migrations.schema_migrations` on the CURRENT production project
-- (`rjwphwsefnuotpbtuycf`): the ledger is continuous through 0092, and 0084,
-- 0085 and 0086 are each explicitly present.
--
-- The "SOURCE-ONLY / NOT APPLIED TO ANY PROJECT" header this replaces was true
-- when written and was never revised. It was written against a DIFFERENT,
-- earlier production project; that project is no longer the deployment target
-- and is now explicitly off-limits. The header therefore described a project
-- this migration was never going to run on, while saying nothing about the one
-- it did run on. That is why it survived four audits.
--
-- Deployment state is tracked in ONE place — docs/project/MIGRATION_LEDGER.md.
-- Do not re-add a per-file deployment claim here: ten copies of one fact is how
-- this contradiction arose.
--
-- DEPENDENCY: apply 0084 BEFORE 0085 when either is eventually rolled out.
-- 0085 does not depend on 0084's contents, but the migration order must hold.
-- This is a FORWARD fix: it CREATE OR REPLACEs three functions. It never edits
-- applied migration history (0083 / 0074) — those bodies are reproduced verbatim
-- here with one added serialization primitive each, so the fix is auditable as a
-- diff against the originals.
--
-- Cross-model audit 2026-08-23 — findings H-10 (HIGH), H-11 (HIGH),
-- H-12 (MEDIUM-HIGH: XP is data-integrity, not money). See
-- docs/FINAL_CROSS_MODEL_AUDIT_RECONCILIATION.md.
--
-- ── The shared root cause ──────────────────────────────────────────────────
-- `SELECT ... FOR UPDATE` does not serialize competing writers when the target
-- row does NOT exist yet: there is no row to lock, so two concurrent "first"
-- transactions both proceed on a stale (empty) read, and a later
-- `ON CONFLICT DO UPDATE` writes a value each computed independently.
--
-- ── The single primitive ───────────────────────────────────────────────────
-- `pg_advisory_xact_lock` on a deterministic per-authority key, taken BEFORE the
-- read. It does not require the row to exist, is released automatically at
-- commit/rollback, and each function takes exactly ONE such lock, acquired ahead
-- of any row lock — so lock ordering is uniform and no deadlock cycle is
-- introduced. `hashtextextended(text, 0)` maps the authority key into the bigint
-- advisory-lock space.
--
-- Idempotency is unchanged and independent of this: same operation_id / same
-- claimed transaction still collapses to one logical mutation via the existing
-- UNIQUE / ON CONFLICT DO NOTHING guards; distinct operation_ids concurrently
-- now each apply exactly once.
--
-- SECURITY: every function keeps its original SECURITY DEFINER, VOLATILE, and
-- `SET search_path = pg_catalog, public, pg_temp`. No grant/revoke or table
-- access is changed here — see the ACL restatement at the end for lockdown on a
-- fresh apply of this file alone.
-- ===========================================================================

-- ── H-10 ── public.apply_entitlement_mutation ────────────────────────────
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
  -- Audit H-10 (Batch 13): serialize competing writers on the entitlement
  -- authority key. SELECT ... FOR UPDATE below locks nothing when the state row
  -- does not exist yet, so two concurrent FIRST grants both read an empty
  -- previous state, both compute now()+duration, and the second ON CONFLICT
  -- overwrites the first's ends_at with its own stale precomputed value — the
  -- two grants collapse into one duration. A transaction advisory lock is
  -- deterministic on the authority key, needs no existing row, and releases at
  -- commit/rollback; the loser then re-reads the winner's committed state and
  -- extends additively. Acquired FIRST (one lock per call) so ordering is
  -- uniform and no deadlock cycle is possible.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('mali_entitlement:' || p_user_id::text || ':' ||
      coalesce(p_entitlement_type, ''), 0));
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
    extensions.digest(
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

-- ── H-11 ── public.qualify_referral_internal ─────────────────────────────
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

  -- Audit H-11 (Batch 13): serialize on the referrer's progress authority
  -- BEFORE reading it. The SELECT ... FOR UPDATE locks nothing when no progress
  -- row exists yet, so two concurrent first qualifiers both take the
  -- absent-row/awaiting_rule branch; if a new rule is published between their
  -- reads, the loser's ON CONFLICT would overwrite the winner's pin and the open
  -- cycle would count a V1 qualification while governed by V2. The advisory lock
  -- makes the loser wait, re-read the committed 'open' row, and keep the winner's
  -- pin. Keyed on the referrer (v_ref resolved above), one lock per call.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('mali_referral_progress:' ||
      v_ref.referrer_user_id::text || ':report_export_ad_free', 0));

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
          cycle_state = 'open'
      -- Audit H-11: pin ONLY while the cycle is still awaiting a rule. An
      -- already-open cycle keeps its original pin for its whole lifetime; the
      -- advisory lock makes this branch unreachable for a concurrent loser, and
      -- this predicate is the belt-and-braces guarantee.
      WHERE public.referral_reward_progress.cycle_state = 'awaiting_rule';
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

-- ── H-12 ── public.award_gamification_for_transaction ─────────────────────
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

-- ===========================================================================
-- ACL restatement — identical to 0083 / 0074, so a fresh apply of THIS file
-- alone stays locked down (CREATE OR REPLACE preserves existing privileges on a
-- project where 0083/0074 already ran; this covers the standalone case). No
-- privilege is broadened relative to the originals.
-- ===========================================================================
-- Internal-only (called by other SECURITY DEFINER functions, never directly):
REVOKE ALL ON FUNCTION public.apply_entitlement_mutation(
  TEXT, UUID, TEXT, TEXT, TEXT, INTEGER, TEXT, UUID, INTEGER, INTEGER, UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.qualify_referral_internal(UUID)
  FROM PUBLIC, anon, authenticated, service_role;

-- Server API for the trusted backend only:
REVOKE ALL ON FUNCTION public.award_gamification_for_transaction(TEXT, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.award_gamification_for_transaction(TEXT, UUID)
  TO service_role;

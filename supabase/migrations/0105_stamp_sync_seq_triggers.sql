-- 0105_stamp_sync_seq_triggers.sql — WP-2 (manifest 0106): stamp_sync_seq()
-- BEFORE INSERT OR UPDATE on every table from 0104.
--
-- For each written row the trigger:
--   1. takes the user's lock and allocates the next number in ONE statement,
--        INSERT INTO user_sync_state .. ON CONFLICT (user_id) DO UPDATE
--          SET last_seq = last_seq + 1 RETURNING last_seq
--      The upsert is lazy-creating, so a missing state row can never leave a row
--      unstamped; a NULL result (impossible) raises 'sync_state_missing'.
--   2. sets NEW.sync_seq (a client-supplied value is always overwritten);
--   3. sets NEW.updated_at := now() — server time on INSERT too, which removes
--      the client-clock INSERT (B6). The existing BEFORE UPDATE updated_at
--      triggers do the same on UPDATE and stay.
--
-- Ordering: the row lock is held until the writer commits. Under READ COMMITTED
-- a second writer for the same user waits, then re-reads the committed last_seq,
-- so allocation order == commit order and no reader sees n+1 before n. Gaps (a
-- rolled-back transaction, a BEFORE INSERT that loses an ON CONFLICT) are
-- harmless to a `> cursor` pull. Cascading triggers (budgets, gamification) run
-- in the same transaction and stamp their own rows.
--
-- SECURITY DEFINER because user_sync_state has no client write grant (0103). It
-- is trigger-bound, takes no arguments, and derives the user only from NEW.user_id.
--
-- Old (build-50) clients are unaffected: their merge-upserts on
-- (user_id, client_request_id) / (user_id, local_id) hit the same unique indexes;
-- the only differences are the extra sync_seq value and server-set updated_at.
-- user_achievements has no updated_at column (trigger arg 'no_updated_at').
--
-- Re-runs public.backfill_sync_seq() at the end as a catch-up for rows written
-- between 0104 and this trigger (CREATE TRIGGER blocks concurrent writers until
-- commit, so nothing can slip in after the catch-up).

BEGIN;

CREATE OR REPLACE FUNCTION public.stamp_sync_seq()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_seq bigint;
BEGIN
  INSERT INTO public.user_sync_state (user_id, last_seq, epoch_reason)
  VALUES (NEW.user_id, 1, 'initial')
  ON CONFLICT (user_id) DO UPDATE
    SET last_seq = public.user_sync_state.last_seq + 1,
        updated_at = now()
  RETURNING last_seq INTO v_seq;
  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'sync_state_missing' USING ERRCODE = 'P0001';
  END IF;
  NEW.sync_seq := v_seq;
  IF TG_NARGS = 0 THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.stamp_sync_seq() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'user_accounts', 'user_transactions', 'user_budgets', 'user_goals',
    'user_goal_contributions', 'user_plans', 'user_plan_transaction_links',
    'user_subscriptions', 'user_bill_payments', 'user_cards', 'user_categories',
    'user_settings', 'user_smart_inbox', 'sender_bank_mappings',
    'user_achievements', 'user_streaks', 'user_xp_levels'
  ] LOOP
    -- The function reads NEW.user_id: every synced table must have that exact
    -- column (no table uses another owner column name today).
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = t AND column_name = 'user_id'
    ) THEN
      RAISE EXCEPTION '0105: synced table % has no user_id column', t;
    END IF;
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'trg_' || t || '_stamp_sync_seq', t);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I '
      || 'FOR EACH ROW EXECUTE FUNCTION public.stamp_sync_seq(%s)',
      'trg_' || t || '_stamp_sync_seq', t,
      CASE WHEN t = 'user_achievements' THEN quote_literal('no_updated_at') ELSE '' END);
  END LOOP;
END $$;

SELECT public.backfill_sync_seq();

COMMIT;

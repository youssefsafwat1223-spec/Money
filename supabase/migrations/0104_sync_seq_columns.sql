-- 0104_sync_seq_columns.sql — WP-2 (manifest 0105): sync_seq column + index +
-- backfill on every synced table. The stamping trigger is 0105.
--
-- sync_seq is the per-USER, commit-ordered change sequence (one counter per user
-- in user_sync_state, shared across that user's tables). Pull becomes
-- `sync_seq > cursor` per table; tombstones are soft-deleted rows.
--
-- SYNCED TABLES (17) — every table the sync plan §14 matrix pulls or pushes:
--   user_accounts, user_transactions, user_budgets, user_goals,
--   user_goal_contributions, user_plans, user_plan_transaction_links,
--   user_subscriptions, user_bill_payments, user_cards, user_categories,
--   user_settings, user_smart_inbox, sender_bank_mappings,
--   user_achievements, user_streaks, user_xp_levels   (gamification read models)
--
-- EXCLUDED, with reason:
--   processed_captures              capture result store (manifest §7: never)
--   user_engagement_events          append-only telemetry, "unchanged" in §14
--   gamification_awarded_transactions  server-internal dedupe ledger, not pulled
--   user_entitlement_state          server-derived entitlement, not in the matrix
--   capture_devices, capture_fingerprints, capture_rate_limits
--                                   device/relay state, not replicated user data
--   profiles, backups, notification_logs, notification_retry_queue,
--   feature_flag_overrides, financial_import_runs, referral_*, affiliate_*,
--   catalog/parser/coupon/bank tables   not user ledger replicas (own protocols
--                                   or server-global data)
--
-- Every synced table's owner column is named user_id (asserted by 0105 and by
-- supabase/tests/sync_seq_0103_0109.sql). user_streaks/user_xp_levels have no id
-- (PK user_id) and user_achievements has no updated_at (unlocked_at is its clock);
-- the backfill order key handles both.
--
-- Backfill order (updated_at, id), per user, across all of that user's tables
-- (one counter), ties broken by table name then row id. It runs with USER
-- triggers disabled so existing rows keep their revision/updated_at and no
-- budget/goal/gamification side effect fires. public.backfill_sync_seq() is left
-- in place (callable by no client) because 0105 re-runs it as a catch-up for rows
-- written between this migration and the trigger.

BEGIN;

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
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS sync_seq bigint', t);
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I ON public.%I (user_id, sync_seq)',
      'idx_' || t || '_user_sync_seq', t);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.backfill_sync_seq()
RETURNS bigint
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  -- {table, row-id column, order-key column}
  spec CONSTANT text[] := ARRAY[
    'user_accounts:id:updated_at', 'user_transactions:id:updated_at',
    'user_budgets:id:updated_at', 'user_goals:id:updated_at',
    'user_goal_contributions:id:updated_at', 'user_plans:id:updated_at',
    'user_plan_transaction_links:id:updated_at', 'user_subscriptions:id:updated_at',
    'user_bill_payments:id:updated_at', 'user_cards:id:updated_at',
    'user_categories:id:updated_at', 'user_settings:id:updated_at',
    'user_smart_inbox:id:updated_at', 'sender_bank_mappings:id:updated_at',
    'user_achievements:id:unlocked_at', 'user_streaks:user_id:updated_at',
    'user_xp_levels:user_id:updated_at'
  ];
  s text;
  parts text[];
  union_sql text := '';
  total bigint;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_trigger tg
    JOIN pg_class c ON c.oid = tg.tgrelid
    WHERE NOT tg.tgisinternal AND tg.tgenabled <> 'O'
      AND c.relnamespace = 'public'::regnamespace
      AND c.relname = ANY (SELECT split_part(x, ':', 1) FROM unnest(spec) x)
  ) THEN
    RAISE EXCEPTION 'backfill_sync_seq: a user trigger on a synced table is already disabled; refusing to re-enable it blindly';
  END IF;

  FOREACH s IN ARRAY spec LOOP
    parts := string_to_array(s, ':');
    union_sql := union_sql || CASE WHEN union_sql = '' THEN '' ELSE ' UNION ALL ' END
      || format('SELECT %L::text AS tbl, user_id, %I AS rid, %I AS ts FROM public.%I WHERE sync_seq IS NULL',
                parts[1], parts[2], parts[3], parts[1]);
  END LOOP;

  DROP TABLE IF EXISTS _sync_bf;
  EXECUTE 'CREATE TEMP TABLE _sync_bf AS SELECT u.*, '
    || 'row_number() OVER (PARTITION BY user_id ORDER BY ts, tbl, rid) AS rn, '
    || 'count(*) OVER (PARTITION BY user_id) AS n, 0::bigint AS seq FROM (' || union_sql || ') u';

  -- Reserve a block per user (this also takes the per-user lock to commit), then
  -- number the block: seq = new head - n + rn.
  INSERT INTO public.user_sync_state (user_id, last_seq, epoch_reason)
  SELECT user_id, max(n), 'initial' FROM _sync_bf GROUP BY user_id
  ON CONFLICT (user_id) DO UPDATE
    SET last_seq = public.user_sync_state.last_seq + EXCLUDED.last_seq,
        updated_at = now();
  UPDATE _sync_bf b SET seq = st.last_seq - b.n + b.rn
  FROM public.user_sync_state st WHERE st.user_id = b.user_id;

  FOREACH s IN ARRAY spec LOOP
    parts := string_to_array(s, ':');
    EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER USER', parts[1]);
    EXECUTE format('UPDATE public.%I t SET sync_seq = b.seq FROM _sync_bf b WHERE b.tbl = %L AND t.%I = b.rid',
                   parts[1], parts[1], parts[2]);
    EXECUTE format('ALTER TABLE public.%I ENABLE TRIGGER USER', parts[1]);
  END LOOP;

  SELECT count(*) INTO total FROM _sync_bf;
  DROP TABLE _sync_bf;
  RETURN total;
END;
$$;

REVOKE ALL ON FUNCTION public.backfill_sync_seq() FROM PUBLIC, anon, authenticated;

SELECT public.backfill_sync_seq();

COMMIT;

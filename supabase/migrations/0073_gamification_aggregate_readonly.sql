-- 0073_gamification_aggregate_readonly.sql — MALI-024 (Batch-5 closure).
--
-- Owner-scoped write is NOT security: the 0062 owner INSERT/UPDATE policies let
-- a normal authenticated client set its OWN authoritative XP / level / streak /
-- achievement totals — self-forgery. This migration supersedes those policies so
-- normal clients may only READ their own aggregates. The authoritative WRITER
-- remains the server: service_role bypasses RLS (the active legacy authority
-- evaluate-gamification; and record_engagement_event once its activation gate is
-- met). Reading one's own aggregate stays allowed (0056 SELECT policies).
--
-- Additive and backward-compatible. Does NOT rewrite 0062 (which stays as
-- history); it drops those policies by name. DEPLOYED (status corrected 2026-09-01: 0001-0092 applied and ledger-verified on production; this header was never revised after the deploy).
--
-- Old-client compatibility (honest): the CURRENT client never writes these
-- tables — gamification_sync_service only .select()s them, treats a missing row
-- as zero, and shows offline progress through the local Drift projection; the
-- server creates/updates the row on the first real award. A hypothetical OLDER
-- client that attempted a one-time bootstrap write now receives an RLS denial,
-- which its best-effort catch swallows — non-destructive, no local progress
-- lost, and the server still materializes the row on first award.

DROP POLICY IF EXISTS user_xp_levels_owner_insert ON public.user_xp_levels;
DROP POLICY IF EXISTS user_xp_levels_owner_update ON public.user_xp_levels;
DROP POLICY IF EXISTS user_streaks_owner_insert ON public.user_streaks;
DROP POLICY IF EXISTS user_streaks_owner_update ON public.user_streaks;
DROP POLICY IF EXISTS user_achievements_owner_insert ON public.user_achievements;
DROP POLICY IF EXISTS user_achievements_owner_update ON public.user_achievements;

-- Belt-and-suspenders: also revoke any table-level write grant from the client
-- role, so authoritative aggregates cannot be mutated even if a future policy is
-- added by mistake. service_role is unaffected (it has its own grants + bypasses
-- RLS), so the server authority keeps writing.
REVOKE INSERT, UPDATE, DELETE ON public.user_xp_levels FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.user_streaks FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.user_achievements FROM authenticated;

-- ── Legacy award idempotency (MALI-024 §5) ───────────────────────────────────
-- The active legacy authority (evaluate-gamification) awarded XP per webhook
-- invocation, so a webhook retry, duplicate transaction delivery, function
-- retry, or two concurrent workers double-awarded. This ledger makes the award
-- exactly-once per transaction: the INSERT is the atomic guard — a repeat
-- collides on the primary key and the award is skipped. Service-role only.
CREATE TABLE IF NOT EXISTS public.gamification_awarded_transactions (
  transaction_id TEXT PRIMARY KEY,
  user_id        UUID NOT NULL,
  awarded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE public.gamification_awarded_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS gamification_awarded_transactions_no_direct_access
  ON public.gamification_awarded_transactions;
CREATE POLICY gamification_awarded_transactions_no_direct_access
  ON public.gamification_awarded_transactions
  USING (false)
  WITH CHECK (false);
CREATE INDEX IF NOT EXISTS idx_gamification_awarded_user
  ON public.gamification_awarded_transactions (user_id);

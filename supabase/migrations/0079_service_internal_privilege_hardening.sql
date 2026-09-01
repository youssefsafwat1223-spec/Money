-- 0079_service_internal_privilege_hardening.sql — MALI-026 (Phase-9B remediation).
--
-- Additive, backward-compatible privilege cleanup.
--
-- DEPLOYMENT STATUS (corrected 2026-09-01): DEPLOYED. The original
-- "DEPLOYED (status corrected 2026-09-01: 0001-0092 applied and ledger-verified on production; this header was never revised after the deploy)" was true when written and was never
-- revised; 0001-0092 are applied and ledger-verified on production
-- `rjwphwsefnuotpbtuycf`.
--
-- WHY. Supabase grants anon/authenticated a broad DEFAULT DML set (SELECT, INSERT,
-- UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES) on every new public table. On
-- service-internal tables these direct privileges are UNNECESSARY authority even
-- when RLS denies row access — RLS does NOT gate TRUNCATE / TRIGGER / REFERENCES,
-- so "RLS denies it" is NOT sufficient evidence that a residual TRUNCATE grant to
-- authenticated is harmless. (The current PostgREST/mobile surface does not expose
-- arbitrary TRUNCATE, so this is not a current remote exploit — but it is authority
-- that should not exist before production.)
--
-- INTENT MATRIX (direct TABLE privileges after this migration):
--   table                              | anon | authenticated | service_role
--   -----------------------------------+------+---------------+-------------
--   metrics                            | none | none          | unchanged    (ingress only via record_metric RPC)
--   metrics_rate_limits                | none | none          | unchanged    (internal quota counter; RLS deny-all)
--   ai_request_idempotency             | none | none          | unchanged    (internal idempotency ledger; RLS deny-all)
--   gamification_awarded_transactions  | none | none          | unchanged    (internal award ledger; RLS deny-all)
--   user_xp_levels                     | none | SELECT only   | unchanged    (owner reads own row via owner_select RLS)
--   user_engagement_events             | none | SELECT only   | unchanged    (owner reads own events via owner_select RLS)
--
-- All writes to these tables flow through SECURITY DEFINER RPCs (record_metric,
-- record_engagement_event, claim/complete/prune_ai_*, award_gamification_for_transaction)
-- owned by postgres, or through service_role — none of which need a client-role
-- direct grant. Function EXECUTE grants are UNCHANGED and untouched here (this
-- migration alters TABLE privileges only). service_role authority is UNCHANGED.
--
-- Forward-recovery: REVOKE/GRANT are idempotent; re-running is a no-op.

-- ── Owner-readable tables: authenticated keeps SELECT only, anon gets nothing ──

-- user_xp_levels: 0073 already dropped the owner write policies and revoked
-- INSERT/UPDATE/DELETE from authenticated. Remove the residual TRUNCATE/TRIGGER/
-- REFERENCES too, and drop all anon access; preserve owner SELECT (owner_select RLS).
revoke all on table public.user_xp_levels from anon;
revoke all on table public.user_xp_levels from authenticated;
grant select on table public.user_xp_levels to authenticated;

-- user_engagement_events (0070): owner reads its own events via the owner_select
-- policy; every write goes through record_engagement_event (SECURITY DEFINER).
revoke all on table public.user_engagement_events from anon;
revoke all on table public.user_engagement_events from authenticated;
grant select on table public.user_engagement_events to authenticated;

-- ── Pure service-internal tables: no direct anon/authenticated access at all ───

-- metrics (0001): ingress ONLY via record_metric (SECURITY DEFINER, owner postgres).
-- 0072 revoked authenticated INSERT; remove every remaining direct grant. The client
-- never reads metrics (UI reads only from Drift; admin reads via service_role).
revoke all on table public.metrics from anon;
revoke all on table public.metrics from authenticated;

-- metrics_rate_limits (0072): internal per-user quota counter (RLS deny-all).
revoke all on table public.metrics_rate_limits from anon;
revoke all on table public.metrics_rate_limits from authenticated;

-- ai_request_idempotency (0071): internal idempotency ledger (RLS deny-all).
revoke all on table public.ai_request_idempotency from anon;
revoke all on table public.ai_request_idempotency from authenticated;

-- gamification_awarded_transactions (0073): internal award ledger (RLS deny-all);
-- written only by award_gamification_for_transaction (service_role / DEFINER).
revoke all on table public.gamification_awarded_transactions from anon;
revoke all on table public.gamification_awarded_transactions from authenticated;

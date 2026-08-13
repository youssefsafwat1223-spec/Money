-- 0080_record_engagement_event_execute_hardening.sql — MALI-026 (Phase-9B).
--
-- Privilege-only. Additive/idempotent. NOT DEPLOYED in this checkpoint.
--
-- WHY. 0070 locked record_engagement_event with `REVOKE ALL ... FROM PUBLIC` +
-- `GRANT EXECUTE ... TO authenticated`, intending (per its own comment) "not
-- callable by public/anon; only authenticated". But Supabase's default privileges
-- grant EXECUTE to anon EXPLICITLY at function-creation time, and
-- `REVOKE ... FROM PUBLIC` does NOT remove an explicit per-role grant — so anon
-- RETAINED EXECUTE (has_function_privilege('anon', …) = true; ACL carried
-- `anon=X/postgres`). The function body rejects a null auth.uid(), so no anonymous
-- engagement write is possible — but anon EXECUTE on a SECURITY DEFINER function is
-- unnecessary attack surface that contradicts 0070's stated lockdown. Defense in
-- depth requires the ACL itself to reject anon, in addition to the in-body owner
-- check. Every other callable SECURITY DEFINER function already revokes anon
-- explicitly (e.g. record_metric/0072, get_user_stats/0035, commit_backup_generation/0076);
-- this brings record_engagement_event in line.
--
-- FIX (privilege-only). Explicitly revoke anon (and re-assert PUBLIC), re-affirm the
-- intended authenticated EXECUTE. service_role / postgres authority is UNCHANGED
-- (service_role keeps its Supabase default-privilege grant). The function BODY,
-- SECURITY DEFINER, search_path, signature, the user_engagement_events table
-- policies/grants, and event semantics are ALL UNCHANGED — this migration issues no
-- CREATE FUNCTION and touches no table.
--
-- Forward-recovery: REVOKE/GRANT are idempotent; re-running is a no-op.

REVOKE ALL ON FUNCTION public.record_engagement_event(
  UUID, TEXT, TIMESTAMPTZ, TEXT, INTEGER
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.record_engagement_event(
  UUID, TEXT, TIMESTAMPTZ, TEXT, INTEGER
) TO authenticated;

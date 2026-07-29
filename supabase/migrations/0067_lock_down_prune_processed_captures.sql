-- Lock down prune_processed_captures() (MALI-004 class; found by the CI
-- migration gate, MALI-036).
--
-- 0012 created this SECURITY DEFINER maintenance function without revoking the
-- default PUBLIC execute grant, and it is NOT trigger-bound — so any
-- authenticated (or anon) role could invoke it directly and force pruning of
-- processed capture rows. It is only ever meant to run from the pg_cron
-- dispatcher run_prune_processed_captures() (0033), which already holds execute
-- as the owner, so revoking PUBLIC does not affect the schedule.

revoke all on function public.prune_processed_captures() from public, anon, authenticated;
grant execute on function public.prune_processed_captures() to service_role;

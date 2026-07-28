-- Lock down run_cron_daily_reminders() (MALI-004).
--
-- Migration 0057 created this SECURITY DEFINER dispatcher without revoking
-- the default PUBLIC execute grant, so any authenticated (or even anon) role
-- could invoke it repeatedly — each call posting to the cron-daily-reminders
-- Edge Function and, before that function grew its own service-only guard,
-- spamming every registered device with reminder pushes.
--
-- pg_cron runs the job as the function owner (postgres), which retains
-- execute implicitly as owner — revoking PUBLIC does not affect the schedule.

revoke all on function public.run_cron_daily_reminders() from public, anon, authenticated;
grant execute on function public.run_cron_daily_reminders() to service_role;

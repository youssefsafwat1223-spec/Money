revoke all on function public.mark_onboarding_completed() from authenticated;
drop function if exists public.mark_onboarding_completed();
alter table public.profiles drop column if exists onboarding_completed_at;

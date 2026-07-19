-- Onboarding completion must follow the authenticated account, not one iPhone
-- installation. The client still keeps a local copy for offline startup, while
-- this account-scoped marker prevents an existing user from repeating setup on
-- a reinstall or a second device.

alter table public.profiles
  add column if not exists onboarding_completed_at timestamptz;

comment on column public.profiles.onboarding_completed_at is
  'First confirmed completion of the required Qirsh setup flow.';

-- last_seen_at is written only after AppShell is reached. It is therefore a
-- stronger legacy completion signal than the existence of user_accounts: the
-- first setup step can create an account before notifications/capture setup is
-- finished.
update public.profiles
set onboarding_completed_at = last_seen_at
where onboarding_completed_at is null
  and last_seen_at is not null;

create or replace function public.mark_onboarding_completed()
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  completed_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  update public.profiles
  set onboarding_completed_at = coalesce(onboarding_completed_at, now())
  where id = auth.uid()
  returning onboarding_completed_at into completed_at;

  if completed_at is null then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;
  return completed_at;
end;
$$;

revoke all on function public.mark_onboarding_completed() from public, anon;
grant execute on function public.mark_onboarding_completed() to authenticated;


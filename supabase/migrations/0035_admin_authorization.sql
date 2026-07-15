-- Server-authoritative allowlist for the internal admin application.
--
-- Only the service role / SQL operators can grant or revoke access. An
-- authenticated user may read only their own membership row so middleware can
-- perform an indexed, fail-closed authorization check with the anon client.

create table if not exists public.admin_users (
  id uuid primary key,
  granted_at timestamptz not null default now(),
  granted_by uuid null,
  note text null
);

alter table public.admin_users enable row level security;

drop policy if exists admin_users_self_check on public.admin_users;
create policy admin_users_self_check
  on public.admin_users
  for select
  to authenticated
  using (auth.uid() = id);

revoke all on table public.admin_users from public, anon, authenticated;
grant select on table public.admin_users to authenticated;

-- User-count metrics are an admin surface. The Next.js server invokes this RPC
-- with its server-only service-role client after requireAdmin() succeeds.
revoke execute on function public.get_user_stats() from public, anon, authenticated;
grant execute on function public.get_user_stats() to service_role;

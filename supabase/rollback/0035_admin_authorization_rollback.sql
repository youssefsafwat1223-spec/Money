-- Fail-closed rollback: application authorization checks will deny everyone
-- after this table is removed until the migration is reapplied.

grant execute on function public.get_user_stats() to authenticated;
drop table if exists public.admin_users;

-- Rollback for supabase/migrations/0025_set_default_account_rpc.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Run manually via the SQL Editor only if 0025 needs
-- to be undone.

drop function if exists public.set_default_account(uuid);
drop index if exists public.uidx_user_accounts_one_default;

-- Rollback for supabase/migrations/0024_phase2_kill_switches.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Run manually via the SQL Editor only if 0024 needs
-- to be undone.

delete from public.feature_flags
where key in ('accounts_supabase_primary', 'transactions_supabase_primary');

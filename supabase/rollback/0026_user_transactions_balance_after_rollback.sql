-- Rollback for supabase/migrations/0026_user_transactions_balance_after.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Run manually via the SQL Editor only if 0026 needs
-- to be undone.

alter table public.user_transactions
  drop column if exists balance_after;

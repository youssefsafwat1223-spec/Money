-- Rollback for supabase/migrations/0027_fix_upsert_conflict_indexes.sql.
--
-- Deliberately kept OUTSIDE supabase/migrations/ so `supabase db push` can
-- never auto-apply it. Restores the original partial-index definitions from
-- 0020/0022. Only run this if 0027 needs to be undone — note that doing so
-- re-breaks AccountsBackfillService/TransactionsBackfillService upserts.

DROP INDEX IF EXISTS public.idx_user_accounts_user_local;
CREATE UNIQUE INDEX idx_user_accounts_user_local
  ON public.user_accounts(user_id, local_id)
  WHERE local_id IS NOT NULL;

DROP INDEX IF EXISTS public.idx_user_transactions_user_client_request;
CREATE UNIQUE INDEX idx_user_transactions_user_client_request
  ON public.user_transactions(user_id, client_request_id)
  WHERE client_request_id IS NOT NULL;

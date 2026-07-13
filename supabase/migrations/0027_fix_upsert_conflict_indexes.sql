-- Phase 2 bugfix, found live during QA: PostgREST's upsert (`Prefer:
-- resolution=merge-duplicates` / supabase-flutter's `.upsert(onConflict:)`)
-- generates a plain `ON CONFLICT (columns) DO UPDATE` with no WHERE clause.
-- Postgres only infers a partial unique index as the conflict target when
-- the ON CONFLICT clause's predicate matches the index's predicate exactly
-- — which PostgREST has no way to express. Both idx_user_accounts_user_local
-- (0020) and idx_user_transactions_user_client_request (0022) were created
-- as partial indexes (`WHERE ... IS NOT NULL`), so every upsert against
-- them fails with 42P10 ("no unique or exclusion constraint matching the
-- ON CONFLICT specification").
--
-- Fix: drop the partial predicate. A plain (non-partial) unique index still
-- treats NULL as distinct from NULL (Postgres default), so rows with a NULL
-- local_id/client_request_id remain unconstrained against each other exactly
-- as before — this only removes the ON CONFLICT inference blocker, it does
-- not change what gets rejected as a duplicate.

DROP INDEX IF EXISTS public.idx_user_accounts_user_local;
CREATE UNIQUE INDEX idx_user_accounts_user_local
  ON public.user_accounts(user_id, local_id);

DROP INDEX IF EXISTS public.idx_user_transactions_user_client_request;
CREATE UNIQUE INDEX idx_user_transactions_user_client_request
  ON public.user_transactions(user_id, client_request_id);

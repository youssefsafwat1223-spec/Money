-- ROLLBACK for 0085_concurrency_absent_row_locking.sql (H-10 / H-11 / H-12)
--
-- 0085 replaces THREE existing functions to close absent-row race conditions:
--
--   public.apply_entitlement_mutation(...)         previously in 0083
--   public.qualify_referral_internal(UUID)         previously in 0083
--   public.award_gamification_for_transaction(...) previously in 0074
--
-- All three are CREATE OR REPLACE of functions that already existed. DO NOT
-- `DROP FUNCTION` any of them: entitlement grants, referral qualification and
-- XP awards would all start failing at the call site.
--
-- Restore the previous bodies by re-running their defining migrations, both
-- verified idempotent by double-application on a throwaway database:
--
--   \i supabase/migrations/0074_gamification_atomic_award.sql
--   \i supabase/migrations/0083_referral_rewards.sql
--
-- ORDER MATTERS: 0074 before 0083, matching forward order. 0083 is the later
-- authority for the two referral/entitlement functions, so running it second
-- guarantees the end state matches what a fresh 0001..0083 chain produces.
--
-- WHAT YOU LOSE: the absent-row locking. Under concurrency the prior versions
-- can double-grant an entitlement, double-qualify a referral, or double-award
-- XP for one transaction, because each checked for a row that a competing
-- transaction had not yet inserted. Those are the H-10/H-11/H-12 defects.
--
-- Grants, re-asserted so the end state is explicit:
revoke all on function public.award_gamification_for_transaction(text, uuid)
  from public, anon;
grant execute on function public.award_gamification_for_transaction(text, uuid)
  to authenticated, service_role;

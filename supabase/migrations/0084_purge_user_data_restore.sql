-- ===========================================================================
-- 0084 ── purge_user_data(): restore deletion completeness + de-identify audit
-- ===========================================================================
-- ── DEPLOYMENT STATUS (corrected 2026-09-02) ───────────────────────────────
-- APPLIED IN PRODUCTION. Verified by a read-only owner query against
-- `supabase_migrations.schema_migrations` on the CURRENT production project
-- (`rjwphwsefnuotpbtuycf`): the ledger is continuous through 0092, and 0084,
-- 0085 and 0086 are each explicitly present.
--
-- The "SOURCE-ONLY / NOT APPLIED TO ANY PROJECT" header this replaces was true
-- when written and was never revised. It was written against a DIFFERENT,
-- earlier production project; that project is no longer the deployment target
-- and is now explicitly off-limits. The header therefore described a project
-- this migration was never going to run on, while saying nothing about the one
-- it did run on. That is why it survived four audits.
--
-- Deployment state is tracked in ONE place — docs/project/MIGRATION_LEDGER.md.
-- Do not re-add a per-file deployment claim here: ten copies of one fact is how
-- this contradiction arose.
--
-- Cross-model audit 2026-08-23 — findings C-3 (CRITICAL) and H-14 (HIGH).
-- See docs/FINAL_CROSS_MODEL_AUDIT_RECONCILIATION.md.
--
-- ── C-3: what went wrong ───────────────────────────────────────────────────
-- 0083 re-created `purge_user_data()` and annotated its body
-- "-- Original 0065 body, unchanged", claiming that "the original body is
-- reproduced verbatim so no existing deletion behaviour changes". That claim
-- was FALSE: it reproduced the **0065** body, not the body as it stood after
-- **0072**, and `create or replace` made the regression total. Four deletions
-- 0072 had added were silently dropped:
--
--   ai_request_idempotency               (0071) — PK (owner_key,…), NO auth FK
--   user_engagement_events               (0070) — HAS ON DELETE CASCADE
--   metrics_rate_limits                  (0072) — user_id UUID, NO auth FK
--   gamification_awarded_transactions    (0073) — user_id UUID, NO auth FK
--
-- Only `user_engagement_events` is rescued by its cascade when auth.users is
-- deleted. The other three SURVIVE an account purge, keyed to the deleted
-- user's UUID, while the deletion saga (purge-scheduled-deletions) dequeues the
-- user and reports erasure complete. That is a right-to-erasure failure.
--
-- ── H-14: audit rows kept identifying free text ────────────────────────────
-- The 0083 purge nulled only `target_user_id` / `target_ref`, while
-- `reason` is operator-entered free text (validated for length/control chars
-- ONLY) and is copied into `after_state` for reject/reverse. Operators
-- routinely enter an email, phone number, referral code or UUID there, so the
-- "de-identified" audit retained exactly what it promised to drop
-- (REFERRAL_ADS_ADMIN_SYSTEM.md §226-233). `reason` is NOT NULL with a
-- CHECK(char_length BETWEEN 4 AND 500), so it is REDACTED, not nulled.
--
-- ── Method ─────────────────────────────────────────────────────────────────
-- This body is rebuilt as: 0083's referral/entitlement block (preserved
-- verbatim, with the audit step extended) + the **0072** deletion body (the
-- true predecessor). Deletion order is preserved: satellites keyed by install
-- hash resolve through `capture_devices` BEFORE those device rows are removed.
--
-- Do NOT forward-copy this body again. A future change must edit the current
-- definition, not a historical one — that is the defect this migration repairs.
-- ===========================================================================

create or replace function public.purge_user_data(p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- ── Referral / entitlement domain (0083, preserved) ──────────────────────
  -- (A) as REFEREE: an unqualified attribution disappears with them…
  delete from public.referrals
   where referred_user_id = p_user_id and status in ('attributed', 'rejected');
  -- …a qualified/reversed one keeps only the non-identifying fact, so the
  -- referrer's history and cycle accounting stay intact.
  update public.referrals
     set referred_user_id = null, referred_user_deleted_at = now()
   where referred_user_id = p_user_id;

  -- (B) as REFERRER: the whole user-facing referral domain is removed.
  delete from public.referral_reward_grants   where referrer_user_id = p_user_id;
  delete from public.referral_reward_progress where referrer_user_id = p_user_id;
  delete from public.referrals                where referrer_user_id = p_user_id;
  delete from public.referral_codes           where user_id = p_user_id;

  -- (C) as ENTITLEMENT OWNER.
  delete from public.user_entitlement_state where user_id = p_user_id;
  delete from public.entitlement_events     where user_id = p_user_id;

  -- (D) as AUDIT TARGET (H-14): the audit row survives as a de-identified
  -- FACT. Beyond the formal target columns, the operator-entered free text and
  -- both state snapshots must go — they are unvalidated for content and are the
  -- most likely place an email / phone / code / uuid was typed.
  update public.referral_admin_audit
     set target_user_id = null,
         target_ref     = null,
         reason         = '[redacted: subject account deleted]',
         before_state   = null,
         after_state    = null
   where target_user_id = p_user_id;

  -- ── 0072 body (the true predecessor), restored in full ───────────────────
  -- Children before parents (FK order), satellites before their anchors.
  -- Capture pipeline + AI satellites keyed by install hash / owner_key: resolve
  -- them through the user's devices before those device rows are removed.
  delete from public.capture_rate_limits
  where install_id_hash in (
    select install_id_hash from public.capture_devices where user_id = p_user_id
  );

  -- RESTORED (C-3). AI idempotency ledger (0071): owner_key is
  -- `u:<uid>` or `d:<installHash>`. No auth FK — deleting auth.users cannot
  -- reach these rows, so they must be deleted explicitly and BEFORE
  -- capture_devices (the subquery depends on it).
  delete from public.ai_request_idempotency
  where owner_key = 'u:' || p_user_id::text
     or owner_key in (
       select 'd:' || install_id_hash
       from public.capture_devices where user_id = p_user_id
     );

  delete from public.notification_logs where user_id = p_user_id;

  delete from public.user_bill_payments        where user_id = p_user_id;
  delete from public.user_goal_contributions   where user_id = p_user_id;
  delete from public.user_plan_transaction_links where user_id = p_user_id;
  delete from public.user_subscriptions        where user_id = p_user_id;
  delete from public.user_goals                where user_id = p_user_id;
  delete from public.user_plans                where user_id = p_user_id;
  delete from public.user_budgets              where user_id = p_user_id;
  delete from public.user_transactions         where user_id = p_user_id;
  delete from public.user_cards                where user_id = p_user_id;
  delete from public.user_accounts             where user_id = p_user_id;
  delete from public.user_smart_inbox          where user_id = p_user_id;
  delete from public.user_categories           where user_id = p_user_id;
  delete from public.financial_import_runs     where user_id = p_user_id;
  delete from public.user_settings             where user_id = p_user_id;
  delete from public.user_achievements         where user_id = p_user_id;
  delete from public.user_streaks              where user_id = p_user_id;
  delete from public.user_xp_levels            where user_id = p_user_id;

  -- RESTORED (C-3). `user_engagement_events` does cascade from auth.users, but
  -- purge must not depend on a later step: the saga treats this function as the
  -- complete erasure authority.
  delete from public.user_engagement_events    where user_id = p_user_id;
  -- RESTORED (C-3). No auth FK — these two survive auth deletion entirely.
  delete from public.metrics_rate_limits       where user_id = p_user_id;
  delete from public.gamification_awarded_transactions where user_id = p_user_id;

  delete from public.feature_flag_overrides    where user_id = p_user_id;
  delete from public.sender_bank_mappings      where user_id = p_user_id;
  delete from public.capture_devices           where user_id = p_user_id;
  delete from public.backups                   where user_id = p_user_id;
  delete from public.profiles                  where id      = p_user_id;
end;
$$;

-- Restate the ACLs so a fresh install of this file alone stays locked down.
revoke all on function public.purge_user_data(uuid) from public, anon, authenticated;
grant execute on function public.purge_user_data(uuid) to service_role;

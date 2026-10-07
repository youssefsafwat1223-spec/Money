-- 0113_purge_user_data_claimed_captures.sql — CAP-2 / WP-2 (manifest §4.10, §7).
--
-- purge_user_data() additionally
--   * deletes processed_captures by claimed_user_id, and
--   * bumps the user's sync epoch with epoch_reason = 'purge'
--     (upsert into public.user_sync_state, created by 0103).
--   * forgets the user's uid in capture_install_owner_history (0110, H1) while keeping those
--     installs ineligible for ownerless uploads (fail closed).
--   * clears consent_owner_uid (and its flags) on any install that still names the user
--     although user_id no longer does (a re-registered row), so no identifier survives.
-- Everything else is the CURRENT body (0084), restated in full. Do not forward-copy
-- this body: edit the current definition.
-- Depends on public.user_sync_state existing at CALL time (plpgsql late binding).

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
  -- CAP-2 (0113): relay rows are removed by the user that CLAIMED them, not only
  -- via the user's currently linked devices (a re-linked device, or a device row
  -- owned by someone else now, may still hold this user's captures and their
  -- notification log link). Content is gone with the rows.
  delete from public.processed_captures where claimed_user_id = p_user_id;

  -- H1 (0110): the install owner history forgets this uid but keeps every install it names
  -- INELIGIBLE for ownerless (build-50) uploads (transitioned = true, first_owner_uid = NULL).
  -- Deleting the device rows below also marks them (trigger), but a history row whose device is
  -- held by someone else, or already gone, is reachable only by uid. Not an FK: the history must
  -- outlive both the device row and the auth user.
  perform public.capture_history_forget_owner(p_user_id);

  -- register-device nulls user_id only, so a re-registered install can still name this uid as
  -- its consent owner (with its old flags) after the device row stopped matching user_id. Every
  -- capture gate already refuses such a row (consent_owner_uid <> user_id); erase the uid and the
  -- flags anyway so deletion leaves no identifier behind. Rows still linked to the user are
  -- deleted below.
  update public.capture_devices
     set consent_owner_uid = null,
         cloud_processing_enabled = false,
         ai_consent_granted = false,
         consent_version = 0,
         consent_client_generation = 0,
         last_revoke_generation = null
   where consent_owner_uid = p_user_id
     and user_id is distinct from p_user_id;

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

  -- Epoch bump (WP-2 user_sync_state, 0103): any replica of this user is
  -- invalidated, and epoch_reason='purge' tells clients not to replay recovery.
  insert into public.user_sync_state (user_id, epoch, epoch_reason, updated_at)
  values (p_user_id, gen_random_uuid(), 'purge', now())
  on conflict (user_id) do update
    set epoch = gen_random_uuid(), epoch_reason = 'purge', updated_at = now();
end;
$$;

revoke all on function public.purge_user_data(uuid) from public, anon, authenticated;
grant execute on function public.purge_user_data(uuid) to service_role;

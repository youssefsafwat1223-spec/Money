-- DRAFT — NOT APPLIED — requires Astra review and owner approval
--
-- Rollback for fence.sql (v2). NOT a migration and NOT executed anywhere; unparsed.
--
-- WHAT "EXACT" MEANS HERE (E3 / Q15; the definition is also in DECISIONS.md):
--   catalog IDENTITY   for function owners, function DEFINITIONS (the restored pg_get_functiondef text must equal
--                      the text captured in rollback_function_snapshot.fn_def byte for byte, which also pins every
--                      attribute: security, volatility, search_path / SET, STRICT, PARALLEL, COST, language),
--                      table owners and row-security / FORCE flags, pg_default_acl content;
--   EFFECTIVE EQUIVALENCE for ACLs: the set of (grantee, grantor, privilege, grant option) tuples, with a NULL
--                      ACL read as acldefault(owner). SQL cannot return an instantiated ACL to NULL (a REVOKE or
--                      GRANT leaves an explicit default-equivalent array), so catalog identity of the ACL column is
--                      NOT claimed. Grants whose grantor is not the object owner cannot be reproduced by a role that
--                      is not that grantor; such preexisting metadata makes this script REFUSE rather than guess.
-- SCOPE: replay is restricted to the reviewed mutation set (two legacy erasure functions, the 45 application
--   table ACLs affected by TRUNCATE revokes, the three direct-DML tables and their column ACLs, plus the rows/policies/triggers/functions the fence added or
--   restated). Everything else in the snapshot is only COMPARED; any difference, or any object the snapshot does
--   not know, makes the rollback fail (drift is rejected, not repaired).
-- ORDER: the comparison runs against TEMP copies of the snapshot taken at the start (verified equal to the
--   snapshot at copy time), after the fence schema and role are gone; the account_fence snapshot tables die with
--   the schema, the copies live until commit. Nothing is left behind on failure (one transaction).
-- QUIESCE: rollback takes ACCESS EXCLUSIVE on account_fence.deletion_job first. New acceptances, lease claims and
--   erasures block on it, and an acceptance/erasure already in flight is waited for (lock_timeout bounds the wait,
--   then the rollback fails). Only after the lock is held does it test for open jobs, so no job can appear between
--   the test and the removal of the fence. The lock is held until commit, when the table is gone.
-- Completed receipts and retention clocks are destroyed with the schema; export them first if they must survive.
-- Re-gaining the fence owner role needs the migration role to hold ADMIN on it (PG16+ creator grant, or
-- CREATEROLE on PG15) -- an E8 assumption; fence.sql section 10 asserts nobody else holds it.

begin;
set local search_path = public, pg_catalog;   -- restated originals use unqualified names
set local lock_timeout = '10s';

grant account_fence_owner to current_user;
-- Approved executor must be the recorded migration principal. Membership supplies snapshot owner access;
-- no different principal is silently assumed. If this executor cannot read the snapshots, rollback refuses.
do $executor$
begin
  if current_user is distinct from (select identity from account_fence.rollback_misc_snapshot where kind = 'migration_role') then
    raise exception 'rollback refused: executor differs from recorded migration principal' using errcode = 'QD099';
  end if;
end
$executor$;

lock table account_fence.deletion_job in access exclusive mode;

do $assert$
begin
  if exists (select 1 from account_fence.deletion_job where state <> 'completed') then
    raise exception 'rollback refused: an accepted deletion job is not completed' using errcode = 'QD099';
  end if;
  if exists (select 1 from account_fence.erasure_ctx) then
    raise exception 'rollback refused: an erasure context is live' using errcode = 'QD099';
  end if;
  if not exists (select 1 from account_fence.rollback_function_snapshot) then
    raise exception 'rollback refused: no snapshot' using errcode = 'QD099';
  end if;
end
$assert$;

-- Required surviving comparison evidence: create as the validated rollback/migration principal,
-- NEVER as account_fence_owner. Its membership permits snapshot reads; copies belong to current_user.
create temp table rb_fn   on commit drop as select * from account_fence.rollback_function_snapshot;
create temp table rb_tbl  on commit drop as select * from account_fence.rollback_table_snapshot;
create temp table rb_misc on commit drop as select * from account_fence.rollback_misc_snapshot;
revoke all on pg_temp.rb_fn, pg_temp.rb_tbl, pg_temp.rb_misc from public, anon, authenticated, service_role, account_fence_owner;
do $assert$
begin
  if exists (select 1 from pg_class c where c.oid = any(array['pg_temp.rb_fn'::regclass, 'pg_temp.rb_tbl'::regclass, 'pg_temp.rb_misc'::regclass])
               and pg_get_userbyid(c.relowner) <> current_user) then
    raise exception 'rollback refused: comparison evidence owner mismatch' using errcode = 'QD099';
  end if;
  if exists ((select * from rb_fn except select * from account_fence.rollback_function_snapshot)
             union all (select * from account_fence.rollback_function_snapshot except select * from rb_fn))
     or exists ((select * from rb_tbl except select * from account_fence.rollback_table_snapshot)
                union all (select * from account_fence.rollback_table_snapshot except select * from rb_tbl))
     or exists ((select * from rb_misc except select * from account_fence.rollback_misc_snapshot)
                union all (select * from account_fence.rollback_misc_snapshot except select * from rb_misc)) then
    raise exception 'rollback refused: snapshot copy content differs' using errcode = 'QD099';
  end if;
end
$assert$;

-- 1. Triggers added by the fence (literal).
drop trigger a0_account_fence_guard on public.account_purge_queue;
drop trigger a0_account_fence_guard on public.user_accounts;
drop trigger a0_account_fence_guard on public.user_transactions;
drop trigger a0_account_fence_guard on public.user_budgets;
drop trigger a0_account_fence_guard on public.user_goals;
drop trigger a0_account_fence_guard on public.user_goal_contributions;
drop trigger a0_account_fence_guard on public.user_plans;
drop trigger a0_account_fence_guard on public.user_plan_transaction_links;
drop trigger a0_account_fence_guard on public.user_subscriptions;
drop trigger a0_account_fence_guard on public.user_bill_payments;
drop trigger a0_account_fence_guard on public.user_cards;
drop trigger a0_account_fence_guard on public.user_categories;
drop trigger a0_account_fence_guard on public.user_settings;
drop trigger a0_account_fence_guard on public.user_smart_inbox;
drop trigger a0_account_fence_guard on public.sender_bank_mappings;
drop trigger a0_account_fence_guard on public.user_achievements;
drop trigger a0_account_fence_guard on public.user_streaks;
drop trigger a0_account_fence_guard on public.user_xp_levels;
drop trigger a0_account_fence_guard on public.user_sync_state;
drop trigger a0_account_fence_guard on public.profiles;
drop trigger a0_account_fence_guard on public.backups;
drop trigger a0_account_fence_guard on public.feature_flag_overrides;
drop trigger a0_account_fence_guard on public.financial_import_runs;
drop trigger a0_account_fence_guard on public.user_engagement_events;
drop trigger a0_account_fence_guard on public.metrics_rate_limits;
drop trigger a0_account_fence_guard on public.gamification_awarded_transactions;
drop trigger a0_account_fence_guard on public.notification_logs;
drop trigger a0_account_fence_guard on public.capture_devices;
drop trigger a0_account_fence_guard on public.processed_captures;
drop trigger a0_account_fence_guard on public.capture_install_owner_history;
drop trigger a0_account_fence_guard on public.referrals;
drop trigger a0_account_fence_guard on public.referral_codes;
drop trigger a0_account_fence_guard on public.referral_reward_progress;
drop trigger a0_account_fence_guard on public.referral_reward_grants;
drop trigger a0_account_fence_guard on public.user_entitlement_state;
drop trigger a0_account_fence_guard on public.entitlement_events;
drop trigger a0_account_fence_guard on public.referral_reward_rules;
drop trigger a0_account_fence_guard on public.referral_admin_audit;
drop trigger a0_account_fence_guard on public.announcement_admin_audit;
drop trigger a0_account_fence_guard on public.feature_flag_admin_audit;
drop trigger a0_account_fence_guard on public.admin_users;
drop trigger a0_account_fence_guard on public.notification_retry_queue;
drop trigger a0_account_fence_guard on public.capture_fingerprints;
drop trigger a0_profiles_protect_legacy_schedule on public.profiles;
drop trigger a0_account_fence_legacy_queue on public.account_purge_queue;

-- 2. Policies added by the fence (literal).
drop policy account_fence_discovery on public.notification_logs;
drop policy account_fence_erasure on public.notification_retry_queue;
drop policy account_fence_erasure on public.capture_fingerprints;
drop policy account_fence_profiles_ins on public.profiles;
drop policy account_fence_profiles_upd on public.profiles;
drop policy account_fence_profiles_del on public.profiles;
drop policy account_fence_backups_ins on public.backups;
drop policy account_fence_backups_upd on public.backups;
drop policy account_fence_backups_del on public.backups;
drop policy account_fence_notification_logs_ins on public.notification_logs;
drop policy account_fence_notification_logs_upd on public.notification_logs;
drop policy account_fence_notification_logs_del on public.notification_logs;
drop policy account_fence_feature_flag_overrides_ins on public.feature_flag_overrides;
drop policy account_fence_feature_flag_overrides_upd on public.feature_flag_overrides;
drop policy account_fence_feature_flag_overrides_del on public.feature_flag_overrides;
drop policy account_fence_financial_import_runs_ins on public.financial_import_runs;
drop policy account_fence_financial_import_runs_upd on public.financial_import_runs;
drop policy account_fence_financial_import_runs_del on public.financial_import_runs;
drop policy account_fence_erasure on public.user_accounts;
drop policy account_fence_erasure on public.user_transactions;
drop policy account_fence_erasure on public.user_budgets;
drop policy account_fence_erasure on public.user_goals;
drop policy account_fence_erasure on public.user_goal_contributions;
drop policy account_fence_erasure on public.user_plans;
drop policy account_fence_erasure on public.user_plan_transaction_links;
drop policy account_fence_erasure on public.user_subscriptions;
drop policy account_fence_erasure on public.user_bill_payments;
drop policy account_fence_erasure on public.user_cards;
drop policy account_fence_erasure on public.user_categories;
drop policy account_fence_erasure on public.user_settings;
drop policy account_fence_erasure on public.user_smart_inbox;
drop policy account_fence_erasure on public.sender_bank_mappings;
drop policy account_fence_erasure on public.user_achievements;
drop policy account_fence_erasure on public.user_streaks;
drop policy account_fence_erasure on public.user_xp_levels;
drop policy account_fence_erasure on public.user_sync_state;
drop policy account_fence_erasure on public.profiles;
drop policy account_fence_erasure on public.backups;
drop policy account_fence_erasure on public.feature_flag_overrides;
drop policy account_fence_erasure on public.financial_import_runs;
drop policy account_fence_erasure on public.user_engagement_events;
drop policy account_fence_erasure on public.metrics_rate_limits;
drop policy account_fence_erasure on public.gamification_awarded_transactions;
drop policy account_fence_erasure on public.referrals;
drop policy account_fence_erasure on public.referral_reward_grants;
drop policy account_fence_erasure on public.referral_reward_progress;
drop policy account_fence_erasure on public.referral_codes;
drop policy account_fence_erasure on public.user_entitlement_state;
drop policy account_fence_erasure on public.entitlement_events;
drop policy account_fence_erasure on public.referral_admin_audit;
drop policy account_fence_erasure on public.referral_reward_rules;
drop policy account_fence_erasure on public.announcement_admin_audit;
drop policy account_fence_erasure on public.feature_flag_admin_audit;
drop policy account_fence_erasure on public.processed_captures;
drop policy account_fence_erasure on public.capture_install_owner_history;
drop policy account_fence_erasure on public.capture_devices;
drop policy account_fence_erasure on public.capture_rate_limits;
drop policy account_fence_erasure on public.ai_request_idempotency;
drop policy account_fence_erasure on public.notification_logs;
drop policy account_fence_erasure on public.admin_users;
drop policy account_fence_discovery on public.capture_devices;
drop policy account_fence_discovery on public.processed_captures;
drop policy account_fence_discovery on public.capture_install_owner_history;
drop policy account_fence_discovery on public.referrals;
drop policy account_fence_discovery on public.referral_codes;
drop policy account_fence_discovery on public.admin_users;
drop policy account_fence_discovery on public.notification_retry_queue;
drop policy account_fence_discovery on public.capture_fingerprints;

-- 3. Original bodies, literal (CREATE OR REPLACE preserves OID; ACL is replayed in 4).
-- >>> GENERATED:BEGIN rpc_originals
-- Generated by gen_rpc_bodies.py: verbatim original statements (CREATE OR REPLACE keeps OID and ACL).
-- 0025_set_default_account_rpc.sql:35-67
create or replace function public.set_default_account(p_account_id uuid)
returns public.user_accounts
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_result public.user_accounts;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.user_accounts
    where id = p_account_id and user_id = auth.uid() and deleted_at is null
  ) then
    raise exception 'account % does not belong to user %', p_account_id, auth.uid()
      using errcode = 'P0001';
  end if;

  update public.user_accounts
  set is_default = false
  where user_id = auth.uid() and is_default = true and id <> p_account_id;

  update public.user_accounts
  set is_default = true
  where id = p_account_id and user_id = auth.uid()
  returning * into v_result;

  return v_result;
end;
$$;

-- 0078_goal_contribution_exact_saved_amount.sql:36-80
create or replace function public.add_goal_contribution(
  p_goal_id uuid,
  p_client_request_id text,
  p_local_id text,
  p_amount numeric,
  p_created_at timestamptz,
  p_note text default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  contribution_row public.user_goal_contributions%rowtype;
  goal_row public.user_goals%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_amount <= 0 then raise exception 'amount must be positive' using errcode = '22023'; end if;
  select * into goal_row from public.user_goals
    where id = p_goal_id and user_id = auth.uid() and deleted_at is null for update;
  if goal_row.id is null then raise exception 'goal not found' using errcode = 'P0002'; end if;

  insert into public.user_goal_contributions(
    user_id, goal_id, local_id, client_request_id, amount, note, created_at
  ) values (
    auth.uid(), p_goal_id, p_local_id, p_client_request_id, p_amount, p_note,
    coalesce(p_created_at, now())
  ) on conflict (user_id, client_request_id) do nothing returning * into contribution_row;

  if contribution_row.id is null then
    select * into contribution_row from public.user_goal_contributions
      where user_id = auth.uid() and client_request_id = p_client_request_id;
  else
    update public.user_goals set saved_amount = saved_amount + p_amount
      where id = p_goal_id and user_id = auth.uid() returning * into goal_row;
  end if;
  select * into goal_row from public.user_goals
    where id = p_goal_id and user_id = auth.uid();

  -- ADDITIVE exact-money response: preserve every existing goal field (including the
  -- legacy `saved_amount` JSON number carried by to_jsonb) and ADD `saved_amount_text`
  -- = exact NUMERIC text. `||` merges the new key without dropping any existing one.
  return jsonb_build_object(
    'contribution', to_jsonb(contribution_row),
    'goal', to_jsonb(goal_row)
              || jsonb_build_object('saved_amount_text', goal_row.saved_amount::text)
  );
end;
$$;

-- 0031_financial_feature_children.sql:220-265
create or replace function public.record_bill_payment(
  p_subscription_id uuid,
  p_transaction_id uuid,
  p_client_request_id text,
  p_local_id text,
  p_amount numeric,
  p_currency text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_paid_at timestamptz,
  p_installment_index integer default null,
  p_note text default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  payment_row public.user_bill_payments%rowtype;
  subscription_row public.user_subscriptions%rowtype;
  inserted boolean := false;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  select * into subscription_row from public.user_subscriptions
    where id = p_subscription_id and user_id = auth.uid() and deleted_at is null for update;
  if subscription_row.id is null then raise exception 'subscription not found' using errcode = 'P0002'; end if;

  insert into public.user_bill_payments(
    user_id, subscription_id, transaction_id, local_id, client_request_id,
    amount, currency, period_start, period_end, paid_at, installment_index, note
  ) values (
    auth.uid(), p_subscription_id, p_transaction_id, p_local_id, p_client_request_id,
    p_amount, upper(p_currency), p_period_start, p_period_end, p_paid_at,
    p_installment_index, p_note
  ) on conflict (user_id, client_request_id) do nothing returning * into payment_row;
  inserted := payment_row.id is not null;
  if not inserted then
    select * into payment_row from public.user_bill_payments
      where user_id = auth.uid() and client_request_id = p_client_request_id;
  elsif subscription_row.type = 'installment' then
    update public.user_subscriptions set paid_count = greatest(
      coalesce(paid_count, 0),
      coalesce(p_installment_index, coalesce(paid_count, 0) + 1)
    ) where id = p_subscription_id and user_id = auth.uid() returning * into subscription_row;
  end if;
  select * into subscription_row from public.user_subscriptions
    where id = p_subscription_id and user_id = auth.uid();
  return jsonb_build_object('payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
end;
$$;

-- 0108_delete_bill_payment_idempotent.sql:22-52
CREATE OR REPLACE FUNCTION public.delete_bill_payment(p_payment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
declare
  payment_row public.user_bill_payments%rowtype;
  subscription_row public.user_subscriptions%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  update public.user_bill_payments set deleted_at = now()
    where id = p_payment_id and user_id = auth.uid() and deleted_at is null
    returning * into payment_row;
  if payment_row.id is null then
    select * into payment_row from public.user_bill_payments
      where id = p_payment_id and user_id = auth.uid();
    if payment_row.id is null then
      return jsonb_build_object('outcome', 'absent', 'payment', null, 'subscription', null);
    end if;
    select * into subscription_row from public.user_subscriptions
      where id = payment_row.subscription_id and user_id = auth.uid();
    return jsonb_build_object('outcome', 'already_deleted',
      'payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
  end if;
  update public.user_subscriptions set paid_count = coalesce((
    select max(installment_index) from public.user_bill_payments
    where user_id = auth.uid() and subscription_id = payment_row.subscription_id
      and deleted_at is null
  ), 0) where id = payment_row.subscription_id and user_id = auth.uid()
    returning * into subscription_row;
  return jsonb_build_object('outcome', 'deleted',
    'payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
end;
$$;

-- 0037_atomic_account_deletion.sql:4-68
create or replace function public.delete_user_account_safely(p_account_id uuid)
returns public.user_accounts
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_target public.user_accounts;
  v_replacement_id uuid;
  v_active_count integer;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  -- Serialize create/delete/default changes for this user's active accounts.
  perform 1
  from public.user_accounts
  where user_id = v_user_id and deleted_at is null
  order by id
  for update;

  select * into v_target
  from public.user_accounts
  where id = p_account_id
    and user_id = v_user_id
    and deleted_at is null;

  if not found then
    raise no_data_found;
  end if;

  select count(*) into v_active_count
  from public.user_accounts
  where user_id = v_user_id and deleted_at is null;

  if v_active_count <= 1 then
    raise exception 'last_account' using errcode = '23514';
  end if;

  if v_target.is_default then
    select id into v_replacement_id
    from public.user_accounts
    where user_id = v_user_id
      and deleted_at is null
      and id <> p_account_id
    order by sort_order, created_at, id
    limit 1;
  end if;

  update public.user_accounts
  set deleted_at = now(), is_default = false
  where id = p_account_id and user_id = v_user_id
  returning * into v_target;

  if v_replacement_id is not null then
    update public.user_accounts
    set is_default = true
    where id = v_replacement_id and user_id = v_user_id;
  end if;

  return v_target;
end;
$$;

-- 0041_fix_bill_payment_rpc_paid_count_overwrite.sql:20-122
create or replace function public.create_subscription_and_record_payment(
  p_subscription_local_id text,
  p_payment_client_request_id text,
  p_name text,
  p_amount numeric,
  p_currency text,
  p_type text,
  p_frequency text,
  p_next_due_date timestamptz,
  p_created_at timestamptz,
  p_server_account_id uuid default null,
  p_merchant_id text default null,
  p_reminder_on boolean default true,
  p_is_confirmed boolean default true,
  p_custom_interval_days integer default null,
  p_note text default null,
  p_status text default 'active',
  p_total_installments integer default null,
  p_paid_count integer default null,
  p_manual_paid_amount numeric default null,
  p_total_purchase_amount numeric default null,
  p_lender_name text default null,
  p_interest_rate numeric default null,
  p_payment_amount numeric default null,
  p_payment_period_start timestamptz default null,
  p_payment_period_end timestamptz default null,
  p_payment_paid_at timestamptz default null,
  p_payment_installment_index integer default null,
  p_payment_note text default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  subscription_row public.user_subscriptions%rowtype;
  payment_row public.user_bill_payments%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_payment_amount is null or p_payment_period_start is null or p_payment_period_end is null or p_payment_paid_at is null then
    raise exception 'missing payment fields' using errcode = '22023';
  end if;

  insert into public.user_subscriptions(
    user_id, local_id, server_account_id, merchant_id, name, amount, currency,
    type, frequency, next_due_date, created_at, reminder_on, is_confirmed,
    custom_interval_days, note, status, total_installments, paid_count,
    manual_paid_amount, total_purchase_amount, lender_name, interest_rate,
    metadata
  ) values (
    auth.uid(), p_subscription_local_id, p_server_account_id, p_merchant_id,
    p_name, p_amount, upper(p_currency), p_type, p_frequency, p_next_due_date,
    p_created_at, p_reminder_on, p_is_confirmed, p_custom_interval_days, p_note,
    p_status, p_total_installments, p_paid_count, p_manual_paid_amount,
    p_total_purchase_amount, p_lender_name, p_interest_rate, '{}'::jsonb
  ) on conflict (user_id, local_id) where local_id is not null do update set
    server_account_id = excluded.server_account_id,
    merchant_id = excluded.merchant_id,
    name = excluded.name,
    amount = excluded.amount,
    currency = excluded.currency,
    type = excluded.type,
    frequency = excluded.frequency,
    next_due_date = excluded.next_due_date,
    reminder_on = excluded.reminder_on,
    is_confirmed = excluded.is_confirmed,
    custom_interval_days = excluded.custom_interval_days,
    note = excluded.note,
    status = excluded.status,
    total_installments = excluded.total_installments,
    manual_paid_amount = excluded.manual_paid_amount,
    total_purchase_amount = excluded.total_purchase_amount,
    lender_name = excluded.lender_name,
    interest_rate = excluded.interest_rate
  returning * into subscription_row;

  select * into subscription_row from public.user_subscriptions
    where user_id = auth.uid() and local_id = p_subscription_local_id and deleted_at is null
    for update;
  if subscription_row.id is null then raise exception 'subscription not found' using errcode = 'P0002'; end if;

  insert into public.user_bill_payments(
    user_id, subscription_id, transaction_id, local_id, client_request_id,
    amount, currency, period_start, period_end, paid_at, installment_index, note
  ) values (
    auth.uid(), subscription_row.id, null, p_payment_client_request_id,
    p_payment_client_request_id, p_payment_amount, upper(p_currency),
    p_payment_period_start, p_payment_period_end, p_payment_paid_at,
    p_payment_installment_index, p_payment_note
  ) on conflict (user_id, client_request_id) do nothing returning * into payment_row;

  if payment_row.id is null then
    select * into payment_row from public.user_bill_payments
      where user_id = auth.uid() and client_request_id = p_payment_client_request_id;
  elsif subscription_row.type = 'installment' then
    update public.user_subscriptions set paid_count = greatest(
      coalesce(paid_count, 0),
      coalesce(p_payment_installment_index, coalesce(paid_count, 0) + 1)
    ) where id = subscription_row.id and user_id = auth.uid()
    returning * into subscription_row;
  end if;

  select * into subscription_row from public.user_subscriptions
    where id = subscription_row.id and user_id = auth.uid();
  return jsonb_build_object('payment', to_jsonb(payment_row), 'subscription', to_jsonb(subscription_row));
end;
$$;

-- 0044_financial_data_portability.sql:82-100
create or replace function public.delete_user_category_safely(p_category_id uuid)
returns public.user_categories
language plpgsql security invoker set search_path = public as $$
declare
  uid uuid := auth.uid();
  result public.user_categories%rowtype;
begin
  if uid is null then raise exception 'authentication required' using errcode='42501'; end if;
  update public.user_transactions set user_category_id = null, category_id = 'other'
    where user_id = uid and user_category_id = p_category_id and deleted_at is null;
  update public.user_budgets set user_category_id = null, category_id = 'other'
    where user_id = uid and user_category_id = p_category_id and deleted_at is null;
  update public.user_categories set deleted_at = now()
    where id = p_category_id and user_id = uid and deleted_at is null
    returning * into result;
  if result.id is null then raise exception 'category not found' using errcode='P0002'; end if;
  return result;
end;
$$;

-- 0051_fix_import_rpc_budget_schema.sql:1-249
create or replace function public.import_financial_package(
  p_import_id text,
  p_mode text,
  p_package jsonb
) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  uid uuid := auth.uid();
  run_row public.financial_import_runs%rowtype;
  r jsonb;
  affected integer;
  imported_count integer := 0;
  duplicate_count integer := 0;
  account_server_id uuid;
  category_server_id uuid;
  transaction_server_id uuid;
  subscription_server_id uuid;
  goal_server_id uuid;
  plan_server_id uuid;
  account_ids text[];
  v_result jsonb;
begin
  if uid is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_import_id is null or btrim(p_import_id) = '' then
    raise exception 'import id required' using errcode='22023';
  end if;
  if p_mode not in ('merge','replace') then
    raise exception 'invalid import mode' using errcode='22023';
  end if;

  insert into public.financial_import_runs(user_id, import_id, mode)
  values(uid, p_import_id, p_mode)
  on conflict(user_id, import_id) do nothing;
  
  select * into run_row from public.financial_import_runs
    where user_id=uid and import_id=p_import_id for update;
    
  if run_row.mode <> p_mode then
    update public.financial_import_runs set mode = p_mode, status = 'processing' where id = run_row.id;
    run_row.mode := p_mode;
    run_row.status := 'processing';
  end if;
  
  if run_row.status = 'completed' then return run_row.result; end if;

  if p_mode = 'replace' then
    update public.user_plan_transaction_links set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_bill_payments set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_goal_contributions set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_budgets set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_subscriptions set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_goals set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_plans set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_transactions set deleted_at=now(), status='ignored' where user_id=uid and deleted_at is null;
    update public.user_categories set deleted_at=now() where user_id=uid and deleted_at is null;
    update public.user_accounts set deleted_at=now(), is_default=false where user_id=uid and deleted_at is null;
  end if;

  for r in select value from jsonb_array_elements(coalesce(p_package->'accounts','[]'::jsonb)) loop
    insert into public.user_accounts(user_id,local_id,name,currency,type,initial_balance,
      current_balance,is_default,sort_order,created_at,updated_at,deleted_at)
    values(uid,r->>'record_id',r->>'name',upper(r->>'currency'),r->>'type',
      nullif(r->>'initial_balance','')::numeric,nullif(r->>'current_balance','')::numeric,
      (r->>'is_default')::boolean,coalesce(nullif(r->>'sort_order','')::int,0),
      coalesce(nullif(r->>'created_at','')::timestamptz,now()),
      coalesce(nullif(r->>'updated_at','')::timestamptz,now()),null)
    on conflict(user_id,local_id) where local_id is not null do update set
      name=excluded.name,currency=excluded.currency,type=excluded.type,
      initial_balance=excluded.initial_balance,current_balance=excluded.current_balance,
      is_default=excluded.is_default,sort_order=excluded.sort_order,deleted_at=null;
    get diagnostics affected = row_count; imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'custom_categories','[]'::jsonb)) loop
    update public.user_categories set name_ar=r->>'name_ar',
      icon=coalesce(nullif(r->>'icon',''),'category'),
      color=coalesce(nullif(r->>'color',''),'#64748B'),
      is_income=coalesce(nullif(r->>'is_income','')::boolean,false),
      sort_order=coalesce(nullif(r->>'sort_order','')::int,0),deleted_at=null
    where user_id=uid and (local_id=r->>'record_id' or key=r->>'key');
    get diagnostics affected = row_count;
    if affected = 0 then
      insert into public.user_categories(user_id,local_id,key,name_ar,icon,color,is_income,sort_order,deleted_at)
      values(uid,r->>'record_id',r->>'key',r->>'name_ar',coalesce(nullif(r->>'icon',''),'category'),
        coalesce(nullif(r->>'color',''),'#64748B'),coalesce(nullif(r->>'is_income','')::boolean,false),
        coalesce(nullif(r->>'sort_order','')::int,0),null);
      affected := 1;
    end if;
    imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'transactions','[]'::jsonb)) loop
    select id into account_server_id from public.user_accounts
      where user_id=uid and local_id=nullif(r->>'account_record_id','') limit 1;
    select id into category_server_id from public.user_categories
      where user_id=uid and (local_id=nullif(r->>'category_record_id','') or key=nullif(r->>'category_key','')) limit 1;
    insert into public.user_transactions(user_id,client_request_id,local_account_id,
      server_account_id,amount,currency,direction,transaction_type,merchant,description,
      category_id,user_category_id,occurred_at,source,confidence,metadata,status,
      foreign_amount,foreign_currency,comparison_timestamp,comparison_timestamp_source,deleted_at)
    values(uid,'portable:'||(r->>'record_id'),nullif(r->>'account_record_id',''),
      account_server_id,(r->>'amount')::numeric,upper(r->>'currency'),
      r->>'direction', r->>'transaction_type',nullif(r->>'merchant',''),r->>'note',null,category_server_id,
      (r->>'occurred_at')::timestamptz, r->>'source', 1,
      '{}'::jsonb, r->>'status',
      nullif(r->>'foreign_amount','')::numeric,nullif(r->>'foreign_currency',''),
      coalesce(nullif(r->>'comparison_timestamp','')::timestamptz, (r->>'occurred_at')::timestamptz),
      r->>'comparison_timestamp_source', null)
    on conflict(user_id,client_request_id) do update set
      server_account_id=excluded.server_account_id,amount=excluded.amount,currency=excluded.currency,
      direction=excluded.direction,transaction_type=excluded.transaction_type,merchant=excluded.merchant,
      description=excluded.description,user_category_id=excluded.user_category_id,
      occurred_at=excluded.occurred_at,source=excluded.source,status=excluded.status,
      foreign_amount=excluded.foreign_amount,foreign_currency=excluded.foreign_currency,
      comparison_timestamp=excluded.comparison_timestamp,
      comparison_timestamp_source=excluded.comparison_timestamp_source,deleted_at=null;
    get diagnostics affected = row_count; imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'budgets','[]'::jsonb)) loop
    select id into account_server_id from public.user_accounts where user_id=uid and local_id=nullif(r->>'account_record_id','') limit 1;
    select id into category_server_id from public.user_categories where user_id=uid and (local_id=nullif(r->>'category_record_id','') or key=nullif(r->>'category_key','')) limit 1;
    insert into public.user_budgets(user_id,local_id,local_account_id,server_account_id,
      category_id,amount,period,start_date,is_active,alert_80_sent,
      alert_100_sent,show_on_header,deleted_at)
    values(uid,r->>'record_id',nullif(r->>'account_record_id',''),account_server_id,
      coalesce(case when category_server_id is null then nullif(r->>'category_key','') end,'other'),
      (r->>'amount')::numeric,r->>'period',(r->>'start_date')::timestamptz,
      coalesce(nullif(r->>'is_active','')::boolean,true),coalesce(nullif(r->>'alert_80_sent','')::boolean,false),
      coalesce(nullif(r->>'alert_100_sent','')::boolean,false),coalesce(nullif(r->>'show_on_header','')::boolean,false),null)
    on conflict(user_id,local_id) where local_id is not null do update set
      server_account_id=excluded.server_account_id,category_id=excluded.category_id,
      amount=excluded.amount,period=excluded.period,start_date=excluded.start_date,
      is_active=excluded.is_active,alert_80_sent=excluded.alert_80_sent,
      alert_100_sent=excluded.alert_100_sent,show_on_header=excluded.show_on_header,deleted_at=null;
    get diagnostics affected = row_count; imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'subscriptions','[]'::jsonb)) loop
    select id into account_server_id from public.user_accounts where user_id=uid and local_id=nullif(r->>'account_record_id','') limit 1;
    insert into public.user_subscriptions(user_id,local_id,local_account_id,server_account_id,
      merchant_id,name,amount,currency,type,frequency,next_due_date,reminder_on,is_confirmed,
      custom_interval_days,note,status,total_installments,paid_count,manual_paid_amount,
      total_purchase_amount,lender_name,interest_rate,created_at,deleted_at)
    values(uid,r->>'record_id',nullif(r->>'account_record_id',''),account_server_id,
      nullif(r->>'merchant',''),r->>'name',(r->>'amount')::numeric,upper(r->>'currency'),
      r->>'type',r->>'frequency',
      coalesce(nullif(r->>'next_due_date','')::timestamptz,now()),
      coalesce(nullif(r->>'reminder_on','')::boolean,true),coalesce(nullif(r->>'is_confirmed','')::boolean,false),
      nullif(r->>'custom_interval_days','')::int,nullif(r->>'note',''),r->>'status',
      nullif(r->>'total_installments','')::int,nullif(r->>'paid_count','')::int,
      nullif(r->>'manual_paid_amount','')::numeric,nullif(r->>'total_purchase_amount','')::numeric,
      nullif(r->>'lender_name',''),nullif(r->>'interest_rate','')::numeric,
      coalesce(nullif(r->>'created_at','')::timestamptz,now()),null)
    on conflict(user_id,local_id) where local_id is not null do update set
      server_account_id=excluded.server_account_id,name=excluded.name,amount=excluded.amount,
      currency=excluded.currency,type=excluded.type,frequency=excluded.frequency,
      next_due_date=excluded.next_due_date,reminder_on=excluded.reminder_on,
      is_confirmed=excluded.is_confirmed,status=excluded.status,deleted_at=null;
    get diagnostics affected = row_count; imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'goals','[]'::jsonb)) loop
    select id into account_server_id from public.user_accounts where user_id=uid and local_id=nullif(r->>'account_record_id','') limit 1;
    insert into public.user_goals(user_id,local_id,local_account_id,server_account_id,name,
      target_amount,saved_amount,deadline,vault_skin,status,auto_save_amount,
      auto_save_period,auto_save_last_run,created_at,deleted_at)
    values(uid,r->>'record_id',nullif(r->>'account_record_id',''),account_server_id,r->>'name',
      (r->>'target_amount')::numeric,coalesce(nullif(r->>'saved_amount','')::numeric,0),
      nullif(r->>'deadline','')::timestamptz,coalesce(nullif(r->>'vault_skin',''),'default'),
      r->>'status',nullif(r->>'auto_save_amount','')::numeric,
      nullif(r->>'auto_save_period',''),nullif(r->>'auto_save_last_run','')::timestamptz,
      coalesce(nullif(r->>'created_at','')::timestamptz,now()),null)
    on conflict(user_id,local_id) where local_id is not null do update set
      server_account_id=excluded.server_account_id,name=excluded.name,target_amount=excluded.target_amount,
      saved_amount=excluded.saved_amount,deadline=excluded.deadline,vault_skin=excluded.vault_skin,
      status=excluded.status,deleted_at=null;
    get diagnostics affected = row_count; imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'plans','[]'::jsonb)) loop
    account_ids := case when coalesce(r->>'account_record_ids','')='' then '{}'::text[]
      else string_to_array(r->>'account_record_ids',',') end;
    insert into public.user_plans(user_id,local_id,name,budget_amount,currency,start_date,end_date,
      local_account_ids,server_account_ids,card_last4s,status,icon,created_at,deleted_at)
    values(uid,r->>'record_id',r->>'name',(r->>'budget_amount')::numeric,upper(r->>'currency'),
      (r->>'start_date')::timestamptz,(r->>'end_date')::timestamptz,account_ids,
      array(select id from public.user_accounts where user_id=uid and local_id=any(account_ids)),
      case when coalesce(r->>'card_last4s','')='' then '{}'::text[] else string_to_array(r->>'card_last4s',',') end,
      r->>'status',nullif(r->>'icon',''),
      coalesce(nullif(r->>'created_at','')::timestamptz,now()),null)
    on conflict(user_id,local_id) where local_id is not null do update set
      name=excluded.name,budget_amount=excluded.budget_amount,currency=excluded.currency,
      start_date=excluded.start_date,end_date=excluded.end_date,
      local_account_ids=excluded.local_account_ids,server_account_ids=excluded.server_account_ids,
      card_last4s=excluded.card_last4s,status=excluded.status,icon=excluded.icon,deleted_at=null;
    get diagnostics affected = row_count; imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'goal_contributions','[]'::jsonb)) loop
    select id into goal_server_id from public.user_goals where user_id=uid and local_id=r->>'goal_record_id' limit 1;
    if goal_server_id is not null then
      insert into public.user_goal_contributions(user_id,goal_id,local_id,client_request_id,amount,note,created_at,deleted_at)
      values(uid,goal_server_id,r->>'record_id','portable:'||(r->>'record_id'),
        (r->>'amount')::numeric,nullif(r->>'note',''),(r->>'created_at')::timestamptz,null)
      on conflict(user_id,client_request_id) do update set amount=excluded.amount,note=excluded.note,deleted_at=null;
      get diagnostics affected = row_count; imported_count := imported_count + affected;
    end if;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'bill_payments','[]'::jsonb)) loop
    select id into subscription_server_id from public.user_subscriptions where user_id=uid and local_id=r->>'subscription_record_id' limit 1;
    select id into transaction_server_id from public.user_transactions where user_id=uid
      and client_request_id='portable:'||(r->>'transaction_record_id') limit 1;
    if subscription_server_id is not null then
      insert into public.user_bill_payments(user_id,subscription_id,transaction_id,local_id,
        client_request_id,amount,currency,period_start,period_end,paid_at,installment_index,note,deleted_at)
      values(uid,subscription_server_id,transaction_server_id,r->>'record_id',
        'portable:'||(r->>'record_id'),(r->>'amount')::numeric,upper(r->>'currency'),
        (r->>'period_start')::timestamptz,(r->>'period_end')::timestamptz,
        (r->>'paid_at')::timestamptz,nullif(r->>'installment_index','')::int,nullif(r->>'note',''),null)
      on conflict(user_id,client_request_id) do update set amount=excluded.amount,
        transaction_id=excluded.transaction_id,note=excluded.note,deleted_at=null;
      get diagnostics affected = row_count; imported_count := imported_count + affected;
    end if;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'plan_transaction_links','[]'::jsonb)) loop
    select id into plan_server_id from public.user_plans where user_id=uid and local_id=r->>'plan_record_id' limit 1;
    select id into transaction_server_id from public.user_transactions where user_id=uid
      and client_request_id='portable:'||(r->>'transaction_record_id') limit 1;
    if plan_server_id is not null and transaction_server_id is not null then
      insert into public.user_plan_transaction_links(user_id,plan_id,transaction_id,client_request_id,created_at,deleted_at)
      values(uid,plan_server_id,transaction_server_id,
        'portable:'||(r->>'plan_record_id')||':'||(r->>'transaction_record_id'),
        coalesce(nullif(r->>'created_at','')::timestamptz,now()),null)
      on conflict(user_id,client_request_id) do update set deleted_at=null;
      get diagnostics affected = row_count; imported_count := imported_count + affected;
    end if;
  end loop;

  v_result := jsonb_build_object('imported',imported_count,'duplicates',duplicate_count,'skipped',0);
  update public.financial_import_runs set status='completed',result=v_result,completed_at=now()
    where id=run_row.id;
  return v_result;
exception when others then
  raise;
end;
$$;

-- 0043_profile_onboarding_completion.sql:21-44
create or replace function public.mark_onboarding_completed()
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  completed_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  update public.profiles
  set onboarding_completed_at = coalesce(onboarding_completed_at, now())
  where id = auth.uid()
  returning onboarding_completed_at into completed_at;

  if completed_at is null then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;
  return completed_at;
end;
$$;

-- 0070_engagement_events.sql:57-145
CREATE OR REPLACE FUNCTION public.record_engagement_event(
  p_event_id     UUID,
  p_event_type   TEXT,
  p_occurred_at  TIMESTAMPTZ,
  p_business_key TEXT DEFAULT NULL,
  p_event_version INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_award   INTEGER;
  v_xp      INTEGER;
  v_level   INTEGER;
  v_streak  INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '28000';
  END IF;
  -- Reject unsupported/future event schema versions (fail safe, no award).
  IF p_event_version IS NULL OR p_event_version <> 1 THEN
    RAISE EXCEPTION 'unsupported event version %', p_event_version
      USING errcode = '22023';
  END IF;

  -- Server-side award rule. An unknown/future event type is rejected — never
  -- silently awarded, and the client can never supply the amount.
  v_award := CASE p_event_type
    WHEN 'transaction_confirmed' THEN 10
    WHEN 'goal_contribution'     THEN 15
    WHEN 'budget_action'         THEN 5
    WHEN 'bill_payment'          THEN 5
    WHEN 'streak_activity'       THEN 2
    ELSE NULL
  END;
  IF v_award IS NULL THEN
    RAISE EXCEPTION 'unknown event type %', p_event_type
      USING errcode = '22023';
  END IF;

  -- Idempotent record. ON CONFLICT DO NOTHING on (user_id, event_id); a
  -- business-key collision raises unique_violation which we treat as a
  -- duplicate no-op below.
  BEGIN
    INSERT INTO public.user_engagement_events(
      user_id, event_id, event_type, occurred_at, business_key,
      event_version, awarded_xp
    ) VALUES (
      v_user_id, p_event_id, p_event_type, p_occurred_at, p_business_key,
      p_event_version, v_award
    )
    ON CONFLICT (user_id, event_id) DO NOTHING;

    IF NOT FOUND THEN
      -- Duplicate event_id → already awarded. Return the current aggregate.
      v_award := 0;
    END IF;
  EXCEPTION WHEN unique_violation THEN
    -- Duplicate business_key → already awarded for this business action.
    v_award := 0;
  END;

  -- Atomic read-modify-write of the XP aggregate (row-locked on conflict, so
  -- concurrent events cannot lose an increment). Only when a new event awarded.
  IF v_award > 0 THEN
    INSERT INTO public.user_xp_levels(user_id, xp, level, updated_at)
    VALUES (v_user_id, v_award, 1 + (v_award / 100), now())
    ON CONFLICT (user_id) DO UPDATE SET
      xp = public.user_xp_levels.xp + EXCLUDED.xp,
      level = 1 + ((public.user_xp_levels.xp + EXCLUDED.xp) / 100),
      updated_at = now();
  END IF;

  SELECT xp, level INTO v_xp, v_level
    FROM public.user_xp_levels WHERE user_id = v_user_id;
  SELECT current_streak INTO v_streak
    FROM public.user_streaks WHERE user_id = v_user_id;

  RETURN jsonb_build_object(
    'xp', COALESCE(v_xp, 0),
    'level', COALESCE(v_level, 1),
    'current_streak', COALESCE(v_streak, 0),
    'awarded', v_award
  );
END;
$$;

-- 0072_backend_security_hardening.sql:76-110
CREATE OR REPLACE FUNCTION public.record_metric(
  p_metric_key TEXT,
  p_dimension TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_count INTEGER;
  -- The complete allowlist of event keys the client is permitted to record.
  c_allowed CONSTANT TEXT[] := ARRAY['app_open'];
  c_daily_limit CONSTANT INTEGER := 1000;
BEGIN
  -- Authenticated only; never trust a caller-supplied identity.
  IF v_uid IS NULL THEN RETURN; END IF;
  -- Event-name allowlist + bounded lengths; unknown/oversized → silently dropped
  -- (metrics are best-effort; never raise into the caller).
  IF NOT (p_metric_key = ANY (c_allowed)) THEN RETURN; END IF;
  IF length(p_metric_key) > 64 THEN RETURN; END IF;
  IF p_dimension IS NOT NULL AND length(p_dimension) > 128 THEN RETURN; END IF;

  -- Per-user daily quota (atomic).
  INSERT INTO metrics_rate_limits AS r (user_id, day, call_count)
  VALUES (v_uid, CURRENT_DATE, 1)
  ON CONFLICT (user_id, day) DO UPDATE SET call_count = r.call_count + 1
  RETURNING call_count INTO v_count;
  IF v_count > c_daily_limit THEN RETURN; END IF;

  INSERT INTO metrics (metric_key, dimension)
  VALUES (p_metric_key, p_dimension);
END;
$$;

-- 0076_backup_generation_cas.sql:25-119
CREATE OR REPLACE FUNCTION public.commit_backup_generation(
  p_generation_id               TEXT,
  p_object_path                 TEXT,
  p_blob_version                INTEGER,
  p_size_bytes                  BIGINT,
  p_blob_sha256                 TEXT,
  p_operation_id                TEXT,
  p_expected_prev_generation_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner    UUID := auth.uid();
  v_existing public.backups%ROWTYPE;
  v_found    BOOLEAN := FALSE;
  v_size     BIGINT;
BEGIN
  -- 1. Owner derived from verified auth; never caller-supplied.
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'authentication_required');
  END IF;
  -- 2. The object path must live under the caller's own <uid>/ folder (matches
  --    the storage-object RLS); a caller can never commit another user's object.
  IF split_part(p_object_path, '/', 1) <> v_owner::text THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ownership_mismatch');
  END IF;
  -- 3. Server-authoritative object existence + size (owner-scoped storage row).
  SELECT (o.metadata->>'size')::bigint INTO v_size
    FROM storage.objects o
    WHERE o.bucket_id = 'backups' AND o.name = p_object_path;
  IF v_size IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'remote_object_missing');
  END IF;
  IF v_size <> p_size_bytes THEN
    RETURN jsonb_build_object('ok', false, 'error', 'upload_verification_failed');
  END IF;

  -- 4. Lock the current pointer row for this owner (serialise concurrent commits).
  SELECT * INTO v_existing FROM backups WHERE user_id = v_owner FOR UPDATE;
  v_found := FOUND;

  -- 5. Idempotent replay of the WINNING operation (a lost response).
  IF v_found AND v_existing.generation_id = p_generation_id THEN
    IF v_existing.operation_id = p_operation_id THEN
      RETURN jsonb_build_object('ok', true, 'replay', true,
                                'generation_id', v_existing.generation_id);
    END IF;
    -- Same generation id from a DIFFERENT operation → conflict.
    RETURN jsonb_build_object('ok', false, 'error', 'operation_conflict');
  END IF;
  -- Same operation id but a different generation/hash → reject.
  IF v_found AND v_existing.operation_id = p_operation_id
     AND v_existing.generation_id IS DISTINCT FROM p_generation_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'operation_conflict');
  END IF;

  -- 6. Compare-and-set: the current committed generation must equal the caller's
  --    expected previous. Two devices from the same previous → one winner, the
  --    other a typed stale_generation.
  IF COALESCE(v_existing.generation_id, '')
       IS DISTINCT FROM COALESCE(p_expected_prev_generation_id, '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'stale_generation');
  END IF;

  -- 7-9. Commit the metadata + move the pointer in this one transaction, keeping
  --      the just-superseded generation as the retained previous known-good.
  INSERT INTO backups (
    user_id, blob_path, blob_version, size_bytes, blob_sha256,
    generation_id, operation_id, status, committed_at, updated_at,
    previous_generation_id, previous_object_path
  ) VALUES (
    v_owner, p_object_path, p_blob_version, p_size_bytes, p_blob_sha256,
    p_generation_id, p_operation_id, 'committed', now(), now(),
    v_existing.generation_id, v_existing.blob_path
  )
  ON CONFLICT (user_id) DO UPDATE SET
    blob_path              = EXCLUDED.blob_path,
    blob_version           = EXCLUDED.blob_version,
    size_bytes             = EXCLUDED.size_bytes,
    blob_sha256            = EXCLUDED.blob_sha256,
    generation_id          = EXCLUDED.generation_id,
    operation_id           = EXCLUDED.operation_id,
    status                 = 'committed',
    committed_at           = now(),
    updated_at             = now(),
    previous_generation_id = backups.generation_id,
    previous_object_path   = backups.blob_path;

  RETURN jsonb_build_object('ok', true, 'generation_id', p_generation_id,
                            'previous_generation_id', v_existing.generation_id);
END;
$$;

-- 0083_referral_rewards.sql:906-959
CREATE OR REPLACE FUNCTION public.get_referral_summary()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_uid  UUID := auth.uid();
  v_code TEXT;
  v_prog public.referral_reward_progress%ROWTYPE;
  v_rule public.referral_reward_rules%ROWTYPE;
  v_ent  public.user_entitlement_state%ROWTYPE;
  v_attr TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_code := public.ensure_referral_code(v_uid);

  -- The caller's OWN attribution, as a bare status. This is the entire reason
  -- the referrals table needs no direct read policy: the UX needs "was my code
  -- accepted / has it qualified", never the counterpart's identity. No user id
  -- of the other party is selected, returned, or derivable from this.
  SELECT status INTO v_attr
    FROM public.referrals WHERE referred_user_id = v_uid;

  SELECT * INTO v_prog FROM public.referral_reward_progress
   WHERE referrer_user_id = v_uid AND reward_type = 'report_export_ad_free';

  IF v_prog.pinned_rule_id IS NOT NULL THEN
    SELECT * INTO v_rule FROM public.referral_reward_rules WHERE id = v_prog.pinned_rule_id;
  ELSE
    v_rule := public.active_referral_rule('report_export_ad_free');
  END IF;

  SELECT * INTO v_ent FROM public.user_entitlement_state
   WHERE user_id = v_uid AND entitlement_type = 'report_export_ad_free';

  RETURN jsonb_build_object(
    'referral_code',       v_code,
    'progress',            coalesce(v_prog.qualified_in_cycle, 0),
    'required_referrals',  v_rule.required_referrals,
    'reward_days',         v_rule.reward_days,
    'repeatable',          v_rule.repeatable,
    'cycle_index',         coalesce(v_prog.cycle_index, 1),
    'cycle_state',         coalesce(v_prog.cycle_state, 'open'),
    'referrals_available', (public.active_referral_rule('report_export_ad_free')).id IS NOT NULL,
    'attribution_status',  coalesce(v_attr, 'none'),
    'entitlement_status',  coalesce(v_ent.status, 'none'),
    'entitlement_ends_at', v_ent.ends_at,
    'server_now',          now());
END $$;

-- 0083_referral_rewards.sql:462-503
CREATE OR REPLACE FUNCTION public.ensure_referral_code(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_code     TEXT;
  v_existing TEXT;
  attempt    INTEGER := 0;
BEGIN
  SELECT code INTO v_existing FROM public.referral_codes
   WHERE user_id = p_user_id AND status = 'active';
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- Bounded collision retry; never degrade to predictable data.
  WHILE attempt < 5 LOOP
    attempt := attempt + 1;
    v_code := public.generate_referral_code();
    BEGIN
      -- Conflict target is the PARTIAL index: a concurrent creator for the
      -- same user loses harmlessly, and rotation history never blocks this.
      INSERT INTO public.referral_codes (user_id, code)
      VALUES (p_user_id, v_code)
      ON CONFLICT (user_id) WHERE status = 'active' DO NOTHING;

      SELECT code INTO v_existing FROM public.referral_codes
       WHERE user_id = p_user_id AND status = 'active';
      IF v_existing IS NOT NULL THEN
        RETURN v_existing;   -- ours, or a concurrent winner's — both canonical
      END IF;
    EXCEPTION WHEN unique_violation THEN
      NULL; -- code collision: draw again
    END;
  END LOOP;

  RAISE EXCEPTION 'referral_code_generation_failed'
    USING ERRCODE = 'data_exception';
END $$;

-- 0085_concurrency_absent_row_locking.sql:58-223
CREATE OR REPLACE FUNCTION public.apply_entitlement_mutation(
  p_operation_id     TEXT,
  p_user_id          UUID,
  p_entitlement_type TEXT,
  p_event_type       TEXT,
  p_source           TEXT,
  p_duration_days    INTEGER DEFAULT NULL,
  p_source_reference TEXT    DEFAULT NULL,
  p_rule_id          UUID    DEFAULT NULL,
  p_rule_version     INTEGER DEFAULT NULL,
  p_cycle_index      INTEGER DEFAULT NULL,
  p_actor_admin_id   UUID    DEFAULT NULL,
  p_reason           TEXT    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_fingerprint TEXT;
  v_existing    public.entitlement_events%ROWTYPE;
  v_prev        public.user_entitlement_state%ROWTYPE;
  v_new_ends    TIMESTAMPTZ;
  v_new_status  TEXT;
  v_event_id    UUID;
  v_rowcount    INTEGER;
BEGIN
  -- Audit H-10 (Batch 13): serialize competing writers on the entitlement
  -- authority key. SELECT ... FOR UPDATE below locks nothing when the state row
  -- does not exist yet, so two concurrent FIRST grants both read an empty
  -- previous state, both compute now()+duration, and the second ON CONFLICT
  -- overwrites the first's ends_at with its own stale precomputed value — the
  -- two grants collapse into one duration. A transaction advisory lock is
  -- deterministic on the authority key, needs no existing row, and releases at
  -- commit/rollback; the loser then re-reads the winner's committed state and
  -- extends additively. Acquired FIRST (one lock per call) so ordering is
  -- uniform and no deadlock cycle is possible.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('mali_entitlement:' || p_user_id::text || ':' ||
      coalesce(p_entitlement_type, ''), 0));
  IF p_operation_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;

  -- CANONICAL REQUESTED INTENT, hashed with SHA-256.
  --
  -- Delimiter-joined concatenation was replaced because it is ambiguous: with a
  -- '|' separator the fields ('a|b', 'c') and ('a', 'b|c') produce an identical
  -- string, so two different operations could collide onto one fingerprint.
  -- jsonb is unambiguous AND canonically ordered by Postgres, so a harmless
  -- change in key order cannot change the hash.
  --
  -- This describes the REQUEST, never the outcome: resulting_ends_at and
  -- resulting_status are deliberately excluded because they depend on current
  -- state, and the same request must fingerprint identically whenever it is
  -- replayed.
  v_fingerprint := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'actor',            coalesce(lower(p_actor_admin_id::text), 'system'),
          'target_user',      lower(p_user_id::text),
          'entitlement_type', lower(p_entitlement_type),
          'event_type',       lower(p_event_type),
          'source',           lower(p_source),
          'duration_days',    p_duration_days,
          'source_reference', p_source_reference,
          'rule_id',          lower(p_rule_id::text),
          'rule_version',     p_rule_version,
          'cycle_index',      p_cycle_index,
          -- Reason is part of an Admin operation's intent, so a materially
          -- different reason is a different operation. Normalized (trimmed,
          -- internal whitespace collapsed) so cosmetic edits do not diverge.
          'reason',           nullif(btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g')), '')
        )::text,
        'UTF8'),
      'sha256'),
    'hex');

  SELECT * INTO v_existing
    FROM public.entitlement_events WHERE operation_id = p_operation_id;

  IF FOUND THEN
    IF v_existing.operation_fingerprint <> v_fingerprint THEN
      -- Same key, different intent: refuse rather than return a stranger's result.
      RAISE EXCEPTION 'idempotency_mismatch' USING ERRCODE = 'data_exception';
    END IF;
    RETURN jsonb_build_object(
      'applied', false, 'duplicate', true,
      'event_id', v_existing.id,
      'ends_at', v_existing.resulting_ends_at,
      'status',  v_existing.resulting_status);
  END IF;

  -- Lock/read the current state (may not exist).
  SELECT * INTO v_prev
    FROM public.user_entitlement_state
   WHERE user_id = p_user_id AND entitlement_type = p_entitlement_type
     FOR UPDATE;

  IF p_event_type IN ('grant', 'extend') THEN
    IF p_duration_days IS NULL OR p_duration_days <= 0 THEN
      RAISE EXCEPTION 'invalid_duration' USING ERRCODE = 'data_exception';
    END IF;
    -- base = greatest(now, current ends_at when the row is still active);
    -- a revoked or expired entitlement restarts from now. Never shortens.
    v_new_ends := greatest(
        now(),
        CASE WHEN v_prev.user_id IS NOT NULL AND v_prev.status = 'active'
             THEN v_prev.ends_at ELSE now() END)
      + make_interval(days => p_duration_days);
    v_new_status := 'active';
  ELSIF p_event_type = 'revoke' THEN
    v_new_ends   := least(coalesce(v_prev.ends_at, now()), now());
    v_new_status := 'revoked';
  ELSIF p_event_type = 'shorten' THEN
    IF p_duration_days IS NULL OR p_duration_days <= 0 THEN
      RAISE EXCEPTION 'invalid_duration' USING ERRCODE = 'data_exception';
    END IF;
    v_new_ends   := greatest(now(),
                     coalesce(v_prev.ends_at, now()) - make_interval(days => p_duration_days));
    v_new_status := coalesce(v_prev.status, 'active');
  ELSE
    RAISE EXCEPTION 'invalid_event_type' USING ERRCODE = 'data_exception';
  END IF;

  -- Claim the operation. UNIQUE(operation_id) serializes concurrent replays:
  -- the loser blocks here, then sees the committed row on retry.
  INSERT INTO public.entitlement_events (
    operation_id, operation_fingerprint, user_id, entitlement_type, event_type,
    source, source_reference, duration_days_applied,
    previous_status, previous_ends_at, resulting_status, resulting_ends_at,
    rule_id, rule_version, cycle_index, actor_admin_id, reason)
  VALUES (
    p_operation_id, v_fingerprint, p_user_id, p_entitlement_type, p_event_type,
    p_source, p_source_reference, p_duration_days,
    v_prev.status, v_prev.ends_at, v_new_status, v_new_ends,
    p_rule_id, p_rule_version, p_cycle_index, p_actor_admin_id, p_reason)
  ON CONFLICT (operation_id) DO NOTHING
  RETURNING id INTO v_event_id;

  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    SELECT * INTO v_existing
      FROM public.entitlement_events WHERE operation_id = p_operation_id;
    IF v_existing.operation_fingerprint <> v_fingerprint THEN
      RAISE EXCEPTION 'idempotency_mismatch' USING ERRCODE = 'data_exception';
    END IF;
    RETURN jsonb_build_object(
      'applied', false, 'duplicate', true, 'event_id', v_existing.id,
      'ends_at', v_existing.resulting_ends_at, 'status', v_existing.resulting_status);
  END IF;

  -- Same transaction as the event: state and history can never diverge.
  INSERT INTO public.user_entitlement_state
         (user_id, entitlement_type, status, starts_at, ends_at)
  VALUES (p_user_id, p_entitlement_type, v_new_status, now(), v_new_ends)
  ON CONFLICT (user_id, entitlement_type) DO UPDATE
     SET status = EXCLUDED.status, ends_at = EXCLUDED.ends_at;

  RETURN jsonb_build_object(
    'applied', true, 'duplicate', false, 'event_id', v_event_id,
    'ends_at', v_new_ends, 'status', v_new_status);
END $$;

-- 0083_referral_rewards.sql:833-886
CREATE OR REPLACE FUNCTION public.apply_referral_code(p_code TEXT)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_uid      UUID := auth.uid();
  v_code     TEXT;
  v_owner    UUID;
  v_rule     public.referral_reward_rules%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Canonical normalization: strip separators/space, upper-case.
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));

  IF EXISTS (SELECT 1 FROM public.referrals WHERE referred_user_id = v_uid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_referred');
  END IF;

  -- New attribution requires an active rule (server authority, not a flag).
  v_rule := public.active_referral_rule('report_export_ad_free');
  IF v_rule.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_rule');
  END IF;

  SELECT user_id INTO v_owner FROM public.referral_codes
   WHERE code = v_code AND status = 'active';

  -- Generic result: reveals nothing about whether a code or account exists.
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_code');
  END IF;
  IF v_owner = v_uid THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'self_referral');
  END IF;

  BEGIN
    INSERT INTO public.referrals (referrer_user_id, referred_user_id,
                                  referral_code, attribution_method, status)
    VALUES (v_owner, v_uid, v_code, 'manual_code', 'attributed');
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_referred');
  END;

  -- Inline qualification through the SAME authoritative path (no second
  -- algorithm). Returns 'identity_unverified' until the referee verifies.
  RETURN jsonb_build_object('ok', true, 'attributed', true,
    'qualification', public.qualify_referral_internal(v_uid));
END $$;

-- 0083_referral_rewards.sql:889-903
CREATE OR REPLACE FUNCTION public.request_referral_qualification()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN public.qualify_referral_internal(v_uid);
END $$;

-- 0085_concurrency_absent_row_locking.sql:226-402
CREATE OR REPLACE FUNCTION public.qualify_referral_internal(p_referred_user_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_ref       public.referrals%ROWTYPE;
  v_rule      public.referral_reward_rules%ROWTYPE;
  v_prog      public.referral_reward_progress%ROWTYPE;
  v_verified  BOOLEAN;
  v_rowcount  INTEGER;
  v_new_count INTEGER;
  v_grant_id  UUID;
  v_ent       jsonb;
  v_next      public.referral_reward_rules%ROWTYPE;
BEGIN
  SELECT * INTO v_ref FROM public.referrals
   WHERE referred_user_id = p_referred_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'no_attribution');
  END IF;
  IF v_ref.status = 'qualified' THEN
    RETURN jsonb_build_object('qualified', true, 'duplicate', true);
  END IF;
  IF v_ref.status <> 'attributed' THEN
    RETURN jsonb_build_object('qualified', false, 'reason', v_ref.status);
  END IF;

  -- Verified identity read from SERVER auth truth. Never a client claim.
  SELECT EXISTS (SELECT 1 FROM auth.users u
                  WHERE u.id = p_referred_user_id AND u.email_confirmed_at IS NOT NULL)
      OR EXISTS (SELECT 1 FROM auth.identities i
                  WHERE i.user_id = p_referred_user_id
                    AND i.provider IN ('google', 'apple'))
    INTO v_verified;
  IF NOT v_verified THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'identity_unverified');
  END IF;

  -- Audit H-11 (Batch 13): serialize on the referrer's progress authority
  -- BEFORE reading it. The SELECT ... FOR UPDATE locks nothing when no progress
  -- row exists yet, so two concurrent first qualifiers both take the
  -- absent-row/awaiting_rule branch; if a new rule is published between their
  -- reads, the loser's ON CONFLICT would overwrite the winner's pin and the open
  -- cycle would count a V1 qualification while governed by V2. The advisory lock
  -- makes the loser wait, re-read the committed 'open' row, and keep the winner's
  -- pin. Keyed on the referrer (v_ref resolved above), one lock per call.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('mali_referral_progress:' ||
      v_ref.referrer_user_id::text || ':report_export_ad_free', 0));

  -- Progress row; lock it so concurrent qualifications serialize.
  SELECT * INTO v_prog FROM public.referral_reward_progress
   WHERE referrer_user_id = v_ref.referrer_user_id
     AND reward_type = 'report_export_ad_free' FOR UPDATE;

  IF NOT FOUND OR v_prog.cycle_state = 'awaiting_rule' THEN
    v_rule := public.active_referral_rule('report_export_ad_free');
    IF v_rule.id IS NULL THEN
      -- No open cycle AND no rule to open one: keep the attribution intact and
      -- let the user retry later. No credit is lost, nothing flips to qualified.
      RETURN jsonb_build_object('qualified', false, 'reason', 'awaiting_active_rule');
    END IF;
    INSERT INTO public.referral_reward_progress (
      referrer_user_id, reward_type, pinned_rule_id, pinned_rule_version,
      cycle_index, qualified_in_cycle, cycle_state)
    VALUES (v_ref.referrer_user_id, 'report_export_ad_free', v_rule.id, v_rule.version,
            coalesce(v_prog.cycle_index, 1), 0, 'open')
    ON CONFLICT (referrer_user_id, reward_type) DO UPDATE
      SET pinned_rule_id = EXCLUDED.pinned_rule_id,
          pinned_rule_version = EXCLUDED.pinned_rule_version,
          cycle_state = 'open'
      -- Audit H-11: pin ONLY while the cycle is still awaiting a rule. An
      -- already-open cycle keeps its original pin for its whole lifetime; the
      -- advisory lock makes this branch unreachable for a concurrent loser, and
      -- this predicate is the belt-and-braces guarantee.
      WHERE public.referral_reward_progress.cycle_state = 'awaiting_rule';
    SELECT * INTO v_prog FROM public.referral_reward_progress
     WHERE referrer_user_id = v_ref.referrer_user_id
       AND reward_type = 'report_export_ad_free' FOR UPDATE;
  ELSIF v_prog.cycle_state = 'completed' THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'cycle_completed');
  END IF;

  -- The pinned rule governs this cycle even if it was later deactivated.
  SELECT * INTO v_rule FROM public.referral_reward_rules WHERE id = v_prog.pinned_rule_id;
  IF v_rule.id IS NULL THEN
    RETURN jsonb_build_object('qualified', false, 'reason', 'awaiting_active_rule');
  END IF;

  -- 1. Guarded transition — the exactly-once anchor.
  UPDATE public.referrals
     SET status = 'qualified', qualified_at = now()
   WHERE id = v_ref.id AND status = 'attributed';
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RETURN jsonb_build_object('qualified', true, 'duplicate', true);
  END IF;

  -- 2. Advance the counter (never a recount of referral rows).
  UPDATE public.referral_reward_progress
     SET qualified_in_cycle = qualified_in_cycle + 1
   WHERE referrer_user_id = v_ref.referrer_user_id
     AND reward_type = 'report_export_ad_free'
  RETURNING qualified_in_cycle INTO v_new_count;

  IF v_new_count < v_rule.required_referrals THEN
    RETURN jsonb_build_object('qualified', true, 'granted', false,
      'progress', v_new_count, 'required', v_rule.required_referrals);
  END IF;

  -- 3. Claim the milestone uniquely.
  INSERT INTO public.referral_reward_grants (
    referrer_user_id, rule_id, rule_version, cycle_index, reward_type,
    reward_days_granted, qualified_referral_count, resulting_ends_at)
  VALUES (v_ref.referrer_user_id, v_rule.id, v_rule.version, v_prog.cycle_index,
          'report_export_ad_free', v_rule.reward_days, v_new_count, now())
  ON CONFLICT (referrer_user_id, rule_id, cycle_index) DO NOTHING
  RETURNING id INTO v_grant_id;
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RETURN jsonb_build_object('qualified', true, 'granted', false, 'duplicate_milestone', true);
  END IF;

  -- 4. Entitlement event + state, same transaction, deterministic operation id.
  v_ent := public.apply_entitlement_mutation(
    p_operation_id     => concat_ws(':', 'referral', v_rule.id::text,
                                    v_prog.cycle_index::text, v_ref.referrer_user_id::text),
    p_user_id          => v_ref.referrer_user_id,
    p_entitlement_type => 'report_export_ad_free',
    p_event_type       => 'grant',
    p_source           => 'referral_reward',
    p_duration_days    => v_rule.reward_days,
    p_source_reference => v_grant_id::text,
    p_rule_id          => v_rule.id,
    p_rule_version     => v_rule.version,
    p_cycle_index      => v_prog.cycle_index);

  -- 5. Complete the grant record with the boundary the event produced.
  UPDATE public.referral_reward_grants
     SET entitlement_event_id = (v_ent->>'event_id')::uuid,
         resulting_ends_at    = (v_ent->>'ends_at')::timestamptz
   WHERE id = v_grant_id;

  -- 6. Close this cycle; open the next one only if the rule repeats AND a rule
  --    is currently active to pin. Otherwise park in awaiting_rule/completed.
  IF v_rule.repeatable THEN
    v_next := public.active_referral_rule('report_export_ad_free');
    IF v_next.id IS NULL THEN
      UPDATE public.referral_reward_progress
         SET cycle_index = cycle_index + 1, qualified_in_cycle = 0,
             pinned_rule_id = NULL, pinned_rule_version = NULL,
             cycle_state = 'awaiting_rule'
       WHERE referrer_user_id = v_ref.referrer_user_id
         AND reward_type = 'report_export_ad_free';
    ELSE
      UPDATE public.referral_reward_progress
         SET cycle_index = cycle_index + 1, qualified_in_cycle = 0,
             pinned_rule_id = v_next.id, pinned_rule_version = v_next.version,
             cycle_state = 'open'
       WHERE referrer_user_id = v_ref.referrer_user_id
         AND reward_type = 'report_export_ad_free';
    END IF;
  ELSE
    UPDATE public.referral_reward_progress
       SET pinned_rule_id = NULL, pinned_rule_version = NULL,
           cycle_state = 'completed'
     WHERE referrer_user_id = v_ref.referrer_user_id
       AND reward_type = 'report_export_ad_free';
  END IF;

  RETURN jsonb_build_object('qualified', true, 'granted', true,
    'grant_id', v_grant_id, 'ends_at', v_ent->>'ends_at',
    'rule_version', v_rule.version, 'cycle_index', v_prog.cycle_index);
END $$;

-- 0083_referral_rewards.sql:1143-1221
CREATE OR REPLACE FUNCTION public.admin_mutate_entitlement(
  p_operation_id     TEXT,
  p_actor_admin_id   UUID,
  p_user_id          UUID,
  p_entitlement_type TEXT,
  p_action           TEXT,
  p_reason           TEXT,
  p_duration_days    INTEGER DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
  v_fp     TEXT;
  v_claim  jsonb;
  v_prev   public.user_entitlement_state%ROWTYPE;
  v_res    jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  IF p_action NOT IN ('grant', 'extend', 'shorten', 'revoke') THEN
    RAISE EXCEPTION 'invalid_event_type' USING ERRCODE = 'data_exception';
  END IF;
  -- Typed, mappable error instead of letting entitlement_events_type_shape
  -- surface a raw constraint violation to the Admin route.
  IF p_entitlement_type IS DISTINCT FROM 'report_export_ad_free' THEN
    RAISE EXCEPTION 'bad_entitlement_type' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',           p_action,
    'actor',            lower(p_actor_admin_id::text),
    'duration_days',    p_duration_days,
    'entitlement_type', lower(p_entitlement_type),
    'reason',           v_reason,
    'target_user',      lower(p_user_id::text)));

  SELECT * INTO v_prev FROM public.user_entitlement_state
   WHERE user_id = p_user_id AND entitlement_type = p_entitlement_type;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, p_action, p_user_id, NULL, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'entitlement_type', p_entitlement_type,
      'status',           coalesce(v_prev.status, 'none'),
      'ends_at',          v_prev.ends_at)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  v_res := public.apply_entitlement_mutation(
    p_operation_id     => p_operation_id,
    p_user_id          => p_user_id,
    p_entitlement_type => p_entitlement_type,
    p_event_type       => p_action,
    p_source           => 'admin_grant',
    p_duration_days    => p_duration_days,
    p_actor_admin_id   => p_actor_admin_id,
    p_reason           => v_reason);

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'entitlement_type', p_entitlement_type,
           'status',           v_res->>'status',
           'ends_at',          v_res->>'ends_at',
           'duration_days',    p_duration_days))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'result', v_res);
END $$;

-- 0083_referral_rewards.sql:1224-1286
CREATE OR REPLACE FUNCTION public.admin_reject_referral(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_referral_id    UUID,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason   TEXT;
  v_fp       TEXT;
  v_claim    jsonb;
  v_ref      public.referrals%ROWTYPE;
  v_rowcount INTEGER;
BEGIN
  IF p_referral_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',          'reject_referral',
    'actor',           lower(p_actor_admin_id::text),
    'reason',          v_reason,
    'target_referral', lower(p_referral_id::text)));

  SELECT * INTO v_ref FROM public.referrals WHERE id = p_referral_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'referral_not_found' USING ERRCODE = 'data_exception';
  END IF;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'reject_referral',
    v_ref.referrer_user_id, p_referral_id::text, v_reason,
    public.referral_audit_allowlist(jsonb_build_object('referral_status', v_ref.status)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  -- Guarded transition: rejection applies ONLY to a still-pending attribution.
  -- An already-qualified referral must go through reversal instead.
  UPDATE public.referrals
     SET status = 'rejected', rejection_reason = v_reason
   WHERE id = p_referral_id AND status = 'attributed';
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RAISE EXCEPTION 'referral_not_rejectable' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'referral_status', 'rejected', 'rejection_reason', v_reason))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'referral_status', 'rejected');
END $$;

-- 0083_referral_rewards.sql:1292-1355
CREATE OR REPLACE FUNCTION public.admin_reverse_referral(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_referral_id    UUID,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason   TEXT;
  v_fp       TEXT;
  v_claim    jsonb;
  v_ref      public.referrals%ROWTYPE;
  v_rowcount INTEGER;
BEGIN
  IF p_referral_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',          'reverse_referral',
    'actor',           lower(p_actor_admin_id::text),
    'reason',          v_reason,
    'target_referral', lower(p_referral_id::text)));

  SELECT * INTO v_ref FROM public.referrals WHERE id = p_referral_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'referral_not_found' USING ERRCODE = 'data_exception';
  END IF;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'reverse_referral',
    v_ref.referrer_user_id, p_referral_id::text, v_reason,
    public.referral_audit_allowlist(jsonb_build_object('referral_status', v_ref.status)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  -- qualified_at is NOT cleared: referrals_qualified_at_shape requires it for
  -- 'reversed', because the fact that this referral once qualified is exactly
  -- the history a fraud review depends on.
  UPDATE public.referrals
     SET status = 'reversed', rejection_reason = v_reason
   WHERE id = p_referral_id AND status = 'qualified';
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RAISE EXCEPTION 'referral_not_reversible' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'referral_status', 'reversed', 'rejection_reason', v_reason))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'referral_status', 'reversed');
END $$;

-- 0083_referral_rewards.sql:1358-1447
CREATE OR REPLACE FUNCTION public.admin_adjust_referral_progress(
  p_operation_id       TEXT,
  p_actor_admin_id     UUID,
  p_referrer_user_id   UUID,
  p_reward_type        TEXT,
  p_qualified_in_cycle INTEGER,
  p_reason             TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
  v_fp     TEXT;
  v_claim  jsonb;
  v_prog   public.referral_reward_progress%ROWTYPE;
  v_rule   public.referral_reward_rules%ROWTYPE;
BEGIN
  IF p_referrer_user_id IS NULL OR p_qualified_in_cycle IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',             'adjust_progress',
    'actor',              lower(p_actor_admin_id::text),
    'qualified_in_cycle', p_qualified_in_cycle,
    'reason',             v_reason,
    'reward_type',        lower(p_reward_type),
    'target_user',        lower(p_referrer_user_id::text)));

  SELECT * INTO v_prog FROM public.referral_reward_progress
   WHERE referrer_user_id = p_referrer_user_id AND reward_type = p_reward_type
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'progress_not_found' USING ERRCODE = 'data_exception';
  END IF;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'adjust_progress',
    p_referrer_user_id, p_reward_type, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'cycle_index',        v_prog.cycle_index,
      'qualified_in_cycle', v_prog.qualified_in_cycle,
      'rule_id',            v_prog.pinned_rule_id,
      'rule_version',       v_prog.pinned_rule_version)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  -- Only an OPEN, rule-pinned cycle can be adjusted. A completed or
  -- awaiting_rule cycle has no threshold to be measured against, and
  -- referral_progress_open_is_pinned would be violated by inventing one.
  IF v_prog.cycle_state <> 'open' THEN
    RAISE EXCEPTION 'cycle_not_adjustable' USING ERRCODE = 'data_exception';
  END IF;

  SELECT * INTO v_rule FROM public.referral_reward_rules WHERE id = v_prog.pinned_rule_id;
  IF v_rule.id IS NULL THEN
    RAISE EXCEPTION 'cycle_not_adjustable' USING ERRCODE = 'data_exception';
  END IF;

  -- The milestone boundary is not crossable by adjustment in EITHER direction:
  -- reaching the threshold is what mints a reward grant, and that must happen
  -- through qualification, never as a side effect of an Admin correction.
  IF p_qualified_in_cycle < 0 OR p_qualified_in_cycle >= v_rule.required_referrals THEN
    RAISE EXCEPTION 'adjustment_crosses_milestone' USING ERRCODE = 'data_exception';
  END IF;

  -- cycle_index and the pinned rule are deliberately untouched: history stays.
  UPDATE public.referral_reward_progress
     SET qualified_in_cycle = p_qualified_in_cycle
   WHERE referrer_user_id = p_referrer_user_id AND reward_type = p_reward_type;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'cycle_index',        v_prog.cycle_index,
           'qualified_in_cycle', p_qualified_in_cycle,
           'rule_id',            v_prog.pinned_rule_id,
           'rule_version',       v_prog.pinned_rule_version))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'qualified_in_cycle', p_qualified_in_cycle);
END $$;

-- 0083_referral_rewards.sql:1455-1542
CREATE OR REPLACE FUNCTION public.admin_rotate_referral_code(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_user_id        UUID,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason  TEXT;
  v_fp      TEXT;
  v_claim   jsonb;
  v_old     public.referral_codes%ROWTYPE;
  v_code    TEXT;
  v_new_id  UUID;
  v_attempt INTEGER := 0;
  v_current TEXT;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',      'rotate_code',
    'actor',       lower(p_actor_admin_id::text),
    'reason',      v_reason,
    'target_user', lower(p_user_id::text)));

  SELECT * INTO v_old FROM public.referral_codes
   WHERE user_id = p_user_id AND status = 'active' FOR UPDATE;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'rotate_code',
    p_user_id, v_old.id::text, v_reason,
    public.referral_audit_allowlist(jsonb_build_object('status', 'active')));

  IF NOT (v_claim->>'claimed')::boolean THEN
    SELECT code INTO v_current FROM public.referral_codes
     WHERE user_id = p_user_id AND status = 'active';
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id',
      -- live state, not a replayed value: the rotation already happened
      'current_active_code', v_current);
  END IF;

  IF v_old.id IS NULL THEN
    RAISE EXCEPTION 'no_active_referral_code' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_codes
     SET status = 'rotated', rotated_at = now()
   WHERE id = v_old.id;

  -- Bounded collision retry against the GLOBAL unique code reservation, which
  -- includes every retired code — so a rotated code can never be handed out.
  -- The loop is LABELLED because the EXIT sits inside a nested
  -- BEGIN … EXCEPTION block: an unlabelled EXIT would still leave the loop,
  -- but naming the target makes that unambiguous to the next reader.
  <<mint_code>>
  WHILE v_attempt < 5 LOOP
    v_attempt := v_attempt + 1;
    v_code := public.generate_referral_code();
    BEGIN
      INSERT INTO public.referral_codes (user_id, code)
      VALUES (p_user_id, v_code)
      RETURNING id INTO v_new_id;
      EXIT mint_code;
    EXCEPTION WHEN unique_violation THEN
      v_new_id := NULL;   -- collided with a live or retired code: draw again
    END;
  END LOOP;

  IF v_new_id IS NULL THEN
    RAISE EXCEPTION 'referral_code_generation_failed' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object('status', 'rotated'))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'new_code', v_code);
END $$;

-- 0083_referral_rewards.sql:1549-1641
CREATE OR REPLACE FUNCTION public.admin_publish_reward_rule(
  p_operation_id       TEXT,
  p_actor_admin_id     UUID,
  p_reward_type        TEXT,
  p_required_referrals INTEGER,
  p_reward_days        INTEGER,
  p_repeatable         BOOLEAN,
  p_reason             TEXT,
  p_effective_until    TIMESTAMPTZ DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason  TEXT;
  v_fp      TEXT;
  v_claim   jsonb;
  v_prev    public.referral_reward_rules%ROWTYPE;
  v_version INTEGER;
  v_new_id  UUID;
BEGIN
  IF p_reward_type IS NULL OR p_required_referrals IS NULL OR p_reward_days IS NULL
     OR p_repeatable IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',             'publish_rule',
    'actor',              lower(p_actor_admin_id::text),
    'effective_until',    p_effective_until,
    'reason',             v_reason,
    'repeatable',         p_repeatable,
    'required_referrals', p_required_referrals,
    'reward_days',        p_reward_days,
    'reward_type',        lower(p_reward_type)));

  -- Serialize publication per reward_type so version numbering cannot race
  -- even when no rule rows exist yet to lock.
  PERFORM pg_advisory_xact_lock(hashtext('referral_rule_publish:' || p_reward_type));

  SELECT * INTO v_prev FROM public.referral_reward_rules
   WHERE reward_type = p_reward_type AND is_active;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'rule_change', NULL, p_reward_type, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'rule_id',            v_prev.id,
      'rule_version',       v_prev.version,
      'required_referrals', v_prev.required_referrals,
      'reward_days',        v_prev.reward_days,
      'repeatable',         v_prev.repeatable,
      'is_active',          v_prev.is_active)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  SELECT coalesce(max(version), 0) + 1 INTO v_version
    FROM public.referral_reward_rules WHERE reward_type = p_reward_type;

  -- Only is_active flips on the superseded row. Its reward semantics are NEVER
  -- rewritten, because open cycles stay pinned to it by pinned_rule_id.
  IF v_prev.id IS NOT NULL THEN
    UPDATE public.referral_reward_rules SET is_active = false WHERE id = v_prev.id;
  END IF;

  INSERT INTO public.referral_reward_rules (
    version, reward_type, required_referrals, reward_days, repeatable,
    is_active, effective_until, created_by)
  VALUES (
    v_version, p_reward_type, p_required_referrals, p_reward_days, p_repeatable,
    true, p_effective_until, p_actor_admin_id)
  RETURNING id INTO v_new_id;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'rule_id',            v_new_id,
           'rule_version',       v_version,
           'required_referrals', p_required_referrals,
           'reward_days',        p_reward_days,
           'repeatable',         p_repeatable,
           'is_active',          true))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id',
    'rule_id', v_new_id, 'rule_version', v_version);
END $$;

-- 0083_referral_rewards.sql:1646-1705
CREATE OR REPLACE FUNCTION public.admin_deactivate_reward_rule(
  p_operation_id   TEXT,
  p_actor_admin_id UUID,
  p_reward_type    TEXT,
  p_reason         TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_reason TEXT;
  v_fp     TEXT;
  v_claim  jsonb;
  v_prev   public.referral_reward_rules%ROWTYPE;
BEGIN
  IF p_reward_type IS NULL THEN
    RAISE EXCEPTION 'missing_operation_arguments' USING ERRCODE = 'data_exception';
  END IF;
  v_reason := public.referral_admin_require_reason(p_reason);

  v_fp := public.referral_admin_fingerprint(jsonb_build_object(
    'action',      'deactivate_rule',
    'actor',       lower(p_actor_admin_id::text),
    'reason',      v_reason,
    'reward_type', lower(p_reward_type)));

  PERFORM pg_advisory_xact_lock(hashtext('referral_rule_publish:' || p_reward_type));

  SELECT * INTO v_prev FROM public.referral_reward_rules
   WHERE reward_type = p_reward_type AND is_active;

  v_claim := public.referral_admin_claim(
    p_operation_id, v_fp, p_actor_admin_id, 'rule_change', NULL, p_reward_type, v_reason,
    public.referral_audit_allowlist(jsonb_build_object(
      'rule_id',      v_prev.id,
      'rule_version', v_prev.version,
      'is_active',    v_prev.is_active)));

  IF NOT (v_claim->>'claimed')::boolean THEN
    RETURN jsonb_build_object('applied', false, 'duplicate', true,
      'audit_id', v_claim->>'audit_id', 'result', v_claim->'after_state');
  END IF;

  IF v_prev.id IS NULL THEN
    RAISE EXCEPTION 'no_active_rule' USING ERRCODE = 'data_exception';
  END IF;

  UPDATE public.referral_reward_rules SET is_active = false WHERE id = v_prev.id;

  UPDATE public.referral_admin_audit
     SET after_state = public.referral_audit_allowlist(jsonb_build_object(
           'rule_id', v_prev.id, 'rule_version', v_prev.version, 'is_active', false))
   WHERE id = (v_claim->>'audit_id')::uuid;

  RETURN jsonb_build_object('applied', true, 'duplicate', false,
    'audit_id', v_claim->>'audit_id', 'rule_id', v_prev.id, 'is_active', false);
END $$;

-- 0110_capture_consent_projection.sql:293-388
create or replace function public.link_capture_device(
  p_install_id_hash text,
  p_device_secret_hash text,
  p_cloud boolean,
  p_ai boolean,
  p_version integer,
  p_client_generation bigint default 0
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.capture_devices%rowtype;
  v_changed boolean;
  v_gen bigint := greatest(coalesce(p_client_generation, 0), 0);
  v_cloud boolean := coalesce(p_cloud, false);
  v_ai boolean := coalesce(p_ai, false);
  v_version integer := greatest(coalesce(p_version, 0), 0);
  v_blocked text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select * into v_row from public.capture_devices
   where install_id_hash = p_install_id_hash for update;
  if not found or v_row.device_secret_hash is distinct from p_device_secret_hash then
    return jsonb_build_object('ok', false, 'error', 'invalid_device_secret');
  end if;
  if v_row.revoked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'credential_revoked');
  end if;

  v_changed := v_row.user_id is distinct from v_uid
            or v_row.consent_owner_uid is distinct from v_uid;

  if v_changed then
    -- The link is the authoritative projection of the replica's consent (§4.6):
    -- flags and version are replaced as sent, so a fresh replica (lower version)
    -- can never leave a stale server TRUE behind. The new owner starts fresh.
    update public.capture_devices
       set user_id = v_uid,
           consent_owner_uid = v_uid,
           cloud_processing_enabled = v_cloud,
           ai_consent_granted = v_ai,
           consent_version = v_version,
           owner_generation = v_row.owner_generation + 1,
           consent_client_generation = v_gen,
           last_revoke_generation = null,
           last_seen_at = now()
     where install_id_hash = p_install_id_hash;
    return jsonb_build_object('ok', true, 'owner_changed', true, 'applied', true,
      'owner_generation', v_row.owner_generation + 1, 'consent_client_generation', v_gen);
  end if;

  if v_row.last_revoke_generation is not null and v_gen <= v_row.last_revoke_generation then
    v_blocked := 'revoked_generation';
  elsif v_gen < v_row.consent_client_generation then
    v_blocked := 'stale_generation';
  end if;

  if v_blocked is not null then
    -- Older than the stored ordering (or not past a recorded revoke): narrow only.
    v_cloud := v_cloud and v_row.cloud_processing_enabled;
    v_ai := v_ai and v_row.ai_consent_granted;
    if v_cloud is distinct from v_row.cloud_processing_enabled
       or v_ai is distinct from v_row.ai_consent_granted then
      update public.capture_devices
         set cloud_processing_enabled = v_cloud, ai_consent_granted = v_ai, last_seen_at = now()
       where install_id_hash = p_install_id_hash;
      perform public.capture_revoke_fanout(p_install_id_hash, v_uid, v_cloud, v_ai,
        v_row.consent_version);
    end if;
    return jsonb_build_object('ok', true, 'owner_changed', false, 'applied', false, 'reason', v_blocked,
      'owner_generation', v_row.owner_generation,
      'consent_client_generation', v_row.consent_client_generation);
  end if;

  update public.capture_devices
     set cloud_processing_enabled = v_cloud,
         ai_consent_granted = v_ai,
         consent_version = v_version,
         consent_client_generation = v_gen,
         last_seen_at = now()
   where install_id_hash = p_install_id_hash;

  if (v_row.cloud_processing_enabled and not v_cloud)
     or (v_row.ai_consent_granted and not v_ai) then
    perform public.capture_revoke_fanout(p_install_id_hash, v_uid, v_cloud, v_ai, v_version);
  end if;

  return jsonb_build_object('ok', true, 'owner_changed', false, 'applied', true,
    'owner_generation', v_row.owner_generation, 'consent_client_generation', v_gen);
end;
$$;

-- 0110_capture_consent_projection.sql:401-474
create or replace function public.set_capture_consent(
  p_install_id_hash text,
  p_device_secret_hash text,
  p_cloud boolean,
  p_ai boolean,
  p_version integer,
  p_client_generation bigint default 0
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.capture_devices%rowtype;
  v_cloud boolean := coalesce(p_cloud, false);
  v_ai boolean := coalesce(p_ai, false);
  v_gen bigint := greatest(coalesce(p_client_generation, 0), 0);
  v_blocked text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select * into v_row from public.capture_devices
   where install_id_hash = p_install_id_hash for update;
  if not found or v_row.device_secret_hash is distinct from p_device_secret_hash then
    return jsonb_build_object('ok', false, 'error', 'invalid_device_secret');
  end if;
  if v_row.revoked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'credential_revoked');
  end if;
  if v_row.user_id is distinct from v_uid or v_row.consent_owner_uid is distinct from v_uid then
    return jsonb_build_object('ok', false, 'error', 'capture_owner_mismatch');
  end if;

  if v_row.last_revoke_generation is not null and v_gen <= v_row.last_revoke_generation then
    v_blocked := 'revoked_generation';
  elsif v_gen < v_row.consent_client_generation then
    v_blocked := 'stale_generation';
  elsif p_version is null or p_version <= v_row.consent_version then
    v_blocked := 'stale_version';
  end if;

  if v_blocked is not null then
    -- A stale write may still narrow consent, never widen it.
    v_cloud := v_cloud and v_row.cloud_processing_enabled;
    v_ai := v_ai and v_row.ai_consent_granted;
    if v_cloud is distinct from v_row.cloud_processing_enabled
       or v_ai is distinct from v_row.ai_consent_granted then
      update public.capture_devices
         set cloud_processing_enabled = v_cloud, ai_consent_granted = v_ai
       where install_id_hash = p_install_id_hash;
      perform public.capture_revoke_fanout(p_install_id_hash, v_uid, v_cloud, v_ai,
        v_row.consent_version);
    end if;
    return jsonb_build_object('ok', true, 'applied', false, 'reason', v_blocked,
      'consent_version', v_row.consent_version,
      'consent_client_generation', v_row.consent_client_generation);
  end if;

  update public.capture_devices
     set cloud_processing_enabled = v_cloud,
         ai_consent_granted = v_ai,
         consent_version = p_version,
         consent_client_generation = v_gen
   where install_id_hash = p_install_id_hash;

  if (v_row.cloud_processing_enabled and not v_cloud) or (v_row.ai_consent_granted and not v_ai) then
    perform public.capture_revoke_fanout(p_install_id_hash, v_uid, v_cloud, v_ai, p_version);
  end if;
  return jsonb_build_object('ok', true, 'applied', true,
    'consent_version', p_version, 'consent_client_generation', v_gen);
end;
$$;

-- 0110_capture_consent_projection.sql:492-549
create or replace function public.revoke_capture_consent(
  p_install_id_hash text,
  p_device_secret_hash text,
  p_owner_uid uuid,
  p_transition_generation bigint,
  p_version integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.capture_devices%rowtype;
  v_version integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_owner_uid is null or p_owner_uid is distinct from v_uid
     or p_transition_generation is null or p_transition_generation < 0 then
    return jsonb_build_object('ok', false, 'applied', false, 'reason', 'owner_mismatch',
      'error', 'owner_mismatch');
  end if;
  select * into v_row from public.capture_devices
   where install_id_hash = p_install_id_hash for update;
  if not found or v_row.device_secret_hash is distinct from p_device_secret_hash then
    return jsonb_build_object('ok', false, 'applied', false, 'reason', 'invalid_device_secret',
      'error', 'invalid_device_secret');
  end if;
  if v_row.revoked_at is not null then
    return jsonb_build_object('ok', false, 'applied', false, 'reason', 'credential_revoked',
      'error', 'credential_revoked');
  end if;
  if v_row.user_id is distinct from v_uid or v_row.consent_owner_uid is distinct from v_uid then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'owner_mismatch');
  end if;
  if v_row.last_revoke_generation is not null
     and v_row.last_revoke_generation >= p_transition_generation then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'already_revoked');
  end if;
  if p_transition_generation < v_row.consent_client_generation then
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'stale_generation');
  end if;

  v_version := greatest(v_row.consent_version, coalesce(p_version, 0));
  update public.capture_devices
     set cloud_processing_enabled = false,
         ai_consent_granted = false,
         consent_version = v_version,
         consent_client_generation = p_transition_generation,
         last_revoke_generation = p_transition_generation,
         last_seen_at = now()
   where install_id_hash = p_install_id_hash;
  perform public.capture_revoke_fanout(p_install_id_hash, v_uid, false, false, v_version);
  return jsonb_build_object('ok', true, 'applied', true, 'reason', 'revoked');
end;
$$;

-- 0110_capture_consent_projection.sql:562-592
create or replace function public.legacy_link_capture_device(
  p_install_id_hash text,
  p_user_id uuid
) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.capture_devices%rowtype;
  v_changed boolean;
begin
  select * into v_row from public.capture_devices
   where install_id_hash = p_install_id_hash for update;
  if not found or v_row.revoked_at is not null then return false; end if;
  v_changed := v_row.user_id is distinct from p_user_id
            or v_row.consent_owner_uid is distinct from p_user_id;
  update public.capture_devices
     set user_id = p_user_id,
         consent_owner_uid = p_user_id,
         cloud_processing_enabled = case when v_changed then false else v_row.cloud_processing_enabled end,
         ai_consent_granted = case when v_changed then false else v_row.ai_consent_granted end,
         consent_version = case when v_changed then 0 else v_row.consent_version end,
         owner_generation = case when v_changed then v_row.owner_generation + 1 else v_row.owner_generation end,
         consent_client_generation = case when v_changed then 0 else v_row.consent_client_generation end,
         last_revoke_generation = case when v_changed then null else v_row.last_revoke_generation end,
         last_seen_at = now()
   where install_id_hash = p_install_id_hash;
  return true;
end;
$$;

-- 0110_capture_consent_projection.sql:604-645
create or replace function public.legacy_set_device_consent(
  p_install_id_hash text,
  p_cloud boolean,
  p_ai boolean
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.capture_devices%rowtype;
  v_cloud boolean := coalesce(p_cloud, false);
  v_ai boolean := coalesce(p_ai, false);
  v_version integer;
begin
  select * into v_row from public.capture_devices
   where install_id_hash = p_install_id_hash for update;
  if not found or v_row.revoked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'invalid_device_secret');
  end if;
  if v_row.consent_owner_uid is distinct from v_row.user_id then
    return jsonb_build_object('ok', false, 'error', 'capture_owner_mismatch');
  end if;
  if v_row.last_revoke_generation is not null then
    v_cloud := v_cloud and v_row.cloud_processing_enabled;
    v_ai := v_ai and v_row.ai_consent_granted;
  end if;
  if v_row.cloud_processing_enabled = v_cloud and v_row.ai_consent_granted = v_ai then
    return jsonb_build_object('ok', true, 'changed', false);
  end if;
  v_version := v_row.consent_version + 1;
  update public.capture_devices
     set cloud_processing_enabled = v_cloud,
         ai_consent_granted = v_ai,
         consent_version = v_version
   where install_id_hash = p_install_id_hash;
  if (v_row.cloud_processing_enabled and not v_cloud) or (v_row.ai_consent_granted and not v_ai) then
    perform public.capture_revoke_fanout(p_install_id_hash, v_row.user_id, v_cloud, v_ai, v_version);
  end if;
  return jsonb_build_object('ok', true, 'changed', true);
end;
$$;

-- 0110_capture_consent_projection.sql:655-678
create or replace function public.unlink_capture_device(p_install_id_hash text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.capture_devices
     set owner_generation = owner_generation
           + case when user_id is not null or consent_owner_uid is not null then 1 else 0 end,
         consent_client_generation = 0,
         last_revoke_generation = null,
         user_id = null,
         consent_owner_uid = null,
         cloud_processing_enabled = false,
         ai_consent_granted = false,
         consent_version = 0,
         apns_token = null,
         token_updated_at = null,
         last_seen_at = now()
   where install_id_hash = p_install_id_hash;
  return found;
end;
$$;

-- 0112_capture_notifications_retention.sql:296-437
create or replace function public.capture_claim(
  p_install_id_hash text,
  p_install_id text,
  p_payload_id text,
  p_raw_fingerprint text,
  p_owner_uid uuid,
  p_contract integer,
  p_lease_seconds integer default 60,
  p_owner_generation bigint default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_push jsonb;
  v_ownerless boolean := false;
begin
  -- One snapshot: the device row is share-locked for the rest of this tx, so a
  -- concurrent link / consent change / revoke serializes strictly before or after.
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  if not found then
    return jsonb_build_object('outcome', 'denied', 'code', 'consent_required');
  end if;
  if d.revoked_at is not null then
    return jsonb_build_object('outcome', 'denied', 'code', 'credential_revoked');
  end if;
  if p_contract = 2 or p_owner_uid is not null then
    -- Owner-bound upload (any schema version): owner_uid == user_id == consent_owner_uid.
    if p_owner_uid is null or d.user_id is null or d.consent_owner_uid is null
       or p_owner_uid <> d.user_id or d.user_id <> d.consent_owner_uid then
      return jsonb_build_object('outcome', 'denied', 'code', 'capture_owner_mismatch');
    end if;
  elsif d.consent_owner_uid is distinct from d.user_id then
    return jsonb_build_object('outcome', 'denied', 'code', 'consent_required');
  else
    v_ownerless := true;
  end if;
  if d.cloud_processing_enabled is not true then
    return jsonb_build_object('outcome', 'denied', 'code', 'consent_required');
  end if;
  if v_ownerless and not exists (
       select 1 from public.capture_install_owner_history h
        where h.install_id_hash = p_install_id_hash
          and h.trusted and not h.transitioned
          and h.first_owner_uid is not null
          and h.first_owner_uid = d.user_id
          and d.user_id = d.consent_owner_uid) then
    -- H1 option B: an OWNERLESS (build-50) upload is attributable only when the trusted
    -- install history proves one owner who never changed (see 0110). No row, no content, no AI.
    return jsonb_build_object('outcome', 'owner_conflict', 'reason', 'ownerless_not_eligible');
  end if;

  insert into public.processed_captures
    (payload_id, install_id_hash, claimed_user_id, status, state, parsed, notification,
     raw_fingerprint, lease_until, lease_token, attempts, owner_uid, consent_owner_uid, consent_version,
     client_owner_generation)
  values
    (p_payload_id, p_install_id_hash, d.user_id, 'rejected', 'processing', '{}'::jsonb, '{}'::jsonb,
     p_raw_fingerprint, now() + make_interval(secs => p_lease_seconds), 1, 1,
     p_owner_uid, d.consent_owner_uid, d.consent_version, p_owner_generation)
  on conflict (install_id_hash, payload_id) do nothing
  returning * into r;
  if found then
    return jsonb_build_object('outcome', 'claimed', 'lease_token', r.lease_token,
      'attempts', r.attempts, 'claimed_user_id', d.user_id,
      'consent_owner_uid', d.consent_owner_uid, 'consent_version', d.consent_version,
      'ai_allowed', d.ai_consent_granted);
  end if;

  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if not found then
    -- Row pruned between the conflict and the read: caller retries.
    return jsonb_build_object('outcome', 'in_progress');
  end if;

  if r.claimed_user_id is distinct from d.user_id then
    return jsonb_build_object('outcome', 'owner_conflict');
  end if;
  if r.raw_fingerprint is not null and r.raw_fingerprint is distinct from p_raw_fingerprint then
    return jsonb_build_object('outcome', 'id_conflict');
  end if;

  -- F1: past the expiry fence nothing is re-claimed, re-leased or replayed with content:
  -- the row is nulled and expired, and the stored (empty, expired) result is replayed.
  if r.state in ('processing', 'processed', 'retryable', 'rejected')
     and not public.capture_content_live(r.created_at) then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
    select * into r from public.processed_captures
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
    return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r));
  end if;

  if r.state in ('processing', 'retryable') then
    if r.state = 'processing' and r.lease_until > now() then
      return jsonb_build_object('outcome', 'in_progress');
    end if;
    if r.state = 'retryable' and r.next_attempt_at > now() then
      return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r));
    end if;
    if r.attempts >= 5 then
      update public.processed_captures
         set state = 'rejected', status = 'rejected', lease_until = null,
             failure_reason = 'attempts_exhausted', parsed = '{}'::jsonb,
             notification = '{}'::jsonb, sanitized_text = null
       where install_id_hash = p_install_id_hash and payload_id = p_payload_id
       returning * into r;
      return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r));
    end if;
    -- Re-claim: lease_token and attempts increment AT CLAIM; the consent snapshot
    -- is retaken; the AI marker is cleared so a new dispatch is required.
    update public.processed_captures
       set state = 'processing', lease_until = now() + make_interval(secs => p_lease_seconds),
           lease_token = lease_token + 1, attempts = attempts + 1,
           consent_owner_uid = d.consent_owner_uid, consent_version = d.consent_version,
           owner_uid = p_owner_uid, client_owner_generation = p_owner_generation,
           ai_started_at = null, ai_consent_version = null, next_attempt_at = null
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id
     returning * into r;
    return jsonb_build_object('outcome', 'claimed', 'lease_token', r.lease_token,
      'attempts', r.attempts, 'claimed_user_id', d.user_id,
      'consent_owner_uid', d.consent_owner_uid, 'consent_version', d.consent_version,
      'ai_allowed', d.ai_consent_granted);
  end if;

  -- processed | rejected | consumed | expired: replay the stored result. A push
  -- that was never confirmed is re-offered only when the stored consent snapshot
  -- still matches the device (the replay is inside the same fenced snapshot).
  if r.state in ('processed', 'rejected') and r.apns_push_sent_at is null
     and coalesce(r.notification ->> 'title', '') <> ''
     and r.consent_owner_uid is not distinct from d.consent_owner_uid
     and r.consent_version is not distinct from d.consent_version then
    v_push := public.capture_queue_push(p_install_id_hash, p_install_id, p_payload_id,
      d.user_id, r.notification ->> 'type');
  end if;
  return jsonb_build_object('outcome', 'replay', 'row', public.capture_row_json(r), 'push', v_push);
end;
$$;

-- 0112_capture_notifications_retention.sql:439-490
create or replace function public.capture_ai_dispatch(
  p_install_id_hash text,
  p_payload_id text,
  p_lease_token integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_reason text;
begin
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if not found or r.lease_token <> p_lease_token or r.state <> 'processing' or d.install_id_hash is null then
    return jsonb_build_object('allowed', false, 'reason', 'lease_lost');
  end if;
  -- F1: an expired row never starts AI (no ai_started_at); it is nulled and expired.
  if not public.capture_content_live(r.created_at) then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
    return jsonb_build_object('allowed', false, 'reason', 'expired');
  end if;

  if d.user_id is distinct from r.claimed_user_id
     or d.consent_owner_uid is distinct from r.consent_owner_uid
     or d.consent_owner_uid is distinct from d.user_id
     or (r.owner_uid is not null and r.owner_uid is distinct from d.user_id) then
    v_reason := 'owner_changed';
  elsif d.revoked_at is not null or d.cloud_processing_enabled is not true
     or d.ai_consent_granted is not true
     or d.consent_version is distinct from r.consent_version then
    v_reason := 'consent_revoked';
  end if;

  if v_reason is not null then
    update public.processed_captures
       set state = 'retryable', failure_reason = v_reason, lease_until = null,
           next_attempt_at = now() + make_interval(secs => 30 * attempts)
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
    return jsonb_build_object('allowed', false, 'reason', v_reason);
  end if;

  update public.processed_captures
     set ai_started_at = now(), ai_consent_version = d.consent_version, ai_invoked = true
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
  return jsonb_build_object('allowed', true);
end;
$$;

-- 0112_capture_notifications_retention.sql:492-576
create or replace function public.capture_finalize(
  p_install_id_hash text,
  p_install_id text,
  p_payload_id text,
  p_lease_token integer,
  p_state text,
  p_status text,
  p_parsed jsonb,
  p_notification jsonb,
  p_sanitized_text text,
  p_failure_reason text,
  p_possible_duplicate boolean,
  p_validator_result jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_reason text;
  v_push jsonb;
begin
  if p_state not in ('processed', 'rejected', 'retryable') then
    raise exception 'invalid_terminal_state' using errcode = '22023';
  end if;
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if not found or d.install_id_hash is null or r.lease_token <> p_lease_token or r.state <> 'processing' then
    return jsonb_build_object('written', false, 'push_allowed', false, 'reason', 'lease_lost');
  end if;
  -- F1: an expired lease writes no result and queues no push; it nulls instead.
  if not public.capture_content_live(r.created_at) then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
    return jsonb_build_object('written', false, 'push_allowed', false, 'reason', 'expired');
  end if;

  if d.user_id is distinct from r.claimed_user_id
     or d.consent_owner_uid is distinct from r.consent_owner_uid
     or d.consent_owner_uid is distinct from d.user_id
     or (r.owner_uid is not null and r.owner_uid is distinct from d.user_id) then
    v_reason := 'owner_changed';
  elsif d.revoked_at is not null or d.cloud_processing_enabled is not true
     or d.consent_version is distinct from r.consent_version then
    v_reason := 'consent_revoked';
  end if;

  if v_reason is not null then
    update public.processed_captures
       set state = 'retryable', failure_reason = v_reason, lease_until = null,
           next_attempt_at = now() + make_interval(secs => 30 * attempts)
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
    return jsonb_build_object('written', false, 'push_allowed', false, 'reason', v_reason);
  end if;

  if p_state = 'retryable' then
    update public.processed_captures
       set state = 'retryable', failure_reason = p_failure_reason, lease_until = null,
           next_attempt_at = now() + make_interval(secs => 30 * attempts)
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id
     returning * into r;
    return jsonb_build_object('written', true, 'push_allowed', false, 'state', 'retryable',
      'row', public.capture_row_json(r));
  end if;

  update public.processed_captures
     set state = p_state, status = p_status, parsed = coalesce(p_parsed, '{}'::jsonb),
         notification = coalesce(p_notification, '{}'::jsonb), sanitized_text = p_sanitized_text,
         failure_reason = p_failure_reason, possible_duplicate = coalesce(p_possible_duplicate, false),
         validator_result = p_validator_result, lease_until = null, next_attempt_at = null
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id
   returning * into r;
  if coalesce(p_notification ->> 'title', '') <> '' then
    v_push := public.capture_queue_push(p_install_id_hash, p_install_id, p_payload_id,
      r.claimed_user_id, p_notification ->> 'type');
    select * into r from public.processed_captures
     where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
  end if;
  return jsonb_build_object('written', true, 'push_allowed', true, 'state', p_state,
    'row', public.capture_row_json(r), 'push', v_push);
end;
$$;

-- 0111_capture_state_machine.sql:442-464
create or replace function public.capture_ack(
  p_install_id_hash text,
  p_user_id uuid,
  p_payload_ids text[]
) returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  update public.processed_captures
     set state = 'consumed', consumed_at = now(), consumed_by_install_hash = p_install_id_hash,
         parsed = '{}'::jsonb, notification = '{}'::jsonb, sanitized_text = null, lease_until = null
   where install_id_hash = p_install_id_hash
     and payload_id = any (p_payload_ids)
     and claimed_user_id is not distinct from p_user_id
     and state in ('processed', 'retryable', 'rejected', 'expired');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- 0112_capture_notifications_retention.sql:232-292
create or replace function public.capture_retry_fence(
  p_install_id_hash text,
  p_payload_id text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.capture_devices%rowtype;
  r public.processed_captures%rowtype;
  v_expired boolean;
begin
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  if d.install_id_hash is null or r.payload_id is null then
    return jsonb_build_object('allowed', false, 'reason', 'gone');
  end if;
  -- F1: a row past the expiry fence is nulled and expired on sight (the row lock is
  -- exclusive so the null cannot race a finalize); a consumed tombstone is untouched.
  v_expired := r.state <> 'consumed' and not public.capture_content_live(r.created_at);
  if v_expired then
    perform public.capture_expire_row(p_install_id_hash, p_payload_id);
  end if;
  if r.apns_push_sent_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'already_sent');
  end if;
  if v_expired then
    return jsonb_build_object('allowed', false, 'reason', 'expired');
  end if;
  -- consumed / expired / retryable / processing: nothing (or nothing yet) to alert about.
  if r.state not in ('processed', 'rejected') then
    return jsonb_build_object('allowed', false, 'reason', 'not_pending');
  end if;
  if d.revoked_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'credential_revoked');
  end if;
  if d.cloud_processing_enabled is not true then
    return jsonb_build_object('allowed', false, 'reason', 'consent_revoked');
  end if;
  if d.user_id is distinct from r.claimed_user_id
     or d.consent_owner_uid is distinct from r.consent_owner_uid
     or d.consent_owner_uid is distinct from d.user_id
     or d.consent_version is distinct from r.consent_version then
    return jsonb_build_object('allowed', false, 'reason', 'owner_changed');
  end if;
  if d.apns_token is null or d.apns_environment is null then
    return jsonb_build_object('allowed', false, 'reason', 'no_token');
  end if;
  if coalesce(r.notification ->> 'title', '') = '' then
    return jsonb_build_object('allowed', false, 'reason', 'no_content');
  end if;
  return jsonb_build_object(
    'allowed', true,
    'apns_token', d.apns_token,
    'apns_environment', d.apns_environment,
    'notification_type', r.notification ->> 'type');
end;
$$;

-- 0112_capture_notifications_retention.sql:147-199
create or replace function public.capture_queue_push(
  p_install_id_hash text,
  p_install_id text,
  p_payload_id text,
  p_user_id uuid,
  p_notification_type text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dev public.capture_devices%rowtype;
  v_log uuid;
  v_created timestamptz;
begin
  -- Locks first (both are re-entrant for the finalize / claim callers, which already hold
  -- them), THEN the expiry re-check: the fence is judged at the linearisation point.
  select * into v_dev from public.capture_devices where install_id_hash = p_install_id_hash for share;
  if not found or v_dev.apns_token is null or v_dev.apns_environment is null
     or p_install_id is null or p_install_id = '' then
    return null;
  end if;
  select notification_log_id, created_at into v_log, v_created from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for update;
  -- F1: nothing is derived from expired content (clock_timestamp(), after the locks above).
  if not public.capture_content_live(v_created) then
    return null;
  end if;
  v_log := coalesce(v_log, gen_random_uuid());
  update public.processed_captures
     set notification_log_id = v_log, push_attempted_at = now()
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id
     and push_attempted_at is null;
  if not found then
    return null;
  end if;
  insert into public.notification_logs
    (id, user_id, install_id, install_id_hash, notification_type, channel, status, queued_at,
     related_entity_type, related_entity_id, device_platform, apns_environment)
  values
    (v_log, p_user_id, p_install_id, p_install_id_hash, p_notification_type, 'apns', 'queued', now(),
     'payload', p_payload_id, 'ios', v_dev.apns_environment)
  on conflict (id) do update
    set status = 'queued', queued_at = now(), user_id = excluded.user_id,
        install_id_hash = excluded.install_id_hash,
        apns_environment = excluded.apns_environment;
  return jsonb_build_object(
    'notification_log_id', v_log,
    'apns_token', v_dev.apns_token,
    'apns_environment', v_dev.apns_environment);
end;
$$;

-- 0110_capture_consent_projection.sql:243-278
create or replace function public.capture_revoke_fanout(
  p_install_id_hash text,
  p_user_id uuid,
  p_cloud boolean,
  p_ai boolean,
  p_version integer
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_user_id is not null then
    update public.user_settings
       set cloud_processing_enabled = p_cloud,
           ai_consent_granted = p_ai,
           consent_version = p_version
     where user_id = p_user_id
       and local_id = 'user_settings'
       and coalesce(consent_version, 0) < p_version;
  end if;

  update public.processed_captures
     set parsed = '{}'::jsonb,
         notification = '{}'::jsonb,
         sanitized_text = null,
         failure_reason = case when state in ('processed', 'retryable') then 'consent_revoked'
                               else failure_reason end,
         status = 'rejected',
         state = 'rejected'
   where install_id_hash = p_install_id_hash
     and claimed_user_id is not distinct from p_user_id
     and consumed_at is null
     and state in ('processed', 'retryable', 'rejected');
end;
$$;

-- 0071_ai_endpoint_hardening.sql:58-98
CREATE OR REPLACE FUNCTION claim_ai_idempotency(
  p_owner_key TEXT,
  p_endpoint TEXT,
  p_request_id TEXT,
  p_payload_hash TEXT,
  p_ttl_seconds INTEGER
)
RETURNS TABLE(outcome TEXT, status TEXT, result JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inserted BOOLEAN := FALSE;
  v_row ai_request_idempotency;
BEGIN
  INSERT INTO ai_request_idempotency AS r
    (owner_key, endpoint, request_id, payload_hash, status, result, expires_at)
  VALUES
    (p_owner_key, p_endpoint, p_request_id, p_payload_hash, 'in_progress',
     '{}'::jsonb, NOW() + make_interval(secs => GREATEST(p_ttl_seconds, 1)))
  ON CONFLICT (owner_key, endpoint, request_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted THEN
    RETURN QUERY SELECT 'claimed'::TEXT, 'in_progress'::TEXT, '{}'::jsonb;
    RETURN;
  END IF;

  SELECT * INTO v_row FROM ai_request_idempotency
    WHERE owner_key = p_owner_key
      AND endpoint = p_endpoint
      AND request_id = p_request_id;

  IF v_row.payload_hash IS DISTINCT FROM p_payload_hash THEN
    RETURN QUERY SELECT 'mismatch'::TEXT, COALESCE(v_row.status, 'unknown'), '{}'::jsonb;
  ELSE
    RETURN QUERY SELECT 'exists'::TEXT, v_row.status, v_row.result;
  END IF;
END;
$$;

-- 0085_concurrency_absent_row_locking.sql:405-513
CREATE OR REPLACE FUNCTION public.award_gamification_for_transaction(
  p_transaction_id TEXT,
  p_user_id        UUID
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_award    CONSTANT INTEGER := 10;
  v_rowcount INTEGER;
  v_existing public.gamification_awarded_transactions%ROWTYPE;
  v_cur_xp    INTEGER;
  v_cur_level INTEGER;
  v_new_xp    INTEGER;
  v_new_level INTEGER;
  v_leveled   BOOLEAN := FALSE;
  v_count     INTEGER;
  v_ach       TEXT := NULL;
BEGIN
  -- Audit H-12 (Batch 13): the claim below serializes per TRANSACTION id, but
  -- the XP read-modify-write is on the per-USER authority row (user_xp_levels)
  -- and was unlocked. Two DISTINCT-transaction awards for one user both read the
  -- same xp and both write +10 → +10 net instead of +20 (the immutable award
  -- ledger shows two, the aggregate reflects one). Serialize on the user
  -- authority key first (needs no existing row); the loser then reads the
  -- winner's committed xp and adds to it. One lock per call, acquired before the
  -- claim, so ordering is uniform (user key only) — no deadlock cycle.
  PERFORM pg_advisory_xact_lock(hashtextextended('mali_xp:' || p_user_id::text, 0));
  IF p_transaction_id IS NULL OR p_user_id IS NULL THEN
    RETURN jsonb_build_object('awarded', false, 'reason', 'missing_args');
  END IF;

  -- Ownership is never trusted from the caller: the transaction must belong to
  -- the target user, or nothing is awarded.
  IF NOT EXISTS (
    SELECT 1 FROM user_transactions
    WHERE id::text = p_transaction_id AND user_id = p_user_id
  ) THEN
    RETURN jsonb_build_object('awarded', false, 'reason', 'not_owner');
  END IF;

  -- Atomic claim. ON CONFLICT DO NOTHING → ROW_COUNT tells us whether THIS call
  -- won the claim. Concurrent workers block on the uncommitted claim row's lock
  -- until the winner commits (then this call sees the conflict → returns the
  -- stored result) or aborts (then this call's INSERT succeeds → it takes over).
  INSERT INTO gamification_awarded_transactions (transaction_id, user_id)
  VALUES (p_transaction_id, p_user_id)
  ON CONFLICT (transaction_id) DO NOTHING;
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;

  IF v_rowcount = 0 THEN
    -- Already awarded (previous call or a concurrent winner that committed).
    -- Return the stored canonical result so a lost-response retry reconstructs
    -- exactly the same outcome without re-awarding.
    SELECT * INTO v_existing
      FROM gamification_awarded_transactions
      WHERE transaction_id = p_transaction_id;
    RETURN jsonb_build_object(
      'awarded',     true,
      'duplicate',   true,
      'leveled_up',  v_existing.leveled_up,
      'level',       v_existing.new_level,
      'achievement', v_existing.achievement_code
    );
  END IF;

  -- We won the claim → apply the award in THIS same transaction. A failure below
  -- rolls back the claim too, so the row never outlives a completed award.
  SELECT xp, level INTO v_cur_xp, v_cur_level
    FROM user_xp_levels WHERE user_id = p_user_id;
  v_new_xp    := COALESCE(v_cur_xp, 0) + v_award;
  v_new_level := floor(sqrt(v_new_xp / 100.0)) + 1;
  v_leveled   := v_new_level > COALESCE(v_cur_level, 1);
  IF NOT v_leveled THEN
    v_new_level := COALESCE(v_cur_level, 1);
  END IF;

  INSERT INTO user_xp_levels (user_id, xp, level, updated_at)
  VALUES (p_user_id, v_new_xp, v_new_level, now())
  ON CONFLICT (user_id) DO UPDATE
    SET xp = EXCLUDED.xp, level = EXCLUDED.level, updated_at = now();

  -- Count-based achievement (matches the legacy Edge thresholds).
  SELECT count(*) INTO v_count FROM user_transactions WHERE user_id = p_user_id;
  IF    v_count = 1   THEN v_ach := 'first_transaction';
  ELSIF v_count = 10  THEN v_ach := 'tenth_transaction';
  ELSIF v_count = 100 THEN v_ach := 'century_transaction';
  END IF;

  -- Record the canonical result + notification eligibility ATOMICALLY with the
  -- award (same transaction). This row IS the exactly-once eligibility record;
  -- provider delivery happens afterward, keyed by a stable id.
  UPDATE gamification_awarded_transactions
    SET leveled_up       = v_leveled,
        new_level        = CASE WHEN v_leveled THEN v_new_level ELSE NULL END,
        achievement_code = v_ach
    WHERE transaction_id = p_transaction_id;

  RETURN jsonb_build_object(
    'awarded',     true,
    'duplicate',   false,
    'leveled_up',  v_leveled,
    'level',       v_new_level,
    'achievement', v_ach
  );
END;
$$;

-- 0033_capture_pipeline_hardening.sql:60-74
CREATE OR REPLACE FUNCTION bump_capture_rate_limit(
  p_install_id_hash TEXT,
  p_limit INTEGER
)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO capture_rate_limits AS r (install_id_hash, date, call_count)
  VALUES (p_install_id_hash, CURRENT_DATE, 1)
  ON CONFLICT (install_id_hash, date)
    DO UPDATE SET call_count = r.call_count + 1
  RETURNING call_count > p_limit;
$$;

-- 0071_ai_endpoint_hardening.sql:105-122
CREATE OR REPLACE FUNCTION complete_ai_idempotency(
  p_owner_key TEXT,
  p_endpoint TEXT,
  p_request_id TEXT,
  p_status TEXT,
  p_result JSONB
)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE ai_request_idempotency
    SET status = p_status, result = COALESCE(p_result, '{}'::jsonb)
  WHERE owner_key = p_owner_key
    AND endpoint = p_endpoint
    AND request_id = p_request_id;
$$;

-- <<< GENERATED:END rpc_originals

-- 0105_stamp_sync_seq_triggers.sql:36-60
CREATE OR REPLACE FUNCTION public.stamp_sync_seq()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_seq bigint;
BEGIN
  INSERT INTO public.user_sync_state (user_id, last_seq, epoch_reason)
  VALUES (NEW.user_id, 1, 'initial')
  ON CONFLICT (user_id) DO UPDATE
    SET last_seq = public.user_sync_state.last_seq + 1,
        updated_at = now()
  RETURNING last_seq INTO v_seq;
  IF v_seq IS NULL THEN
    RAISE EXCEPTION 'sync_state_missing' USING ERRCODE = 'P0001';
  END IF;
  NEW.sync_seq := v_seq;
  IF TG_NARGS = 0 THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

-- 0107_sync_cas_rpcs.sql:179-198
CREATE OR REPLACE FUNCTION public.sync_lock_epoch()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_epoch uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;
  INSERT INTO public.user_sync_state (user_id, epoch_reason)
  VALUES (v_uid, 'initial')
  ON CONFLICT (user_id) DO NOTHING;
  SELECT epoch INTO v_epoch FROM public.user_sync_state WHERE user_id = v_uid FOR UPDATE;
  RETURN v_epoch;
END;
$$;

-- 0086_backups_owner_liveness.sql:40-53
create or replace function public.backups_owner_is_live()
returns boolean
language sql
volatile
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
      from auth.users as u
     where u.id = (select auth.uid())
     for key share
  );
$$;

-- 0042_account_deletion_policy.sql:17-45
create or replace function public.request_account_deletion()
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_scheduled timestamptz;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select delete_scheduled_at into v_scheduled
  from public.profiles where id = v_user_id;

  if v_scheduled is not null then
    return v_scheduled;
  end if;

  update public.profiles
  set delete_scheduled_at = now() + interval '30 days'
  where id = v_user_id
  returning delete_scheduled_at into v_scheduled;

  return v_scheduled;
end;
$$;

-- 0042_account_deletion_policy.sql:47-62
create or replace function public.cancel_account_deletion()
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  update public.profiles
  set delete_scheduled_at = null
  where id = auth.uid();
end;
$$;

-- 0101_feature_flag_admin_audit.sql:74-79
CREATE OR REPLACE FUNCTION public.feature_flag_audit_append_only()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'feature_flag_admin_audit is append-only' USING ERRCODE = 'P0403';
END;
$$;

-- 4. Replay -- restricted to the reviewed mutation set. Nothing else is touched here; section 6 compares everything.
-- (4a) Row-security / FORCE flags of every table the fence added policies or triggers to, restored to the snapshot
--      (fence.sql changes none of them; this makes the claim true instead of assumed). Dynamic format() is used
--      only to replay recorded metadata.
do $flags$
declare r record;
begin
  for r in select t.rel, t.rls, t.force_rls from rb_tbl t
            where t.rel::regclass = any (array['public.account_purge_queue', 'public.admin_users', 'public.ai_request_idempotency', 'public.announcement_admin_audit', 'public.backups', 'public.capture_devices', 'public.capture_fingerprints', 'public.capture_install_owner_history', 'public.capture_rate_limits', 'public.entitlement_events', 'public.feature_flag_admin_audit', 'public.feature_flag_overrides', 'public.financial_import_runs', 'public.gamification_awarded_transactions', 'public.metrics_rate_limits', 'public.notification_logs', 'public.notification_retry_queue', 'public.processed_captures', 'public.profiles', 'public.referral_admin_audit', 'public.referral_codes', 'public.referral_reward_grants', 'public.referral_reward_progress', 'public.referral_reward_rules', 'public.referrals', 'public.sender_bank_mappings', 'public.user_accounts', 'public.user_achievements', 'public.user_bill_payments', 'public.user_budgets', 'public.user_cards', 'public.user_categories', 'public.user_engagement_events', 'public.user_entitlement_state', 'public.user_goal_contributions', 'public.user_goals', 'public.user_plan_transaction_links', 'public.user_plans', 'public.user_settings', 'public.user_smart_inbox', 'public.user_streaks', 'public.user_subscriptions', 'public.user_sync_state', 'public.user_transactions', 'public.user_xp_levels']::regclass[]) order by t.rel loop
    execute format('alter table %s %s row level security', r.rel, case when r.rls then 'enable' else 'disable' end);
    execute format('alter table %s %s row level security', r.rel, case when r.force_rls then 'force' else 'no force' end);
  end loop;
end
$flags$;

-- (4b) ACLs of the reviewed set: the two legacy erasure function EXECUTEs, all 45 application TRUNCATE
--      table ACLs and the three direct-DML table column ACLs (rate limits, idempotency, sync state). Delta algorithm on (grantee, grantor, privilege, grant option) tuples with
--      NULL read as acldefault(owner): revoke tuples that should not exist, grant tuples that should. A tuple whose
--      grantor is not the object owner cannot be reproduced here -> refuse (unsupported preexisting metadata).
--      Grants TO account_fence_owner are left for DROP OWNED below.
create temp table rb_obj (
  kind text not null, rel text, col text, fn text, owner_oid oid not null, cur aclitem[], des aclitem[]
) on commit drop;
insert into rb_obj
select 'function', null, null, f.fn_identity, p.proowner,
       coalesce(p.proacl, acldefault('f', p.proowner)), coalesce(f.fn_acl, acldefault('f', p.proowner))
  from rb_fn f join pg_proc p on p.oid = to_regprocedure(f.fn_identity)
 where p.oid = any (array[to_regprocedure('public.purge_user_data(uuid)'),
                          to_regprocedure('public.capture_history_forget_owner(uuid)')]);
insert into rb_obj
select 'table', t.rel, null, null, c.relowner,
       coalesce(c.relacl, acldefault('r', c.relowner)), coalesce(t.rel_acl, acldefault('r', c.relowner))
  from rb_tbl t join pg_class c on c.oid = t.rel::regclass
 where c.oid = any (array['public.account_purge_queue'::regclass,'public.admin_users'::regclass,'public.ai_request_idempotency'::regclass,'public.announcement_admin_audit'::regclass,'public.backups'::regclass,'public.capture_devices'::regclass,'public.capture_fingerprints'::regclass,'public.capture_install_owner_history'::regclass,'public.capture_rate_limits'::regclass,'public.entitlement_events'::regclass,'public.feature_flag_admin_audit'::regclass,'public.feature_flag_overrides'::regclass,'public.financial_import_runs'::regclass,'public.gamification_awarded_transactions'::regclass,'public.metrics_rate_limits'::regclass,'public.notification_logs'::regclass,'public.notification_retry_queue'::regclass,'public.processed_captures'::regclass,'public.profiles'::regclass,'public.referral_admin_audit'::regclass,'public.referral_codes'::regclass,'public.referral_reward_grants'::regclass,'public.referral_reward_progress'::regclass,'public.referral_reward_rules'::regclass,'public.referrals'::regclass,'public.sender_bank_mappings'::regclass,'public.user_accounts'::regclass,'public.user_achievements'::regclass,'public.user_bill_payments'::regclass,'public.user_budgets'::regclass,'public.user_cards'::regclass,'public.user_categories'::regclass,'public.user_engagement_events'::regclass,'public.user_entitlement_state'::regclass,'public.user_goal_contributions'::regclass,'public.user_goals'::regclass,'public.user_plan_transaction_links'::regclass,'public.user_plans'::regclass,'public.user_settings'::regclass,'public.user_smart_inbox'::regclass,'public.user_streaks'::regclass,'public.user_subscriptions'::regclass,'public.user_sync_state'::regclass,'public.user_transactions'::regclass,'public.user_xp_levels'::regclass]);
insert into rb_obj
select 'column', k.rel, k.col, null, c.relowner, coalesce(a.attacl, '{}'::aclitem[]), coalesce(m.acl, '{}'::aclitem[])
  from (select regexp_replace(m1.identity, '\.[^.]*$', '') as rel, substring(m1.identity from '[^.]*$') as col
          from rb_misc m1 where m1.kind = 'column'
        union
        select a1.attrelid::regclass::text, a1.attname::text from pg_attribute a1
         where a1.attrelid in (select c1.oid from pg_class c1 where c1.relnamespace = 'public'::regnamespace and c1.relkind in ('r','p'))
           and a1.attnum > 0 and not a1.attisdropped and a1.attacl is not null) k
  join pg_class c on c.oid = k.rel::regclass
  left join pg_attribute a on a.attrelid = c.oid and a.attname = k.col
  left join rb_misc m on m.kind = 'column' and m.identity = k.rel || '.' || k.col
 where c.oid = any(array['public.capture_rate_limits'::regclass, 'public.ai_request_idempotency'::regclass, 'public.user_sync_state'::regclass]);

do $acl$
declare x record; v_grantee text;
begin
  -- Executor/grantor assumption is explicit: each replayed object's owner must BE the recorded
  -- migration executor. A superuser replay then records that owner's grantor; a non-superuser acts as
  -- itself, the owner. No implicit choice among membership-derived grant options is accepted.
  if exists (select 1 from rb_obj where owner_oid <> current_user::regrole::oid) then
    raise exception 'rollback refused: replay object owner differs from approved executor' using errcode = 'QD099';
  end if;
  -- refuse anything that is not reproducible by the owner
  for x in
    with c as (select o.*, e.grantee, e.grantor, e.privilege_type, e.is_grantable from rb_obj o, lateral aclexplode(o.cur) e),
         d as (select o.*, e.grantee, e.grantor, e.privilege_type, e.is_grantable from rb_obj o, lateral aclexplode(o.des) e),
         delta as (
           (select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from c
            except select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from d)
           union all
           (select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from d
            except select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from c))
    select * from delta
     where grantor <> owner_oid
       and grantee <> (select oid from pg_roles where rolname = 'account_fence_owner')
  loop
    raise exception 'rollback refused: grant chain not reproducible by the owner (grantor %, privilege %)',
      x.grantor::regrole, x.privilege_type using errcode = 'QD099';
  end loop;

  -- revoke what should not exist (not grants to the narrow owner: DROP OWNED removes those)
  for x in
    with c as (select o.*, e.grantee, e.grantor, e.privilege_type, e.is_grantable from rb_obj o, lateral aclexplode(o.cur) e),
         d as (select o.*, e.grantee, e.grantor, e.privilege_type, e.is_grantable from rb_obj o, lateral aclexplode(o.des) e)
    select * from (
      select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from c
      except select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from d) q
     where grantee <> (select oid from pg_roles where rolname = 'account_fence_owner')
  loop
    v_grantee := case when x.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(x.grantee)) end;
    execute case x.kind
      when 'function' then format('revoke %s on function %s from %s', x.privilege_type, x.fn, v_grantee)
      when 'table'    then format('revoke %s on table %s from %s', x.privilege_type, x.rel, v_grantee)
      else format('revoke %s (%I) on table %s from %s', x.privilege_type, x.col, x.rel, v_grantee) end;
  end loop;

  -- grant what should exist
  for x in
    with c as (select o.*, e.grantee, e.grantor, e.privilege_type, e.is_grantable from rb_obj o, lateral aclexplode(o.cur) e),
         d as (select o.*, e.grantee, e.grantor, e.privilege_type, e.is_grantable from rb_obj o, lateral aclexplode(o.des) e)
    select * from (
      select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from d
      except select kind, rel, col, fn, owner_oid, grantee, grantor, privilege_type, is_grantable from c) q
  loop
    v_grantee := case when x.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(x.grantee)) end;
    execute case x.kind
      when 'function' then format('grant %s on function %s to %s%s', x.privilege_type, x.fn, v_grantee, case when x.is_grantable then ' with grant option' else '' end)
      when 'table'    then format('grant %s on table %s to %s%s', x.privilege_type, x.rel, v_grantee, case when x.is_grantable then ' with grant option' else '' end)
      else format('grant %s (%I) on table %s to %s%s', x.privilege_type, x.col, x.rel, v_grantee, case when x.is_grantable then ' with grant option' else '' end) end;
  end loop;
end
$acl$;

-- Column-level and non-public grants made to the narrow owner are removed with DROP OWNED below. This includes the
-- 2026-10-24 additions: SELECT (user_id, provider, provider_id, identity_data) on auth.identities, USAGE on schema
-- extensions and EXECUTE on extensions.gen_random_bytes(integer); their ACLs are compared with the snapshot in section 6.
-- auth.users(id), schema auth and auth.uid() privileges granted to account_fence_owner, and the transient
-- CREATE on public, are covered by that DROP OWNED (they are grants TO the role); section 6 compares the
-- remaining ACLs of those objects with the snapshot.

-- 5. Fence entry points, schema, role.

-- D5/contract section 8: remove the two pg_cron jobs and the worker dispatcher added by fence.sql section 11.
-- Guarded like the schedule itself: nothing happens without pg_cron, and an absent job name is not an error
-- (cron.unschedule raises for an unknown job, so existence is tested first; 0112 convention).
-- account_fence.purge_expired_deletion_records dies with the schema in the DROP OWNED below.
do $cron$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'account-deletion-worker') then
      perform cron.unschedule('account-deletion-worker');
    end if;
    if exists (select 1 from cron.job where jobname = 'account-deletion-purge-expired') then
      perform cron.unschedule('account-deletion-purge-expired');
    end if;
  end if;
end
$cron$;
drop function public.run_account_deletion_worker();

drop function public.account_deletion_reserve_material(text, text);
drop function public.account_deletion_dispose_material(text);
drop function public.account_deletion_read_material(text);
drop function public.account_deletion_find_accepted(text);
drop function public.account_deletion_issue_challenge(uuid);
drop function public.account_deletion_read_challenge(uuid, text);
drop function public.account_deletion_apple_subject(uuid);
drop function public.account_deletion_accept(text, uuid, text, bigint, text, text, text);
drop function public.account_deletion_fence_attempt(text);
drop function public.account_deletion_claim_lease(text, integer, uuid);
drop function public.account_deletion_heartbeat(uuid, uuid, integer, integer);
drop function public.account_deletion_begin_step(uuid, uuid, integer, text);
drop function public.account_deletion_complete_step(uuid, uuid, integer, text);
drop function public.account_deletion_record_failure(uuid, uuid, integer, text, text, boolean, bigint);
drop function public.account_deletion_complete_job(uuid, uuid, integer, bigint);
drop function public.account_deletion_get_receipt(text);
drop function public.account_deletion_purge(uuid, uuid, integer);
drop owned by account_fence_owner cascade;   -- schema account_fence and every grant TO the role
drop role account_fence_owner;

-- 6. Post-condition, against the temp copies of the snapshot (the account_fence snapshot died with the schema).
--    Catalog identity: function owners and definitions, table owners and row-security / FORCE flags, default
--    privileges, absence of every object the fence added. Effective equivalence: ACLs. Anything else: refuse.
do $cmp$
declare v text;
begin
  if to_regclass('pg_temp.rb_fn') is null or to_regclass('pg_temp.rb_tbl') is null or to_regclass('pg_temp.rb_misc') is null then
    raise exception 'rollback post-condition failed: comparison evidence did not survive' using errcode = 'QD098';
  end if;
  -- function set, owners, definitions
  select string_agg(x.k, ', ') into v from (
    select 'missing:' || f.fn_identity as k from rb_fn f where to_regprocedure(f.fn_identity) is null
    union all
    select 'unknown:' || p.oid::regprocedure::text from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
       and not exists (select 1 from rb_fn f where to_regprocedure(f.fn_identity) = p.oid)
    union all
    select 'owner:' || f.fn_identity from rb_fn f join pg_proc p on p.oid = to_regprocedure(f.fn_identity)
     where pg_get_userbyid(p.proowner) <> f.fn_owner
    union all
    select 'definition:' || f.fn_identity from rb_fn f
     where to_regprocedure(f.fn_identity) is not null
       and pg_get_functiondef(to_regprocedure(f.fn_identity)) is distinct from f.fn_def
    union all
    select 'acl:' || f.fn_identity from rb_fn f join pg_proc p on p.oid = to_regprocedure(f.fn_identity)
     where (select coalesce(array_agg(format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) order by format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable)), '{}')
              from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) e)
           is distinct from
           (select coalesce(array_agg(format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) order by format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable)), '{}')
              from aclexplode(coalesce(f.fn_acl, acldefault('f', p.proowner))) e)
  ) x;
  if v is not null then raise exception 'rollback post-condition failed (functions): %', v using errcode = 'QD098'; end if;

  -- tables
  select string_agg(x.k, ', ') into v from (
    select 'missing:' || t.rel as k from rb_tbl t where to_regclass(t.rel) is null
    union all
    select 'unknown:' || c.oid::regclass::text from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
       and not exists (select 1 from rb_tbl t where to_regclass(t.rel) = c.oid)
    union all
    select 'state:' || t.rel from rb_tbl t join pg_class c on c.oid = to_regclass(t.rel)
     where pg_get_userbyid(c.relowner) <> t.rel_owner or c.relrowsecurity <> t.rls or c.relforcerowsecurity <> t.force_rls
    union all
    select 'acl:' || t.rel from rb_tbl t join pg_class c on c.oid = to_regclass(t.rel)
     where (select coalesce(array_agg(format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) order by format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable)), '{}')
              from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) e)
           is distinct from
           (select coalesce(array_agg(format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) order by format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable)), '{}')
              from aclexplode(coalesce(t.rel_acl, acldefault('r', c.relowner))) e)
  ) x;
  if v is not null then raise exception 'rollback post-condition failed (tables): %', v using errcode = 'QD098'; end if;

  -- schemas, auth.users, auth.uid(), column ACLs, default privileges
  select string_agg(x.k, ', ') into v from (
    select m.kind || ':' || m.identity as k from rb_misc m
     where m.kind in ('schema', 'relation', 'function')
       and (select coalesce(array_agg(format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) order by format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable)), '{}')
              from aclexplode(coalesce(
                case m.kind when 'schema' then (select n.nspacl from pg_namespace n where n.nspname = m.identity)
                            when 'relation' then (select c.relacl from pg_class c where c.oid = m.identity::regclass)
                            else (select p.proacl from pg_proc p where p.oid = m.identity::regprocedure) end,
                case m.kind when 'schema' then (select acldefault('n', n.nspowner) from pg_namespace n where n.nspname = m.identity)
                            when 'relation' then (select acldefault('r', c.relowner) from pg_class c where c.oid = m.identity::regclass)
                            else (select acldefault('f', p.proowner) from pg_proc p where p.oid = m.identity::regprocedure) end)) e)
           is distinct from
           (select coalesce(array_agg(format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) order by format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable)), '{}')
              from aclexplode(coalesce(m.acl,
                case m.kind when 'schema' then (select acldefault('n', n.nspowner) from pg_namespace n where n.nspname = m.identity)
                            when 'relation' then (select acldefault('r', c.relowner) from pg_class c where c.oid = m.identity::regclass)
                            else (select acldefault('f', p.proowner) from pg_proc p where p.oid = m.identity::regprocedure) end)) e)
    union all
    select 'column:' || a.attrelid::regclass::text || '.' || a.attname from pg_attribute a
     where a.attrelid in (select c1.oid from pg_class c1 where c1.relnamespace = 'public'::regnamespace and c1.relkind in ('r','p'))
       and a.attnum > 0 and not a.attisdropped
       and (select coalesce(array_agg(a2::text order by a2::text), '{}') from unnest(coalesce(a.attacl, '{}'::aclitem[])) a2)
           is distinct from
           (select coalesce(array_agg(a2::text order by a2::text), '{}') from rb_misc m, unnest(coalesce(m.acl, '{}'::aclitem[])) a2
             where m.kind = 'column' and m.identity = a.attrelid::regclass::text || '.' || a.attname)
    union all
    select 'default_acl' where exists (
      select 1 from ((select d.defaclrole::regrole::text || ':' || d.defaclnamespace::regnamespace::text || ':' || d.defaclobjtype::text as k2,
                             (select array_agg(y::text order by y::text) from unnest(d.defaclacl) y) as a2 from pg_default_acl d
                      except select m.identity, (select array_agg(y::text order by y::text) from unnest(m.acl) y) from rb_misc m where m.kind = 'default_acl')
                     union all
                     (select m.identity, (select array_agg(y::text order by y::text) from unnest(m.acl) y) from rb_misc m where m.kind = 'default_acl'
                      except select d.defaclrole::regrole::text || ':' || d.defaclnamespace::regnamespace::text || ':' || d.defaclobjtype::text,
                                    (select array_agg(y::text order by y::text) from unnest(d.defaclacl) y) from pg_default_acl d)) z)
  ) x;
  if v is not null then raise exception 'rollback post-condition failed (misc): %', v using errcode = 'QD098'; end if;

  -- no fence residue
  select string_agg(x.k, ', ') into v from (
    select 'policy:' || polname || ' on ' || polrelid::regclass::text as k from pg_policy where polname like 'account\_fence\_%' or polname like 'a0\_%'
    union all select 'trigger:' || tgname || ' on ' || tgrelid::regclass::text from pg_trigger where not tgisinternal and tgname like 'a0\_%'
    union all select 'schema:account_fence' where to_regnamespace('account_fence') is not null
    union all select 'role:account_fence_owner' where exists (select 1 from pg_roles where rolname = 'account_fence_owner')
    union all select 'function:' || p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'public'::regnamespace and (p.proname like 'account\_deletion\_%' or p.proname = 'run_account_deletion_worker')
  ) x;
  if v is not null then raise exception 'rollback post-condition failed (residue): %', v using errcode = 'QD098'; end if;
end
$cmp$;

commit;

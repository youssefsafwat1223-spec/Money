-- Approved 30-day account deletion policy.
--
-- request_account_deletion(): user-invoked, schedules deletion 30 days out.
-- Idempotent — a second call while already scheduled returns the existing
-- date rather than pushing the clock forward.
--
-- cancel_account_deletion(): user-invoked, clears the pending schedule.
--
-- purge_user_data(p_user_id): service-role-only. Hard-deletes every row the
-- user owns, child tables before parents, mirroring the exact table list
-- documented in docs/USER_DELETION_DECISION_BRIEF.md. Does NOT delete the
-- Storage backup blob or the auth.users row — those require the Storage API
-- and the Auth Admin API respectively, neither reachable from SQL, and are
-- performed by the scheduled worker (supabase/functions/purge-scheduled-deletions)
-- immediately before/after calling this function.

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

create or replace function public.purge_user_data(p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  delete from public.user_bill_payments where user_id = p_user_id;
  delete from public.user_goal_contributions where user_id = p_user_id;
  delete from public.user_plan_transaction_links where user_id = p_user_id;
  delete from public.user_subscriptions where user_id = p_user_id;
  delete from public.user_goals where user_id = p_user_id;
  delete from public.user_plans where user_id = p_user_id;
  delete from public.user_budgets where user_id = p_user_id;
  delete from public.user_transactions where user_id = p_user_id;
  delete from public.user_accounts where user_id = p_user_id;
  delete from public.user_smart_inbox where user_id = p_user_id;
  delete from public.sender_bank_mappings where user_id = p_user_id;
  delete from public.capture_devices where user_id = p_user_id;
  delete from public.backups where user_id = p_user_id;
  delete from public.profiles where id = p_user_id;
end;
$$;

revoke all on function public.request_account_deletion() from public, anon;
grant execute on function public.request_account_deletion() to authenticated;

revoke all on function public.cancel_account_deletion() from public, anon;
grant execute on function public.cancel_account_deletion() to authenticated;

revoke all on function public.purge_user_data(uuid) from public, anon, authenticated;
grant execute on function public.purge_user_data(uuid) to service_role;

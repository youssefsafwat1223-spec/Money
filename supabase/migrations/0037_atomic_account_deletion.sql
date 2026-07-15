-- Batch 1: prevent the final-account deletion check from racing two clients.
-- SECURITY INVOKER keeps the existing owner-only user_accounts RLS authoritative.

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

revoke all on function public.delete_user_account_safely(uuid) from public;
revoke all on function public.delete_user_account_safely(uuid) from anon;
grant execute on function public.delete_user_account_safely(uuid) to authenticated;

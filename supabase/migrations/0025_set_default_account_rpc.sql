-- Phase 2: atomic default-account switch.
--
-- SECURITY INVOKER (not DEFINER): the existing user_accounts RLS policy
-- (user_accounts_owner, from 0020) already restricts UPDATE to
-- user_id = auth.uid() for both the USING and WITH CHECK clauses, so running
-- as the invoking role gives no extra privilege the caller doesn't already
-- have — it just makes the two updates atomic (one function call = one
-- transaction) instead of two separate round trips from the client.

-- Preflight: refuse to add the partial unique index if any user already has
-- more than one active default (would violate the index on creation).
do $$
declare
  v_violations integer;
begin
  select count(*) into v_violations from (
    select user_id
    from public.user_accounts
    where is_default = true and deleted_at is null
    group by user_id
    having count(*) > 1
  ) dupes;

  if v_violations > 0 then
    raise exception
      'set_default_account migration blocked: % user(s) already have more than one active default account',
      v_violations;
  end if;
end $$;

create unique index if not exists uidx_user_accounts_one_default
  on public.user_accounts(user_id)
  where is_default = true and deleted_at is null;

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

revoke all on function public.set_default_account(uuid) from public;
grant execute on function public.set_default_account(uuid) to authenticated;

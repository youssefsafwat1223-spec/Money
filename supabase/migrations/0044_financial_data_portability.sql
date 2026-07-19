-- Qirsh financial data portability. Additive only; legacy backups and the
-- processed_captures relay remain untouched.

create table if not exists public.user_categories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text null,
  key text not null,
  name_ar text not null,
  icon text not null,
  color text not null,
  is_income boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null
);

create unique index if not exists user_categories_user_key_uidx
  on public.user_categories(user_id, key);
create unique index if not exists user_categories_user_local_uidx
  on public.user_categories(user_id, local_id) where local_id is not null;
alter table public.user_categories enable row level security;
drop policy if exists user_categories_owner on public.user_categories;
create policy user_categories_owner on public.user_categories for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop trigger if exists trg_user_categories_updated_at on public.user_categories;
create trigger trg_user_categories_updated_at before update on public.user_categories
  for each row execute function public.set_updated_at();

alter table public.user_transactions
  add column if not exists user_category_id uuid null
    references public.user_categories(id) on delete set null;
alter table public.user_budgets
  add column if not exists user_category_id uuid null
    references public.user_categories(id) on delete set null;

create or replace function public.validate_user_category_ownership()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.user_category_id is not null and not exists (
    select 1 from public.user_categories c
    where c.id = new.user_category_id and c.user_id = new.user_id
      and c.deleted_at is null
  ) then
    raise exception 'category ownership mismatch' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_user_transactions_category_ownership on public.user_transactions;
create trigger trg_user_transactions_category_ownership before insert or update
  on public.user_transactions for each row
  execute function public.validate_user_category_ownership();
drop trigger if exists trg_user_budgets_category_ownership on public.user_budgets;
create trigger trg_user_budgets_category_ownership before insert or update
  on public.user_budgets for each row
  execute function public.validate_user_category_ownership();

create table if not exists public.financial_import_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  import_id text not null,
  mode text not null check (mode in ('merge', 'replace')),
  status text not null default 'processing'
    check (status in ('processing', 'completed', 'failed')),
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz null,
  unique(user_id, import_id)
);
alter table public.financial_import_runs enable row level security;
drop policy if exists financial_import_runs_owner on public.financial_import_runs;
create policy financial_import_runs_owner on public.financial_import_runs for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop trigger if exists trg_financial_import_runs_updated_at on public.financial_import_runs;
create trigger trg_financial_import_runs_updated_at before update on public.financial_import_runs
  for each row execute function public.set_updated_at();

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
    raise exception 'package was already imported with a different mode' using errcode='22023';
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
    values(uid,r->>'record_id',r->>'name',upper(r->>'currency'),coalesce(nullif(r->>'type',''),'bank'),
      nullif(r->>'initial_balance','')::numeric,nullif(r->>'current_balance','')::numeric,
      coalesce(nullif(r->>'is_default','')::boolean,false),coalesce(nullif(r->>'sort_order','')::int,0),
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
      coalesce(nullif(r->>'direction',''),'unknown'),
      case coalesce(r->>'type','unknown') when 'payment' then 'expense' when 'withdrawal' then 'expense'
        when 'income' then 'income' when 'refund' then 'refund' when 'transfer' then 'transfer' else 'unknown' end,
      nullif(r->>'merchant',''),nullif(r->>'note',''),
      case when category_server_id is null then nullif(r->>'category_key','') else null end,
      category_server_id,(r->>'occurred_at')::timestamptz,'import',1,
      jsonb_build_object('transaction_source','imported','portable_record_id',r->>'record_id'),
      coalesce(nullif(r->>'status',''),'confirmed'),nullif(r->>'foreign_amount','')::numeric,
      nullif(r->>'foreign_currency',''),nullif(r->>'comparison_timestamp','')::timestamptz,
      coalesce(nullif(r->>'comparison_timestamp_source',''),'received_at'),null)
    on conflict(user_id,client_request_id) where client_request_id is not null do update set
      server_account_id=excluded.server_account_id,amount=excluded.amount,currency=excluded.currency,
      direction=excluded.direction,transaction_type=excluded.transaction_type,merchant=excluded.merchant,
      description=excluded.description,category_id=excluded.category_id,
      user_category_id=excluded.user_category_id,occurred_at=excluded.occurred_at,
      status=excluded.status,deleted_at=null;
    get diagnostics affected = row_count; imported_count := imported_count + affected;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_package->'budgets','[]'::jsonb)) loop
    select id into account_server_id from public.user_accounts where user_id=uid and local_id=nullif(r->>'account_record_id','') limit 1;
    select id into category_server_id from public.user_categories where user_id=uid and (local_id=nullif(r->>'category_record_id','') or key=nullif(r->>'category_key','')) limit 1;
    insert into public.user_budgets(user_id,local_id,local_account_id,server_account_id,
      category_id,user_category_id,amount,period,start_date,is_active,alert_80_sent,
      alert_100_sent,show_on_header,deleted_at)
    values(uid,r->>'record_id',nullif(r->>'account_record_id',''),account_server_id,
      coalesce(case when category_server_id is null then nullif(r->>'category_key','') end,'other'),
      category_server_id,(r->>'amount')::numeric,r->>'period',(r->>'start_date')::timestamptz,
      coalesce(nullif(r->>'is_active','')::boolean,true),coalesce(nullif(r->>'alert_80_sent','')::boolean,false),
      coalesce(nullif(r->>'alert_100_sent','')::boolean,false),coalesce(nullif(r->>'show_on_header','')::boolean,false),null)
    on conflict(user_id,local_id) where local_id is not null do update set
      server_account_id=excluded.server_account_id,category_id=excluded.category_id,
      user_category_id=excluded.user_category_id,amount=excluded.amount,period=excluded.period,
      start_date=excluded.start_date,is_active=excluded.is_active,deleted_at=null;
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
      coalesce(nullif(r->>'type',''),'subscription'),coalesce(nullif(r->>'frequency',''),'monthly'),
      coalesce(nullif(r->>'next_due_date','')::timestamptz,now()),
      coalesce(nullif(r->>'reminder_on','')::boolean,true),coalesce(nullif(r->>'is_confirmed','')::boolean,false),
      nullif(r->>'custom_interval_days','')::int,nullif(r->>'note',''),coalesce(nullif(r->>'status',''),'active'),
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
      coalesce(nullif(r->>'status',''),'active'),nullif(r->>'auto_save_amount','')::numeric,
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
      coalesce(nullif(r->>'status',''),'active'),nullif(r->>'icon',''),
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
  -- The function call is atomic. The failed status cannot be persisted without
  -- also committing partial financial writes, so the whole call rolls back.
  raise;
end;
$$;

grant execute on function public.delete_user_category_safely(uuid) to authenticated;
grant execute on function public.import_financial_package(text,text,jsonb) to authenticated;
revoke execute on function public.delete_user_category_safely(uuid) from anon;
revoke execute on function public.import_financial_package(text,text,jsonb) from anon;

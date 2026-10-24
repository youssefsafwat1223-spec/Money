-- acl.sql — POST-fence catalog ASSERTIONS.
-- Run only on the disposable database after fence.sql (migration 0117). Raises on any violation.
\set ON_ERROR_STOP on
do $$
declare
  r record;
  n integer;
  tbl text;
begin
  -- 1. new schemas are private
  for r in select s.nspname from pg_namespace s where s.nspname in ('account_fence','account_fence_impl') loop
    if has_schema_privilege('anon', r.nspname, 'USAGE') then
      raise exception 'anon has USAGE on %', r.nspname;
    end if;
  end loop;
  if not exists (select 1 from pg_roles where rolname = 'authenticator'
                  and coalesce(array_to_string(rolconfig, ','), '') !~ 'account_fence') then
    raise exception 'authenticator config exposes a fence schema (or role missing)';
  end if;

  -- 2. fence tables: no API-role privileges at all, RLS forced
  foreach tbl in array array['deletion_job','deletion_scope','deletion_receipt','deletion_material',
                             'deletion_attempt_tombstone','deletion_challenge','erasure_ctx'] loop
    if has_table_privilege('authenticated', 'account_fence.' || tbl, 'SELECT,INSERT,UPDATE,DELETE')
       or has_table_privilege('anon', 'account_fence.' || tbl, 'SELECT,INSERT,UPDATE,DELETE')
       or has_table_privilege('service_role', 'account_fence.' || tbl, 'SELECT,INSERT,UPDATE,DELETE') then
      raise exception 'API role has privileges on account_fence.%', tbl;
    end if;
    if not (select c.relforcerowsecurity from pg_class c where c.oid = ('account_fence.' || tbl)::regclass) then
      raise exception 'RLS not forced on account_fence.%', tbl;
    end if;
  end loop;

  -- 3. service RPCs: service_role only
  for r in select p.oid, p.proname from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname like 'account_deletion\_%' loop
    if has_function_privilege('anon', r.oid, 'EXECUTE') or has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      raise exception 'public.% executable by anon/authenticated', r.proname;
    end if;
    if not has_function_privilege('service_role', r.oid, 'EXECUTE') then
      raise exception 'public.% not executable by service_role', r.proname;
    end if;
  end loop;
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname like 'account_deletion\_%';
  if n <> 17 then raise exception 'expected 17 account_deletion_* RPCs, found %', n; end if;

  -- 4. no blanket erasure bypass
  if has_function_privilege('service_role', 'public.purge_user_data(uuid)', 'EXECUTE') then
    raise exception 'service_role can still call purge_user_data directly';
  end if;
  if has_table_privilege('service_role', 'public.capture_rate_limits', 'INSERT,UPDATE,DELETE')
     or has_table_privilege('service_role', 'public.ai_request_idempotency', 'INSERT,UPDATE,DELETE') then
    raise exception 'service_role still has direct DML on a fenced counter/ledger table';
  end if;

  -- 5. account_fence function ACL: ONLY the three authenticated self helpers are reachable by an API role
  --    (fence.sql section 9 grants the admission helpers to the migration role alone); anon, service_role and
  --    PUBLIC reach nothing, and authenticated reaches nothing else.
  for r in select p.oid, p.proname from pg_proc p where p.pronamespace = 'account_fence'::regnamespace loop
    if has_function_privilege('anon', r.oid, 'EXECUTE')
       or has_function_privilege('service_role', r.oid, 'EXECUTE')
       or has_function_privilege(0, r.oid, 'EXECUTE') then
      raise exception 'account_fence.% is callable by anon/service_role/PUBLIC', r.proname;
    end if;
    if r.proname not in ('admit_self','admit_check_self','is_pending_self')
       and has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      raise exception 'account_fence.% is callable by authenticated', r.proname;
    end if;
  end loop;

  -- 6. no wrapper/impl-schema design in this draft: bodies are restated in place (fence.sql section 5), so the
  --    account_fence_impl schema must not exist, and no restated public function may have GAINED anon/authenticated
  --    EXECUTE relative to the pre-fence snapshot (a NULL snapshot ACL means the PUBLIC default, i.e. executable).
  if to_regnamespace('account_fence_impl') is not null then
    raise exception 'unexpected schema account_fence_impl';
  end if;
  for r in select p.oid, s.fn_identity, s.fn_acl
             from account_fence.rollback_function_snapshot s join pg_proc p on p.oid = to_regprocedure(s.fn_identity) loop
    if has_function_privilege('anon', r.oid, 'EXECUTE')
       and r.fn_acl is not null
       and not exists (select 1 from aclexplode(r.fn_acl) a
                        where a.privilege_type = 'EXECUTE' and a.grantee in (0, (select oid from pg_roles where rolname = 'anon'))) then
      raise exception 'anon gained EXECUTE on %', r.fn_identity;
    end if;
    if has_function_privilege('authenticated', r.oid, 'EXECUTE')
       and r.fn_acl is not null
       and not exists (select 1 from aclexplode(r.fn_acl) a
                        where a.privilege_type = 'EXECUTE' and a.grantee in (0, (select oid from pg_roles where rolname = 'authenticated'))) then
      raise exception 'authenticated gained EXECUTE on %', r.fn_identity;
    end if;
  end loop;

  -- 7. restrictive policies on all three commands for the five client tables
  foreach tbl in array array['profiles','backups','notification_logs','feature_flag_overrides','financial_import_runs'] loop
    select count(*) into n from pg_policies
     where schemaname = 'public' and tablename = tbl and permissive = 'RESTRICTIVE' and policyname like 'account\_fence\_%';
    if n <> 3 then raise exception 'expected 3 restrictive fence policies on %, found %', tbl, n; end if;
  end loop;

  -- 8. guard triggers present and named to fire first
  foreach tbl in array array['capture_devices','processed_captures','notification_logs','referrals','referral_codes',
      'referral_reward_progress','referral_reward_grants','user_entitlement_state','entitlement_events',
      'referral_reward_rules','referral_admin_audit'] loop
    if not exists (select 1 from pg_trigger t where t.tgrelid = ('public.' || tbl)::regclass
                    and t.tgname = 'a0_account_fence_guard' and not t.tgisinternal) then
      raise exception 'missing guard trigger on %', tbl;
    end if;
  end loop;

  -- 9. hooked authorities really contain the admission call
  if position('account_fence.admit' in pg_get_functiondef('public.stamp_sync_seq()'::regprocedure)) = 0 then
    raise exception 'stamp_sync_seq has no admission hook';
  end if;
  if position('account_fence.admit' in pg_get_functiondef('public.sync_lock_epoch()'::regprocedure)) = 0 then
    raise exception 'sync_lock_epoch has no admission hook';
  end if;

  -- 10. a pending marker exists as a unique partial index
  if not exists (select 1 from pg_indexes where schemaname = 'account_fence'
                  and indexname = 'deletion_job_one_open_per_uid') then
    raise exception 'pending uniqueness index missing';
  end if;

  raise notice 'acl.sql: all assertions passed';
end $$;

-- 11. F3 existence oracle: an authenticated API caller naming ANOTHER user's id in a strict owner column is refused with
--     42501 (message owner_column_mismatch) by the guard BEFORE admission, so QD001/QD002/55P03 are never observable.
--     The ids are random: the guard fires before any FK check, so no Auth user needs to exist.
do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_state text;
  v_msg text;
begin
  perform set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_a), true);
  begin
    set local role authenticated;
    insert into public.profiles (id) values (v_b);
    v_state := 'no error';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  reset role;
  if v_state is distinct from '42501' or v_msg is distinct from 'owner_column_mismatch' then
    raise exception 'F3: cross-user profiles insert gave % (%), expected 42501 owner_column_mismatch', v_state, v_msg;
  end if;
  raise notice 'acl.sql: F3 oracle check passed';
end $$;

-- 12. F2: the legacy purge queue is empty (apply preflight QD096) and the legacy cron job is unscheduled.
do $$
begin
  if exists (select 1 from public.account_purge_queue) then
    raise exception 'F2: public.account_purge_queue is not empty';
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'purge-scheduled-deletions-job') then
    raise exception 'F1: legacy purge-scheduled-deletions-job is still scheduled';
  end if;
end $$;

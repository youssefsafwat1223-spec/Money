-- acl.sql — POST-fence catalog ASSERTIONS. NOT EXECUTED by its author.
-- Run only on the disposable database after fence.sql. Raises on any violation.
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
  if n <> 14 then raise exception 'expected 14 account_deletion_* RPCs, found %', n; end if;

  -- 4. no blanket erasure bypass
  if has_function_privilege('service_role', 'public.purge_user_data(uuid)', 'EXECUTE') then
    raise exception 'service_role can still call purge_user_data directly';
  end if;
  if has_table_privilege('service_role', 'public.capture_rate_limits', 'INSERT,UPDATE,DELETE')
     or has_table_privilege('service_role', 'public.ai_request_idempotency', 'INSERT,UPDATE,DELETE') then
    raise exception 'service_role still has direct DML on a fenced counter/ledger table';
  end if;

  -- 5. account_fence function ACL: only the admission helpers reach API roles
  for r in select p.oid, p.proname from pg_proc p where p.pronamespace = 'account_fence'::regnamespace loop
    if r.proname not in ('admit','admit_check','admit_many','admit_install','admit_rate_key','admit_owner_key')
       and (has_function_privilege('authenticated', r.oid, 'EXECUTE')
            or has_function_privilege('anon', r.oid, 'EXECUTE')
            or has_function_privilege('service_role', r.oid, 'EXECUTE')
            or has_function_privilege(0, r.oid, 'EXECUTE')) then
      raise exception 'account_fence.% is callable by an API role/PUBLIC', r.proname;
    end if;
  end loop;

  -- 6. every moved original is paired with a same-identity wrapper whose ACL matches
  for r in select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as idargs, p.proacl
             from pg_proc p where p.pronamespace = 'account_fence_impl'::regnamespace loop
    if not exists (select 1 from pg_proc w
                    where w.pronamespace = 'public'::regnamespace and w.proname = r.proname
                      and pg_get_function_identity_arguments(w.oid) = r.idargs) then
      raise exception 'no wrapper for moved %(%)', r.proname, r.idargs;
    end if;
    if exists (select 1 from pg_proc w
                where w.pronamespace = 'public'::regnamespace and w.proname = r.proname
                  and pg_get_function_identity_arguments(w.oid) = r.idargs
                  and w.proacl is distinct from r.proacl) then
      raise exception 'wrapper ACL differs from original for %(%)', r.proname, r.idargs;
    end if;
    if has_function_privilege('anon', r.oid, 'EXECUTE')
       and not exists (select 1 from aclexplode(r.proacl) a where a.grantee = (select oid from pg_roles where rolname = 'anon')) then
      raise exception 'anon gained EXECUTE on moved %', r.proname;
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

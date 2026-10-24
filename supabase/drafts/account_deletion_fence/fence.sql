-- account_deletion_fence v2 — additive migration for IMMEDIATE, permanent account deletion.
-- This file is migration 0117 (supabase/migrations/0117_account_deletion_fence.sql is the canonical copy; this
-- drafts/ copy is the generator's working copy and MUST stay byte-identical). The reviewed-set rollback is
-- supabase/rollback/0117_account_deletion_fence_rollback.sql (identical to rollback.sql beside this file; DECISIONS.md
-- defines what 'exact' does and does not mean there).
-- STATUS: qualified on a disposable, loopback-only Supabase stack (migrate, apply, acl, concurrency, drain, rollback
-- with an identical baseline) and reviewed by a fresh Opus 5.5 security review. Applying it to production requires the
-- owner's explicit approval. DECISIONS.md holds the decisions; inventory.md (in the unit log directory) grounds every
-- source claim.
--
-- This file is LITERAL SQL. It contains no statement that generates DDL from the catalog. The only
-- DO blocks are fail-closed ASSERTIONS (preflight at the top, effective-ACL checks at the end);
-- they read the catalog and raise, they never create or alter anything. The exceptions are the
-- guarded pg_cron blocks (section 0 snapshot insert; section 11 cron.schedule / cron.unschedule), which never generate DDL. Sections 5 (and the
-- preflight rows) were produced offline from the historical migrations by gen_rpc_bodies.py and
-- are checked in as text; the script is NOT needed to apply this file (it only lets a reviewer
-- reproduce the text byte for byte).
--
-- Sections: 0 preflight + rollback snapshot · 1 role/schema/tables · 2 admission + erasure context
-- · 3 direct-DML closure · 4 hooks · 5 restated RPC bodies with admission (E3) · 6 acceptance/lease
-- RPCs (incl. challenge issuer/reader, Apple subject lookup) · 7 erasure (E1, O4, O5) · 8 legacy route + audit
-- append-only exception · 9 ACL + ownership · 10 effective-privilege assertions · 11 retention purge function and
-- guarded pg_cron schedules and the legacy-job unschedule (skipped when pg_cron is absent).
-- 2026-10-24 owner decisions D4-D7 (DELETION-COMPLETION-CONTRACT.md; recorded in DECISIONS.md): 14-day anonymous
-- marker retention + daily purge (D5), referral/entitlement protocol retired with QD040 (D6, section 5), admin
-- self-deletion blocked with QD031 (D7). Review fixes F1-F4 (DECISIONS.md): legacy purge queue must be empty at apply
-- (QD096), a drifted legacy cron job is refused (QD097), and the legacy 30-day cron job is unscheduled and snapshotted (section 11); owner-column forgery by API roles
-- is refused with 42501 before admission (guard_owner_columns); client writes may not set install: columns; terminal failure retains Apple ciphertext 14 days (operator recovery functions).
--
-- Assumptions that MUST be proven on a real stack (E8, owner-gated) before approval:
--   * the migration role is `postgres`, owns every restated public function, may CREATE ROLE, and
--     holds GRANT OPTION on auth.users(id), schema auth and auth.uid() (needed for the narrow owner);
--       DISPROVEN on the Supabase image (postgres has USAGE on auth and EXECUTE on auth.uid() without grant option):
--       replaced by the migration-role-owned account_fence.auth_* shims (section 1, right after CREATE SCHEMA);
--   * PostgREST db-schemas does NOT expose account_fence (and nothing here relies on that: no
--     API role can execute a bypass-capable function; see the assertions in section 9);
--   * deployed pg_proc.prosrc of every restated function equals its migration text (preflight);
--   * (D5/D7, 2026-10-24) pgcrypto is installed in schema `extensions` (as the existing migrations assume:
--     generate_referral_code uses extensions.gen_random_bytes) and the migration role may GRANT USAGE on it and
--     EXECUTE on extensions.gen_random_bytes(integer) (PROVEN on the Supabase image: no warning);
--     auth.identities is read through the account_fence.auth_apple_subject shim, not through a column grant.
--   * Auth deletion performs NO UPDATE of any application row after section 7 closed every
--     reference (erase_verify); a residual reference makes the Auth delete fail closed.
--   * The narrow owner's WRITE reach is bounded by erasure predicates that are false outside an erasure
--     transaction, but its READ reach is not: the discovery SELECT policies of section 3 (capture_devices,
--     processed_captures, notification_logs, capture_install_owner_history, referrals, referral_codes, notification_retry_queue,
--     capture_fingerprints) are `using (true)` and apply at all times. That read access is a SEPARATE
--     privilege that needs its own approval (DECISIONS.md E1.4); it is not limited to erasure.
--
-- LOCK ORDER (source argument only, NOT deadlock proof): blocking account gates precede job-row locks.
-- Existing-job acceptance and completion both lock the job BEFORE challenges. A newly inserted job is not
-- visible to another transaction before commit. Install/account reverse acquisitions are TRY only.
-- Purge may wait for application rows while holding its job; domain-trigger/FK behavior still requires E8 proof.

begin;
-- Restated historical statements below use unqualified names (e.g. bump_capture_rate_limit); pin them to public.
set local search_path = public, pg_catalog;

-- ════════════════════════════════════════════════════════════════════════════
-- 0. Preflight (assertions only) and rollback snapshot
-- ════════════════════════════════════════════════════════════════════════════

do $assert$
begin
  if current_user <> 'postgres' then
    raise exception 'account_fence preflight: expected migration role postgres, got %', current_user using errcode = 'QD090';
  end if;
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'account_fence preflight: PostgreSQL 15+ required (xid8, pg_current_xact_id_if_assigned)' using errcode = 'QD090';
  end if;
  if to_regnamespace('account_fence') is not null then
    raise exception 'account_fence preflight: schema already exists (not a fresh apply)' using errcode = 'QD090';
  end if;
  if exists (select 1 from pg_roles where rolname = 'account_fence_owner') then
    raise exception 'account_fence preflight: role account_fence_owner already exists' using errcode = 'QD090';
  end if;
  if to_regclass('auth.users') is null then
    raise exception 'account_fence preflight: auth.users missing' using errcode = 'QD090';
  end if;
  if to_regclass('public.account_purge_queue') is null then
    raise exception 'account_fence preflight: public.account_purge_queue missing' using errcode = 'QD090';
  end if;
end
$assert$;

-- F1 / E5 owner policy: legacy 30-day purge work is never converted, accelerated or discarded by this migration.
-- EXCLUSIVE mode blocks every writer (the legacy worker enqueues and advances rows) for the rest of this transaction,
-- so the emptiness test below stays true until commit. Rows are NOT deleted or modified here.
lock table public.account_purge_queue in exclusive mode;
do $assert$
begin
  if exists (select 1 from public.account_purge_queue) then
    raise exception 'account_fence preflight: legacy purge work is queued or in progress in public.account_purge_queue; it needs a separate incident assessment (E5) before this migration'
      using errcode = 'QD096';
  end if;
  -- Rollback restores ONLY the exact 0065 job; a drifted production job is found here, before apply, not at rollback.
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job j where j.jobname = 'purge-scheduled-deletions-job'
                  and (j.schedule is distinct from '30 3 * * *'
                       or j.command is distinct from 'select public.run_purge_scheduled_deletions()')) then
      raise exception 'account_fence preflight: cron job purge-scheduled-deletions-job differs from migration 0065 (schedule 30 3 * * *, command select public.run_purge_scheduled_deletions()); rollback could not restore it, reconcile it first'
        using errcode = 'QD097';
    end if;
  end if;
end
$assert$;

-- >>> GENERATED:BEGIN rpc_preflight
do $chk$
declare r record; v_md5 text; v_owner text;
begin
  for r in select * from (values
    ('public.stamp_sync_seq()', 'ba8fbb974a42fb73cf9fed36bc602110', '0105_stamp_sync_seq_triggers.sql:36-60'),
    ('public.sync_lock_epoch()', '81678ce50d8302bb6e8a9f5d5d5af62f', '0107_sync_cas_rpcs.sql:179-198'),
    ('public.backups_owner_is_live()', '1d18a82bce1a84362a2ae9b9ee25be0d', '0086_backups_owner_liveness.sql:40-53'),
    ('public.request_account_deletion()', 'cd074a72f0827145e3e81b6186ffa92f', '0042_account_deletion_policy.sql:17-45'),
    ('public.cancel_account_deletion()', '6c5c878a029705164e00a8cbf1dfac7a', '0042_account_deletion_policy.sql:47-62'),
    ('public.feature_flag_audit_append_only()', 'f10a22bf9ab780435ecd03892f9549d1', '0101_feature_flag_admin_audit.sql:74-79'),
    ('public.set_default_account(uuid)', '79c44bea7ba558163f8c66a36b34d3d8', '0025_set_default_account_rpc.sql:35-67'),
    ('public.add_goal_contribution(uuid,text,text,numeric,timestamp with time zone,text)', '7855b38e41c1a98213e2d74381b1b0df', '0078_goal_contribution_exact_saved_amount.sql:36-80'),
    ('public.record_bill_payment(uuid,uuid,text,text,numeric,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,integer,text)', '64eabc9f055c54a457efd9c9a05ca09d', '0031_financial_feature_children.sql:220-265'),
    ('public.delete_bill_payment(uuid)', '7c67d920d676b850051fd909c25b2878', '0108_delete_bill_payment_idempotent.sql:22-52'),
    ('public.delete_user_account_safely(uuid)', 'b4cb58e6bb98606f38e3e74781425989', '0037_atomic_account_deletion.sql:4-68'),
    ('public.create_subscription_and_record_payment(text,text,text,numeric,text,text,text,timestamp with time zone,timestamp with time zone,uuid,text,boolean,boolean,integer,text,text,integer,integer,numeric,numeric,text,numeric,numeric,timestamp with time zone,timestamp with time zone,timestamp with time zone,integer,text)', 'c8a53eeb0bfe523233a1b8bd0843d5ce', '0041_fix_bill_payment_rpc_paid_count_overwrite.sql:20-122'),
    ('public.delete_user_category_safely(uuid)', 'cac14d6e1695c8daa18a4255c94947f5', '0044_financial_data_portability.sql:82-100'),
    ('public.import_financial_package(text,text,jsonb)', 'f160f3c38f6fa73239ec3d272bf2db77', '0051_fix_import_rpc_budget_schema.sql:1-249'),
    ('public.mark_onboarding_completed()', 'c6afaa88b52afaf43e1879fb87242e5a', '0043_profile_onboarding_completion.sql:21-44'),
    ('public.record_engagement_event(uuid,text,timestamp with time zone,text,integer)', 'e9b10e0c75a1699d7d28febfa83d622f', '0070_engagement_events.sql:57-145'),
    ('public.record_metric(text,text)', 'd38dd967625dbea6370ac8bd30385955', '0072_backend_security_hardening.sql:76-110'),
    ('public.commit_backup_generation(text,text,integer,bigint,text,text,text)', 'cd88648fac26b202ff511e0631dd6c67', '0076_backup_generation_cas.sql:25-119'),
    ('public.get_referral_summary()', '5d511b088a0335bc84c97b197faae2df', '0083_referral_rewards.sql:906-959'),
    ('public.ensure_referral_code(uuid)', '7e6cb223413b90160f9505e2014b2258', '0083_referral_rewards.sql:462-503'),
    ('public.apply_entitlement_mutation(text,uuid,text,text,text,integer,text,uuid,integer,integer,uuid,text)', '363c5c7d7695350fc43be7a43544e424', '0085_concurrency_absent_row_locking.sql:58-223'),
    ('public.apply_referral_code(text)', 'a1c4ea44634c6073042ed5c2b5f405e4', '0083_referral_rewards.sql:833-886'),
    ('public.request_referral_qualification()', 'd6cc3c1a3b3cbe6e54315c8415092e0a', '0083_referral_rewards.sql:889-903'),
    ('public.qualify_referral_internal(uuid)', '6bb19a1eee7e8c425ec838a0eba54167', '0085_concurrency_absent_row_locking.sql:226-402'),
    ('public.admin_mutate_entitlement(text,uuid,uuid,text,text,text,integer)', '12710e769a439e9b3009dad6a5a1586b', '0083_referral_rewards.sql:1143-1221'),
    ('public.admin_reject_referral(text,uuid,uuid,text)', 'e64aad54331bcabdb3c8d6570ea241e2', '0083_referral_rewards.sql:1224-1286'),
    ('public.admin_reverse_referral(text,uuid,uuid,text)', 'b43786e439795b1fc6d6fcd7af10a3a9', '0083_referral_rewards.sql:1292-1355'),
    ('public.admin_adjust_referral_progress(text,uuid,uuid,text,integer,text)', 'e56bbad6e9674316eb4624328723bffc', '0083_referral_rewards.sql:1358-1447'),
    ('public.admin_rotate_referral_code(text,uuid,uuid,text)', 'ee22254aee43b4ec476082d4ec68a260', '0083_referral_rewards.sql:1455-1542'),
    ('public.admin_publish_reward_rule(text,uuid,text,integer,integer,boolean,text,timestamp with time zone)', '43bf9b7c15d0171497cc235f99b020f7', '0083_referral_rewards.sql:1549-1641'),
    ('public.admin_deactivate_reward_rule(text,uuid,text,text)', 'de06cb586a6d724e84edb8bc1c9123cf', '0083_referral_rewards.sql:1646-1705'),
    ('public.link_capture_device(text,text,boolean,boolean,integer,bigint)', '14629df85147e9ca10577f44a35e64a3', '0110_capture_consent_projection.sql:293-388'),
    ('public.set_capture_consent(text,text,boolean,boolean,integer,bigint)', '89f665a2a17a094a3b0455268473f219', '0110_capture_consent_projection.sql:401-474'),
    ('public.revoke_capture_consent(text,text,uuid,bigint,integer)', '29ce334ab2085d791f3c34699661467e', '0110_capture_consent_projection.sql:492-549'),
    ('public.legacy_link_capture_device(text,uuid)', '17fe992c06dfbdaee321a6828d756875', '0110_capture_consent_projection.sql:562-592'),
    ('public.legacy_set_device_consent(text,boolean,boolean)', '980a6f5efeedfbf082de452c5042ca1c', '0110_capture_consent_projection.sql:604-645'),
    ('public.unlink_capture_device(text)', '8aa7b29df81b36a5e294bd8b6e6a9605', '0110_capture_consent_projection.sql:655-678'),
    ('public.capture_claim(text,text,text,text,uuid,integer,integer,bigint)', 'da5754145b65352a263f9038495692e1', '0112_capture_notifications_retention.sql:296-437'),
    ('public.capture_ai_dispatch(text,text,integer)', '09b40764ded7f726dbbb5d5e9cf9e746', '0112_capture_notifications_retention.sql:439-490'),
    ('public.capture_finalize(text,text,text,integer,text,text,jsonb,jsonb,text,text,boolean,jsonb)', 'bb40a0b7015f5ee4cd406cb4d82a4175', '0112_capture_notifications_retention.sql:492-576'),
    ('public.capture_ack(text,uuid,text[])', '2eaac2d9064d3b34ecc3911f3ea20403', '0111_capture_state_machine.sql:442-464'),
    ('public.capture_retry_fence(text,text)', 'f3db157f5361c16026a07bd403ad1643', '0112_capture_notifications_retention.sql:232-292'),
    ('public.capture_queue_push(text,text,text,uuid,text)', '99aa679bdac2995a1ac91aed776a952a', '0112_capture_notifications_retention.sql:147-199'),
    ('public.capture_revoke_fanout(text,uuid,boolean,boolean,integer)', '31b29f1876eeecacd64f14a9cc05b448', '0110_capture_consent_projection.sql:243-278'),
    ('public.claim_ai_idempotency(text,text,text,text,integer)', '6cffd8bc4b07d5dd6aac9d17097cf6cd', '0071_ai_endpoint_hardening.sql:58-98'),
    ('public.award_gamification_for_transaction(text,uuid)', 'd5d021af7541a1696dfdf8bfd8c632be', '0085_concurrency_absent_row_locking.sql:405-513'),
    ('public.bump_capture_rate_limit(text,integer)', 'b4886765a6e2acf4867bf5ee13611a95', '0033_capture_pipeline_hardening.sql:60-74'),
    ('public.complete_ai_idempotency(text,text,text,text,jsonb)', '7310c6cdd35dcfb5145a9075275d9db7', '0071_ai_endpoint_hardening.sql:105-122')
  ) as t(sig, expected_md5, src) loop
    select md5(p.prosrc), pg_catalog.pg_get_userbyid(p.proowner)
      into v_md5, v_owner
      from pg_catalog.pg_proc p where p.oid = to_regprocedure(r.sig);
    if v_md5 is null then
      raise exception 'account_fence preflight: signature does not resolve: %', r.sig using errcode = 'QD090';
    end if;
    if v_md5 <> r.expected_md5 then
      raise exception 'account_fence preflight: deployed body differs from %: %', r.src, r.sig using errcode = 'QD091';
    end if;
    if v_owner <> current_user then
      raise exception 'account_fence preflight: % is owned by %, expected %', r.sig, v_owner, current_user using errcode = 'QD092';
    end if;
  end loop;
end
$chk$;

-- <<< GENERATED:END rpc_preflight

-- ════════════════════════════════════════════════════════════════════════════
-- 1. Narrow owner role, schema, tables
-- ════════════════════════════════════════════════════════════════════════════

-- E1: one NOLOGIN role owns the fence, with no inheritance, no BYPASSRLS, no superuser. Every
-- privilege it needs on application tables is granted explicitly in section 3 and bounded by a
-- row policy that is false outside an erasure transaction. The migration role is a member only
-- until the last statement of this file (section 9 revokes it).
create role account_fence_owner nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
grant account_fence_owner to current_user;

create schema account_fence;

-- Qualification finding (loopback stack, 2026-10-24): the migration role `postgres` holds USAGE on schema auth and
-- EXECUTE on auth.uid() WITHOUT grant option (auth.users/auth.identities carry arwdDxtm with grant option only on a/r), so
-- `grant usage on schema auth` / `grant execute on function auth.uid()` to account_fence_owner grant NOTHING (WARNING only)
-- and the narrow owner could not reference any auth object ("permission denied for schema auth", which also broke Auth's own
-- user insert through the profiles guard). Narrowest fix: three read-only SECURITY DEFINER shims that STAY OWNED BY THE
-- MIGRATION ROLE (never altered to account_fence_owner), pinned search_path, VOLATILE (each inner query takes its own
-- snapshot, as the inline statements they replace did), EXECUTE granted to account_fence_owner only. They return strictly
-- less than the column grants they replace: one boolean / one text for a caller-supplied uid, never a row set.
create function account_fence.auth_uid() returns uuid
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$ select auth.uid() $$;

create function account_fence.auth_user_exists(p_uid uuid) returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$ select exists (select 1 from auth.users u where u.id = p_uid) $$;

create function account_fence.auth_apple_subject(p_uid uuid) returns text
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(nullif(i.provider_id, ''), i.identity_data ->> 'sub')
    from auth.identities i where i.user_id = p_uid and i.provider = 'apple' limit 1
$$;

-- F2: public.account_purge_queue is never erased by this design (it has no owner policy and no DELETE grant). The
-- preflight proves it EMPTY at apply (QD096, table locked EXCLUSIVE), section 11 unschedules the job that enqueues into it, and
-- account_fence.legacy_queue_guard refuses EVERY later INSERT (QD003, any caller), so no row can appear afterwards. This fourth shim lets erase_verify ASSERT that no queue row exists for the
-- subject (the narrow owner has no privilege on the table); it returns one boolean for a caller-supplied uid.
create function account_fence.legacy_queue_has_uid(p_uid uuid) returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$ select exists (select 1 from public.account_purge_queue q where q.user_id = p_uid) $$;

revoke all on function account_fence.auth_uid(), account_fence.auth_user_exists(uuid), account_fence.auth_apple_subject(uuid), account_fence.legacy_queue_has_uid(uuid) from public;
grant execute on function account_fence.auth_uid(), account_fence.auth_user_exists(uuid), account_fence.auth_apple_subject(uuid), account_fence.legacy_queue_has_uid(uuid) to account_fence_owner;

-- Rollback metadata, captured BEFORE any ACL or body is changed. rollback.sql compares against it and replays
-- only the reviewed mutation set (DECISIONS.md E3 defines what that guarantees).
create table account_fence.rollback_function_snapshot (
  fn_identity text primary key,          -- regprocedure::text
  fn_owner    text not null,
  fn_acl      aclitem[],                 -- pg_proc.proacl exactly (NULL = owner default)
  fn_def      text not null              -- pg_get_functiondef
);
insert into account_fence.rollback_function_snapshot
select p.oid::regprocedure::text, pg_catalog.pg_get_userbyid(p.proowner), p.proacl, pg_catalog.pg_get_functiondef(p.oid)
  from pg_catalog.pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f';

create table account_fence.rollback_table_snapshot (
  rel        text primary key,
  rel_owner  text not null,
  rel_acl    aclitem[],
  rls        boolean not null,
  force_rls  boolean not null
);
insert into account_fence.rollback_table_snapshot
select c.oid::regclass::text, pg_catalog.pg_get_userbyid(c.relowner), c.relacl, c.relrowsecurity, c.relforcerowsecurity
  from pg_catalog.pg_class c
 where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p');

create table account_fence.rollback_misc_snapshot (
  kind     text not null,
  identity text not null,
  acl      aclitem[],
  primary key (kind, identity)
);
insert into account_fence.rollback_misc_snapshot
select 'schema', n.nspname, n.nspacl from pg_catalog.pg_namespace n where n.nspname in ('public', 'auth', 'extensions');
insert into account_fence.rollback_misc_snapshot
select 'relation', 'auth.users', c.relacl from pg_catalog.pg_class c where c.oid = 'auth.users'::regclass;
insert into account_fence.rollback_misc_snapshot
select 'relation', 'auth.identities', c.relacl from pg_catalog.pg_class c where c.oid = 'auth.identities'::regclass;
insert into account_fence.rollback_misc_snapshot
select 'function', 'auth.uid()', p.proacl from pg_catalog.pg_proc p where p.oid = 'auth.uid()'::regprocedure;
insert into account_fence.rollback_misc_snapshot
select 'function', 'extensions.gen_random_bytes(integer)', p.proacl from pg_catalog.pg_proc p where p.oid = 'extensions.gen_random_bytes(integer)'::regprocedure;
insert into account_fence.rollback_misc_snapshot
select 'default_acl', d.defaclrole::regrole::text || ':' || d.defaclnamespace::regnamespace::text || ':' || d.defaclobjtype::text, d.defaclacl
  from pg_catalog.pg_default_acl d;
-- E3: snapshot every public application column ACL, including all reviewed E2/Q14 revokes.
-- A table-level REVOKE never removes a column grant. No catalog-driven DDL is used.
insert into account_fence.rollback_misc_snapshot
select 'column', c.attrelid::regclass::text || '.' || c.attname, c.attacl
  from pg_catalog.pg_attribute c
 where c.attrelid in (select t.oid from pg_catalog.pg_class t where t.relnamespace = 'public'::regnamespace and t.relkind in ('r', 'p'))
   and c.attnum > 0 and not c.attisdropped and c.attacl is not null;
insert into account_fence.rollback_misc_snapshot values ('migration_role', current_user, null);

-- F1: exact schedule/command of the legacy 30-day purge cron job (0065) that section 11 unschedules. Captured here, before RLS
-- and the owner transfer, so rollback.sql can re-schedule it verbatim. Empty when pg_cron or the job is absent.
create table account_fence.rollback_cron_snapshot (
  jobname  text primary key,
  schedule text not null,
  command  text not null,
  active   boolean not null,
  database text not null,
  username text not null
);
do $snap$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    insert into account_fence.rollback_cron_snapshot (jobname, schedule, command, active, database, username)
    select j.jobname, j.schedule, j.command, j.active, j.database, j.username
      from cron.job j where j.jobname = 'purge-scheduled-deletions-job';
  end if;
end
$snap$;

-- E3 attribute preflight (needs the snapshot above; changes nothing outside account_fence).
-- >>> GENERATED:BEGIN rpc_attr_preflight
-- E3: attributes that CREATE OR REPLACE would overwrite must already equal the migration statement.
-- Expected values are derived offline from each statement header by gen_rpc_bodies.py; the catalog
-- columns and the captured pg_get_functiondef text (rollback_function_snapshot.fn_def) must agree.
do $attr$
declare r record; p pg_catalog.pg_proc%rowtype; s account_fence.rollback_function_snapshot%rowtype; v_cfg text; v_lang text;
begin
  for r in select * from (values
    ('public.stamp_sync_seq()', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.sync_lock_epoch()', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.backups_owner_is_live()', 'sql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog'),
    ('public.request_account_deletion()', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.cancel_account_deletion()', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.feature_flag_audit_append_only()', 'plpgsql', false, 'v', false, 'u', false, 100, null::text),
    ('public.set_default_account(uuid)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.add_goal_contribution(uuid,text,text,numeric,timestamp with time zone,text)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.record_bill_payment(uuid,uuid,text,text,numeric,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,integer,text)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.delete_bill_payment(uuid)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.delete_user_account_safely(uuid)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.create_subscription_and_record_payment(text,text,text,numeric,text,text,text,timestamp with time zone,timestamp with time zone,uuid,text,boolean,boolean,integer,text,text,integer,integer,numeric,numeric,text,numeric,numeric,timestamp with time zone,timestamp with time zone,timestamp with time zone,integer,text)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.delete_user_category_safely(uuid)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.import_financial_package(text,text,jsonb)', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.mark_onboarding_completed()', 'plpgsql', false, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.record_engagement_event(uuid,text,timestamp with time zone,text,integer)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.record_metric(text,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.commit_backup_generation(text,text,integer,bigint,text,text,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.get_referral_summary()', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.ensure_referral_code(uuid)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.apply_entitlement_mutation(text,uuid,text,text,text,integer,text,uuid,integer,integer,uuid,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.apply_referral_code(text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.request_referral_qualification()', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.qualify_referral_internal(uuid)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.admin_mutate_entitlement(text,uuid,uuid,text,text,text,integer)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.admin_reject_referral(text,uuid,uuid,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.admin_reverse_referral(text,uuid,uuid,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.admin_adjust_referral_progress(text,uuid,uuid,text,integer,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.admin_rotate_referral_code(text,uuid,uuid,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.admin_publish_reward_rule(text,uuid,text,integer,integer,boolean,text,timestamp with time zone)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.admin_deactivate_reward_rule(text,uuid,text,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=pg_catalog,public,pg_temp'),
    ('public.link_capture_device(text,text,boolean,boolean,integer,bigint)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.set_capture_consent(text,text,boolean,boolean,integer,bigint)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.revoke_capture_consent(text,text,uuid,bigint,integer)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.legacy_link_capture_device(text,uuid)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.legacy_set_device_consent(text,boolean,boolean)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.unlink_capture_device(text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.capture_claim(text,text,text,text,uuid,integer,integer,bigint)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.capture_ai_dispatch(text,text,integer)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.capture_finalize(text,text,text,integer,text,text,jsonb,jsonb,text,text,boolean,jsonb)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.capture_ack(text,uuid,text[])', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.capture_retry_fence(text,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.capture_queue_push(text,text,text,uuid,text)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.capture_revoke_fanout(text,uuid,boolean,boolean,integer)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public,pg_temp'),
    ('public.claim_ai_idempotency(text,text,text,text,integer)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.award_gamification_for_transaction(text,uuid)', 'plpgsql', true, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.bump_capture_rate_limit(text,integer)', 'sql', true, 'v', false, 'u', false, 100, 'search_path=public'),
    ('public.complete_ai_idempotency(text,text,text,text,jsonb)', 'sql', true, 'v', false, 'u', false, 100, 'search_path=public')
  ) as t(sig, lang, secdef, vol, is_strict, par, leak, cost, cfg) loop
    select * into p from pg_catalog.pg_proc where oid = to_regprocedure(r.sig);
    if p.oid is null then
      raise exception 'account_fence preflight: signature does not resolve: %', r.sig using errcode = 'QD090';
    end if;
    select * into s from account_fence.rollback_function_snapshot where fn_identity = p.oid::regprocedure::text;
    if s.fn_identity is null then
      raise exception 'account_fence preflight: function missing from rollback snapshot: %', r.sig using errcode = 'QD094';
    end if;
    select l.lanname into v_lang from pg_catalog.pg_language l where l.oid = p.prolang;
    v_cfg := replace(replace(replace(lower(pg_catalog.array_to_string(p.proconfig, ';')), ' ', ''), '"', ''), '''', '');
    if v_lang is distinct from r.lang
       or p.prosecdef is distinct from r.secdef
       or p.provolatile::text is distinct from r.vol
       or p.proisstrict is distinct from r.is_strict
       or p.proparallel::text is distinct from r.par
       or p.proleakproof is distinct from r.leak
       or p.procost::numeric is distinct from r.cost::numeric
       or v_cfg is distinct from r.cfg then
      raise exception 'account_fence preflight: deployed attributes differ from the migration statement (drift): %', r.sig using errcode = 'QD094';
    end if;
    -- the captured definition text must agree with the catalog row it was taken from
    if (position(' SECURITY DEFINER' in s.fn_def) > 0) is distinct from r.secdef
       or position(' LANGUAGE ' || r.lang || E'\n' in s.fn_def) = 0 then
      raise exception 'account_fence preflight: captured pg_get_functiondef disagrees with expected attributes: %', r.sig using errcode = 'QD094';
    end if;
  end loop;
end
$attr$;

-- <<< GENERATED:END rpc_attr_preflight

-- One row per accepted deletion. PENDING == a row whose state <> 'completed'. uid is erased on
-- completion. No FK to auth.users (it must survive Auth deletion).
create table account_fence.deletion_job (
  job_id             uuid primary key default gen_random_uuid(),
  uid                uuid,
  attempt_id         text not null unique,
  state              text not null default 'accepted'
                     check (state in ('accepted', 'running', 'retryable', 'failed', 'completed')),
  completed_steps    text[] not null default '{}',
  current_step       text,
  apple_material_ref text,
  attempts           integer not null default 0 check (attempts >= 0),
  next_attempt_at    timestamptz not null default clock_timestamp(),
  lease_token        uuid,
  lease_generation   integer not null default 0,
  lease_expires_at   timestamptz,
  last_code          text check (last_code is null or last_code ~ '^[a-z][a-z0-9_]{0,39}$'),
  accepted_at        timestamptz not null default clock_timestamp(),
  completed_at       timestamptz,
  -- F4 (revised): set by account_deletion_record_failure on a TERMINAL failure, cleared on a retryable failure and by
  -- account_fence.operator_requeue_failed_job. Drives the 14-day retention of the job's committed Apple material.
  failed_at          timestamptz,
  -- P3: start of the current retry window (accepted_at at creation, reset by operator_requeue_failed_job). A job that is still
  -- not terminal 72 hours after this is moved to 'failed' (record_failure on a retryable failure; claim_lease for crash loops).
  retry_window_started_at timestamptz not null default clock_timestamp(),
  -- D5: anonymous completion marker. Set by account_deletion_complete_job to at most completed_at + 14 days;
  -- the whole marker (job, scope, receipt, material) is physically purged by account_fence.purge_expired_deletion_records.
  retained_until     timestamptz,
  -- O4: what the erasure could and could not attribute. Never exposed to clients; product copy must
  -- not claim completeness beyond 'known_ownership_only' (historical attribution is first-owner only).
  coverage           text not null default 'known_ownership_only'
                     check (coverage in ('known_ownership_only')),
  constraint deletion_job_uid_shape check ((state = 'completed') = (uid is null)),
  constraint deletion_job_steps_prefix check (
    completed_steps <@ array['apple_revoke', 'storage_sweep', 'sql_purge', 'auth_delete', 'terminal_storage']
  )
);
create unique index deletion_job_one_open_per_uid on account_fence.deletion_job (uid) where state <> 'completed';

create table account_fence.deletion_scope (
  scope_key    text primary key,
  job_id       uuid not null references account_fence.deletion_job (job_id),
  receipt_hash text not null
);
create table account_fence.deletion_receipt (
  receipt_hash text primary key,
  job_id       uuid not null references account_fence.deletion_job (job_id)
);
create table account_fence.deletion_material (
  ref         text primary key check (ref ~ '^enc:[A-Za-z0-9_.:-]{8,255}$'),
  state       text not null default 'reserved' check (state in ('reserved', 'committed', 'disposed')),
  ciphertext  text,
  job_id      uuid references account_fence.deletion_job (job_id),
  reserved_at timestamptz not null default clock_timestamp(),
  expires_at  timestamptz not null default clock_timestamp() + interval '15 minutes',
  constraint deletion_material_disposed_empty check (state <> 'disposed' or ciphertext is null)
);
create table account_fence.deletion_attempt_tombstone (
  attempt_id text primary key,
  created_at timestamptz not null default clock_timestamp()
);
-- Challenge rows are written ONLY by public.account_deletion_issue_challenge (section 6, contract section 1) and
-- consumed by account_deletion_accept. The raw nonce is returned to the client once and is NEVER stored: only
-- nonce_hash = lower-hex sha256(nonce utf8), which Apple echoes in the identity token's `nonce` claim.
create table account_fence.deletion_challenge (
  challenge_id text primary key,
  uid          uuid not null,
  nonce_hash   text not null check (nonce_hash ~ '^[0-9a-f]{64}$'),
  expires_at   timestamptz not null,
  consumed_at  timestamptz
);
-- O4/E2: the installs attributable to the subject at ACCEPTANCE, captured under the exclusive account
-- gate before any unlink/purge can change ownership. Erasure uses this set plus live discovery.
create table account_fence.deletion_workset (
  job_id          uuid not null references account_fence.deletion_job (job_id),
  install_id_hash text not null check (install_id_hash ~ '^[0-9a-f]{32}$'),
  source          text not null check (source in ('device_owner', 'consent_owner', 'claimant', 'first_owner', 'capture_owner', 'capture_consent', 'consumed_install', 'log_owner', 'retry_install', 'retry_parent_install')),
  primary key (job_id, install_id_hash, source)
);
-- Transaction-scoped erasure context. A row exists only inside the transaction of
-- public.account_deletion_purge and is deleted before it returns; nothing but that function writes
-- here (owner-only privileges, forced RLS with one owner policy).
create table account_fence.erasure_ctx (
  xid        xid8 primary key,
  backend_pid integer not null,
  job_id     uuid not null,
  uid        uuid not null,
  installs   text[] not null default '{}',
  exclusive_installs text[] not null default '{}'
);

alter table account_fence.deletion_job enable row level security;
alter table account_fence.deletion_scope enable row level security;
alter table account_fence.deletion_receipt enable row level security;
alter table account_fence.deletion_material enable row level security;
alter table account_fence.deletion_attempt_tombstone enable row level security;
alter table account_fence.deletion_challenge enable row level security;
alter table account_fence.deletion_workset enable row level security;
alter table account_fence.erasure_ctx enable row level security;
alter table account_fence.rollback_function_snapshot enable row level security;
alter table account_fence.rollback_table_snapshot enable row level security;
alter table account_fence.rollback_misc_snapshot enable row level security;
alter table account_fence.rollback_cron_snapshot enable row level security;
-- FORCE + one explicit owner policy: proves the narrow owner works under forced RLS without BYPASSRLS.
-- (The snapshot tables are filled above, before RLS, by the migration role: ENABLE only.)
alter table account_fence.deletion_job force row level security;
alter table account_fence.deletion_scope force row level security;
alter table account_fence.deletion_receipt force row level security;
alter table account_fence.deletion_material force row level security;
alter table account_fence.deletion_attempt_tombstone force row level security;
alter table account_fence.deletion_challenge force row level security;
alter table account_fence.deletion_workset force row level security;
alter table account_fence.erasure_ctx force row level security;
create policy account_fence_owner_all on account_fence.deletion_job to account_fence_owner using (true) with check (true);
create policy account_fence_owner_all on account_fence.deletion_scope to account_fence_owner using (true) with check (true);
create policy account_fence_owner_all on account_fence.deletion_receipt to account_fence_owner using (true) with check (true);
create policy account_fence_owner_all on account_fence.deletion_material to account_fence_owner using (true) with check (true);
create policy account_fence_owner_all on account_fence.deletion_attempt_tombstone to account_fence_owner using (true) with check (true);
create policy account_fence_owner_all on account_fence.deletion_challenge to account_fence_owner using (true) with check (true);
create policy account_fence_owner_all on account_fence.deletion_workset to account_fence_owner using (true) with check (true);
create policy account_fence_owner_all on account_fence.erasure_ctx to account_fence_owner using (true) with check (true);

-- ════════════════════════════════════════════════════════════════════════════
-- 2. Admission (try-exclusive), structured denials, erasure context
-- ════════════════════════════════════════════════════════════════════════════

-- E4: the ONLY place a fence denial is raised. Messages are fixed tokens (no payloads); DETAIL and HINT
-- are machine-readable for the client classifier. 55P03 = busy (whole mutation rolled back, retry, no
-- business attempt consumed); QD001 pending (park writes, preserve rows); QD002 Auth user gone (revoke
-- authority); QD003 legacy route unavailable. Other codes: QD010 lease lost, QD011 step not authorised,
-- QD012 not in erasure context, QD013 closure incomplete, QD020 material unavailable, 0A000 isolation,
-- 22023 invalid key grammar, QD090-QD092 preflight. D5-D7 (2026-10-24): QD031 admin account cannot be deleted
-- (remove admin rights first), QD032 challenge issuance rate limited, QD040 feature_retired (raised inline by the
-- restated referral/entitlement bodies of section 5, not through this function).
create function account_fence.deny(p_kind text) returns void
language plpgsql volatile
set search_path = pg_catalog
as $$
begin
  if p_kind = 'busy' then
    raise exception 'account_busy' using errcode = '55P03', detail = 'fence:busy', hint = 'retry_whole_transaction_no_attempt';
  elsif p_kind = 'pending' then
    raise exception 'account_deletion_pending' using errcode = 'QD001', detail = 'fence:pending', hint = 'park_account_writes';
  elsif p_kind = 'gone' then
    raise exception 'account_gone' using errcode = 'QD002', detail = 'fence:gone', hint = 'revoke_authority_account_gone';
  elsif p_kind = 'legacy' then
    raise exception 'legacy_scheduled_deletion_disabled' using errcode = 'QD003', detail = 'fence:legacy', hint = 'legacy_route_unavailable';
  elsif p_kind = 'admin' then
    raise exception 'admin_self_delete_blocked' using errcode = 'QD031', detail = 'fence:admin', hint = 'remove_admin_rights_first';
  elsif p_kind = 'challenge_rate' then
    raise exception 'challenge_rate_limited' using errcode = 'QD032', detail = 'fence:challenge_rate', hint = 'retry_later';
  else
    raise exception 'account_fence_unknown_denial' using errcode = 'XX000';
  end if;
end;
$$;

create function account_fence.gate_key(p_uid uuid) returns bigint
language sql immutable parallel safe
set search_path = pg_catalog
as $$ select pg_catalog.hashtextextended('qirsh.account_fence.v1:' || p_uid::text, 0) $$;

create function account_fence.install_gate_key(p_hash text) returns bigint
language sql immutable parallel safe
set search_path = pg_catalog
as $$ select pg_catalog.hashtextextended('qirsh.account_fence.install.v1:' || p_hash, 0) $$;

-- Context accessors. Absence of context is unequivocally NULL / false, never an unknown that a caller
-- could mistake for success: refusals below use IS NOT TRUE.
create function account_fence.erasure_uid() returns uuid
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select c.uid from account_fence.erasure_ctx c
   where c.xid = pg_catalog.pg_current_xact_id_if_assigned() and c.backend_pid = pg_catalog.pg_backend_pid()
$$;

create function account_fence.erasure_installs() returns text[]
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select coalesce((select c.installs from account_fence.erasure_ctx c
   where c.xid = pg_catalog.pg_current_xact_id_if_assigned() and c.backend_pid = pg_catalog.pg_backend_pid()), '{}'::text[])
$$;

create function account_fence.erasure_exclusive_installs() returns text[]
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select coalesce((select c.exclusive_installs from account_fence.erasure_ctx c
   where c.xid = pg_catalog.pg_current_xact_id_if_assigned() and c.backend_pid = pg_catalog.pg_backend_pid()), '{}'::text[])
$$;

create function account_fence.in_erasure(p_uid uuid) returns boolean
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$ select coalesce(p_uid is not null and account_fence.erasure_uid() = p_uid, false) $$;

create function account_fence.is_pending(p_uid uuid) returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
  select exists (select 1 from account_fence.deletion_job j where j.uid = p_uid and j.state <> 'completed')
$$;

create function account_fence.is_pending_self() returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$ select account_fence.is_pending(account_fence.auth_uid()) $$;

-- Ordinary-writer admission. NEVER waits: if the account gate is held (by an accepting or erasing
-- transaction, or a sibling writer) the whole mutation fails with 55P03 and rolls back. Re-entrant
-- within one transaction. There is deliberately NO erasure shortcut here: inside an erasure
-- transaction the only passes are the fixed per-table shapes in erasure_row_allowed (section 7).
--   p_require_auth_user  : false only for historical references that may name a deleted account
--   p_allow_pending      : true only for the reviewed consent-NARROWING entries (O2)
create function account_fence.admit(p_uid uuid, p_require_auth_user boolean default true, p_allow_pending boolean default false)
returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if p_uid is null then
    return;
  end if;
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'account_fence_isolation_unsupported' using errcode = '0A000';
  end if;
  if not pg_catalog.pg_try_advisory_xact_lock(account_fence.gate_key(p_uid)) then
    perform account_fence.deny('busy');
  end if;
  -- READ COMMITTED: each statement below takes a fresh snapshot with the gate held, so a pending row
  -- committed by an acceptance that finished before us is visible.
  if not p_allow_pending and account_fence.is_pending(p_uid) then
    perform account_fence.deny('pending');
  end if;
  if p_require_auth_user and not account_fence.auth_user_exists(p_uid) then
    perform account_fence.deny('gone');
  end if;
end;
$$;

-- Authenticated surface: only about the caller. No uid argument, so it cannot probe other accounts.
create function account_fence.admit_self() returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  perform account_fence.admit(account_fence.auth_uid());
end;
$$;

-- RLS policy form: admits only the caller's own uid; for any other value it does nothing and returns
-- true (the permissive ownership policy decides that row), so no probe and no behaviour change.
create function account_fence.admit_check_self(p_uid uuid) returns boolean
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if p_uid is not null and p_uid = account_fence.auth_uid() then
    perform account_fence.admit(p_uid);
  end if;
  return true;
end;
$$;

create function account_fence.admit_many(p_uids uuid[], p_require_auth_user boolean default true, p_allow_pending boolean default false)
returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v uuid;
begin
  -- Sorted, distinct. The order is cosmetic: every acquisition is a TRY-lock.
  for v in select distinct u from pg_catalog.unnest(p_uids) as u where u is not null order by 1 loop
    perform account_fence.admit(v, p_require_auth_user, p_allow_pending);
  end loop;
end;
$$;

-- E7/O6: does THIS backend hold the advisory lock p_key in the expected mode, in THIS database?
-- pg_locks encoding of a bigint advisory key: classid = high 32 bits, objid = low 32 bits, objsubid = 1,
-- database = oid of the current database. Exclusive advisory locks show as ExclusiveLock, shared as ShareLock.
-- (pg_locks cannot tell a transaction-level lock from a session-level one; the gate functions only ever
-- take transaction-level locks. Residual: a session-level lock on the same key by the same backend would
-- satisfy this test. Unproven; listed in DECISIONS.md.)
create function account_fence.holds_advisory(p_key bigint, p_exclusive boolean) returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
  select exists (
    select 1 from pg_catalog.pg_locks l
     where l.locktype = 'advisory' and l.pid = pg_catalog.pg_backend_pid() and l.granted and l.objsubid = 1
       and l.database = (select d.oid from pg_catalog.pg_database d where d.datname = pg_catalog.current_database())
       and l.classid = (((p_key >> 32) & 4294967295)::bigint)::oid
       and l.objid   = ((p_key & 4294967295)::bigint)::oid
       and (l.mode = 'ExclusiveLock' or (not p_exclusive and l.mode = 'ShareLock')))
$$;

-- The account gate is an EXCLUSIVE advisory lock (pg_try_advisory_xact_lock in admit; pg_advisory_xact_lock in
-- accept/purge).
create function account_fence.holds_gate(p_uid uuid) returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$ select p_uid is not null and account_fence.holds_advisory(account_fence.gate_key(p_uid), true) $$;

-- The install gate: exclusive for ownership-changing callers and erasure, shared (or exclusive) for ordinary ones.
create function account_fence.holds_install_gate(p_hash text, p_exclusive boolean) returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$ select p_hash is not null and account_fence.holds_advisory(account_fence.install_gate_key(p_hash), p_exclusive) $$;

-- O6: after the domain row lock, every owner discovered inside the body must already be gated by the
-- pre-lock manifest. If attribution grew or changed, abort the whole transaction (55P03) so the caller
-- retries and rediscovers; never add a BLOCKING lower-order gate while holding domain rows. For every owner
-- the exclusive gate must be held by this backend in this database AND admission is re-established
-- (pending / Auth existence are re-read; the gate is already held so admit() cannot wait or add a gate).
create function account_fence.assert_gated(p_uids uuid[]) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v uuid;
begin
  for v in select distinct u from pg_catalog.unnest(p_uids) as u where u is not null loop
    if not account_fence.holds_gate(v) then
      perform account_fence.deny('busy');
    end if;
    perform account_fence.admit(v);
  end loop;
end;
$$;

-- Owners of either capture install reference: linked/consent owners, all three capture UUIDs, retained first owner.
-- consumed_by_install_hash is an install identifier, NEVER a UUID.
-- Discovery only; callers re-read after gating.
create function account_fence.install_owners(p_hash text) returns uuid[]
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(array_agg(distinct o), '{}'::uuid[]) from (
    select d.user_id as o from public.capture_devices d where d.install_id_hash = p_hash
    union all select d.consent_owner_uid from public.capture_devices d where d.install_id_hash = p_hash
    union all select p.claimed_user_id from public.processed_captures p where p.install_id_hash = p_hash or p.consumed_by_install_hash = p_hash
    union all select p.owner_uid from public.processed_captures p where p.install_id_hash = p_hash or p.consumed_by_install_hash = p_hash
    union all select p.consent_owner_uid from public.processed_captures p where p.install_id_hash = p_hash or p.consumed_by_install_hash = p_hash
    union all select l.user_id from public.notification_logs l where l.install_id_hash = p_hash
    -- A retry's install is independent of its FK parent in 0052/0112. Include the explicit parent UUID
    -- even for historical conflicts; ordinary mutation refuses the conflict, never hides this owner.
    union all select l.user_id from public.notification_retry_queue q
      join public.notification_logs l on l.id = q.notification_log_id where q.install_id_hash = p_hash
    union all select h.first_owner_uid from public.capture_install_owner_history h where h.install_id_hash = p_hash
  ) s where o is not null
$$;

-- Install-level try-lock only (no owner admission). Shared by writers that merely attach data to an install;
-- exclusive for ownership changes and erasure. Never waits.
create function account_fence.lock_install(p_hash text, p_exclusive boolean default false) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v_ok boolean;
begin
  if p_hash is null then
    return;
  end if;
  if p_exclusive then
    v_ok := pg_catalog.pg_try_advisory_xact_lock(account_fence.install_gate_key(p_hash));
  else
    v_ok := pg_catalog.pg_try_advisory_xact_lock_shared(account_fence.install_gate_key(p_hash));
  end if;
  if not v_ok then
    perform account_fence.deny('busy');
  end if;
end;
$$;

-- E2: serialise install attribution. A per-install advisory try-lock (SHARED for ordinary callers, so
-- ordinary calls on one install do not contend with each other on the install lock; EXCLUSIVE only for
-- ownership-changing callers and erasure: link/legacy link/unlink/purge) is taken FIRST; then optimistic
-- read of the owner set -> try-gates -> locked re-read. A grown set aborts with 55P03. NOTE: the per-OWNER
-- account gate taken by admit() is an exclusive try-lock, so two concurrent calls for the SAME account do
-- conflict (one gets 55P03 and retries); calls for different accounts / unrelated installs do not.
create function account_fence.admit_install(p_hash text, p_allow_pending boolean default false, p_exclusive boolean default false)
returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v_before uuid[]; v_after uuid[]; v_ok boolean;
begin
  if p_hash is null then
    return;
  end if;
  if p_exclusive then
    v_ok := pg_catalog.pg_try_advisory_xact_lock(account_fence.install_gate_key(p_hash));
  else
    v_ok := pg_catalog.pg_try_advisory_xact_lock_shared(account_fence.install_gate_key(p_hash));
  end if;
  if not v_ok then
    perform account_fence.deny('busy');
  end if;
  v_before := account_fence.install_owners(p_hash);
  perform account_fence.admit_many(v_before, false, p_allow_pending);
  v_after := account_fence.install_owners(p_hash);
  if not (v_after <@ v_before) then
    perform account_fence.deny('busy');
  end if;
end;
$$;

-- O4: EXACT key grammars. Source: install hash = first 32 hex of SHA-256 (capture_auth.ts:35);
-- rate key = `<ownerKey>:<endpoint>` or bare `<hash>` (capture_auth.ts:199, process-ios-sms/index.ts:402,
-- set-device-consent/index.ts:96); ownerKey = `u:<uuid>` | `d:<hash>` (ai_endpoint.ts:252,277).
-- Returns {'u', uuid-text} or {'i', hash}; NULL = unknown grammar. Lower-case uuid only (Auth ids are).
create function account_fence.rate_key_parts(p_key text) returns text[]
language plpgsql immutable
set search_path = pg_catalog
as $$
declare m text[];
begin
  if p_key is null then
    return null;
  end if;
  m := regexp_match(p_key, '^u:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):[a-z][a-z0-9-]{0,63}$');
  if m is not null then return array['u', m[1]]; end if;
  m := regexp_match(p_key, '^d:([0-9a-f]{32}):[a-z][a-z0-9-]{0,63}$');
  if m is not null then return array['i', m[1]]; end if;
  m := regexp_match(p_key, '^([0-9a-f]{32}):[a-z][a-z0-9-]{0,63}$');
  if m is not null then return array['i', m[1]]; end if;
  m := regexp_match(p_key, '^([0-9a-f]{32})$');
  if m is not null then return array['i', m[1]]; end if;
  return null;
end;
$$;

create function account_fence.owner_key_parts(p_key text) returns text[]
language plpgsql immutable
set search_path = pg_catalog
as $$
declare m text[];
begin
  if p_key is null then
    return null;
  end if;
  m := regexp_match(p_key, '^u:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$');
  if m is not null then return array['u', m[1]]; end if;
  m := regexp_match(p_key, '^d:([0-9a-f]{32})$');
  if m is not null then return array['i', m[1]]; end if;
  return null;
end;
$$;

-- Unknown grammars are REJECTED (22023): no reviewed anonymous path exists today (every caller passes a
-- verified identity), so an unparsable key must never become permission to mutate.
create function account_fence.admit_rate_key(p_key text) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare p text[] := account_fence.rate_key_parts(p_key);
begin
  if p is null then
    raise exception 'rate_key_invalid' using errcode = '22023', detail = 'fence:key_grammar';
  end if;
  if p[1] = 'u' then
    perform account_fence.admit(p[2]::uuid);
  else
    perform account_fence.admit_install(p[2]);
  end if;
end;
$$;

create function account_fence.admit_owner_key(p_key text) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare p text[] := account_fence.owner_key_parts(p_key);
begin
  if p is null then
    raise exception 'owner_key_invalid' using errcode = '22023', detail = 'fence:key_grammar';
  end if;
  if p[1] = 'u' then
    perform account_fence.admit(p[2]::uuid);
  else
    perform account_fence.admit_install(p[2]);
  end if;
end;
$$;

-- O6 manifest discovery (read-only, no row locks).
create function account_fence.referral_code_owner(p_code text) returns uuid
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select c.user_id from public.referral_codes c
   where c.code = upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g')) and c.status = 'active'
$$;

create function account_fence.referral_owners(p_referral_id uuid) returns uuid[]
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(array_agg(u) filter (where u is not null), '{}'::uuid[]) from (
    select r.referrer_user_id as u from public.referrals r where r.id = p_referral_id
    union all select r.referred_user_id from public.referrals r where r.id = p_referral_id) s
$$;

create function account_fence.referral_owners_for_referred(p_uid uuid) returns uuid[]
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(array_agg(r.referrer_user_id), '{}'::uuid[]) from public.referrals r where r.referred_user_id = p_uid
$$;

-- O2: unlinking an install that a PENDING account owns is allowed only if the install is in that job's
-- acceptance workset (so erasure can still find it after the owner link is cleared).
create function account_fence.assert_unlink_allowed(p_hash text) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare o uuid;
begin
  for o in select unnest(account_fence.install_owners(p_hash)) loop
    if account_fence.is_pending(o) and not exists (
         select 1 from account_fence.deletion_workset w join account_fence.deletion_job j on j.job_id = w.job_id
          where j.uid = o and j.state <> 'completed' and w.install_id_hash = p_hash) then
      perform account_fence.deny('pending');
    end if;
  end loop;
end;
$$;

-- O5 (PENDING OWNER APPROVAL): the fixed deletion tombstone. Pattern redaction (uuid / e-mail / digit
-- patterns) is NOT used: it cannot de-identify free text. The value satisfies every reason-shape CHECK that
-- applies (referral_admin_audit 0083, announcement_admin_audit 0089, feature_flag_admin_audit 0101,
-- entitlement_events 0083): 4..500 characters, no control characters, not NULL.
create function account_fence.deletion_tombstone() returns text
language sql immutable
set search_path = pg_catalog
as $$ select '[redacted: subject account deleted]'::text $$;

create function account_fence.only_changed(p_old jsonb, p_new jsonb, p_cols text[]) returns boolean
language sql immutable
set search_path = pg_catalog
as $$ select (p_old - p_cols) = (p_new - p_cols) $$;

-- Erasure-scope predicates used by the owner's row policies (false outside an erasure transaction).
create function account_fence.rate_key_in_scope(p_key text) returns boolean
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
declare p text[] := account_fence.rate_key_parts(p_key); v uuid := account_fence.erasure_uid();
begin
  if v is null or p is null then return false; end if;
  if p[1] = 'u' then return p[2]::uuid = v; end if;
  -- O4 conservative default: install-keyed counters are erased ONLY for installs the history proves
  -- single-owner (erasure_exclusive_installs); shared / unproven / anonymous install data is retained.
  return p[2] = any (account_fence.erasure_exclusive_installs());
end;
$$;

create function account_fence.owner_key_in_scope(p_key text) returns boolean
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
declare p text[] := account_fence.owner_key_parts(p_key); v uuid := account_fence.erasure_uid();
begin
  if v is null or p is null then return false; end if;
  if p[1] = 'u' then return p[2]::uuid = v; end if;
  return p[2] = any (account_fence.erasure_exclusive_installs());     -- O4: see rate_key_in_scope
end;
$$;

-- Fixed, reviewed erasure operations (E1). The guard trigger lets an operation through ONLY when it
-- matches one of these shapes for the transaction's own subject: the subject's own rows are removed
-- or de-identified; a row naming an unrelated healthy owner in another column is touched only in the
-- subject's column. Any other write inside an erasure transaction is refused by the ordinary path.
create function account_fence.erasure_row_allowed(p_tbl text, p_op text, o jsonb, n jsonb, p_uid uuid)
returns boolean
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
declare u text := p_uid::text;
begin
  if p_uid is null then
    return false;
  end if;
  if p_tbl = any (array['user_accounts', 'user_transactions', 'user_budgets', 'user_goals', 'user_goal_contributions',
       'user_plans', 'user_plan_transaction_links', 'user_subscriptions', 'user_bill_payments', 'user_cards',
       'user_categories', 'user_settings', 'user_smart_inbox', 'sender_bank_mappings', 'user_achievements',
       'user_streaks', 'user_xp_levels', 'user_sync_state', 'backups', 'feature_flag_overrides',
       'financial_import_runs', 'user_engagement_events', 'metrics_rate_limits',
       'gamification_awarded_transactions', 'referral_codes', 'user_entitlement_state']) then
    return p_op = 'DELETE' and o ->> 'user_id' = u;
  elsif p_tbl = 'profiles' then
    return p_op = 'DELETE' and o ->> 'id' = u;
  elsif p_tbl in ('referral_reward_grants', 'referral_reward_progress') then
    return p_op = 'DELETE' and o ->> 'referrer_user_id' = u;
  elsif p_tbl = 'referrals' then
    if p_op = 'DELETE' then
      return (o ->> 'referred_user_id' = u and o ->> 'status' in ('attributed', 'rejected')) or o ->> 'referrer_user_id' = u;
    end if;
    return p_op = 'UPDATE' and o ->> 'referred_user_id' = u and n ->> 'referred_user_id' is null
       and account_fence.only_changed(o, n, array['referred_user_id', 'referred_user_deleted_at']);
  elsif p_tbl = 'entitlement_events' then
    if p_op = 'DELETE' then return o ->> 'user_id' = u; end if;
    return p_op = 'UPDATE' and o ->> 'actor_admin_id' = u and n ->> 'actor_admin_id' is null
       and account_fence.only_changed(o, n, array['actor_admin_id', 'reason'])
       and n ->> 'reason' is not distinct from account_fence.deletion_tombstone();
  elsif p_tbl = 'referral_admin_audit' then
    if p_op <> 'UPDATE' then return false; end if;
    if o ->> 'target_user_id' = u then
      return n ->> 'target_user_id' is null and n ->> 'target_ref' is null and n ->> 'before_state' is null
         and n ->> 'after_state' is null and n ->> 'reason' = '[redacted: subject account deleted]'
         and account_fence.only_changed(o, n, array['target_user_id', 'target_ref', 'reason', 'before_state', 'after_state']);
    end if;
    return o ->> 'actor_admin_id' = u and n ->> 'actor_admin_id' is null
       and account_fence.only_changed(o, n, array['actor_admin_id', 'reason'])
       and n ->> 'reason' is not distinct from account_fence.deletion_tombstone();
  elsif p_tbl in ('announcement_admin_audit', 'feature_flag_admin_audit') then
    return p_op = 'UPDATE' and o ->> 'actor_admin_id' = u and n ->> 'actor_admin_id' is null
       and account_fence.only_changed(o, n, array['actor_admin_id', 'reason'])
       and n ->> 'reason' is not distinct from account_fence.deletion_tombstone();
  elsif p_tbl = 'referral_reward_rules' then
    return p_op = 'UPDATE' and o ->> 'created_by' = u and n ->> 'created_by' is null
       and account_fence.only_changed(o, n, array['created_by']);
  elsif p_tbl = 'processed_captures' then
    if p_op = 'DELETE' then
      return o ->> 'install_id_hash' = any(account_fence.erasure_exclusive_installs())
         and not exists (select 1 from unnest(array[o ->> 'claimed_user_id', o ->> 'owner_uid', o ->> 'consent_owner_uid']) x
                         where x is not null and x <> u)
         and (o ->> 'consumed_by_install_hash' is null
              or o ->> 'consumed_by_install_hash' = any(account_fence.erasure_exclusive_installs()));
    end if;
    -- Shared/unproven/conflicting rows: remove ONLY subject UUIDs and a proven-exclusive consumed hash.
    -- Retained content and foreign attribution are pending owner approval (O4/Q15).
    return p_op = 'UPDATE'
       and (u = any(array[o ->> 'claimed_user_id', o ->> 'owner_uid', o ->> 'consent_owner_uid'])
            or o ->> 'consumed_by_install_hash' = any(account_fence.erasure_exclusive_installs()))
       and account_fence.only_changed(o, n, array['claimed_user_id', 'owner_uid', 'consent_owner_uid', 'consumed_by_install_hash'])
       and n ->> 'claimed_user_id' is not distinct from (case when o ->> 'claimed_user_id' = u then null else o ->> 'claimed_user_id' end)
       and n ->> 'owner_uid' is not distinct from (case when o ->> 'owner_uid' = u then null else o ->> 'owner_uid' end)
       and n ->> 'consent_owner_uid' is not distinct from (case when o ->> 'consent_owner_uid' = u then null else o ->> 'consent_owner_uid' end)
       and n ->> 'consumed_by_install_hash' is not distinct from
           (case when o ->> 'consumed_by_install_hash' = any(account_fence.erasure_exclusive_installs()) then null else o ->> 'consumed_by_install_hash' end);
  elsif p_tbl = 'notification_logs' then
    return p_op = 'DELETE' and (o ->> 'user_id' = u
       or (o ->> 'user_id' is null and o ->> 'install_id_hash' = any(account_fence.erasure_exclusive_installs())));
  elsif p_tbl = 'capture_fingerprints' then
    return p_op = 'DELETE' and o ->> 'install_id_hash' = any(account_fence.erasure_exclusive_installs());
  elsif p_tbl = 'notification_retry_queue' then
    -- No foreign-child authority is inferred from parent UUID alone. Binding, frozen-exclusive child,
    -- held exclusive install gate and targeted parent are all required; explicit DELETE precedes parent.
    return p_op = 'DELETE'
       and o ->> 'install_id_hash' = any(account_fence.erasure_exclusive_installs())
       and account_fence.holds_install_gate(o ->> 'install_id_hash', true)
       and exists (select 1 from public.notification_logs l
         where l.id = (o ->> 'notification_log_id')::uuid
           and l.install_id_hash is not null and l.install_id_hash = o ->> 'install_id_hash'
           and (l.user_id = p_uid or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs()))));
  elsif p_tbl = 'capture_install_owner_history' then
    return p_op = 'UPDATE' and o ->> 'first_owner_uid' = u and n ->> 'first_owner_uid' is null
       and n ->> 'transitioned' = 'true'
       and account_fence.only_changed(o, n, array['first_owner_uid', 'transitioned', 'transitioned_at', 'updated_at']);
  elsif p_tbl = 'capture_devices' then
    -- O4 / E1.2: the parent row is DELETED only for an install the history proves single-owner (its
    -- ON DELETE CASCADE children processed_captures and capture_fingerprints, 0012:25,50, are then the
    -- install's own data). Any other install keeps its row: the subject is only UNLINKED (the same column
    -- set public.unlink_capture_device writes, 0110:662-675), so no unrelated child is cascaded away.
    if p_op = 'DELETE' then
      return o ->> 'user_id' = u and o ->> 'install_id_hash' = any (account_fence.erasure_exclusive_installs());
    end if;
    if p_op <> 'UPDATE' then return false; end if;
    -- (a) consent attribution only (subject is consent owner but not the linked user)
    if o ->> 'consent_owner_uid' = u and o ->> 'user_id' is distinct from u
       and n ->> 'consent_owner_uid' is null and n ->> 'cloud_processing_enabled' = 'false'
       and n ->> 'ai_consent_granted' = 'false' and n ->> 'consent_version' = '0'
       and n ->> 'consent_client_generation' = '0' and n ->> 'last_revoke_generation' is null
       and account_fence.only_changed(o, n, array['consent_owner_uid', 'cloud_processing_enabled', 'ai_consent_granted',
            'consent_version', 'consent_client_generation', 'last_revoke_generation']) then
      return true;
    end if;
    -- (b) full unlink: subject is the linked user and the consent owner is the subject or absent
    if o ->> 'user_id' = u and (o ->> 'consent_owner_uid' is null or o ->> 'consent_owner_uid' = u)
       and n ->> 'user_id' is null and n ->> 'consent_owner_uid' is null
       and n ->> 'cloud_processing_enabled' = 'false' and n ->> 'ai_consent_granted' = 'false'
       and n ->> 'consent_version' = '0' and n ->> 'consent_client_generation' = '0'
       and n ->> 'last_revoke_generation' is null and n ->> 'apns_token' is null and n ->> 'token_updated_at' is null
       and (n ->> 'owner_generation')::bigint = (o ->> 'owner_generation')::bigint + 1
       and account_fence.only_changed(o, n, array['owner_generation', 'consent_client_generation', 'last_revoke_generation',
            'user_id', 'consent_owner_uid', 'cloud_processing_enabled', 'ai_consent_granted', 'consent_version',
            'apns_token', 'token_updated_at']) then
      return true;
    end if;
    -- (c) subject is the linked user but ANOTHER account is the consent owner: only the link and the token go;
    -- the other account's consent columns are not touched.
    return o ->> 'user_id' = u and o ->> 'consent_owner_uid' is not null and o ->> 'consent_owner_uid' <> u
       and n ->> 'user_id' is null and n ->> 'apns_token' is null and n ->> 'token_updated_at' is null
       and (n ->> 'owner_generation')::bigint = (o ->> 'owner_generation')::bigint + 1
       and account_fence.only_changed(o, n, array['owner_generation', 'user_id', 'apns_token', 'token_updated_at']);
  elsif p_tbl = 'admin_users' then
    if p_op = 'DELETE' then return o ->> 'id' = u; end if;
    return p_op = 'UPDATE' and o ->> 'granted_by' = u and n ->> 'granted_by' is null
       and account_fence.only_changed(o, n, array['granted_by']);
  end if;
  return false;
end;
$$;

-- Reviewed data-MINIMISATION updates, CLASSIFIED (Q18/Q20, E2.4, E7/O2). Returns NULL when the UPDATE is not
-- one of them, so it falls through to ordinary admission. Each kind is an exact reviewed operation; none is a
-- touch. Side effects / cascades are stated per kind.
--   'content' processed_captures: content removal only, as written by capture_expire_row / capture_sync_list /
--             run_prune_processed_captures (0112:136-142, 594-601, 638-644: state -> expired, content emptied,
--             lease/next attempt cleared) and capture_revoke_fanout (0110:265-276: state/status -> rejected,
--             content emptied, failure_reason unchanged or 'consent_revoked'). No children, no triggers beyond the
--             immutable-created_at and default-state guards. Never touches a consumed/expired tombstone, never
--             sets a lease, a next attempt, a validator result or any other column.
--   'narrow'  capture_devices: a REAL consent narrowing (a flag true -> false, or last_revoke_generation
--             strictly increases) with flags non-increasing and versions/generations non-decreasing, as written
--             by set_capture_consent / revoke_capture_consent / legacy_set_device_consent / link_capture_device's narrow branch
--             (0110:361-363, 450-452, 461-466, 538-545, 635-639). last_seen_at may accompany a real narrowing but a last_seen_at-only
--             change (capture_auth.ts:168 touch) is NOT a narrowing. The UPDATE sets none of install_id_hash /
--             user_id / consent_owner_uid, so the owner-history tracker (0110:206) does not fire.
--   'unlink'  capture_devices: the exact column set public.unlink_capture_device writes (0110:662-675),
--             owner_generation advanced by one when an owner existed. Side effect: the tracker fires and marks the
--             install's history transitioned (kind 'history').
--   'history' capture_install_owner_history: the monotonic transition the tracker writes (0110:140-146,
--             160-162, 195-197): transitioned becomes/stays true, transitioned_at set once, nothing else.
create function account_fence.minimizing_update_kind(p_tbl text, o jsonb, n jsonb) returns text
language plpgsql immutable
set search_path = pg_catalog
as $$
begin
  if p_tbl = 'processed_captures' then
    -- expiry
    if o ->> 'state' in ('processing', 'processed', 'retryable', 'rejected') and n ->> 'state' = 'expired'
       and account_fence.only_changed(o, n, array['state', 'parsed', 'notification', 'sanitized_text', 'validator_result',
             'lease_until', 'next_attempt_at'])
       and n -> 'parsed' = '{}'::jsonb and n -> 'notification' = '{}'::jsonb and n ->> 'sanitized_text' is null
       and (n ->> 'validator_result' is null or n -> 'validator_result' = o -> 'validator_result')
       and n ->> 'lease_until' is null and n ->> 'next_attempt_at' is null then
      return 'content';
    end if;
    -- consent revocation fan-out
    if o ->> 'state' in ('processed', 'retryable', 'rejected') and o ->> 'consumed_at' is null
       and n ->> 'state' = 'rejected' and n ->> 'status' = 'rejected'
       and account_fence.only_changed(o, n, array['state', 'status', 'parsed', 'notification', 'sanitized_text', 'failure_reason'])
       and n -> 'parsed' = '{}'::jsonb and n -> 'notification' = '{}'::jsonb and n ->> 'sanitized_text' is null
       and (n ->> 'failure_reason' is not distinct from o ->> 'failure_reason'
            or (o ->> 'state' in ('processed', 'retryable') and n ->> 'failure_reason' = 'consent_revoked')) then
      return 'content';
    end if;
    return null;
  elsif p_tbl = 'capture_devices' then
    if account_fence.only_changed(o, n, array['cloud_processing_enabled', 'ai_consent_granted', 'consent_version',
          'consent_client_generation', 'last_revoke_generation', 'last_seen_at'])
       and (n ->> 'cloud_processing_enabled')::boolean <= (o ->> 'cloud_processing_enabled')::boolean
       and (n ->> 'ai_consent_granted')::boolean <= (o ->> 'ai_consent_granted')::boolean
       and (n ->> 'consent_version')::bigint >= (o ->> 'consent_version')::bigint
       and (n ->> 'consent_client_generation')::bigint >= (o ->> 'consent_client_generation')::bigint
       and coalesce((n ->> 'last_revoke_generation')::bigint, -1) >= coalesce((o ->> 'last_revoke_generation')::bigint, -1)
       and ((n ->> 'cloud_processing_enabled')::boolean < (o ->> 'cloud_processing_enabled')::boolean
            or (n ->> 'ai_consent_granted')::boolean < (o ->> 'ai_consent_granted')::boolean
            or coalesce((n ->> 'last_revoke_generation')::bigint, -1) > coalesce((o ->> 'last_revoke_generation')::bigint, -1)) then
      return 'narrow';
    end if;
    if account_fence.only_changed(o, n, array['owner_generation', 'consent_client_generation', 'last_revoke_generation',
          'user_id', 'consent_owner_uid', 'cloud_processing_enabled', 'ai_consent_granted', 'consent_version',
          'apns_token', 'token_updated_at', 'last_seen_at'])
       and n ->> 'user_id' is null and n ->> 'consent_owner_uid' is null
       and n ->> 'cloud_processing_enabled' = 'false' and n ->> 'ai_consent_granted' = 'false'
       and n ->> 'consent_version' = '0' and n ->> 'consent_client_generation' = '0'
       and n ->> 'last_revoke_generation' is null and n ->> 'apns_token' is null and n ->> 'token_updated_at' is null
       and (n ->> 'owner_generation')::bigint = (o ->> 'owner_generation')::bigint
             + (case when o ->> 'user_id' is not null or o ->> 'consent_owner_uid' is not null then 1 else 0 end) then
      return 'unlink';
    end if;
    return null;
  elsif p_tbl = 'capture_install_owner_history' then
    if account_fence.only_changed(o, n, array['transitioned', 'transitioned_at', 'updated_at'])
       and n ->> 'transitioned' = 'true' and n ->> 'transitioned_at' is not null
       and (o ->> 'transitioned_at' is null or n ->> 'transitioned_at' = o ->> 'transitioned_at') then
      return 'history';
    end if;
    return null;
  end if;
  return null;
end;
$$;

-- Cascade shape for DELETE (E1 / Q18). ONLY for tables that carry a real FK to auth.users ... ON DELETE CASCADE
-- (0001:3,17; 0005:5; 0008:7; 0014:29,91; 0019:16; 0020:18; 0021:8,34,70,97; 0031:9,31,63; 0044:6,63;
-- 0056:29,36,46; 0058:9; 0060:14; 0070:18; 0083:46,128,166,204,278; 0103:26) and ONLY on the cascading column, and
-- only when the cascading owner is already absent from Auth. Tables without such an FK (capture_devices,
-- metrics_rate_limits, gamification_awarded_transactions, admin_users, ...) get no exemption. The guard
-- additionally requires trigger nesting (pg_trigger_depth() >= 2) because the RI action runs inside the
-- parent's trigger. This proves a state predicate and nesting, NOT that Auth originated the DELETE.
create function account_fence.cascade_delete_allowed(p_tbl text, p_row jsonb) returns boolean
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
as $$
declare c text; v uuid;
begin
  c := case
    when p_tbl = 'profiles' then 'id'
    when p_tbl in ('referrals', 'referral_reward_progress', 'referral_reward_grants') then 'referrer_user_id'
    when p_tbl = any (array['user_accounts', 'user_transactions', 'user_budgets', 'user_goals', 'user_goal_contributions',
         'user_plans', 'user_plan_transaction_links', 'user_subscriptions', 'user_bill_payments', 'user_cards',
         'user_categories', 'user_settings', 'user_smart_inbox', 'sender_bank_mappings', 'user_achievements',
         'user_streaks', 'user_xp_levels', 'user_sync_state', 'backups', 'feature_flag_overrides',
         'financial_import_runs', 'user_engagement_events', 'referral_codes', 'user_entitlement_state']) then 'user_id'
    else null end;
  if c is null then
    return false;
  end if;
  v := nullif(p_row ->> c, '')::uuid;
  return v is not null and not account_fence.auth_user_exists(v);
end;
$$;

-- Guarded mutation for tables that service/DEFINER paths write directly. TG_ARGV = owner columns; a
-- trailing '?' marks a column that may name a deleted account (no Auth requirement); 'install:<col>' names the
-- install-hash column of an install-attributed table. BEFORE ROW.
--   1. a fixed erasure shape for the transaction's own subject passes;
--   2. a classified minimisation update passes (UPDATE only): 'content' needs nothing; 'narrow' / 'unlink' take
--      the install gate (shared / exclusive, allow-pending) and, for unlink, the workset check, exactly like the
--      RPCs; 'history' passes only while this backend holds the install gate exclusively;
--   3. a DELETE of a row whose cascading Auth owner is gone passes (nested Auth FK action only);
--   4. anything else is an ordinary write: capture_devices takes the install gate FIRST (the same install ->
--      account order as admit_install; exclusive when ownership can change), then OLD and NEW owners are try-gated;
--      every install reference on OLD and NEW is admitted through its known owner set (E2/Q15).
-- There is NO "absent Auth + owner -> NULL" cascade exception (E1): section 7 removes every reference
-- first; a residual reference fails the Auth deletion closed instead of being waved through.
create function account_fence.guard_owner_columns() returns trigger
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  a text; col text; v_strict boolean; o uuid; n uuid; jo jsonb; jn jsonb;
  v_ctx uuid := account_fence.erasure_uid();
  v_kind text; v_icol text; v_oh text; v_nh text; v_excl boolean; v_log_id uuid;
  v_retry_installs text[] := '{}'::text[]; v_hash text; v_ocol uuid;
begin
  if tg_op in ('UPDATE', 'DELETE') then jo := pg_catalog.to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then jn := pg_catalog.to_jsonb(new); end if;
  -- F3: BEFORE ROW triggers run before RLS WITH CHECK, so a direct API write naming ANOTHER user's strict owner column
  -- would reach admit(victim, true) and leak the victim's pending/missing/busy state (QD001/QD002/55P03) instead of the
  -- RLS answer 42501. Direct client DML exists only on the five client tables (the ones with restrictive fence policies);
  -- their RLS requires owner = auth.uid(), so refuse a mismatch with 42501 BEFORE any admission or lock. The role GUC is
  -- used because this function is SECURITY DEFINER (current_user is the narrow owner here); definer RPCs that legitimately
  -- write other users' rows do so on tables outside this list.
  if tg_op in ('INSERT', 'UPDATE')
     and tg_table_name in ('profiles', 'backups', 'notification_logs', 'feature_flag_overrides', 'financial_import_runs')
     and pg_catalog.current_setting('role', true) in ('anon', 'authenticated') then
    -- (a) strict owner columns must equal the caller; (b) optional ('?') owner columns must equal the caller WHEN non-null;
    -- (c) a client write may not set or change an install: column (see below). The client RLS policies for these
    -- tables (e.g. notification_logs_insert_own: auth.uid() = user_id) never admit a NULL or foreign owner, so refusing here
    -- changes no legitimate client write: install-only rows with a NULL user_id are service-side only.
    foreach a in array tg_argv loop
      continue when left(a, 8) = 'install:';
      v_ocol := nullif(jn ->> rtrim(a, '?'), '')::uuid;
      if v_ocol is not null and v_ocol is distinct from account_fence.auth_uid() then
        raise exception 'owner_column_mismatch' using errcode = '42501';
      end if;
      if right(a, 1) <> '?' and v_ocol is distinct from account_fence.auth_uid() then
        raise exception 'owner_column_mismatch' using errcode = '42501';
      end if;
    end loop;
    -- (c) install: columns (notification_logs.install_id_hash) are written by service-side RPCs only: the app payload carries the RAW
    -- install_id, never the hash. A client may not set one on INSERT or change one on UPDATE, otherwise it could make itself an
    -- owner of a victim's install (install_owners) or probe its state through admit_install before RLS answers.
    foreach a in array tg_argv loop
      continue when left(a, 8) <> 'install:';
      if (tg_op = 'INSERT' and nullif(jn ->> substr(a, 9), '') is not null)
         or (tg_op = 'UPDATE' and (jn ->> substr(a, 9)) is distinct from (jo ->> substr(a, 9))) then
        raise exception 'owner_column_mismatch' using errcode = '42501';
      end if;
    end loop;
  end if;
  -- Retry/log binding protocol (source-only, not a schema equality constraint): every log I/U/D takes
  -- BOTH identity TRY keys before checking children or ordinary/erasure admission. No row-lock wait is
  -- added. Retry mutations use the same keys before reading parent UUID/hash. Failed TRY aborts.
  if tg_table_name = 'notification_logs' then
    if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
      raise exception 'account_fence_isolation_unsupported' using errcode = '0A000';
    end if;
    for v_log_id in
      select distinct x from unnest(array[nullif(jo ->> 'id', '')::uuid, nullif(jn ->> 'id', '')::uuid]) x
       where x is not null order by x
    loop
      if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended('qirsh.account_fence.notification_log:' || v_log_id::text, 0)) then
        perform account_fence.deny('busy');
      end if;
    end loop;
    -- Separate READ COMMITTED statement after key acquisition. No historical-repair exception.
    -- OLD binding and proposed NEW binding must both remain valid for every attached child.
    if exists (select 1 from public.notification_retry_queue q
                where q.notification_log_id = any(array[nullif(jo ->> 'id', '')::uuid, nullif(jn ->> 'id', '')::uuid])
                  and (tg_op = 'DELETE'
                    or (jo is not null and q.notification_log_id = nullif(jo ->> 'id', '')::uuid
                        and (jo ->> 'install_id_hash' is null or q.install_id_hash is distinct from jo ->> 'install_id_hash'))
                    or (jn is not null and (q.notification_log_id is distinct from nullif(jn ->> 'id', '')::uuid
                        or jn ->> 'install_id_hash' is null or q.install_id_hash is distinct from jn ->> 'install_id_hash')))) then
      raise exception 'retry_parent_binding_unproven_or_child_still_present'
        using errcode = 'QD013', detail = 'fence:retry_attribution', hint = 'refuse_conflict_or_delete_reviewed_child_first';
    end if;
    select coalesce(array_agg(distinct q.install_id_hash), '{}'::text[]) into v_retry_installs
      from public.notification_retry_queue q
     where q.notification_log_id = any(array[nullif(jo ->> 'id', '')::uuid, nullif(jn ->> 'id', '')::uuid]);
  end if;
  if v_ctx is not null and account_fence.erasure_row_allowed(tg_table_name, tg_op, jo, jn, v_ctx) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  -- Ordinary log writes explicitly admit attached child installs too; binding equality is not admission.
  foreach v_hash in array v_retry_installs loop
    perform account_fence.admit_install(v_hash);
  end loop;
  foreach a in array tg_argv loop
    if left(a, 8) = 'install:' then v_icol := substr(a, 9); end if;
  end loop;
  if v_icol is not null then
    v_oh := jo ->> v_icol;
    v_nh := jn ->> v_icol;
  end if;
  if tg_op = 'UPDATE' then
    v_kind := account_fence.minimizing_update_kind(tg_table_name, jo, jn);
    if v_kind = 'content' then
      return new;
    elsif v_kind in ('narrow', 'unlink') then
      perform account_fence.admit_install(v_oh, true, v_kind = 'unlink');
      if v_kind = 'unlink' then
        perform account_fence.assert_unlink_allowed(v_oh);
      end if;
      return new;
    elsif v_kind = 'history' and account_fence.holds_install_gate(jo ->> 'install_id_hash', true) then
      return new;
    end if;
  end if;
  if tg_op = 'DELETE' and pg_catalog.pg_trigger_depth() >= 2 and account_fence.cascade_delete_allowed(tg_table_name, jo) then
    return old;
  end if;
  if tg_table_name = 'capture_devices' then
    v_excl := tg_op = 'DELETE'
      or (tg_op = 'INSERT' and (jn ->> 'user_id' is not null or jn ->> 'consent_owner_uid' is not null))
      or (tg_op = 'UPDATE' and (jo ->> 'user_id' is distinct from jn ->> 'user_id'
                                or jo ->> 'consent_owner_uid' is distinct from jn ->> 'consent_owner_uid'));
    perform account_fence.admit_install(coalesce(v_nh, v_oh), false, v_excl);
  end if;
  -- Non-device rows may reference BOTH source and consumed installs. Gate/admit OLD and NEW for each.
  -- Historical pending owners cannot be hidden by supplying an explicit healthy UUID.
  if tg_table_name <> 'capture_devices' then
    foreach a in array tg_argv loop
      if left(a, 8) = 'install:' then
        v_oh := jo ->> substr(a, 9); v_nh := jn ->> substr(a, 9);
        if v_oh is not null then perform account_fence.admit_install(v_oh); end if;
        if v_nh is not null and v_nh is distinct from v_oh then perform account_fence.admit_install(v_nh); end if;
      end if;
    end loop;
  end if;
  foreach a in array tg_argv loop
    continue when left(a, 8) = 'install:';
    col := rtrim(a, '?');
    v_strict := right(a, 1) <> '?';
    o := case when jo is null then null else nullif(jo ->> col, '')::uuid end;
    n := case when jn is null then null else nullif(jn ->> col, '')::uuid end;
    if o is not null and o is distinct from n then
      perform account_fence.admit(o, false);
    end if;
    if n is not null then
      perform account_fence.admit(n, v_strict);
    end if;
  end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

-- Install-keyed I/U/D: retry parent UUID/install AND child install are admitted on OLD and NEW.
-- Parent identities are frozen by transaction TRY keys shared with every log I/U/D, including erasure.
-- Hash equality is a guarded contract, not an invented schema constraint or proof of exclusive ownership.
-- Claim/reclaim remains ordinary work scheduling; only the exact resolution block below passes unadmitted.
create function account_fence.guard_install_column() returns trigger
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  jo jsonb; jn jsonb; v_old text; v_new text; v_ctx uuid := account_fence.erasure_uid();
  v_log_id uuid; v_side jsonb; v_parent public.notification_logs%rowtype;
  v_parent_uids uuid[] := '{}'::uuid[]; v_installs text[] := '{}'::text[]; v_uid uuid; v_hash text;
begin
  if tg_op in ('UPDATE', 'DELETE') then jo := pg_catalog.to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then jn := pg_catalog.to_jsonb(new); end if;
  if tg_table_name = 'notification_retry_queue' and tg_op = 'UPDATE'
     and account_fence.only_changed(jo, jn, array['resolved_at', 'updated_at'])
     and jo ->> 'resolved_at' is null and jn ->> 'resolved_at' is not null then
    return new;     -- claim timestamp, install, parent, payload and attempt fields are unchanged
  end if;
  if tg_table_name = 'notification_retry_queue' then
    if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
      raise exception 'account_fence_isolation_unsupported' using errcode = '0A000';
    end if;
    -- Acquire ALL OLD/NEW parent keys before the first parent read/admission; held until transaction end.
    for v_log_id in
      select distinct x from unnest(array[nullif(jo ->> 'notification_log_id', '')::uuid,
                                          nullif(jn ->> 'notification_log_id', '')::uuid]) x
       where x is not null order by x
    loop
      if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended('qirsh.account_fence.notification_log:' || v_log_id::text, 0)) then
        perform account_fence.deny('busy');
      end if;
    end loop;
    -- Fresh statement snapshots under READ COMMITTED AFTER acquiring the keys. No SELECT FOR UPDATE,
    -- no lock wait and no extra parent UPDATE grant. Parent writes use those same keys in the guard above.
    for v_side in select x from unnest(array[jo, jn]) x where x is not null loop
      select * into v_parent from public.notification_logs
       where id = nullif(v_side ->> 'notification_log_id', '')::uuid;
      if not found or v_parent.install_id_hash is null
         or v_parent.install_id_hash is distinct from v_side ->> 'install_id_hash' then
        raise exception 'retry_parent_binding_unproven'
          using errcode = 'QD013', detail = 'fence:retry_attribution', hint = 'refuse_conflicting_or_missing_parent';
      end if;
      v_parent_uids := array_append(v_parent_uids, v_parent.user_id);
      -- Both references are collected/admitted explicitly; equality alone is never owner admission.
      v_installs := array_append(v_installs, v_parent.install_id_hash);
      v_installs := array_append(v_installs, v_side ->> 'install_id_hash');
    end loop;
  end if;
  if v_ctx is not null and account_fence.erasure_row_allowed(tg_table_name, tg_op, jo, jn, v_ctx) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if tg_table_name = 'notification_retry_queue' then
    for v_hash in select distinct x from unnest(v_installs) x where x is not null order by x loop
      perform account_fence.admit_install(v_hash);
    end loop;
    for v_uid in select distinct x from unnest(v_parent_uids) x where x is not null order by x loop
      perform account_fence.admit(v_uid);
    end loop;
  else
    v_old := jo ->> tg_argv[0]; v_new := jn ->> tg_argv[0];
    if v_old is not null then perform account_fence.admit_install(v_old); end if;
    if v_new is not null and v_new is distinct from v_old then perform account_fence.admit_install(v_new); end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

-- Lease check WITHOUT a row lock: returns the subject uid iff the lease is current by DATABASE clock now.
-- Used only to learn which gate to take before any job-row lock is acquired (lock order, DECISIONS.md).
create function account_fence.lease_peek(p_job_id uuid, p_token uuid, p_generation integer)
returns uuid
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
  select j.uid from account_fence.deletion_job j
   where j.job_id = p_job_id and j.lease_token = p_token and j.lease_generation = p_generation
     and j.lease_expires_at > pg_catalog.clock_timestamp() and j.state = 'running'
$$;

-- Lock by identity FIRST, then sample a new database clock and validate every lease field.
-- A lock-only blocker need not update the row; no freshness claim depends on WHERE re-evaluation.
create function account_fence.lease_job(p_job_id uuid, p_token uuid, p_generation integer)
returns account_fence.deletion_job
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare j account_fence.deletion_job; v_now timestamptz;
begin
  select * into j from account_fence.deletion_job where job_id = p_job_id for update;
  if not found then return null; end if;
  v_now := pg_catalog.clock_timestamp();
  if j.lease_token is distinct from p_token or p_token is null
     or j.lease_generation is distinct from p_generation or p_generation is null
     or j.state is distinct from 'running' or j.lease_expires_at is null
     or j.lease_expires_at <= v_now then
    return null;
  end if;
  return j;
end;
$$;

-- O5 (PENDING OWNER APPROVAL): the ONLY exception to feature_flag_admin_audit's append-only rule (section 8):
-- actor -> NULL and reason -> the fixed tombstone, for the subject currently being erased, nothing else.
create function account_fence.audit_redaction_ok(o jsonb, n jsonb) returns boolean
language sql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
  select account_fence.in_erasure(nullif(o ->> 'actor_admin_id', '')::uuid)
     and n ->> 'actor_admin_id' is null
     and account_fence.only_changed(o, n, array['actor_admin_id', 'reason'])
     and n ->> 'reason' is not distinct from account_fence.deletion_tombstone()
$$;

-- (guard functions for the legacy route are defined in section 8; their triggers are created there)


-- ════════════════════════════════════════════════════════════════════════════
-- 3. Direct DML closure (literal statements; E2 inventory in inventory.md)
-- ════════════════════════════════════════════════════════════════════════════

-- 4a. Restrictive early-admission policies for authenticated (pre-lock). Triggers in 4b
-- additionally cover service_role and DEFINER writers, which bypass RLS.
create policy account_fence_profiles_ins on public.profiles as restrictive for insert to authenticated
  with check (account_fence.admit_check_self(id));
create policy account_fence_profiles_upd on public.profiles as restrictive for update to authenticated
  using (account_fence.admit_check_self(id)) with check (account_fence.admit_check_self(id));
create policy account_fence_profiles_del on public.profiles as restrictive for delete to authenticated
  using (account_fence.admit_check_self(id));
create policy account_fence_backups_ins on public.backups as restrictive for insert to authenticated
  with check (account_fence.admit_check_self(user_id));
create policy account_fence_backups_upd on public.backups as restrictive for update to authenticated
  using (account_fence.admit_check_self(user_id)) with check (account_fence.admit_check_self(user_id));
create policy account_fence_backups_del on public.backups as restrictive for delete to authenticated
  using (account_fence.admit_check_self(user_id));
create policy account_fence_notification_logs_ins on public.notification_logs as restrictive for insert to authenticated
  with check (account_fence.admit_check_self(user_id));
create policy account_fence_notification_logs_upd on public.notification_logs as restrictive for update to authenticated
  using (account_fence.admit_check_self(user_id)) with check (account_fence.admit_check_self(user_id));
create policy account_fence_notification_logs_del on public.notification_logs as restrictive for delete to authenticated
  using (account_fence.admit_check_self(user_id));
create policy account_fence_feature_flag_overrides_ins on public.feature_flag_overrides as restrictive for insert to authenticated
  with check (account_fence.admit_check_self(user_id));
create policy account_fence_feature_flag_overrides_upd on public.feature_flag_overrides as restrictive for update to authenticated
  using (account_fence.admit_check_self(user_id)) with check (account_fence.admit_check_self(user_id));
create policy account_fence_feature_flag_overrides_del on public.feature_flag_overrides as restrictive for delete to authenticated
  using (account_fence.admit_check_self(user_id));
create policy account_fence_financial_import_runs_ins on public.financial_import_runs as restrictive for insert to authenticated
  with check (account_fence.admit_check_self(user_id));
create policy account_fence_financial_import_runs_upd on public.financial_import_runs as restrictive for update to authenticated
  using (account_fence.admit_check_self(user_id)) with check (account_fence.admit_check_self(user_id));
create policy account_fence_financial_import_runs_del on public.financial_import_runs as restrictive for delete to authenticated
  using (account_fence.admit_check_self(user_id));

-- 4b. Guard triggers, named a0_* so they fire before every other BEFORE trigger on the table.
create trigger a0_account_fence_guard before delete on public.user_accounts
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_transactions
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_budgets
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_goals
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_goal_contributions
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_plans
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_plan_transaction_links
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_subscriptions
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_bill_payments
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_cards
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_categories
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_settings
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_smart_inbox
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.sender_bank_mappings
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_achievements
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_streaks
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before delete on public.user_xp_levels
  for each row execute function account_fence.guard_owner_columns('user_id');
-- E2.1: user_sync_state is granted ALL to service_role (0103:44); INSERT and UPDATE are guarded as well as DELETE.
-- (The create_user_sync_state trigger 0103:62-71 inserts AFTER the Auth row exists, so a new account passes.)
create trigger a0_account_fence_guard before insert or update or delete on public.user_sync_state
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.profiles
  for each row execute function account_fence.guard_owner_columns('id');
create trigger a0_account_fence_guard before insert or update or delete on public.backups
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.feature_flag_overrides
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.financial_import_runs
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.user_engagement_events
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.metrics_rate_limits
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.gamification_awarded_transactions
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.notification_logs
  for each row execute function account_fence.guard_owner_columns('user_id?', 'install:install_id_hash');
create trigger a0_account_fence_guard before insert or update or delete on public.capture_devices
  for each row execute function account_fence.guard_owner_columns('user_id', 'consent_owner_uid', 'install:install_id_hash');
create trigger a0_account_fence_guard before insert or update or delete on public.processed_captures
  for each row execute function account_fence.guard_owner_columns('claimed_user_id', 'owner_uid', 'consent_owner_uid', 'install:install_id_hash', 'install:consumed_by_install_hash');
create trigger a0_account_fence_guard before insert or update or delete on public.capture_install_owner_history
  for each row execute function account_fence.guard_owner_columns('first_owner_uid?');
create trigger a0_account_fence_guard before insert or update or delete on public.referrals
  for each row execute function account_fence.guard_owner_columns('referrer_user_id', 'referred_user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.referral_codes
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.referral_reward_progress
  for each row execute function account_fence.guard_owner_columns('referrer_user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.referral_reward_grants
  for each row execute function account_fence.guard_owner_columns('referrer_user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.user_entitlement_state
  for each row execute function account_fence.guard_owner_columns('user_id');
create trigger a0_account_fence_guard before insert or update or delete on public.entitlement_events
  for each row execute function account_fence.guard_owner_columns('user_id?', 'actor_admin_id?');
create trigger a0_account_fence_guard before insert or update or delete on public.referral_reward_rules
  for each row execute function account_fence.guard_owner_columns('created_by?');
create trigger a0_account_fence_guard before insert or update or delete on public.referral_admin_audit
  for each row execute function account_fence.guard_owner_columns('actor_admin_id?', 'target_user_id?');
create trigger a0_account_fence_guard before insert or update or delete on public.announcement_admin_audit
  for each row execute function account_fence.guard_owner_columns('actor_admin_id');
create trigger a0_account_fence_guard before insert on public.feature_flag_admin_audit
  for each row execute function account_fence.guard_owner_columns('actor_admin_id');
create trigger a0_account_fence_guard before insert or update or delete on public.admin_users
  for each row execute function account_fence.guard_owner_columns('id', 'granted_by?');
-- install-keyed relay tables (no uuid owner column): admission through the install owner set
create trigger a0_account_fence_guard before insert or update or delete on public.notification_retry_queue
  for each row execute function account_fence.guard_install_column('install_id_hash');
create trigger a0_account_fence_guard before insert or update or delete on public.capture_fingerprints
  for each row execute function account_fence.guard_install_column('install_id_hash');

-- 4c. Direct DML/column/TRUNCATE privilege delta (effective role closure is asserted in section 10).
-- Q14 recommended privilege delta, PENDING OWNER APPROVAL BEFORE ADOPTION/APPLICATION.
revoke truncate on table public.account_purge_queue,
  public.admin_users,
  public.ai_request_idempotency,
  public.announcement_admin_audit,
  public.backups,
  public.capture_devices,
  public.capture_fingerprints,
  public.capture_install_owner_history,
  public.capture_rate_limits,
  public.entitlement_events,
  public.feature_flag_admin_audit,
  public.feature_flag_overrides,
  public.financial_import_runs,
  public.gamification_awarded_transactions,
  public.metrics_rate_limits,
  public.notification_logs,
  public.notification_retry_queue,
  public.processed_captures,
  public.profiles,
  public.referral_admin_audit,
  public.referral_codes,
  public.referral_reward_grants,
  public.referral_reward_progress,
  public.referral_reward_rules,
  public.referrals,
  public.sender_bank_mappings,
  public.user_accounts,
  public.user_achievements,
  public.user_bill_payments,
  public.user_budgets,
  public.user_cards,
  public.user_categories,
  public.user_engagement_events,
  public.user_entitlement_state,
  public.user_goal_contributions,
  public.user_goals,
  public.user_plan_transaction_links,
  public.user_plans,
  public.user_settings,
  public.user_smart_inbox,
  public.user_streaks,
  public.user_subscriptions,
  public.user_sync_state,
  public.user_transactions,
  public.user_xp_levels from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate, references, trigger on table public.capture_rate_limits from public, anon, authenticated, service_role;
revoke insert (install_id_hash, date, call_count), update (install_id_hash, date, call_count), references (install_id_hash, date, call_count) on table public.capture_rate_limits from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate, references, trigger on table public.ai_request_idempotency from public, anon, authenticated, service_role;
revoke insert (owner_key, endpoint, request_id, payload_hash, status, result, created_at, expires_at), update (owner_key, endpoint, request_id, payload_hash, status, result, created_at, expires_at), references (owner_key, endpoint, request_id, payload_hash, status, result, created_at, expires_at) on table public.ai_request_idempotency from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate, references, trigger on table public.user_sync_state from public, anon, authenticated, service_role;
revoke insert (user_id, last_seq, epoch, epoch_reason, updated_at), update (user_id, last_seq, epoch, epoch_reason, updated_at), references (user_id, last_seq, epoch, epoch_reason, updated_at) on table public.user_sync_state from public, anon, authenticated, service_role;
-- Unknown future columns or membership-derived grants are refused by section 10, not silently revoked.

-- 4d. Narrow erasure privileges for account_fence_owner (E1). Row-level reach is bounded by the
-- policies below: every predicate is false outside an erasure transaction (erasure_uid() is NULL).
-- (No grant on schema auth / auth.users / auth.uid() / auth.identities: the migration role cannot grant them; see the
-- account_fence.auth_* shims after `create schema account_fence`.)
-- D4/contract section 4: account_deletion_apple_subject reads the Apple `sub` of the caller-supplied uid. Column-level,
-- read-only. If RLS were enabled on auth.identities the narrow owner would see no row (-> null -> mismatch, fail closed).
-- Contract section 1: the challenge issuer draws 32 CSPRNG bytes twice (pgcrypto; sha256 is built in).
grant usage on schema extensions to account_fence_owner;
grant execute on function extensions.gen_random_bytes(integer) to account_fence_owner;
grant select, delete on table public.user_accounts to account_fence_owner;
create policy account_fence_erasure on public.user_accounts as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_transactions to account_fence_owner;
create policy account_fence_erasure on public.user_transactions as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_budgets to account_fence_owner;
create policy account_fence_erasure on public.user_budgets as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_goals to account_fence_owner;
create policy account_fence_erasure on public.user_goals as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_goal_contributions to account_fence_owner;
create policy account_fence_erasure on public.user_goal_contributions as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_plans to account_fence_owner;
create policy account_fence_erasure on public.user_plans as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_plan_transaction_links to account_fence_owner;
create policy account_fence_erasure on public.user_plan_transaction_links as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_subscriptions to account_fence_owner;
create policy account_fence_erasure on public.user_subscriptions as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_bill_payments to account_fence_owner;
create policy account_fence_erasure on public.user_bill_payments as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_cards to account_fence_owner;
create policy account_fence_erasure on public.user_cards as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_categories to account_fence_owner;
create policy account_fence_erasure on public.user_categories as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_settings to account_fence_owner;
create policy account_fence_erasure on public.user_settings as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_smart_inbox to account_fence_owner;
create policy account_fence_erasure on public.user_smart_inbox as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.sender_bank_mappings to account_fence_owner;
create policy account_fence_erasure on public.sender_bank_mappings as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_achievements to account_fence_owner;
create policy account_fence_erasure on public.user_achievements as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_streaks to account_fence_owner;
create policy account_fence_erasure on public.user_streaks as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_xp_levels to account_fence_owner;
create policy account_fence_erasure on public.user_xp_levels as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_sync_state to account_fence_owner;
create policy account_fence_erasure on public.user_sync_state as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.profiles to account_fence_owner;
create policy account_fence_erasure on public.profiles as permissive for all to account_fence_owner
  using (id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.backups to account_fence_owner;
create policy account_fence_erasure on public.backups as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.feature_flag_overrides to account_fence_owner;
create policy account_fence_erasure on public.feature_flag_overrides as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.financial_import_runs to account_fence_owner;
create policy account_fence_erasure on public.financial_import_runs as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_engagement_events to account_fence_owner;
create policy account_fence_erasure on public.user_engagement_events as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.metrics_rate_limits to account_fence_owner;
create policy account_fence_erasure on public.metrics_rate_limits as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.gamification_awarded_transactions to account_fence_owner;
create policy account_fence_erasure on public.gamification_awarded_transactions as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.referrals to account_fence_owner;
grant update (referred_user_id, referred_user_deleted_at) on table public.referrals to account_fence_owner;
create policy account_fence_erasure on public.referrals as permissive for all to account_fence_owner
  using (referrer_user_id = account_fence.erasure_uid() or referred_user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.referral_reward_grants to account_fence_owner;
create policy account_fence_erasure on public.referral_reward_grants as permissive for all to account_fence_owner
  using (referrer_user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.referral_reward_progress to account_fence_owner;
create policy account_fence_erasure on public.referral_reward_progress as permissive for all to account_fence_owner
  using (referrer_user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.referral_codes to account_fence_owner;
create policy account_fence_erasure on public.referral_codes as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.user_entitlement_state to account_fence_owner;
create policy account_fence_erasure on public.user_entitlement_state as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.entitlement_events to account_fence_owner;
grant update (actor_admin_id, reason) on table public.entitlement_events to account_fence_owner;
create policy account_fence_erasure on public.entitlement_events as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid() or actor_admin_id = account_fence.erasure_uid()) with check (true);
grant select on table public.referral_admin_audit to account_fence_owner;
grant update (target_user_id, target_ref, reason, before_state, after_state, actor_admin_id) on table public.referral_admin_audit to account_fence_owner;
create policy account_fence_erasure on public.referral_admin_audit as permissive for all to account_fence_owner
  using (target_user_id = account_fence.erasure_uid() or actor_admin_id = account_fence.erasure_uid()) with check (true);
grant select on table public.referral_reward_rules to account_fence_owner;
grant update (created_by) on table public.referral_reward_rules to account_fence_owner;
create policy account_fence_erasure on public.referral_reward_rules as permissive for all to account_fence_owner
  using (created_by = account_fence.erasure_uid()) with check (true);
grant select on table public.announcement_admin_audit to account_fence_owner;
grant update (actor_admin_id, reason) on table public.announcement_admin_audit to account_fence_owner;
create policy account_fence_erasure on public.announcement_admin_audit as permissive for all to account_fence_owner
  using (actor_admin_id = account_fence.erasure_uid()) with check (true);
grant select on table public.feature_flag_admin_audit to account_fence_owner;
grant update (actor_admin_id, reason) on table public.feature_flag_admin_audit to account_fence_owner;
create policy account_fence_erasure on public.feature_flag_admin_audit as permissive for all to account_fence_owner
  using (actor_admin_id = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.processed_captures to account_fence_owner;
grant update (claimed_user_id, owner_uid, consent_owner_uid, consumed_by_install_hash) on table public.processed_captures to account_fence_owner;
create policy account_fence_erasure on public.processed_captures as permissive for all to account_fence_owner
  using (claimed_user_id = account_fence.erasure_uid() or owner_uid = account_fence.erasure_uid()
      or consent_owner_uid = account_fence.erasure_uid() or install_id_hash = any(account_fence.erasure_exclusive_installs())
      or consumed_by_install_hash = any(account_fence.erasure_exclusive_installs()))
  with check (account_fence.erasure_uid() is not null);
grant select on table public.capture_install_owner_history to account_fence_owner;
grant update (first_owner_uid, transitioned, transitioned_at, updated_at) on table public.capture_install_owner_history to account_fence_owner;
create policy account_fence_erasure on public.capture_install_owner_history as permissive for all to account_fence_owner
  using (first_owner_uid = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.capture_devices to account_fence_owner;
grant update (user_id, owner_generation, apns_token, token_updated_at, consent_owner_uid, cloud_processing_enabled, ai_consent_granted, consent_version, consent_client_generation, last_revoke_generation) on table public.capture_devices to account_fence_owner;
create policy account_fence_erasure on public.capture_devices as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid() or consent_owner_uid = account_fence.erasure_uid()) with check (true);
grant select, delete on table public.capture_rate_limits to account_fence_owner;
create policy account_fence_erasure on public.capture_rate_limits as permissive for all to account_fence_owner
  using (account_fence.rate_key_in_scope(install_id_hash)) with check (true);
grant select, delete on table public.ai_request_idempotency to account_fence_owner;
create policy account_fence_erasure on public.ai_request_idempotency as permissive for all to account_fence_owner
  using (account_fence.owner_key_in_scope(owner_key)) with check (true);
grant select, delete on table public.notification_logs to account_fence_owner;
create policy account_fence_erasure on public.notification_logs as permissive for all to account_fence_owner
  using (user_id = account_fence.erasure_uid() or (user_id is null and install_id_hash = any (account_fence.erasure_exclusive_installs()))) with check (true);
grant select, delete on table public.admin_users to account_fence_owner;
grant update (granted_by) on table public.admin_users to account_fence_owner;
create policy account_fence_erasure on public.admin_users as permissive for all to account_fence_owner
  using (id = account_fence.erasure_uid() or granted_by = account_fence.erasure_uid()) with check (true);
-- D7: the challenge issuer and acceptance (running as the narrow owner OUTSIDE an erasure transaction) must see whether
-- the subject is an admin. The erasure policy above is false there, so without this read-only policy the check would
-- silently find nobody. SELECT only (no write reach); a separate READ privilege like the discovery policies below.
create policy account_fence_discovery on public.admin_users as permissive for select to account_fence_owner using (true);
-- E1.4: DISCOVERY policies. These are `using (true)`: the narrow owner can READ these tables at ALL times, not
-- only during erasure (only its writes are bounded by the erasure predicates). Separate privilege; needs approval.
create policy account_fence_discovery on public.capture_devices as permissive for select to account_fence_owner using (true);
create policy account_fence_discovery on public.processed_captures as permissive for select to account_fence_owner using (true);
create policy account_fence_discovery on public.notification_logs as permissive for select to account_fence_owner using (true);
create policy account_fence_discovery on public.capture_install_owner_history as permissive for select to account_fence_owner using (true);
create policy account_fence_discovery on public.referrals as permissive for select to account_fence_owner using (true);
create policy account_fence_discovery on public.referral_codes as permissive for select to account_fence_owner using (true);
grant select on table public.capture_devices, public.processed_captures, public.capture_install_owner_history,
  public.referrals, public.referral_codes to account_fence_owner;
grant select, delete on table public.notification_retry_queue, public.capture_fingerprints to account_fence_owner;
create policy account_fence_erasure on public.notification_retry_queue as permissive for delete to account_fence_owner
  using (account_fence.erasure_uid() is not null
    and install_id_hash = any(account_fence.erasure_exclusive_installs())
    and account_fence.holds_install_gate(install_id_hash, true)
    and exists (select 1 from public.notification_logs l
      where l.id = notification_log_id and l.install_id_hash is not null
        and l.install_id_hash = notification_retry_queue.install_id_hash
        and (l.user_id = account_fence.erasure_uid()
          or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs())))));
create policy account_fence_erasure on public.capture_fingerprints as permissive for delete to account_fence_owner
  using (install_id_hash = any(account_fence.erasure_exclusive_installs()));
create policy account_fence_discovery on public.notification_retry_queue as permissive for select to account_fence_owner using (true);
create policy account_fence_discovery on public.capture_fingerprints as permissive for select to account_fence_owner using (true);

-- ════════════════════════════════════════════════════════════════════════════
-- 4. Hooks in the existing mutation authorities (bodies restated from source)
-- ════════════════════════════════════════════════════════════════════════════

-- Restated from 0105_stamp_sync_seq_triggers.sql:36-60 + admission. The late row trigger only TRY-locks
-- (never waits for the gate while holding a tuple). DELETE is covered by the guard triggers of section 3.
create or replace function public.stamp_sync_seq()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_seq bigint;
begin
  if tg_op = 'INSERT' then                                  -- [fence]
    perform account_fence.admit(new.user_id);               -- [fence]
  else                                                      -- [fence]
    perform account_fence.admit(old.user_id);               -- [fence]
    if new.user_id is distinct from old.user_id then        -- [fence]
      perform account_fence.admit(new.user_id);             -- [fence]
    end if;                                                 -- [fence]
  end if;                                                   -- [fence]
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

-- Restated from 0107_sync_cas_rpcs.sql:179-198 + admission BEFORE the state INSERT/lock, so a CAS writer
-- never holds user_sync_state while waiting.
create or replace function public.sync_lock_epoch()
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_epoch uuid;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  perform account_fence.admit(v_uid);                       -- [fence]
  insert into public.user_sync_state (user_id, epoch_reason)
  values (v_uid, 'initial')
  on conflict (user_id) do nothing;
  select epoch into v_epoch from public.user_sync_state where user_id = v_uid for update;
  return v_epoch;
end;
$$;

-- Restated from 0086_backups_owner_liveness.sql:40-53. Pending covers the pre-Auth phase; Auth liveness
-- (original predicate) covers the post-Auth phase. A DB policy cannot prove Storage bytes stop arriving:
-- the terminal sweep and real Storage tests remain required (E8).
create or replace function public.backups_owner_is_live()
returns boolean
language sql
volatile
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1 from auth.users as u where u.id = (select auth.uid()) for key share
  ) and not account_fence.is_pending((select auth.uid()));
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- 5. Restated RPC bodies with admission (E3) — explicit CREATE OR REPLACE, same OID/ACL/owner/config
-- ════════════════════════════════════════════════════════════════════════════
-- No function is moved, wrapped or generated at apply time. Each authoritative body is restated with
-- admission lines tagged `-- [fence]` and nothing else; CREATE OR REPLACE keeps the OID (so dependent
-- triggers/defaults keep their bindings), owner, ACL and grant options. INVOKER functions stay INVOKER
-- (caller authorization unchanged). The old bodies do not survive anywhere callable.
-- >>> GENERATED:BEGIN rpc_bodies
-- Generated by gen_rpc_bodies.py from supabase/migrations (read-only). Do not hand-edit.
-- Every line added to a verbatim body carries the tag `-- [fence]`; `diff` against the cited
-- migration range must show nothing else.

-- [gen] public.set_default_account(uuid)
--   source: supabase/migrations/0025_set_default_account_rpc.sql:35-67
--   verbatim statement sha256: 66c805487175e91769f5e185903efad1dc31bf30145b761f43bd46bf841304bb
--   original body md5 (pg_proc.prosrc preflight): 79c44bea7ba558163f8c66a36b34d3d8
create or replace function public.set_default_account(p_account_id uuid)
returns public.user_accounts
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_result public.user_accounts;
begin
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.add_goal_contribution(uuid,text,text,numeric,timestamp with time zone,text)
--   source: supabase/migrations/0078_goal_contribution_exact_saved_amount.sql:36-80
--   verbatim statement sha256: 73d3e2d41ff5ee7fafaea73ba7725cd8634c347bb9c34d557820def1c1b003e2
--   original body md5 (pg_proc.prosrc preflight): 7855b38e41c1a98213e2d74381b1b0df
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
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.record_bill_payment(uuid,uuid,text,text,numeric,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,integer,text)
--   source: supabase/migrations/0031_financial_feature_children.sql:220-265
--   verbatim statement sha256: 51f84da2520e3a8aecc279a4992e9daf4eec0ab3d42817f127e37481a8698e00
--   original body md5 (pg_proc.prosrc preflight): 64eabc9f055c54a457efd9c9a05ca09d
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
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.delete_bill_payment(uuid)
--   source: supabase/migrations/0108_delete_bill_payment_idempotent.sql:22-52
--   verbatim statement sha256: b895d74cb01acc0eeb65a3f95a05ca69b991ed202fe251f66f058143a6ffe75f
--   original body md5 (pg_proc.prosrc preflight): 7c67d920d676b850051fd909c25b2878
CREATE OR REPLACE FUNCTION public.delete_bill_payment(p_payment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
declare
  payment_row public.user_bill_payments%rowtype;
  subscription_row public.user_subscriptions%rowtype;
begin
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.delete_user_account_safely(uuid)
--   source: supabase/migrations/0037_atomic_account_deletion.sql:4-68
--   verbatim statement sha256: 8531f67ee21146b7db25f77b77c73675cf591b0d38ac4387ad37d0327aeb973d
--   original body md5 (pg_proc.prosrc preflight): b4cb58e6bb98606f38e3e74781425989
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
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.create_subscription_and_record_payment(text,text,text,numeric,text,text,text,timestamp with time zone,timestamp with time zone,uuid,text,boolean,boolean,integer,text,text,integer,integer,numeric,numeric,text,numeric,numeric,timestamp with time zone,timestamp with time zone,timestamp with time zone,integer,text)
--   source: supabase/migrations/0041_fix_bill_payment_rpc_paid_count_overwrite.sql:20-122
--   verbatim statement sha256: 9264ffd60c8bffac0ab81b5b7ca4cd1e8ae1a10abe0695813d4647edfe91be1d
--   original body md5 (pg_proc.prosrc preflight): c8a53eeb0bfe523233a1b8bd0843d5ce
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
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.delete_user_category_safely(uuid)
--   source: supabase/migrations/0044_financial_data_portability.sql:82-100
--   verbatim statement sha256: aeb8bd408818da0012846d7cabf01ee2250995a8f5f394e0737f19c36e9fcc17
--   original body md5 (pg_proc.prosrc preflight): cac14d6e1695c8daa18a4255c94947f5
create or replace function public.delete_user_category_safely(p_category_id uuid)
returns public.user_categories
language plpgsql security invoker set search_path = public as $$
declare
  uid uuid := auth.uid();
  result public.user_categories%rowtype;
begin
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.import_financial_package(text,text,jsonb)
--   source: supabase/migrations/0051_fix_import_rpc_budget_schema.sql:1-249
--   verbatim statement sha256: da6fbd9cd8c7d9ff6a2adef411a922d3062291de966dd4ec4bb4264ae5472164
--   original body md5 (pg_proc.prosrc preflight): f160f3c38f6fa73239ec3d272bf2db77
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
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.mark_onboarding_completed()
--   source: supabase/migrations/0043_profile_onboarding_completion.sql:21-44
--   verbatim statement sha256: 7765123f93d2d78c19fdf260e217345f7322c47135a46a438a4df8dd040ef02b
--   original body md5 (pg_proc.prosrc preflight): c6afaa88b52afaf43e1879fb87242e5a
create or replace function public.mark_onboarding_completed()
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  completed_at timestamptz;
begin
  perform account_fence.admit_self();  -- [fence]
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

-- [gen] public.record_engagement_event(uuid,text,timestamp with time zone,text,integer)
--   source: supabase/migrations/0070_engagement_events.sql:57-145
--   verbatim statement sha256: 75e1c1ba2f0ebe9c4db540ba8887de37aa9c38a128afcff5cc8b68a83f7f4c94
--   original body md5 (pg_proc.prosrc preflight): e9b10e0c75a1699d7d28febfa83d622f
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
  perform account_fence.admit(auth.uid());  -- [fence]
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

-- [gen] public.record_metric(text,text)
--   source: supabase/migrations/0072_backend_security_hardening.sql:76-110
--   verbatim statement sha256: dece054b817fd4fb3a13824bbc1000098fd746ef2864deb59049bc5be4021d17
--   original body md5 (pg_proc.prosrc preflight): d38dd967625dbea6370ac8bd30385955
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
  perform account_fence.admit(auth.uid());  -- [fence]
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

-- [gen] public.commit_backup_generation(text,text,integer,bigint,text,text,text)
--   source: supabase/migrations/0076_backup_generation_cas.sql:25-119
--   verbatim statement sha256: 78487c0680b5ac3d7c4f796bc4f517716b318de39ff41a3b8e49895f3b71f74f
--   original body md5 (pg_proc.prosrc preflight): cd88648fac26b202ff511e0631dd6c67
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
  perform account_fence.admit(auth.uid());  -- [fence]
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

-- [gen] public.get_referral_summary()
--   source: supabase/migrations/0083_referral_rewards.sql:906-959
--   verbatim statement sha256: 38c0d758b66d7f9e1dbac408625293815b1ac06164ebd1c015578d9b9eb85011
--   original body md5 (pg_proc.prosrc preflight): 5d511b088a0335bc84c97b197faae2df
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
  perform account_fence.admit(auth.uid());  -- [fence]
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  select code into v_code from public.referral_codes where user_id = v_uid and status = 'active';  -- [fence] D6: read the existing code only; creation is retired

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

-- [gen] public.ensure_referral_code(uuid)
--   source: supabase/migrations/0083_referral_rewards.sql:462-503
--   verbatim statement sha256: beab2db249601be10f16e7122679c42f232485149c7e6c0c628b02f31adce65c
--   original body md5 (pg_proc.prosrc preflight): 7e6cb223413b90160f9505e2014b2258
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.apply_entitlement_mutation(text,uuid,text,text,text,integer,text,uuid,integer,integer,uuid,text)
--   source: supabase/migrations/0085_concurrency_absent_row_locking.sql:58-223
--   verbatim statement sha256: 533e16e7f2cd03664e8e1d7510467af3a29d64b3b21ce1eab3623d6e62fdd712
--   original body md5 (pg_proc.prosrc preflight): 363c5c7d7695350fc43be7a43544e424
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.apply_referral_code(text)
--   source: supabase/migrations/0083_referral_rewards.sql:833-886
--   verbatim statement sha256: 059f2d6e341d4e7338014873fcc81b3dc0e30bc6846c9fb961415af2895fb658
--   original body md5 (pg_proc.prosrc preflight): a1c4ea44634c6073042ed5c2b5f405e4
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.request_referral_qualification()
--   source: supabase/migrations/0083_referral_rewards.sql:889-903
--   verbatim statement sha256: 4bbcf26deb632c1e3c29c0c370295ee3b854f6d965e08738222b1035d7eb8282
--   original body md5 (pg_proc.prosrc preflight): d6cc3c1a3b3cbe6e54315c8415092e0a
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN public.qualify_referral_internal(v_uid);
END $$;

-- [gen] public.qualify_referral_internal(uuid)
--   source: supabase/migrations/0085_concurrency_absent_row_locking.sql:226-402
--   verbatim statement sha256: 54954cd6c824e79f654b7f59d4bb3f5b9f14d92ee11b65cd7bbba315823c95f4
--   original body md5 (pg_proc.prosrc preflight): 6bb19a1eee7e8c425ec838a0eba54167
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.admin_mutate_entitlement(text,uuid,uuid,text,text,text,integer)
--   source: supabase/migrations/0083_referral_rewards.sql:1143-1221
--   verbatim statement sha256: 8c9a2a07172a0b229d7370a26fc87195c334a3198ab1ae6f83ec27476fff5504
--   original body md5 (pg_proc.prosrc preflight): 12710e769a439e9b3009dad6a5a1586b
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.admin_reject_referral(text,uuid,uuid,text)
--   source: supabase/migrations/0083_referral_rewards.sql:1224-1286
--   verbatim statement sha256: 0f42430c9ff059091b98293ec447c3646c896b9b439146c3041d57b3982192db
--   original body md5 (pg_proc.prosrc preflight): e64aad54331bcabdb3c8d6570ea241e2
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.admin_reverse_referral(text,uuid,uuid,text)
--   source: supabase/migrations/0083_referral_rewards.sql:1292-1355
--   verbatim statement sha256: 8b84fa94901c5839216fb661eb1f3521d90554feac2b943d872aee76a822a598
--   original body md5 (pg_proc.prosrc preflight): b43786e439795b1fc6d6fcd7af10a3a9
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.admin_adjust_referral_progress(text,uuid,uuid,text,integer,text)
--   source: supabase/migrations/0083_referral_rewards.sql:1358-1447
--   verbatim statement sha256: 7172dc0d3d125b4e7c5c335f7090e0446c8135af8fbd4e0861a8daf73be9bc0e
--   original body md5 (pg_proc.prosrc preflight): e56bbad6e9674316eb4624328723bffc
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.admin_rotate_referral_code(text,uuid,uuid,text)
--   source: supabase/migrations/0083_referral_rewards.sql:1455-1542
--   verbatim statement sha256: 427d3f9be752e0604902d8594086c7e8af4b55f4663f836c53580c276f140999
--   original body md5 (pg_proc.prosrc preflight): ee22254aee43b4ec476082d4ec68a260
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.admin_publish_reward_rule(text,uuid,text,integer,integer,boolean,text,timestamp with time zone)
--   source: supabase/migrations/0083_referral_rewards.sql:1549-1641
--   verbatim statement sha256: d2322550c9b8a7e1eae4efba567af6723181b6199d1d832c8575c835e537d5d9
--   original body md5 (pg_proc.prosrc preflight): 43bf9b7c15d0171497cc235f99b020f7
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.admin_deactivate_reward_rule(text,uuid,text,text)
--   source: supabase/migrations/0083_referral_rewards.sql:1646-1705
--   verbatim statement sha256: 1eef58cb9c5b0042bb43aa74d448be773ecc6f77a76dfbd86c4b23156516c668
--   original body md5 (pg_proc.prosrc preflight): de06cb586a6d724e84edb8bc1c9123cf
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
  raise exception 'feature_retired' using errcode = 'QD040';  -- [fence] D6: referral/entitlement protocol retired (QD040)
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

-- [gen] public.link_capture_device(text,text,boolean,boolean,integer,bigint)
--   source: supabase/migrations/0110_capture_consent_projection.sql:293-388
--   verbatim statement sha256: 9cbdcb64d9ccc5a3f5afaa52e8769ac4a731dfb677683191a417919dbdcb9da2
--   original body md5 (pg_proc.prosrc preflight): 14629df85147e9ca10577f44a35e64a3
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
  perform account_fence.admit(auth.uid());  -- [fence]
  perform account_fence.admit_install(p_install_id_hash, false, true);  -- [fence]
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

-- [gen] public.set_capture_consent(text,text,boolean,boolean,integer,bigint)
--   source: supabase/migrations/0110_capture_consent_projection.sql:401-474
--   verbatim statement sha256: 910af528949ad2fcd0757896e2052e4134d9c3933ff002a5893cd9bd81f96d7a
--   original body md5 (pg_proc.prosrc preflight): 89f665a2a17a094a3b0455268473f219
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
  perform account_fence.admit(auth.uid(), true, true);  -- [fence]
  perform account_fence.admit_install(p_install_id_hash, true);  -- [fence]
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

  if v_blocked is null and account_fence.is_pending(v_uid) then  -- [fence]
    v_blocked := 'deletion_pending';  -- O2: pending account may only narrow  -- [fence]
  end if;  -- [fence]
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

-- [gen] public.revoke_capture_consent(text,text,uuid,bigint,integer)
--   source: supabase/migrations/0110_capture_consent_projection.sql:492-549
--   verbatim statement sha256: 6bbeb1e1623b56c37dc79f5784089402bc2f83c867fe2707951956a5d25d3b25
--   original body md5 (pg_proc.prosrc preflight): 29ce334ab2085d791f3c34699661467e
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
  perform account_fence.admit(auth.uid(), true, true);  -- [fence]
  perform account_fence.admit_install(p_install_id_hash, true);  -- [fence]
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

-- [gen] public.legacy_link_capture_device(text,uuid)
--   source: supabase/migrations/0110_capture_consent_projection.sql:562-592
--   verbatim statement sha256: c81146f9c6427ad44c164cae9eac4450d131272968e926121628ef80e6b9a756
--   original body md5 (pg_proc.prosrc preflight): 17fe992c06dfbdaee321a6828d756875
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
  perform account_fence.admit(p_user_id);  -- [fence]
  perform account_fence.admit_install(p_install_id_hash, false, true);  -- [fence]
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

-- [gen] public.legacy_set_device_consent(text,boolean,boolean)
--   source: supabase/migrations/0110_capture_consent_projection.sql:604-645
--   verbatim statement sha256: 5bf6cba7531c77d9fe73775294a793bc12e08d3a4125efd07da33585680e08f3
--   original body md5 (pg_proc.prosrc preflight): 980a6f5efeedfbf082de452c5042ca1c
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
  perform account_fence.admit_install(p_install_id_hash, true);  -- [fence]
  select * into v_row from public.capture_devices
   where install_id_hash = p_install_id_hash for update;
  if not found or v_row.revoked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'invalid_device_secret');
  end if;
  if v_row.consent_owner_uid is distinct from v_row.user_id then
    return jsonb_build_object('ok', false, 'error', 'capture_owner_mismatch');
  end if;
  if account_fence.is_pending(v_row.user_id) then  -- [fence]
    v_cloud := v_cloud and v_row.cloud_processing_enabled;  -- O2: pending account may only narrow  -- [fence]
    v_ai := v_ai and v_row.ai_consent_granted;  -- [fence]
  end if;  -- [fence]
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

-- [gen] public.unlink_capture_device(text)
--   source: supabase/migrations/0110_capture_consent_projection.sql:655-678
--   verbatim statement sha256: 1f2ac5aa8414c06e802a23be47a95213b35b1c1fbd88ee45a98d260a970d5f1c
--   original body md5 (pg_proc.prosrc preflight): 8aa7b29df81b36a5e294bd8b6e6a9605
create or replace function public.unlink_capture_device(p_install_id_hash text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform account_fence.admit_install(p_install_id_hash, true, true);  -- [fence]
  perform account_fence.assert_unlink_allowed(p_install_id_hash);  -- [fence]
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

-- [gen] public.capture_claim(text,text,text,text,uuid,integer,integer,bigint)
--   source: supabase/migrations/0112_capture_notifications_retention.sql:296-437
--   verbatim statement sha256: 98a58d049b24c4f799ce7e6fa8648bb9854da108ad67504903d3a2245e02af48
--   original body md5 (pg_proc.prosrc preflight): da5754145b65352a263f9038495692e1
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
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
  perform account_fence.admit(p_owner_uid);  -- [fence]
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

-- [gen] public.capture_ai_dispatch(text,text,integer)
--   source: supabase/migrations/0112_capture_notifications_retention.sql:439-490
--   verbatim statement sha256: 7e5fb8e2dd2c3d878852b2acd884c3aad603e40096583a7db4e48cdcea16a5fb
--   original body md5 (pg_proc.prosrc preflight): 09b40764ded7f726dbbb5d5e9cf9e746
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
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
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

-- [gen] public.capture_finalize(text,text,text,integer,text,text,jsonb,jsonb,text,text,boolean,jsonb)
--   source: supabase/migrations/0112_capture_notifications_retention.sql:492-576
--   verbatim statement sha256: b60f3bf0aba1fc0ad4e2cdbe84eccd306389d4e30749889efd2554f4de30f880
--   original body md5 (pg_proc.prosrc preflight): bb40a0b7015f5ee4cd406cb4d82a4175
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
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
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

-- [gen] public.capture_ack(text,uuid,text[])
--   source: supabase/migrations/0111_capture_state_machine.sql:442-464
--   verbatim statement sha256: 7ce801ad4e5f54baa2a5002e653e472d50b3122a71295a2d00324c669918b703
--   original body md5 (pg_proc.prosrc preflight): 2eaac2d9064d3b34ecc3911f3ea20403
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
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
  perform account_fence.admit(p_user_id);  -- [fence]
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

-- [gen] public.capture_retry_fence(text,text)
--   source: supabase/migrations/0112_capture_notifications_retention.sql:232-292
--   verbatim statement sha256: b074b37644973febd5106570ddd0d00b3c7965be7c8826a1ee24d5c73f9725df
--   original body md5 (pg_proc.prosrc preflight): f3db157f5361c16026a07bd403ad1643
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
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
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

-- [gen] public.capture_queue_push(text,text,text,uuid,text)
--   source: supabase/migrations/0112_capture_notifications_retention.sql:147-199
--   verbatim statement sha256: 7b718144c8123fc099e8778531e5537d0f3aba8d8ec863cfc985939f4487cbb0
--   original body md5 (pg_proc.prosrc preflight): 99aa679bdac2995a1ac91aed776a952a
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
  perform account_fence.admit_install(p_install_id_hash);  -- [fence]
  perform account_fence.admit(p_user_id);  -- [fence]
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

-- [gen] public.capture_revoke_fanout(text,uuid,boolean,boolean,integer)
--   source: supabase/migrations/0110_capture_consent_projection.sql:243-278
--   verbatim statement sha256: faf9c95eb7742f1d928508f19f79d8b8a782c5d0d79fdb0471e860424e70d52e
--   original body md5 (pg_proc.prosrc preflight): 31b29f1876eeecacd64f14a9cc05b448
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
  if p_user_id is not null and not account_fence.is_pending(p_user_id) then  -- [fence] O2: no settings-mirror write for a pending account
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

-- [gen] public.claim_ai_idempotency(text,text,text,text,integer)
--   source: supabase/migrations/0071_ai_endpoint_hardening.sql:58-98
--   verbatim statement sha256: 2383a40fc67bfa1a4f03ab32c6df87822f869b0dea1954de840a6c92015045d1
--   original body md5 (pg_proc.prosrc preflight): 6cffd8bc4b07d5dd6aac9d17097cf6cd
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
  perform account_fence.admit_owner_key(p_owner_key);  -- [fence]
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

-- [gen] public.award_gamification_for_transaction(text,uuid)
--   source: supabase/migrations/0085_concurrency_absent_row_locking.sql:405-513
--   verbatim statement sha256: 589bf71710e8ec8acda75151830d56aada0ce668d478aa59363da2df2d832d51
--   original body md5 (pg_proc.prosrc preflight): d5d021af7541a1696dfdf8bfd8c632be
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
  perform account_fence.admit(p_user_id);  -- [fence]
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

-- [gen/template] public.bump_capture_rate_limit(text,integer)  (LANGUAGE sql original rewritten as plpgsql, same statement)
--   source: supabase/migrations/0033_capture_pipeline_hardening.sql:60-74
--   verbatim statement sha256: 3d7f69edfea4052ae85ee50ccb7d46d1210f072b5be6c5bf782727ba87d42c5a
--   original body md5 (pg_proc.prosrc preflight): b4886765a6e2acf4867bf5ee13611a95
create or replace function bump_capture_rate_limit(
  p_install_id_hash TEXT,
  p_limit INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_over boolean;
begin
  perform account_fence.admit_rate_key(p_install_id_hash);  -- [fence] exact grammar or reject
  INSERT INTO capture_rate_limits AS r (install_id_hash, date, call_count)
  VALUES (p_install_id_hash, CURRENT_DATE, 1)
  ON CONFLICT (install_id_hash, date)
    DO UPDATE SET call_count = r.call_count + 1
  RETURNING call_count > p_limit INTO v_over;
  return v_over;
end;
$$;

-- [gen/template] public.complete_ai_idempotency(text,text,text,text,jsonb)  (LANGUAGE sql original rewritten as plpgsql, same statement)
--   source: supabase/migrations/0071_ai_endpoint_hardening.sql:105-122
--   verbatim statement sha256: af642970d06d8ffc226fe200493324921e533a01a77ce0902c9f91dffcaba8f7
--   original body md5 (pg_proc.prosrc preflight): 7310c6cdd35dcfb5145a9075275d9db7
create or replace function complete_ai_idempotency(
  p_owner_key TEXT,
  p_endpoint TEXT,
  p_request_id TEXT,
  p_status TEXT,
  p_result JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
begin
  perform account_fence.admit_owner_key(p_owner_key);  -- [fence] exact grammar or reject
  UPDATE ai_request_idempotency
    SET status = p_status, result = COALESCE(p_result, '{}'::jsonb)
  WHERE owner_key = p_owner_key
    AND endpoint = p_endpoint
    AND request_id = p_request_id;
end;
$$;

-- <<< GENERATED:END rpc_bodies

-- ════════════════════════════════════════════════════════════════════════════
-- 6. Acceptance / lease / receipt RPCs used by the Edge adapter (public.account_deletion_*)
-- ════════════════════════════════════════════════════════════════════════════
-- Service-only (section 9). SECURITY DEFINER, owned by account_fence_owner after section 9.

create function public.account_deletion_reserve_material(p_ref text, p_ciphertext text)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  if p_ciphertext is null or p_ciphertext = '' then
    raise exception 'invalid_material' using errcode = '22023';
  end if;
  insert into account_fence.deletion_material (ref, ciphertext) values (p_ref, p_ciphertext);
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

-- Reference-aware, keep-safe disposal: only a still-RESERVED row is destroyed.
create function public.account_deletion_dispose_material(p_ref text)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare m account_fence.deletion_material;
begin
  select * into m from account_fence.deletion_material where ref = p_ref for update;
  if not found then
    return pg_catalog.jsonb_build_object('status', 'kept_unconfirmed');
  end if;
  if m.state = 'committed' then
    return pg_catalog.jsonb_build_object('status', 'kept_referenced');
  end if;
  update account_fence.deletion_material set state = 'disposed', ciphertext = null where ref = p_ref;
  return pg_catalog.jsonb_build_object('status', 'disposed');
end;
$$;

create function public.account_deletion_read_material(p_ref text)
returns text
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select m.ciphertext from account_fence.deletion_material m
   join account_fence.deletion_job j on j.job_id = m.job_id
  where m.ref = p_ref and m.state = 'committed' and j.state <> 'completed'
$$;

create function public.account_deletion_find_accepted(p_scope_key text)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select pg_catalog.jsonb_build_object('job_id', s.job_id, 'receipt_hash', s.receipt_hash)
    from account_fence.deletion_scope s where s.scope_key = p_scope_key
$$;

-- Challenge issuance (contract section 1, D7). Serialises with acceptance on the same account gate, so the
-- 3-open-challenge limit cannot be raced past. The raw nonce exists only in this function's return value; the table
-- keeps nonce_hash = lower-hex sha256(nonce utf8). challenge_id and nonce are 32 CSPRNG bytes each, base64url
-- (no padding, 43 chars). Order of refusals: gone (QD002) -> admin (QD031) -> pending job (already_pending) -> rate (QD032).
create function public.account_deletion_issue_challenge(p_uid uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_id    text;
  v_nonce text;
  v_exp   timestamptz;
  v_n     integer;
begin
  if p_uid is null then
    raise exception 'invalid_uid' using errcode = '22023';
  end if;
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'account_fence_isolation_unsupported' using errcode = '0A000';
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.pg_advisory_xact_lock(account_fence.gate_key(p_uid));   -- lock_timeout -> 55P03

  if not account_fence.auth_user_exists(p_uid) then
    perform account_fence.deny('gone');
  end if;
  if exists (select 1 from public.admin_users a where a.id = p_uid) then
    perform account_fence.deny('admin');
  end if;
  if exists (select 1 from account_fence.deletion_job j where j.uid = p_uid and j.state <> 'completed') then
    -- A job is already accepted: the client must use `status`, not mint another challenge.
    return pg_catalog.jsonb_build_object('outcome', 'already_pending');
  end if;
  select pg_catalog.count(*) into v_n from account_fence.deletion_challenge c
   where c.uid = p_uid and c.consumed_at is null and c.expires_at > pg_catalog.clock_timestamp();
  if v_n >= 3 then
    perform account_fence.deny('challenge_rate');
  end if;

  v_id    := pg_catalog.rtrim(pg_catalog.translate(pg_catalog.encode(extensions.gen_random_bytes(32), 'base64'), E'+/\n', '-_'), '=');
  v_nonce := pg_catalog.rtrim(pg_catalog.translate(pg_catalog.encode(extensions.gen_random_bytes(32), 'base64'), E'+/\n', '-_'), '=');
  v_exp   := pg_catalog.clock_timestamp() + interval '5 minutes';
  insert into account_fence.deletion_challenge (challenge_id, uid, nonce_hash, expires_at)
  values (v_id, p_uid, pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_nonce, 'UTF8')), 'hex'), v_exp);
  return pg_catalog.jsonb_build_object(
    'outcome', 'issued', 'challenge_id', v_id, 'nonce', v_nonce,
    'expires_at_ms', pg_catalog.floor(extract(epoch from v_exp) * 1000)::bigint);
end;
$$;

-- Read-only view of one challenge for the Edge Apple verification (contract section 4). Consumption stays inside
-- account_deletion_accept. Returns SQL NULL when no row exists for (uid, id); a challenge of another uid is
-- indistinguishable from an unknown one. When found: exactly nonce_hash, expires_at_ms (number), consumed (boolean). The hash is not secret
-- (Apple echoes it in the identity token); the raw nonce is not stored anywhere.
create function public.account_deletion_read_challenge(p_uid uuid, p_challenge_id text)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select pg_catalog.jsonb_build_object(
      'nonce_hash', c.nonce_hash,
      'expires_at_ms', pg_catalog.floor(extract(epoch from c.expires_at) * 1000)::bigint,
      'consumed', c.consumed_at is not null)
    from account_fence.deletion_challenge c
   where c.challenge_id = p_challenge_id and c.uid = p_uid
$$;

-- The Apple `sub` bound to the Auth user (contract section 4). Never matched by email. NULL when there is no Apple identity.
create function public.account_deletion_apple_subject(p_uid uuid)
returns text
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select account_fence.auth_apple_subject(p_uid)
$$;

-- Acceptance: attempt -> account gate -> EXISTING job FOR UPDATE -> challenge FOR UPDATE -> FK inserts.
-- Completion takes job -> challenges too. For a new acceptance, challenge -> INSERT new job cannot wait
-- on a pre-existing holder of that new row. Every challenge is revalidated after its row lock is acquired.
create function public.account_deletion_accept(
  p_scope_key text, p_uid uuid, p_challenge_id text, p_challenge_expires_at_ms bigint,
  p_receipt_hash text, p_apple_material_ref text, p_attempt_id text
) returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_scope account_fence.deletion_scope;
  v_open  account_fence.deletion_job;
  v_chal  account_fence.deletion_challenge;
  v_job   uuid;
  v_n     integer;
begin
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'account_fence_isolation_unsupported' using errcode = '0A000';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('qirsh.account_fence.attempt:' || p_attempt_id, 0));
  if exists (select 1 from account_fence.deletion_attempt_tombstone t where t.attempt_id = p_attempt_id) then
    return pg_catalog.jsonb_build_object('outcome', 'fenced');
  end if;

  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.pg_advisory_xact_lock(account_fence.gate_key(p_uid));   -- lock_timeout -> 55P03

  select * into v_scope from account_fence.deletion_scope where scope_key = p_scope_key;
  if found then
    return case when v_scope.receipt_hash = p_receipt_hash
      then pg_catalog.jsonb_build_object('outcome', 'duplicate', 'job_id', v_scope.job_id)
      else pg_catalog.jsonb_build_object('outcome', 'idempotency_conflict') end;
  end if;

  if not account_fence.auth_user_exists(p_uid) then
    perform account_fence.deny('gone');
  end if;
  -- D7: an admin account is never accepted (QD031, before any insert); admin rights must be removed first.
  if exists (select 1 from public.admin_users a where a.id = p_uid) then
    perform account_fence.deny('admin');
  end if;

  -- Existing-job order matches completion: job row BEFORE challenge. Re-read under lock.
  select * into v_open from account_fence.deletion_job
   where uid = p_uid and state <> 'completed' for update;

  select * into v_chal from account_fence.deletion_challenge
   where challenge_id = p_challenge_id and uid = p_uid for update;
  if not found or v_chal.consumed_at is not null or v_chal.expires_at <= pg_catalog.clock_timestamp()
     or pg_catalog.clock_timestamp() > pg_catalog.to_timestamp(p_challenge_expires_at_ms / 1000.0) then
    return pg_catalog.jsonb_build_object('outcome', 'challenge_expired');
  end if;

  if v_open.job_id is not null then
    insert into account_fence.deletion_scope values (p_scope_key, v_open.job_id, p_receipt_hash);
    insert into account_fence.deletion_receipt values (p_receipt_hash, v_open.job_id) on conflict do nothing;
    update account_fence.deletion_challenge set consumed_at = pg_catalog.clock_timestamp() where challenge_id = p_challenge_id;
    return pg_catalog.jsonb_build_object('outcome', 'already_pending', 'job_id', v_open.job_id);
  end if;

  insert into account_fence.deletion_job (uid, attempt_id, apple_material_ref)
  values (p_uid, p_attempt_id, p_apple_material_ref) returning job_id into v_job;
  update account_fence.deletion_material
     set state = 'committed', job_id = v_job
   where ref = p_apple_material_ref and state = 'reserved' and expires_at > pg_catalog.clock_timestamp();
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    -- Never commit a job that references destroyed/expired material.
    raise exception 'material_unavailable' using errcode = 'QD020';
  end if;
  insert into account_fence.deletion_workset (job_id, install_id_hash, source)
  select v_job, d.install_id_hash, 'device_owner' from public.capture_devices d
   where d.user_id = p_uid and d.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, d.install_id_hash, 'consent_owner' from public.capture_devices d
   where d.consent_owner_uid = p_uid and d.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.install_id_hash, 'claimant' from public.processed_captures p
   where p.claimed_user_id = p_uid and p.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.install_id_hash, 'capture_owner' from public.processed_captures p
   where p.owner_uid = p_uid and p.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.install_id_hash, 'capture_consent' from public.processed_captures p
   where p.consent_owner_uid = p_uid and p.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, p.consumed_by_install_hash, 'consumed_install' from public.processed_captures p
   where p_uid = any(array[p.claimed_user_id, p.owner_uid, p.consent_owner_uid])
     and p.consumed_by_install_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, l.install_id_hash, 'log_owner' from public.notification_logs l
   where l.user_id = p_uid and l.install_id_hash ~ '^[0-9a-f]{32}$'
  union
  select v_job, q.install_id_hash, 'retry_install' from public.notification_retry_queue q
    left join public.notification_logs l on l.id = q.notification_log_id
   where q.install_id_hash ~ '^[0-9a-f]{32}$'
     and (l.user_id = p_uid or p_uid = any(account_fence.install_owners(q.install_id_hash))
          or p_uid = any(account_fence.install_owners(l.install_id_hash)))
  union
  select v_job, l.install_id_hash, 'retry_parent_install' from public.notification_retry_queue q
    join public.notification_logs l on l.id = q.notification_log_id
   where l.install_id_hash ~ '^[0-9a-f]{32}$'
     and (l.user_id = p_uid or p_uid = any(account_fence.install_owners(q.install_id_hash))
          or p_uid = any(account_fence.install_owners(l.install_id_hash)))
  union
  select v_job, h.install_id_hash, 'first_owner' from public.capture_install_owner_history h
   where h.first_owner_uid = p_uid and h.install_id_hash ~ '^[0-9a-f]{32}$'
  on conflict do nothing;
  insert into account_fence.deletion_scope values (p_scope_key, v_job, p_receipt_hash);
  insert into account_fence.deletion_receipt values (p_receipt_hash, v_job);
  update account_fence.deletion_challenge set consumed_at = pg_catalog.clock_timestamp() where challenge_id = p_challenge_id;
  return pg_catalog.jsonb_build_object('outcome', 'accepted', 'job_id', v_job);
end;
$$;

-- Fence: serialises with accept() on the attempt lock, so afterwards the attempt has either visibly
-- committed or can never commit.
create function public.account_deletion_fence_attempt(p_attempt_id text)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v_job uuid;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('qirsh.account_fence.attempt:' || p_attempt_id, 0));
  select job_id into v_job from account_fence.deletion_job where attempt_id = p_attempt_id;
  if found then
    return pg_catalog.jsonb_build_object('fenced', false, 'outcome', 'accepted', 'job_id', v_job);
  end if;
  insert into account_fence.deletion_attempt_tombstone (attempt_id) values (p_attempt_id) on conflict do nothing;
  return pg_catalog.jsonb_build_object('fenced', true);
end;
$$;

create function public.account_deletion_claim_lease(p_worker_id text, p_lease_ms integer, p_job_id uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  j account_fence.deletion_job;
  c_max_retryable_age constant interval := interval '72 hours';
begin
  -- P3: a crash-looping job (lease expires, is re-claimed, never reaches record_failure) must not starve others forever: before
  -- selecting, move up to 20 unleased jobs whose retry window is older than 72 hours to the terminal 'failed' state. Same lock
  -- discipline as the claim itself (FOR UPDATE SKIP LOCKED), so a concurrent writer of the row is skipped, not waited for.
  update account_fence.deletion_job d
     set state = 'failed', failed_at = pg_catalog.clock_timestamp(), last_code = 'retry_window_exceeded',
         current_step = null, lease_token = null, lease_expires_at = null
   where d.job_id in (select x.job_id from account_fence.deletion_job x
                       where x.state in ('accepted', 'running', 'retryable')
                         and (x.lease_expires_at is null or x.lease_expires_at < pg_catalog.clock_timestamp())
                         and x.retry_window_started_at < pg_catalog.clock_timestamp() - c_max_retryable_age
                       order by x.retry_window_started_at limit 20
                         for update skip locked);
  select * into j from account_fence.deletion_job
   where state in ('accepted', 'running', 'retryable')
     and (p_job_id is null or job_id = p_job_id)
     and (lease_expires_at is null or lease_expires_at < pg_catalog.clock_timestamp())
     and next_attempt_at <= pg_catalog.clock_timestamp()
   order by next_attempt_at, accepted_at
   limit 1
   for update skip locked;
  if not found then
    return null;
  end if;
  update account_fence.deletion_job
     set lease_generation = lease_generation + 1,
         lease_token = gen_random_uuid(),
         lease_expires_at = pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => p_lease_ms / 1000.0),
         state = 'running'
   where job_id = j.job_id
   returning * into j;
  return pg_catalog.jsonb_build_object(
    'lease', pg_catalog.jsonb_build_object('job_id', j.job_id, 'token', j.lease_token, 'generation', j.lease_generation),
    'job', pg_catalog.jsonb_build_object(
      'job_id', j.job_id, 'uid', j.uid, 'completed_steps', pg_catalog.to_jsonb(j.completed_steps),
      'apple_material_ref', case when pg_catalog.cardinality(j.completed_steps) = 0 then j.apple_material_ref end,
      'attempts', j.attempts));
end;
$$;

create function public.account_deletion_heartbeat(p_job_id uuid, p_lease_token uuid, p_generation integer, p_lease_ms integer)
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare j account_fence.deletion_job;
begin
  j := account_fence.lease_job(p_job_id, p_lease_token, p_generation);
  if j.job_id is null then return pg_catalog.jsonb_build_object('ok', false, 'reason', 'lease_lost'); end if;
  update account_fence.deletion_job
     set lease_expires_at = pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => p_lease_ms / 1000.0)
   where job_id = j.job_id;
  return pg_catalog.jsonb_build_object('ok', true);
end; $$;

create function public.account_deletion_begin_step(p_job_id uuid, p_lease_token uuid, p_generation integer, p_stage text)
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare
  j account_fence.deletion_job;
  v_order constant text[] := array['apple_revoke', 'storage_sweep', 'sql_purge', 'auth_delete', 'terminal_storage'];
begin
  j := account_fence.lease_job(p_job_id, p_lease_token, p_generation);
  if j.job_id is null then return pg_catalog.jsonb_build_object('ok', false, 'reason', 'lease_lost'); end if;
  if pg_catalog.cardinality(j.completed_steps) >= 5 or v_order[pg_catalog.cardinality(j.completed_steps) + 1] is distinct from p_stage then
    return pg_catalog.jsonb_build_object('ok', false, 'reason', 'out_of_order');
  end if;
  update account_fence.deletion_job set current_step = p_stage where job_id = j.job_id;
  return pg_catalog.jsonb_build_object('ok', true);
end; $$;

create function public.account_deletion_complete_step(p_job_id uuid, p_lease_token uuid, p_generation integer, p_stage text)
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare j account_fence.deletion_job;
begin
  j := account_fence.lease_job(p_job_id, p_lease_token, p_generation);
  if j.job_id is null then return pg_catalog.jsonb_build_object('ok', false, 'reason', 'lease_lost'); end if;
  if j.current_step is distinct from p_stage then
    return pg_catalog.jsonb_build_object('ok', false, 'reason', 'out_of_order');
  end if;
  update account_fence.deletion_job
     set completed_steps = completed_steps || p_stage, current_step = null,
         apple_material_ref = case when p_stage = 'apple_revoke' then null else apple_material_ref end
   where job_id = j.job_id;
  if p_stage = 'apple_revoke' then
    -- The temporary Apple token is destroyed in the same transaction.
    update account_fence.deletion_material set state = 'disposed', ciphertext = null where job_id = j.job_id;
  end if;
  return pg_catalog.jsonb_build_object('ok', true);
end; $$;

create function public.account_deletion_record_failure(
  p_job_id uuid, p_lease_token uuid, p_generation integer,
  p_stage text, p_code text, p_retryable boolean, p_retry_delay_ms bigint)
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare
  j account_fence.deletion_job;
  -- P2-3: a job may stay retryable for at most this long after its retry window started (acceptance or operator requeue); a retryable failure past it becomes terminal.
  c_max_retryable_age constant interval := interval '72 hours';
  v_terminal boolean;
begin
  j := account_fence.lease_job(p_job_id, p_lease_token, p_generation);
  if j.job_id is null then return pg_catalog.jsonb_build_object('ok', false, 'reason', 'lease_lost'); end if;
  v_terminal := p_retryable is not true or j.retry_window_started_at < pg_catalog.clock_timestamp() - c_max_retryable_age;
  update account_fence.deletion_job
     set attempts = attempts + 1,
         state = case when v_terminal then 'failed' else 'retryable' end,
         failed_at = case when v_terminal then pg_catalog.clock_timestamp() else null end,
         last_code = case when p_code ~ '^[a-z][a-z0-9_]{0,39}$' then p_code end,
         current_step = null, lease_token = null, lease_expires_at = null,
         next_attempt_at = pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => greatest(p_retry_delay_ms, 0) / 1000.0)
   where job_id = j.job_id;
  return pg_catalog.jsonb_build_object('ok', true);
end; $$;

-- D5: the anonymous completion marker (uid nulled; job, scope, receipt remain) is kept AT MOST 14 days. The coordinator
-- still passes p_receipt_retention_ms (its default is 30 days): a SHORTER request is honoured (retained_until = completed_at
-- + request, floor 0), a longer or NULL request is capped at / defaults to 14 days. account_fence.purge_expired_deletion_records
-- physically deletes the marker once completed_at + 14 days has passed, whatever retained_until says.
create function public.account_deletion_complete_job(p_job_id uuid, p_lease_token uuid, p_generation integer, p_receipt_retention_ms bigint)
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare
  j account_fence.deletion_job;
  v_now timestamptz;
  v_max_ms constant bigint := 14::bigint * 24 * 3600 * 1000;   -- D5 cap
  v_ms bigint;
begin
  j := account_fence.lease_job(p_job_id, p_lease_token, p_generation);
  if j.job_id is null then return pg_catalog.jsonb_build_object('ok', false, 'reason', 'lease_lost'); end if;
  if pg_catalog.cardinality(j.completed_steps) <> 5 then
    return pg_catalog.jsonb_build_object('ok', false, 'reason', 'incomplete_steps');
  end if;
  delete from account_fence.deletion_challenge where uid = j.uid;
  delete from account_fence.deletion_workset where job_id = j.job_id;     -- install hashes are identifiers
  v_now := pg_catalog.clock_timestamp();
  v_ms  := least(greatest(coalesce(p_receipt_retention_ms, v_max_ms), 0), v_max_ms);
  update account_fence.deletion_job
     set state = 'completed', uid = null, completed_at = v_now,
         retained_until = v_now + pg_catalog.make_interval(secs => v_ms / 1000.0),
         lease_token = null, lease_expires_at = null, current_step = null
   where job_id = j.job_id;
  return pg_catalog.jsonb_build_object('ok', true);
end; $$;

-- Unknown and expired receipts are indistinguishable (null). Non-terminal receipts never expire.
create function public.account_deletion_get_receipt(p_receipt_hash text)
returns jsonb language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select case
    when j.state = 'completed' and j.retained_until > pg_catalog.clock_timestamp() then
      pg_catalog.jsonb_build_object('state', 'completed',
        'retained_until_ms', (extract(epoch from j.retained_until) * 1000)::bigint)
    when j.state = 'completed' then null
    else pg_catalog.jsonb_build_object('state', j.state)
  end
  from account_fence.deletion_receipt r join account_fence.deletion_job j on j.job_id = r.job_id
  where r.receipt_hash = p_receipt_hash
$$;

-- D5 retention purge (contract section 9). NOT an API entry point: owned by the narrow owner, EXECUTE only for the
-- migration role (pg_cron runs as the scheduling role). Physically deletes, bounded per run by p_limit (default 500,
-- clamped to 1..5000) and idempotent:
--   * COMPLETED jobs with completed_at < now() - 14 days, children first (workset, material, scope, receipt), then the job;
--     a nonterminal job is NEVER purged by age (it escalates through last_code);
--   * material of jobs FAILED for more than 14 days (state disposed, ciphertext null; the job row stays);
--   * orphan material (job_id null): an expired still-reserved row is first emptied (state disposed, ciphertext null),
--     then disposed orphans older than 14 days are deleted;
--   * attempt tombstones older than 14 days;
--   * challenges that expired more than 1 day ago.
-- Job rows are taken FOR UPDATE SKIP LOCKED so a concurrent writer of the same row is skipped, not waited for.
create function account_fence.purge_expired_deletion_records(p_limit integer default 500)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
  v_now   timestamptz := pg_catalog.clock_timestamp();
  v_cut   timestamptz;
  v_jobs  uuid[];
  n_work  integer := 0; n_mat integer := 0; n_scope integer := 0; n_rcpt integer := 0;
  n_job   integer := 0; n_omat integer := 0; n_tomb integer := 0; n_chal integer := 0; n_fmat integer := 0;
begin
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  v_cut := v_now - interval '14 days';

  select pg_catalog.array_agg(x.job_id) into v_jobs from (
    select j.job_id from account_fence.deletion_job j
     where j.state = 'completed' and j.completed_at < v_cut
     order by j.completed_at limit v_limit
       for update skip locked) x;
  if v_jobs is not null then
    delete from account_fence.deletion_workset where job_id = any(v_jobs);
    get diagnostics n_work = row_count;
    delete from account_fence.deletion_material where job_id = any(v_jobs);
    get diagnostics n_mat = row_count;
    delete from account_fence.deletion_scope where job_id = any(v_jobs);
    get diagnostics n_scope = row_count;
    delete from account_fence.deletion_receipt where job_id = any(v_jobs);
    get diagnostics n_rcpt = row_count;
    delete from account_fence.deletion_job where job_id = any(v_jobs) and state = 'completed';
    get diagnostics n_job = row_count;
  end if;

  -- F4 (revised): the committed Apple material of a job that has been terminally 'failed' for MORE than 14 days (failed_at, set by
  -- account_deletion_record_failure) is emptied; until then it is retained so an operator can requeue the job and still revoke.
  -- The job row and its marker are NOT deleted by age.
  update account_fence.deletion_material
     set state = 'disposed', ciphertext = null
   where ref in (select m.ref from account_fence.deletion_material m
                   join account_fence.deletion_job fj on fj.job_id = m.job_id
                  where fj.state = 'failed' and fj.failed_at < v_now - interval '14 days' and m.state <> 'disposed'
                  order by m.reserved_at limit v_limit);
  get diagnostics n_fmat = row_count;

  update account_fence.deletion_material
     set state = 'disposed', ciphertext = null
   where ref in (select m.ref from account_fence.deletion_material m
                  where m.job_id is null and m.state = 'reserved' and m.expires_at < v_now
                  order by m.expires_at limit v_limit);
  delete from account_fence.deletion_material
   where ref in (select m.ref from account_fence.deletion_material m
                  where m.job_id is null and m.state = 'disposed' and m.reserved_at < v_cut
                  order by m.reserved_at limit v_limit);
  get diagnostics n_omat = row_count;

  delete from account_fence.deletion_attempt_tombstone
   where attempt_id in (select t.attempt_id from account_fence.deletion_attempt_tombstone t
                         where t.created_at < v_cut order by t.created_at limit v_limit);
  get diagnostics n_tomb = row_count;

  delete from account_fence.deletion_challenge
   where challenge_id in (select c.challenge_id from account_fence.deletion_challenge c
                           where c.expires_at < v_now - interval '1 day' order by c.expires_at limit v_limit);
  get diagnostics n_chal = row_count;

  return pg_catalog.jsonb_build_object(
    'jobs', n_job, 'scopes', n_scope, 'receipts', n_rcpt, 'worksets', n_work, 'job_material', n_mat,
    'orphan_material', n_omat, 'tombstones', n_tomb, 'challenges', n_chal, 'failed_job_material', n_fmat);
end;
$$;

-- F4 recovery (operator only). A job in the terminal state 'failed' has no automatic exit: accept() returns the open job for the
-- uid and the lease worker never claims 'failed'. These two functions are the ONLY exit and are executable by the migration
-- principal (postgres) alone: no API role, not even service_role. Neither returns uid, ciphertext or attempt_id.
create function account_fence.operator_failed_jobs()
returns table (job_id uuid, last_code text, completed_steps text[], attempts integer, accepted_at timestamptz, retry_window_started_at timestamptz, failed_at timestamptz, material_committed boolean)
language sql stable security definer
set search_path = pg_catalog, pg_temp
as $$
  select j.job_id, j.last_code, j.completed_steps, j.attempts, j.accepted_at, j.retry_window_started_at, j.failed_at,
         exists (select 1 from account_fence.deletion_material m where m.job_id = j.job_id and m.state = 'committed')
    from account_fence.deletion_job j
   where j.state = 'failed'
   order by j.failed_at nulls first, j.job_id
$$;

create function account_fence.operator_requeue_failed_job(p_job_id uuid) returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  j account_fence.deletion_job;
begin
  select * into j from account_fence.deletion_job x where x.job_id = p_job_id for update;
  if not found or j.state is distinct from 'failed' then
    return pg_catalog.jsonb_build_object('ok', false, 'reason', 'not_failed');
  end if;
  -- Without a committed token the Apple revoke can no longer happen: an incident for the owner, never a silent skip.
  if not ('apple_revoke' = any(j.completed_steps))
     and not exists (select 1 from account_fence.deletion_material m where m.job_id = j.job_id and m.state = 'committed') then
    return pg_catalog.jsonb_build_object('ok', false, 'reason', 'apple_material_disposed');
  end if;
  update account_fence.deletion_job
     set state = 'retryable', next_attempt_at = pg_catalog.clock_timestamp(), failed_at = null,
         retry_window_started_at = pg_catalog.clock_timestamp(),
         lease_token = null, lease_expires_at = null, current_step = null
   where job_id = j.job_id;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

-- P2-4: exit for a failed job that can no longer be requeued (its Apple material was disposed) or that the owner decides to abandon.
-- Allowed ONLY while no destructive step ran (completed_steps empty). Removes every row that references the job (scope, receipt,
-- material, workset), the subject's challenges, tombstones the attempt id (the attempt can never be replayed) and deletes the job,
-- so the uid is no longer pending and the user can start a fresh deletion with a new Apple re-authentication.
create function account_fence.operator_cancel_failed_job(p_job_id uuid) returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  j account_fence.deletion_job;
begin
  select * into j from account_fence.deletion_job x where x.job_id = p_job_id for update;
  if not found or j.state is distinct from 'failed' or pg_catalog.cardinality(j.completed_steps) <> 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'reason', 'not_cancellable');
  end if;
  update account_fence.deletion_material set state = 'disposed', ciphertext = null where job_id = j.job_id;
  delete from account_fence.deletion_material where job_id = j.job_id;
  delete from account_fence.deletion_workset where job_id = j.job_id;
  delete from account_fence.deletion_scope where job_id = j.job_id;
  delete from account_fence.deletion_receipt where job_id = j.job_id;
  delete from account_fence.deletion_challenge where uid = j.uid;
  insert into account_fence.deletion_attempt_tombstone (attempt_id) values (j.attempt_id) on conflict do nothing;
  delete from account_fence.deletion_job where job_id = j.job_id;
  return pg_catalog.jsonb_build_object('ok', true);
end;
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- 7. Erasure (E1, O4, O5): the ONLY SQL erasure entry
-- ════════════════════════════════════════════════════════════════════════════
-- Authority = a current lease on a job whose current step is sql_purge and whose Apple+Storage steps are
-- complete; the subject comes from the job row, never from an argument. The function is owned by the
-- narrow NOLOGIN role; service_role may only EXECUTE it. It does NOT call purge_user_data (whose terminal
-- user_sync_state upsert would re-create an application row referencing Auth): the fixed list below
-- restates 0113 minus that upsert, plus the closure items 0113 lacks, and ends with a closure assertion.
--
-- LOCK ORDER (E1.1): account gate FIRST, job row SECOND. The first lease check is lock-free (lease_peek) and
-- only tells us which gate to take; the BLOCKING gate wait therefore happens while this transaction holds NO
-- deletion_job row lock. Only after the gate is held is the job row locked FOR UPDATE (lease_job), which
-- samples the DATABASE clock after obtaining the row lock and validates every lease field. The accept transaction takes the same
-- order (gate, then job-row KEY SHARE for its FK inserts), so there is no gate/job-row inversion. A final
-- lease_job at the end samples again after the erasure statements' row waits. This validates that boundary;
-- it is not a claim that every individual wait or the eventual COMMIT instant has been exercised.
create function public.account_deletion_purge(p_job_id uuid, p_lease_token uuid, p_generation integer)
returns jsonb
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  j account_fence.deletion_job;
  v_uid uuid;
  v_installs text[];
  v_excl text[];
begin
  if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'account_fence_isolation_unsupported' using errcode = '0A000';
  end if;
  v_uid := account_fence.lease_peek(p_job_id, p_lease_token, p_generation);      -- no row lock
  if v_uid is null then
    raise exception 'lease_lost' using errcode = 'QD010';
  end if;

  perform pg_catalog.set_config('lock_timeout', '10s', true);
  perform pg_catalog.pg_advisory_xact_lock(account_fence.gate_key(v_uid));        -- 55P03 on timeout; no job lock held

  j := account_fence.lease_job(p_job_id, p_lease_token, p_generation);            -- FOR UPDATE, after the gate
  if j.job_id is null or j.uid is distinct from v_uid then
    raise exception 'lease_lost' using errcode = 'QD010';
  end if;
  if j.current_step is distinct from 'sql_purge'
     or j.completed_steps is distinct from array['apple_revoke', 'storage_sweep'] then
    raise exception 'step_not_authorised' using errcode = 'QD011';
  end if;

  v_installs := array(
    select w.install_id_hash from account_fence.deletion_workset w where w.job_id = j.job_id
    union select d.install_id_hash from public.capture_devices d where d.user_id = j.uid or d.consent_owner_uid = j.uid
    union select p.install_id_hash from public.processed_captures p where j.uid = any(array[p.claimed_user_id, p.owner_uid, p.consent_owner_uid])
    union select p.consumed_by_install_hash from public.processed_captures p
     where j.uid = any(array[p.claimed_user_id, p.owner_uid, p.consent_owner_uid]) and p.consumed_by_install_hash is not null
    union select l.install_id_hash from public.notification_logs l where l.user_id = j.uid and l.install_id_hash is not null
    union select q.install_id_hash from public.notification_retry_queue q
      left join public.notification_logs l on l.id = q.notification_log_id
     where l.user_id = j.uid or j.uid = any(account_fence.install_owners(q.install_id_hash))
        or j.uid = any(account_fence.install_owners(l.install_id_hash))
    union select l.install_id_hash from public.notification_retry_queue q
      join public.notification_logs l on l.id = q.notification_log_id
     where l.install_id_hash is not null
       and (l.user_id = j.uid or j.uid = any(account_fence.install_owners(q.install_id_hash))
            or j.uid = any(account_fence.install_owners(l.install_id_hash)))
    union select h.install_id_hash from public.capture_install_owner_history h where h.first_owner_uid = j.uid);
  -- Install gates, exclusive and TRY (never wait): writers that attach data to these installs, change their
  -- ownership or unlink them cannot interleave with the erasure (install -> account order is what writers use;
  -- all of their acquisitions are try-locks, so this reverse order cannot deadlock).
  perform account_fence.lock_install(h, true) from pg_catalog.unnest(v_installs) as h;
  -- O4 conservative default (E7/O4, E1.2): data without a user column, and the capture_devices PARENT row with its
  -- ON DELETE CASCADE children (processed_captures, capture_fingerprints), is erased only for installs the history
  -- PROVES single-owner (trusted, never transitioned, first owner = subject) AND that currently hold no row
  -- attributed to anyone else. Shared / unproven / anonymous install data is RETAINED (job.coverage).
  v_excl := array(
    select h.install_id_hash from public.capture_install_owner_history h
     where h.install_id_hash = any (v_installs) and h.trusted and not h.transitioned and h.first_owner_uid = j.uid
       and not exists (select 1 from public.processed_captures p
                        where (p.install_id_hash = h.install_id_hash or p.consumed_by_install_hash = h.install_id_hash)
                          and (exists (select 1 from unnest(array[p.claimed_user_id, p.owner_uid, p.consent_owner_uid]) o
                                        where o is not null and o <> j.uid)
                               -- A second install reference is conservatively shared, even if its current user matches.
                               or p.install_id_hash <> h.install_id_hash
                               or (p.consumed_by_install_hash is not null and p.consumed_by_install_hash <> h.install_id_hash)))
       and not exists (select 1 from public.notification_logs l
                        where l.install_id_hash = h.install_id_hash and l.user_id is not null and l.user_id <> j.uid)
       and not exists (select 1 from public.notification_retry_queue q
                          left join public.notification_logs l on l.id = q.notification_log_id
                        where (q.install_id_hash = h.install_id_hash or l.install_id_hash = h.install_id_hash)
                          and (l.id is null or l.install_id_hash is null
                            or q.install_id_hash is distinct from l.install_id_hash
                            or (l.user_id is not null and l.user_id <> j.uid)))
       and not exists (select 1 from public.capture_devices d
                        where d.install_id_hash = h.install_id_hash
                          and ((d.user_id is not null and d.user_id <> j.uid)
                               or (d.consent_owner_uid is not null and d.consent_owner_uid <> j.uid))));

  insert into account_fence.erasure_ctx (xid, backend_pid, job_id, uid, installs, exclusive_installs)
  values (pg_catalog.pg_current_xact_id(), pg_catalog.pg_backend_pid(), j.job_id, j.uid, v_installs, v_excl);

  perform account_fence.erase_user_data(j.job_id, j.uid);
  perform account_fence.erase_verify(j.uid);

  -- Revalidate at the erasure boundary after its row waits; this is not a validation after each individual statement.
  j := account_fence.lease_job(p_job_id, p_lease_token, p_generation);
  if j.job_id is null then
    raise exception 'lease_lost' using errcode = 'QD010';
  end if;

  delete from account_fence.erasure_ctx where xid = pg_catalog.pg_current_xact_id();
  return pg_catalog.jsonb_build_object('status', 'done');
end;
$$;

create function account_fence.erase_user_data(p_job_id uuid, p_uid uuid) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v_log_id uuid;
begin
  if account_fence.in_erasure(p_uid) is not true then
    raise exception 'not_in_erasure_context' using errcode = 'QD012';
  end if;

  -- Retry/log preflight BEFORE ANY domain erasure. Same parent keys as ordinary I/U/D, all TRY.
  -- Freeze targeted parents and every subject-workset-linked child/parent, then read again under keys.
  -- Missing/conflicting bindings or a non-exclusive child of a targeted log block the ENTIRE purge;
  -- historical shared/conflicting disposition remains pending owner approval, never foreign-child deletion.
  for v_log_id in
    select l.id from public.notification_logs l
     where l.user_id = p_uid or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs()))
    union
    select q.notification_log_id from public.notification_retry_queue q
      left join public.notification_logs l on l.id = q.notification_log_id
     where l.user_id = p_uid or q.install_id_hash = any(account_fence.erasure_installs())
        or l.install_id_hash = any(account_fence.erasure_installs())
  loop
    if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtextextended('qirsh.account_fence.notification_log:' || v_log_id::text, 0)) then
      perform account_fence.deny('busy');
    end if;
  end loop;
  if exists (select 1 from public.notification_retry_queue q
              left join public.notification_logs l on l.id = q.notification_log_id
             where (l.user_id = p_uid or q.install_id_hash = any(account_fence.erasure_installs())
                    or l.install_id_hash = any(account_fence.erasure_installs()))
               and (l.id is null or l.install_id_hash is null or q.install_id_hash is distinct from l.install_id_hash
                 or ((l.user_id = p_uid or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs())))
                     and (not (q.install_id_hash = any(account_fence.erasure_exclusive_installs()))
                       or not account_fence.holds_install_gate(q.install_id_hash, true))))) then
    raise exception 'retry_erasure_attribution_unproven'
      using errcode = 'QD013', detail = 'fence:retry_attribution', hint = 'owner_review_required_no_partial_erasure';
  end if;

  -- ── Referral / entitlement domain (0113:21-45) ───────────────────────────
  delete from public.referrals where referred_user_id = p_uid and status in ('attributed', 'rejected');
  update public.referrals set referred_user_id = null, referred_user_deleted_at = now() where referred_user_id = p_uid;
  delete from public.referral_reward_grants   where referrer_user_id = p_uid;
  delete from public.referral_reward_progress where referrer_user_id = p_uid;
  delete from public.referrals                where referrer_user_id = p_uid;
  delete from public.referral_codes           where user_id = p_uid;
  delete from public.user_entitlement_state   where user_id = p_uid;
  delete from public.entitlement_events       where user_id = p_uid;

  -- ── O5 (PENDING OWNER APPROVAL; DECISIONS.md lists every retained identifying field) ─────────────
  -- Actor rows get actor -> NULL and reason -> the fixed tombstone (no pattern redaction). The retained-field
  -- inventory (admin_users.note, before/after snapshots, target_ref, operation fingerprints, ...) is NOT changed
  -- here; each is an owner decision.
  update public.referral_admin_audit
     set target_user_id = null, target_ref = null, reason = '[redacted: subject account deleted]',
         before_state = null, after_state = null
   where target_user_id = p_uid;
  update public.referral_admin_audit
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;
  update public.entitlement_events
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;
  update public.referral_reward_rules set created_by = null where created_by = p_uid;
  update public.announcement_admin_audit
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;
  -- feature_flag_admin_audit is append-only: this UPDATE passes only the narrow exception in
  -- public.feature_flag_audit_append_only (section 8); every other UPDATE/DELETE/TRUNCATE stays denied.
  update public.feature_flag_admin_audit
     set actor_admin_id = null, reason = account_fence.deletion_tombstone() where actor_admin_id = p_uid;

  -- ── Capture (0113:63-98) + O4 ────────────────────────────────────────────
  -- history first: a later device delete/update fires the history tracker, which must not see the subject.
  update public.capture_install_owner_history
     set first_owner_uid = null, transitioned = true,
         transitioned_at = coalesce(transitioned_at, clock_timestamp()), updated_at = clock_timestamp()
   where first_owner_uid = p_uid;
  -- O4/Q15 recommendation, PENDING OWNER APPROVAL: conflicting/shared rows are retained, not blanket deleted.
  -- Frozen exclusive evidence was captured before history/UUID minimisation and is never inferred from it.
  delete from public.processed_captures
   where install_id_hash = any(account_fence.erasure_exclusive_installs());
  update public.processed_captures
     set claimed_user_id = case when claimed_user_id = p_uid then null else claimed_user_id end,
         owner_uid = case when owner_uid = p_uid then null else owner_uid end,
         consent_owner_uid = case when consent_owner_uid = p_uid then null else consent_owner_uid end,
         consumed_by_install_hash = case when consumed_by_install_hash = any(account_fence.erasure_exclusive_installs())
                                        then null else consumed_by_install_hash end
   where p_uid = any(array[claimed_user_id, owner_uid, consent_owner_uid])
      or consumed_by_install_hash = any(account_fence.erasure_exclusive_installs());
  delete from public.capture_fingerprints where install_id_hash = any(account_fence.erasure_exclusive_installs());
  update public.capture_devices
     set consent_owner_uid = null, cloud_processing_enabled = false, ai_consent_granted = false,
         consent_version = 0, consent_client_generation = 0, last_revoke_generation = null
   where consent_owner_uid = p_uid and user_id is distinct from p_uid;
  -- E1.2 / O4: capture_devices. The parent DELETE cascades to processed_captures and capture_fingerprints
  -- (0012:25,50), so it is used ONLY for proven single-owner installs (erasure_exclusive_installs, computed under
  -- the exclusive install gates with an explicit "no row attributed to anyone else" test). Every other device of
  -- the subject is UNLINKED (the column set of unlink_capture_device, 0110:662-675): the row and all of its
  -- children stay for the other claimants; only the subject's link, consent and push token go.
  delete from public.capture_devices
   where user_id = p_uid and install_id_hash = any (account_fence.erasure_exclusive_installs());
  update public.capture_devices
     set owner_generation = owner_generation + 1, consent_client_generation = 0, last_revoke_generation = null,
         user_id = null, consent_owner_uid = null, cloud_processing_enabled = false, ai_consent_granted = false,
         consent_version = 0, apns_token = null, token_updated_at = null
   where user_id = p_uid and (consent_owner_uid is null or consent_owner_uid = p_uid);
  update public.capture_devices
     set owner_generation = owner_generation + 1, user_id = null, apns_token = null, token_updated_at = null
   where user_id = p_uid and consent_owner_uid is not null and consent_owner_uid <> p_uid;
  delete from public.capture_rate_limits where account_fence.rate_key_in_scope(install_id_hash);
  delete from public.ai_request_idempotency where account_fence.owner_key_in_scope(owner_key);
  delete from public.notification_retry_queue r
   where r.install_id_hash = any(account_fence.erasure_exclusive_installs())
     and account_fence.holds_install_gate(r.install_id_hash, true)
     and exists (select 1 from public.notification_logs l
       where l.id = r.notification_log_id and l.install_id_hash is not null and l.install_id_hash = r.install_id_hash
         and (l.user_id = p_uid or (l.user_id is null and l.install_id_hash = any(account_fence.erasure_exclusive_installs()))));
  delete from public.notification_logs
   where user_id = p_uid or (user_id is null and install_id_hash = any (account_fence.erasure_exclusive_installs()));

  -- ── Owner data (0113:100-125) ─────────────────────────────────────────────
  delete from public.user_bill_payments          where user_id = p_uid;
  delete from public.user_goal_contributions     where user_id = p_uid;
  delete from public.user_plan_transaction_links where user_id = p_uid;
  delete from public.user_subscriptions          where user_id = p_uid;
  delete from public.user_goals                  where user_id = p_uid;
  delete from public.user_plans                  where user_id = p_uid;
  delete from public.user_budgets                where user_id = p_uid;
  delete from public.user_transactions           where user_id = p_uid;
  delete from public.user_cards                  where user_id = p_uid;
  delete from public.user_accounts               where user_id = p_uid;
  delete from public.user_smart_inbox            where user_id = p_uid;
  delete from public.user_categories             where user_id = p_uid;
  delete from public.financial_import_runs       where user_id = p_uid;
  delete from public.user_settings               where user_id = p_uid;
  delete from public.user_achievements           where user_id = p_uid;
  delete from public.user_streaks                where user_id = p_uid;
  delete from public.user_xp_levels              where user_id = p_uid;
  delete from public.user_engagement_events      where user_id = p_uid;
  delete from public.metrics_rate_limits         where user_id = p_uid;
  delete from public.gamification_awarded_transactions where user_id = p_uid;
  delete from public.feature_flag_overrides      where user_id = p_uid;
  delete from public.sender_bank_mappings        where user_id = p_uid;
  delete from public.backups                     where user_id = p_uid;
  delete from public.profiles                    where id      = p_uid;

  -- ── E1 closure: the sync-state anchor is DELETED, never upserted (0113:138-141 re-created it) ──
  delete from public.user_sync_state where user_id = p_uid;
  -- Admin membership of a deleted account (PROPOSED, PENDING OWNER APPROVAL, O5): the subject's membership row is
  -- removed (no Auth user can use it); rows naming the subject only as grantor lose granted_by. Their free-text
  -- `note` is NOT changed (owner decision, DECISIONS.md).
  update public.admin_users set granted_by = null where granted_by = p_uid;
  delete from public.admin_users where id = p_uid;
end;
$$;

-- E1 closure assertion: after the fixed list, NO row references the subject. A residual reference
-- raises QD013 and rolls the whole erasure back (retry/repair), instead of being waved through later
-- as an Auth ON DELETE SET NULL update. Runs as the narrow owner, so it sees exactly the rows its
-- erasure policies expose (all rows naming the subject).
create function account_fence.erase_verify(p_uid uuid) returns void
language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
as $$
declare v_tbl text;
begin
  if account_fence.in_erasure(p_uid) is not true then
    raise exception 'not_in_erasure_context' using errcode = 'QD012';
  end if;
  select s.tbl into v_tbl from (
    select 'user_accounts'::text as tbl where exists (select 1 from public.user_accounts where user_id = p_uid)
    union all select 'user_transactions'::text as tbl where exists (select 1 from public.user_transactions where user_id = p_uid)
    union all select 'user_budgets'::text as tbl where exists (select 1 from public.user_budgets where user_id = p_uid)
    union all select 'user_goals'::text as tbl where exists (select 1 from public.user_goals where user_id = p_uid)
    union all select 'user_goal_contributions'::text as tbl where exists (select 1 from public.user_goal_contributions where user_id = p_uid)
    union all select 'user_plans'::text as tbl where exists (select 1 from public.user_plans where user_id = p_uid)
    union all select 'user_plan_transaction_links'::text as tbl where exists (select 1 from public.user_plan_transaction_links where user_id = p_uid)
    union all select 'user_subscriptions'::text as tbl where exists (select 1 from public.user_subscriptions where user_id = p_uid)
    union all select 'user_bill_payments'::text as tbl where exists (select 1 from public.user_bill_payments where user_id = p_uid)
    union all select 'user_cards'::text as tbl where exists (select 1 from public.user_cards where user_id = p_uid)
    union all select 'user_categories'::text as tbl where exists (select 1 from public.user_categories where user_id = p_uid)
    union all select 'user_settings'::text as tbl where exists (select 1 from public.user_settings where user_id = p_uid)
    union all select 'user_smart_inbox'::text as tbl where exists (select 1 from public.user_smart_inbox where user_id = p_uid)
    union all select 'sender_bank_mappings'::text as tbl where exists (select 1 from public.sender_bank_mappings where user_id = p_uid)
    union all select 'user_achievements'::text as tbl where exists (select 1 from public.user_achievements where user_id = p_uid)
    union all select 'user_streaks'::text as tbl where exists (select 1 from public.user_streaks where user_id = p_uid)
    union all select 'user_xp_levels'::text as tbl where exists (select 1 from public.user_xp_levels where user_id = p_uid)
    union all select 'user_sync_state'::text as tbl where exists (select 1 from public.user_sync_state where user_id = p_uid)
    union all select 'backups'::text as tbl where exists (select 1 from public.backups where user_id = p_uid)
    union all select 'feature_flag_overrides'::text as tbl where exists (select 1 from public.feature_flag_overrides where user_id = p_uid)
    union all select 'financial_import_runs'::text as tbl where exists (select 1 from public.financial_import_runs where user_id = p_uid)
    union all select 'user_engagement_events'::text as tbl where exists (select 1 from public.user_engagement_events where user_id = p_uid)
    union all select 'metrics_rate_limits'::text as tbl where exists (select 1 from public.metrics_rate_limits where user_id = p_uid)
    union all select 'gamification_awarded_transactions'::text as tbl where exists (select 1 from public.gamification_awarded_transactions where user_id = p_uid)
    union all select 'referral_codes'::text as tbl where exists (select 1 from public.referral_codes where user_id = p_uid)
    union all select 'user_entitlement_state'::text as tbl where exists (select 1 from public.user_entitlement_state where user_id = p_uid)
    union all select 'entitlement_events'::text as tbl where exists (select 1 from public.entitlement_events where user_id = p_uid)
    union all select 'notification_logs'::text as tbl where exists (select 1 from public.notification_logs where user_id = p_uid)
    union all select 'notification_retry_queue'::text as tbl where exists (
      select 1 from public.notification_retry_queue q left join public.notification_logs l on l.id = q.notification_log_id
       where l.user_id = p_uid or q.install_id_hash = any(account_fence.erasure_exclusive_installs())
          or l.install_id_hash = any(account_fence.erasure_exclusive_installs())
          or ((q.install_id_hash = any(account_fence.erasure_installs()) or l.install_id_hash = any(account_fence.erasure_installs()))
              and (l.id is null or l.install_id_hash is null or q.install_id_hash is distinct from l.install_id_hash)))
    union all select 'profiles'::text as tbl where exists (select 1 from public.profiles where id = p_uid)
    union all select 'referral_reward_grants'::text as tbl where exists (select 1 from public.referral_reward_grants where referrer_user_id = p_uid)
    union all select 'referral_reward_progress'::text as tbl where exists (select 1 from public.referral_reward_progress where referrer_user_id = p_uid)
    union all select 'referrals'::text as tbl where exists (select 1 from public.referrals where referrer_user_id = p_uid or referred_user_id = p_uid)
    union all select 'entitlement_events'::text as tbl where exists (select 1 from public.entitlement_events where actor_admin_id = p_uid)
    union all select 'referral_admin_audit'::text as tbl where exists (select 1 from public.referral_admin_audit where target_user_id = p_uid or actor_admin_id = p_uid)
    union all select 'referral_reward_rules'::text as tbl where exists (select 1 from public.referral_reward_rules where created_by = p_uid)
    union all select 'announcement_admin_audit'::text as tbl where exists (select 1 from public.announcement_admin_audit where actor_admin_id = p_uid)
    union all select 'feature_flag_admin_audit'::text as tbl where exists (select 1 from public.feature_flag_admin_audit where actor_admin_id = p_uid)
    union all select 'processed_captures'::text as tbl where exists (select 1 from public.processed_captures where p_uid = any(array[claimed_user_id, owner_uid, consent_owner_uid])
      or consumed_by_install_hash = any(account_fence.erasure_exclusive_installs())
      or install_id_hash = any(account_fence.erasure_exclusive_installs()))
    union all select 'capture_devices'::text as tbl where exists (select 1 from public.capture_devices where user_id = p_uid or consent_owner_uid = p_uid)
    union all select 'capture_install_owner_history'::text as tbl where exists (select 1 from public.capture_install_owner_history where first_owner_uid = p_uid)
    union all select 'admin_users'::text as tbl where exists (select 1 from public.admin_users where id = p_uid or granted_by = p_uid)
    union all select 'capture_rate_limits'::text as tbl where exists (select 1 from public.capture_rate_limits where account_fence.rate_key_in_scope(install_id_hash))
    union all select 'ai_request_idempotency'::text as tbl where exists (select 1 from public.ai_request_idempotency where account_fence.owner_key_in_scope(owner_key))
    union all select 'account_purge_queue'::text as tbl where account_fence.legacy_queue_has_uid(p_uid)
  ) s limit 1;
  if v_tbl is not null then
    raise exception 'erasure_closure_incomplete' using errcode = 'QD013', detail = 'fence:' || v_tbl;
  end if;
end;
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- 8. Legacy 30-day route (E5 mechanics only; disposition of existing accounts is an OWNER decision)
--    and the narrow append-only exception (O5)
-- ════════════════════════════════════════════════════════════════════════════

-- Restated from 0042_account_deletion_policy.sql:17-45 with the schedule route disabled. ACL preserved.
create or replace function public.request_account_deletion()
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
begin
  raise exception 'legacy_scheduled_deletion_disabled' using errcode = 'QD003', detail = 'fence:legacy', hint = 'legacy_route_unavailable';
end;
$$;

-- Restated from 0042:47-62. E5 privilege repair: the INVOKER body asks account_fence.is_pending_self()
-- (EXECUTE granted to authenticated, about the caller only) instead of the unexposed is_pending(uuid).
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
  -- An accepted immediate deletion can never be cancelled.
  if account_fence.is_pending_self() then
    raise exception 'account_deletion_pending' using errcode = 'QD001', detail = 'fence:pending', hint = 'park_account_writes';
  end if;
  update public.profiles
  set delete_scheduled_at = null
  where id = auth.uid();
end;
$$;

-- Clients may no longer SET the legacy schedule by direct DML; clearing it stays allowed.
create function account_fence.profiles_protect_legacy_schedule() returns trigger
language plpgsql security invoker
set search_path = pg_catalog, pg_temp
as $$
begin
  if current_user in ('anon', 'authenticated')
     and new.delete_scheduled_at is not null
     and (tg_op = 'INSERT' or new.delete_scheduled_at is distinct from old.delete_scheduled_at) then
    raise exception 'legacy_scheduled_deletion_disabled' using errcode = 'QD003', detail = 'fence:legacy', hint = 'legacy_route_unavailable';
  end if;
  return new;
end;
$$;
create trigger a0_profiles_protect_legacy_schedule
  before insert or update on public.profiles
  for each row execute function account_fence.profiles_protect_legacy_schedule();

-- The legacy worker may not enqueue an account that has an immediate job.
create function account_fence.legacy_queue_guard() returns trigger
language plpgsql security definer
set search_path = pg_catalog, pg_temp
as $$
begin
  -- P2-2: after this migration the legacy 30-day route is closed for EVERY caller (service_role included). An enqueue that was
  -- blocked on the preflight's EXCLUSIVE lock would otherwise land after commit as a half-processed legacy request.
  raise exception 'legacy_scheduled_deletion_disabled' using errcode = 'QD003', detail = 'fence:legacy', hint = 'legacy_route_unavailable';
  return new;
end;
$$;
-- Existing immediate-pending admission also applies to direct legacy queue UPDATE/DELETE;
-- this does not decide disposition of scheduled/partial legacy work (E5 remains pending).
create trigger a0_account_fence_guard before insert or update or delete on public.account_purge_queue
  for each row execute function account_fence.guard_owner_columns('user_id');
-- Named to sort BEFORE a0_account_fence_guard so a refused enqueue never reaches the admission oracle.
create trigger a0_account_fence_a_legacy_queue
  before insert on public.account_purge_queue
  for each row execute function account_fence.legacy_queue_guard();

-- O5 (PENDING OWNER APPROVAL): restated from 0101_feature_flag_admin_audit.sql:74-79. UPDATE is permitted ONLY for the fixed
-- actor-redaction shape while the subject's own erasure transaction runs; DELETE, TRUNCATE and every other
-- UPDATE still raise P0403. SECURITY DEFINER (owner = migration role) only so the exception can consult
-- the fence helpers without granting API roles EXECUTE on them; it has no caller-authorization semantics.
create or replace function public.feature_flag_audit_append_only()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then                                                   -- [fence]
    if account_fence.audit_redaction_ok(to_jsonb(old), to_jsonb(new)) then   -- [fence]
      return new;                                                            -- [fence]
    end if;                                                                  -- [fence]
  end if;                                                                    -- [fence]
  RAISE EXCEPTION 'feature_flag_admin_audit is append-only' USING ERRCODE = 'P0403';
end;
$$;


-- ════════════════════════════════════════════════════════════════════════════
-- 8a. Pre-handover assertions that read the rollback snapshot (E3, E1.3). They run BEFORE section 9 hands the
--     snapshot tables to the narrow owner, because afterwards the migration role can no longer read them.
-- ════════════════════════════════════════════════════════════════════════════
do $assert$
declare
  r record; v_new text; v_hdr_old text; v_hdr_new text; v_fence oid; v text;
begin
  select o.oid into v_fence from pg_catalog.pg_roles o where o.rolname = 'account_fence_owner';

  -- (1) Restatement preserved every attribute: the pg_get_functiondef header (everything before the body: name,
  --     arguments with defaults, RETURNS, LANGUAGE, SECURITY, volatility, STRICT, PARALLEL, COST, ROWS, SET)
  --     of every pre-existing public function equals the captured one. The two LANGUAGE sql -> plpgsql
  --     rewrites and the exact reviewed audit DEFINER/search_path delta are the only permitted differences.
  for r in select s.fn_identity, s.fn_def from account_fence.rollback_function_snapshot s loop
    v_new := pg_catalog.pg_get_functiondef(to_regprocedure(r.fn_identity));
    if v_new is null then
      raise exception 'assert: snapshotted function vanished: %', r.fn_identity using errcode = 'QD095';
    end if;
    if strpos(r.fn_def, E'\nAS ') = 0 or strpos(v_new, E'\nAS ') = 0 then
      raise exception 'assert: cannot split function definition header: %', r.fn_identity using errcode = 'QD095';
    end if;
    v_hdr_old := substr(r.fn_def, 1, strpos(r.fn_def, E'\nAS ') - 1);
    v_hdr_new := substr(v_new, 1, strpos(v_new, E'\nAS ') - 1);
    if r.fn_identity ~ '(^|\.)(bump_capture_rate_limit|complete_ai_idempotency)\(' then
      v_hdr_old := replace(v_hdr_old, E'\n LANGUAGE sql', E'\n LANGUAGE plpgsql');
    end if;
    if r.fn_identity = 'feature_flag_audit_append_only()'
       or r.fn_identity = 'public.feature_flag_audit_append_only()' then
      -- rpc_attr_preflight already pins BEFORE = plpgsql, INVOKER, volatile, nonstrict, unsafe,
      -- nonleakproof, cost 100, proconfig NULL. AFTER changes only security + this exact SET list.
      if not exists (select 1 from pg_proc p join pg_language l on l.oid = p.prolang
        where p.oid = to_regprocedure(r.fn_identity) and l.lanname = 'plpgsql'
          and p.prosecdef and p.provolatile = 'v' and not p.proisstrict and p.proparallel = 'u'
          and not p.proleakproof and p.procost = 100
          and p.proconfig = array['search_path=pg_catalog, public, pg_temp']::text[]) then
        raise exception 'assert: audit reviewed AFTER attributes differ' using errcode = 'QD095';
      end if;
      v_hdr_old := v_hdr_old || E'\n SECURITY DEFINER\n SET search_path TO ''pg_catalog'', ''public'', ''pg_temp''';
    end if;
    if v_hdr_old is distinct from v_hdr_new then
      raise exception 'assert: function header changed by restatement: %', r.fn_identity using errcode = 'QD095';
    end if;
  end loop;

  -- (2) Owners and EFFECTIVE ACLs (NULL == acldefault, grantor / grant option compared, grants TO the narrow
  --     owner excluded) of every pre-existing public function equal the snapshot, except the two whose service
  --     EXECUTE this file revokes on purpose.
  select string_agg(x.fn_identity, ', ') into v from (
    select s.fn_identity from account_fence.rollback_function_snapshot s
      join pg_catalog.pg_proc p on p.oid = to_regprocedure(s.fn_identity)
     where s.fn_identity !~ '(^|\.)(purge_user_data|capture_history_forget_owner)\('
       and (pg_catalog.pg_get_userbyid(p.proowner) <> s.fn_owner
            or (select coalesce(array_agg(a::text order by a::text), '{}') from (
                  select format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) a
                    from pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) e where e.grantee <> v_fence) q)
               is distinct from
               (select coalesce(array_agg(a::text order by a::text), '{}') from (
                  select format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) a
                    from pg_catalog.aclexplode(coalesce(s.fn_acl, pg_catalog.acldefault('f', p.proowner))) e where e.grantee <> v_fence) q))
  ) x;
  if v is not null then raise exception 'assert: function owner/ACL changed outside the reviewed set: %', v using errcode = 'QD095'; end if;

  -- (3) Exact reviewed application ACL delta: retain owners/RLS; remove ONLY listed direct privileges
  -- from PUBLIC/API roles. The current side is not filtered, so a surviving revoke or unexpected grant fails.
  select string_agg(x.rel, ', ') into v from (
    select s.rel from account_fence.rollback_table_snapshot s
      join pg_catalog.pg_class c on c.oid = s.rel::regclass
     where pg_catalog.pg_get_userbyid(c.relowner) <> s.rel_owner or c.relrowsecurity <> s.rls or c.relforcerowsecurity <> s.force_rls
        or (select coalesce(array_agg(a order by a), '{}') from (
              select format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) a
                from pg_catalog.aclexplode(coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))) e
               where e.grantee <> v_fence) q)
           is distinct from
           (select coalesce(array_agg(a order by a), '{}') from (
              select format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) a
                from pg_catalog.aclexplode(coalesce(s.rel_acl, pg_catalog.acldefault('r', c.relowner))) e
               where e.grantee <> v_fence and not (
                 e.grantee = any(array[0::oid, 'anon'::regrole::oid, 'authenticated'::regrole::oid, 'service_role'::regrole::oid])
                 and ((c.oid = any(array['public.account_purge_queue'::regclass,'public.admin_users'::regclass,'public.ai_request_idempotency'::regclass,'public.announcement_admin_audit'::regclass,'public.backups'::regclass,'public.capture_devices'::regclass,'public.capture_fingerprints'::regclass,'public.capture_install_owner_history'::regclass,'public.capture_rate_limits'::regclass,'public.entitlement_events'::regclass,'public.feature_flag_admin_audit'::regclass,'public.feature_flag_overrides'::regclass,'public.financial_import_runs'::regclass,'public.gamification_awarded_transactions'::regclass,'public.metrics_rate_limits'::regclass,'public.notification_logs'::regclass,'public.notification_retry_queue'::regclass,'public.processed_captures'::regclass,'public.profiles'::regclass,'public.referral_admin_audit'::regclass,'public.referral_codes'::regclass,'public.referral_reward_grants'::regclass,'public.referral_reward_progress'::regclass,'public.referral_reward_rules'::regclass,'public.referrals'::regclass,'public.sender_bank_mappings'::regclass,'public.user_accounts'::regclass,'public.user_achievements'::regclass,'public.user_bill_payments'::regclass,'public.user_budgets'::regclass,'public.user_cards'::regclass,'public.user_categories'::regclass,'public.user_engagement_events'::regclass,'public.user_entitlement_state'::regclass,'public.user_goal_contributions'::regclass,'public.user_goals'::regclass,'public.user_plan_transaction_links'::regclass,'public.user_plans'::regclass,'public.user_settings'::regclass,'public.user_smart_inbox'::regclass,'public.user_streaks'::regclass,'public.user_subscriptions'::regclass,'public.user_sync_state'::regclass,'public.user_transactions'::regclass,'public.user_xp_levels'::regclass]) and e.privilege_type = 'TRUNCATE')
                   or (c.oid = any(array['public.capture_rate_limits'::regclass, 'public.ai_request_idempotency'::regclass, 'public.user_sync_state'::regclass])
                       and e.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'))))) q)
  ) x;
  if v is not null then raise exception 'assert: table owner/RLS/ACL differs from exact reviewed delta: %', v using errcode = 'QD095'; end if;

  -- (4) Default privileges: compared by FULL CONTENT (role, namespace, object type, every aclitem), not by count.
  if exists (
    select 1 from (
      (select d.defaclrole::regrole::text || ':' || d.defaclnamespace::regnamespace::text || ':' || d.defaclobjtype::text as k,
              (select array_agg(x::text order by x::text) from pg_catalog.unnest(d.defaclacl) x) as a
         from pg_catalog.pg_default_acl d
       except
       select m.identity, (select array_agg(x::text order by x::text) from pg_catalog.unnest(m.acl) x)
         from account_fence.rollback_misc_snapshot m where m.kind = 'default_acl')
      union all
      (select m.identity, (select array_agg(x::text order by x::text) from pg_catalog.unnest(m.acl) x)
         from account_fence.rollback_misc_snapshot m where m.kind = 'default_acl'
       except
       select d.defaclrole::regrole::text || ':' || d.defaclnamespace::regnamespace::text || ':' || d.defaclobjtype::text,
              (select array_agg(x::text order by x::text) from pg_catalog.unnest(d.defaclacl) x)
         from pg_catalog.pg_default_acl d)) z) then
    raise exception 'assert: pg_default_acl content changed during apply' using errcode = 'QD093';
  end if;

  -- (5) Schemas public / auth, auth.users and auth.uid(): effective ACL equal to the snapshot modulo grants to the
  --     narrow owner (its grants on auth objects are intentional and removed by rollback).
  select string_agg(x.k, ', ') into v from (
    select m.kind || ':' || m.identity as k from account_fence.rollback_misc_snapshot m
     where m.kind in ('schema', 'relation', 'function')
       and (select coalesce(array_agg(a::text order by a::text), '{}') from (
              select format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) a
                from pg_catalog.aclexplode(coalesce(
                  case m.kind
                    when 'schema' then (select n.nspacl from pg_catalog.pg_namespace n where n.nspname = m.identity)
                    when 'relation' then (select c.relacl from pg_catalog.pg_class c where c.oid = m.identity::regclass)
                    else (select p.proacl from pg_catalog.pg_proc p where p.oid = m.identity::regprocedure) end,
                  case m.kind
                    when 'schema' then (select pg_catalog.acldefault('n', n.nspowner) from pg_catalog.pg_namespace n where n.nspname = m.identity)
                    when 'relation' then (select pg_catalog.acldefault('r', c.relowner) from pg_catalog.pg_class c where c.oid = m.identity::regclass)
                    else (select pg_catalog.acldefault('f', p.proowner) from pg_catalog.pg_proc p where p.oid = m.identity::regprocedure) end)) e
               where e.grantee <> v_fence) q)
           is distinct from
           (select coalesce(array_agg(a::text order by a::text), '{}') from (
              select format('%s/%s/%s/%s', e.grantee, e.grantor, e.privilege_type, e.is_grantable) a
                from pg_catalog.aclexplode(coalesce(m.acl,
                  case m.kind
                    when 'schema' then (select pg_catalog.acldefault('n', n.nspowner) from pg_catalog.pg_namespace n where n.nspname = m.identity)
                    when 'relation' then (select pg_catalog.acldefault('r', c.relowner) from pg_catalog.pg_class c where c.oid = m.identity::regclass)
                    else (select pg_catalog.acldefault('f', p.proowner) from pg_catalog.pg_proc p where p.oid = m.identity::regprocedure) end)) e
               where e.grantee <> v_fence) q)
  ) x;
  if v is not null then raise exception 'assert: schema/auth ACL changed: %', v using errcode = 'QD093'; end if;
end
$assert$;

-- ════════════════════════════════════════════════════════════════════════════
-- 9. Effective ACLs (explicit) and ownership transfer to the narrow owner
-- ════════════════════════════════════════════════════════════════════════════
revoke all on schema account_fence from public, anon, authenticated, service_role;
grant usage on schema account_fence to authenticated;
revoke all on all tables in schema account_fence from public, anon, authenticated, service_role;
revoke all on function account_fence.gate_key(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.install_gate_key(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.erasure_uid() from public, anon, authenticated, service_role;
revoke all on function account_fence.in_erasure(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.is_pending(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.is_pending_self() from public, anon, authenticated, service_role;
revoke all on function account_fence.deny(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.admit(uuid, boolean, boolean) from public, anon, authenticated, service_role;
revoke all on function account_fence.admit_self() from public, anon, authenticated, service_role;
revoke all on function account_fence.admit_check_self(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.admit_many(uuid[], boolean, boolean) from public, anon, authenticated, service_role;
revoke all on function account_fence.install_owners(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.admit_install(text, boolean, boolean) from public, anon, authenticated, service_role;
revoke all on function account_fence.admit_rate_key(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.admit_owner_key(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.holds_gate(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.holds_advisory(bigint, boolean) from public, anon, authenticated, service_role;
revoke all on function account_fence.holds_install_gate(text, boolean) from public, anon, authenticated, service_role;
revoke all on function account_fence.lock_install(text, boolean) from public, anon, authenticated, service_role;
revoke all on function account_fence.lease_peek(uuid, uuid, integer) from public, anon, authenticated, service_role;
revoke all on function account_fence.assert_gated(uuid[]) from public, anon, authenticated, service_role;
revoke all on function account_fence.referral_code_owner(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.referral_owners(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.referral_owners_for_referred(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.assert_unlink_allowed(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.deletion_tombstone() from public, anon, authenticated, service_role;
revoke all on function account_fence.only_changed(jsonb, jsonb, text[]) from public, anon, authenticated, service_role;
revoke all on function account_fence.rate_key_parts(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.owner_key_parts(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.erasure_installs() from public, anon, authenticated, service_role;
revoke all on function account_fence.erasure_exclusive_installs() from public, anon, authenticated, service_role;
revoke all on function account_fence.rate_key_in_scope(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.owner_key_in_scope(text) from public, anon, authenticated, service_role;
revoke all on function account_fence.erasure_row_allowed(text, text, jsonb, jsonb, uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.minimizing_update_kind(text, jsonb, jsonb) from public, anon, authenticated, service_role;
revoke all on function account_fence.cascade_delete_allowed(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function account_fence.guard_owner_columns() from public, anon, authenticated, service_role;
revoke all on function account_fence.guard_install_column() from public, anon, authenticated, service_role;
revoke all on function account_fence.lease_job(uuid, uuid, integer) from public, anon, authenticated, service_role;
revoke all on function account_fence.erase_user_data(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.erase_verify(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.audit_redaction_ok(jsonb, jsonb) from public, anon, authenticated, service_role;
revoke all on function account_fence.purge_expired_deletion_records(integer) from public, anon, authenticated, service_role;
revoke all on function account_fence.operator_failed_jobs() from public, anon, authenticated, service_role;
revoke all on function account_fence.operator_requeue_failed_job(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.operator_cancel_failed_job(uuid) from public, anon, authenticated, service_role;
revoke all on function account_fence.profiles_protect_legacy_schedule() from public, anon, authenticated, service_role;
revoke all on function account_fence.legacy_queue_guard() from public, anon, authenticated, service_role;
grant execute on function account_fence.is_pending_self() to authenticated;
grant execute on function account_fence.admit_self() to authenticated;
grant execute on function account_fence.admit_check_self(uuid) to authenticated;

revoke all on function public.account_deletion_reserve_material(text, text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_dispose_material(text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_read_material(text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_find_accepted(text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_issue_challenge(uuid) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_read_challenge(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_apple_subject(uuid) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_accept(text, uuid, text, bigint, text, text, text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_fence_attempt(text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_claim_lease(text, integer, uuid) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_heartbeat(uuid, uuid, integer, integer) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_begin_step(uuid, uuid, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_complete_step(uuid, uuid, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_record_failure(uuid, uuid, integer, text, text, boolean, bigint) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_complete_job(uuid, uuid, integer, bigint) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_get_receipt(text) from public, anon, authenticated, service_role;
revoke all on function public.account_deletion_purge(uuid, uuid, integer) from public, anon, authenticated, service_role;
grant execute on function
  public.account_deletion_reserve_material(text, text),
  public.account_deletion_dispose_material(text),
  public.account_deletion_read_material(text),
  public.account_deletion_find_accepted(text),
  public.account_deletion_issue_challenge(uuid),
  public.account_deletion_read_challenge(uuid, text),
  public.account_deletion_apple_subject(uuid),
  public.account_deletion_accept(text, uuid, text, bigint, text, text, text),
  public.account_deletion_fence_attempt(text),
  public.account_deletion_claim_lease(text, integer, uuid),
  public.account_deletion_heartbeat(uuid, uuid, integer, integer),
  public.account_deletion_begin_step(uuid, uuid, integer, text),
  public.account_deletion_complete_step(uuid, uuid, integer, text),
  public.account_deletion_record_failure(uuid, uuid, integer, text, text, boolean, bigint),
  public.account_deletion_complete_job(uuid, uuid, integer, bigint),
  public.account_deletion_get_receipt(text),
  public.account_deletion_purge(uuid, uuid, integer)
  to service_role;
-- Erasure is reachable only through the leased entry above (E5: legacy worker fails closed).
revoke execute on function public.purge_user_data(uuid) from service_role;
revoke execute on function public.capture_history_forget_owner(uuid) from service_role;

-- Ownership. Default privileges: no ALTER DEFAULT PRIVILEGES is issued for any role; the explicit
-- revokes above are the ACL (default PUBLIC EXECUTE on new functions is removed per function).
-- ALTER ... OWNER needs CREATE on the target schema for the new owner: granted transiently, revoked below.
grant create on schema public to account_fence_owner;
grant create on schema account_fence to account_fence_owner;
alter table account_fence.deletion_job owner to account_fence_owner;
alter table account_fence.deletion_scope owner to account_fence_owner;
alter table account_fence.deletion_receipt owner to account_fence_owner;
alter table account_fence.deletion_material owner to account_fence_owner;
alter table account_fence.deletion_attempt_tombstone owner to account_fence_owner;
alter table account_fence.deletion_challenge owner to account_fence_owner;
alter table account_fence.deletion_workset owner to account_fence_owner;
alter table account_fence.erasure_ctx owner to account_fence_owner;
alter table account_fence.rollback_function_snapshot owner to account_fence_owner;
alter table account_fence.rollback_table_snapshot owner to account_fence_owner;
alter table account_fence.rollback_misc_snapshot owner to account_fence_owner;
alter table account_fence.rollback_cron_snapshot owner to account_fence_owner;
alter function account_fence.gate_key(uuid) owner to account_fence_owner;
alter function account_fence.install_gate_key(text) owner to account_fence_owner;
alter function account_fence.erasure_uid() owner to account_fence_owner;
alter function account_fence.in_erasure(uuid) owner to account_fence_owner;
alter function account_fence.is_pending(uuid) owner to account_fence_owner;
alter function account_fence.is_pending_self() owner to account_fence_owner;
alter function account_fence.deny(text) owner to account_fence_owner;
alter function account_fence.admit(uuid, boolean, boolean) owner to account_fence_owner;
alter function account_fence.admit_self() owner to account_fence_owner;
alter function account_fence.admit_check_self(uuid) owner to account_fence_owner;
alter function account_fence.admit_many(uuid[], boolean, boolean) owner to account_fence_owner;
alter function account_fence.install_owners(text) owner to account_fence_owner;
alter function account_fence.admit_install(text, boolean, boolean) owner to account_fence_owner;
alter function account_fence.admit_rate_key(text) owner to account_fence_owner;
alter function account_fence.admit_owner_key(text) owner to account_fence_owner;
alter function account_fence.holds_gate(uuid) owner to account_fence_owner;
alter function account_fence.holds_advisory(bigint, boolean) owner to account_fence_owner;
alter function account_fence.holds_install_gate(text, boolean) owner to account_fence_owner;
alter function account_fence.lock_install(text, boolean) owner to account_fence_owner;
alter function account_fence.lease_peek(uuid, uuid, integer) owner to account_fence_owner;
alter function account_fence.assert_gated(uuid[]) owner to account_fence_owner;
alter function account_fence.referral_code_owner(text) owner to account_fence_owner;
alter function account_fence.referral_owners(uuid) owner to account_fence_owner;
alter function account_fence.referral_owners_for_referred(uuid) owner to account_fence_owner;
alter function account_fence.assert_unlink_allowed(text) owner to account_fence_owner;
alter function account_fence.deletion_tombstone() owner to account_fence_owner;
alter function account_fence.only_changed(jsonb, jsonb, text[]) owner to account_fence_owner;
alter function account_fence.rate_key_parts(text) owner to account_fence_owner;
alter function account_fence.owner_key_parts(text) owner to account_fence_owner;
alter function account_fence.erasure_installs() owner to account_fence_owner;
alter function account_fence.erasure_exclusive_installs() owner to account_fence_owner;
alter function account_fence.rate_key_in_scope(text) owner to account_fence_owner;
alter function account_fence.owner_key_in_scope(text) owner to account_fence_owner;
alter function account_fence.erasure_row_allowed(text, text, jsonb, jsonb, uuid) owner to account_fence_owner;
alter function account_fence.minimizing_update_kind(text, jsonb, jsonb) owner to account_fence_owner;
alter function account_fence.cascade_delete_allowed(text, jsonb) owner to account_fence_owner;
alter function account_fence.guard_owner_columns() owner to account_fence_owner;
alter function account_fence.guard_install_column() owner to account_fence_owner;
alter function account_fence.lease_job(uuid, uuid, integer) owner to account_fence_owner;
alter function account_fence.erase_user_data(uuid, uuid) owner to account_fence_owner;
alter function account_fence.erase_verify(uuid) owner to account_fence_owner;
alter function account_fence.audit_redaction_ok(jsonb, jsonb) owner to account_fence_owner;
alter function account_fence.profiles_protect_legacy_schedule() owner to account_fence_owner;
alter function account_fence.legacy_queue_guard() owner to account_fence_owner;
alter function account_fence.purge_expired_deletion_records(integer) owner to account_fence_owner;
alter function account_fence.operator_failed_jobs() owner to account_fence_owner;
alter function account_fence.operator_requeue_failed_job(uuid) owner to account_fence_owner;
alter function account_fence.operator_cancel_failed_job(uuid) owner to account_fence_owner;
alter function public.account_deletion_reserve_material(text, text) owner to account_fence_owner;
alter function public.account_deletion_dispose_material(text) owner to account_fence_owner;
alter function public.account_deletion_read_material(text) owner to account_fence_owner;
alter function public.account_deletion_find_accepted(text) owner to account_fence_owner;
alter function public.account_deletion_issue_challenge(uuid) owner to account_fence_owner;
alter function public.account_deletion_read_challenge(uuid, text) owner to account_fence_owner;
alter function public.account_deletion_apple_subject(uuid) owner to account_fence_owner;
alter function public.account_deletion_accept(text, uuid, text, bigint, text, text, text) owner to account_fence_owner;
alter function public.account_deletion_fence_attempt(text) owner to account_fence_owner;
alter function public.account_deletion_claim_lease(text, integer, uuid) owner to account_fence_owner;
alter function public.account_deletion_heartbeat(uuid, uuid, integer, integer) owner to account_fence_owner;
alter function public.account_deletion_begin_step(uuid, uuid, integer, text) owner to account_fence_owner;
alter function public.account_deletion_complete_step(uuid, uuid, integer, text) owner to account_fence_owner;
alter function public.account_deletion_record_failure(uuid, uuid, integer, text, text, boolean, bigint) owner to account_fence_owner;
alter function public.account_deletion_complete_job(uuid, uuid, integer, bigint) owner to account_fence_owner;
alter function public.account_deletion_get_receipt(text) owner to account_fence_owner;
alter function public.account_deletion_purge(uuid, uuid, integer) owner to account_fence_owner;
alter schema account_fence owner to account_fence_owner;
-- Grants TO THE MIGRATION ROLE must come AFTER the ownership transfer: while it still owned these objects, a grant to
-- itself is a no-op, and ALTER ... OWNER then discards the old owner's implicit entry (found on the loopback stack:
-- postgres lost EXECUTE on account_fence.admit and the legacy-route writers failed with 42501). The membership granted
-- in section 1 still carries INHERIT here, so these grants are issued on behalf of the new owner.
grant usage on schema account_fence to postgres;
grant execute on function account_fence.is_pending(uuid) to postgres;
grant execute on function account_fence.admit(uuid, boolean, boolean) to postgres;
grant execute on function account_fence.admit_many(uuid[], boolean, boolean) to postgres;
grant execute on function account_fence.admit_install(text, boolean, boolean) to postgres;
grant execute on function account_fence.admit_rate_key(text) to postgres;
grant execute on function account_fence.admit_owner_key(text) to postgres;
grant execute on function account_fence.assert_gated(uuid[]) to postgres;
grant execute on function account_fence.referral_code_owner(text) to postgres;
grant execute on function account_fence.referral_owners(uuid) to postgres;
grant execute on function account_fence.referral_owners_for_referred(uuid) to postgres;
grant execute on function account_fence.assert_unlink_allowed(text) to postgres;
grant execute on function account_fence.audit_redaction_ok(jsonb, jsonb) to postgres;
grant execute on function account_fence.purge_expired_deletion_records(integer) to postgres;   -- pg_cron runs as the migration role
grant execute on function account_fence.operator_failed_jobs() to postgres;                       -- F4 operator recovery
grant execute on function account_fence.operator_cancel_failed_job(uuid) to postgres;
grant execute on function account_fence.operator_requeue_failed_job(uuid) to postgres;           -- (preflight pins current_user = postgres)
revoke create on schema public from account_fence_owner;
revoke account_fence_owner from current_user;

-- ════════════════════════════════════════════════════════════════════════════
-- 10. Effective-privilege assertions (fail closed; assertions only, no DDL)
-- ════════════════════════════════════════════════════════════════════════════

do $assert$
declare
  v text; v_fence oid; v_ver int := current_setting('server_version_num')::int;
  r record; api text[] := array['anon', 'authenticated', 'service_role'];
begin
  select o.oid into v_fence from pg_catalog.pg_roles o where o.rolname = 'account_fence_owner';
  -- no overloads of the admission entry (a stray overload would have its own ACL)
  if (select count(*) from pg_proc p where p.pronamespace = 'account_fence'::regnamespace and p.proname = 'admit') <> 1 then
    raise exception 'assert: admit must have exactly one signature' using errcode = 'QD093';
  end if;
  -- ownership: functions, entry points, schema, and EVERY relation in account_fence
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p where p.pronamespace = 'account_fence'::regnamespace
     and p.proname not in ('auth_uid', 'auth_user_exists', 'auth_apple_subject', 'legacy_queue_has_uid')
     and pg_get_userbyid(p.proowner) <> 'account_fence_owner';
  if v is not null then raise exception 'assert: not owned by account_fence_owner: %', v using errcode = 'QD093'; end if;
  -- The four shims (three auth, one legacy-queue probe) are the ONLY account_fence functions that stay owned by the migration role (the narrow owner
  -- cannot be granted schema auth, nor the legacy queue). They must be exactly: migration-role-owned, SECURITY DEFINER, pinned search_path,
  -- and executable by account_fence_owner alone (and the owner).
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p where p.pronamespace = 'account_fence'::regnamespace
     and p.proname in ('auth_uid', 'auth_user_exists', 'auth_apple_subject', 'legacy_queue_has_uid')
     and (pg_get_userbyid(p.proowner) <> current_user or not p.prosecdef
          or p.proconfig is distinct from array['search_path=pg_catalog, pg_temp']
          or exists (select 1 from aclexplode(p.proacl) a
                      where a.grantee not in (p.proowner, v_fence) or a.privilege_type <> 'EXECUTE'));
  if v is not null then raise exception 'assert: shim has unexpected owner/attributes/ACL: %', v using errcode = 'QD093'; end if;
  if (select count(*) from pg_proc p where p.pronamespace = 'account_fence'::regnamespace
       and p.proname in ('auth_uid', 'auth_user_exists', 'auth_apple_subject', 'legacy_queue_has_uid')) <> 4 then
    raise exception 'assert: expected exactly the four migration-role shims' using errcode = 'QD093';
  end if;
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'account_deletion\_%'
     and pg_get_userbyid(p.proowner) <> 'account_fence_owner';
  if v is not null then raise exception 'assert: entry not owned by account_fence_owner: %', v using errcode = 'QD093'; end if;
  if (select pg_get_userbyid(n.nspowner) from pg_namespace n where n.nspname = 'account_fence') <> 'account_fence_owner' then
    raise exception 'assert: schema account_fence not owned by account_fence_owner' using errcode = 'QD093';
  end if;
  select string_agg(c.relname, ', ') into v
    from pg_class c where c.relnamespace = 'account_fence'::regnamespace and c.relkind in ('r', 'p', 'S', 'v', 'm')
     and pg_get_userbyid(c.relowner) <> 'account_fence_owner';
  if v is not null then raise exception 'assert: account_fence relation not owned by account_fence_owner: %', v using errcode = 'QD093'; end if;
  -- operational tables: row security ENABLED and FORCED; rollback snapshot tables: enabled, no policy at all
  select string_agg(c.relname, ', ') into v
    from pg_class c where c.relnamespace = 'account_fence'::regnamespace and c.relkind = 'r'
     and c.relname in ('deletion_job', 'deletion_scope', 'deletion_receipt', 'deletion_material',
                       'deletion_attempt_tombstone', 'deletion_challenge', 'deletion_workset', 'erasure_ctx')
     and not (c.relrowsecurity and c.relforcerowsecurity);
  if v is not null then raise exception 'assert: operational table without forced RLS: %', v using errcode = 'QD093'; end if;
  select string_agg(c.relname, ', ') into v
    from pg_class c where c.relnamespace = 'account_fence'::regnamespace and c.relkind = 'r'
     and c.relname like 'rollback\_%' and (not c.relrowsecurity or exists (select 1 from pg_policy pol where pol.polrelid = c.oid));
  if v is not null then raise exception 'assert: snapshot table RLS/policy shape: %', v using errcode = 'QD093'; end if;

  -- Traverse OUTWARD from each API principal. PG15: rolinherit controls inheritance, membership permits SET.
  -- PG16+: per-membership inherit_option/set_option. Unioning edge types is a conservative reachability
  -- superset (mixed chains may be refused); it never exempts authenticated -> service_role.
  for r in
    with recursive reach(principal, oid) as (
      select ro.rolname::text, ro.oid from pg_roles ro where ro.rolname = any(api)
      union
      select q.principal, m.roleid from reach q join pg_auth_members m on m.member = q.oid
        join pg_roles member_role on member_role.oid = m.member
       where (case when v_ver >= 160000 then coalesce((to_jsonb(m)->>'inherit_option')::boolean, false)
                   else member_role.rolinherit end)
          or (case when v_ver >= 160000 then coalesce((to_jsonb(m)->>'set_option')::boolean, false) else true end)
    )
    select q.principal, ro.oid, ro.rolname, ro.rolsuper, ro.rolbypassrls, ro.rolcreaterole,
           q.principal = 'service_role' as is_service, q.principal = 'authenticated' as is_auth
      from reach q join pg_roles ro on ro.oid = q.oid
  loop
    if r.rolsuper or r.rolcreaterole or r.rolname = 'account_fence_owner'
       or (r.rolbypassrls and not (r.is_service and r.rolname = 'service_role'))
       or (r.rolname = 'service_role' and not r.is_service) then
      raise exception 'assert: API principal % reaches privileged role %', r.principal, r.rolname using errcode = 'QD093';
    end if;
    if exists (select 1 from pg_auth_members m where m.member = r.oid and m.admin_option) then
      raise exception 'assert: API principal % via % can administer a role membership', r.principal, r.rolname using errcode = 'QD093';
    end if;
    -- Effective application privileges include PUBLIC, inherited ACLs and every reachable SET role.
    select string_agg(c.oid::regclass::text, ', ') into v from pg_class c
     where c.oid = any(array['public.account_purge_queue'::regclass,'public.admin_users'::regclass,'public.ai_request_idempotency'::regclass,'public.announcement_admin_audit'::regclass,'public.backups'::regclass,'public.capture_devices'::regclass,'public.capture_fingerprints'::regclass,'public.capture_install_owner_history'::regclass,'public.capture_rate_limits'::regclass,'public.entitlement_events'::regclass,'public.feature_flag_admin_audit'::regclass,'public.feature_flag_overrides'::regclass,'public.financial_import_runs'::regclass,'public.gamification_awarded_transactions'::regclass,'public.metrics_rate_limits'::regclass,'public.notification_logs'::regclass,'public.notification_retry_queue'::regclass,'public.processed_captures'::regclass,'public.profiles'::regclass,'public.referral_admin_audit'::regclass,'public.referral_codes'::regclass,'public.referral_reward_grants'::regclass,'public.referral_reward_progress'::regclass,'public.referral_reward_rules'::regclass,'public.referrals'::regclass,'public.sender_bank_mappings'::regclass,'public.user_accounts'::regclass,'public.user_achievements'::regclass,'public.user_bill_payments'::regclass,'public.user_budgets'::regclass,'public.user_cards'::regclass,'public.user_categories'::regclass,'public.user_engagement_events'::regclass,'public.user_entitlement_state'::regclass,'public.user_goal_contributions'::regclass,'public.user_goals'::regclass,'public.user_plan_transaction_links'::regclass,'public.user_plans'::regclass,'public.user_settings'::regclass,'public.user_smart_inbox'::regclass,'public.user_streaks'::regclass,'public.user_subscriptions'::regclass,'public.user_sync_state'::regclass,'public.user_transactions'::regclass,'public.user_xp_levels'::regclass])
       and has_table_privilege(r.oid, c.oid, 'TRUNCATE');
    if v is not null then raise exception 'assert: % via % retains application TRUNCATE: %', r.principal, r.rolname, v using errcode = 'QD093'; end if;
    select string_agg(c.oid::regclass::text, ', ') into v from pg_class c
     where c.oid = any(array['public.capture_rate_limits'::regclass, 'public.ai_request_idempotency'::regclass, 'public.user_sync_state'::regclass])
       and (has_table_privilege(r.oid, c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
            or has_any_column_privilege(r.oid, c.oid, 'INSERT, UPDATE, REFERENCES'));
    if v is not null then raise exception 'assert: % via % retains revoked application DML: %', r.principal, r.rolname, v using errcode = 'QD093'; end if;
    select string_agg(p.oid::regprocedure::text, ', ') into v
      from pg_proc p
     where p.pronamespace = 'account_fence'::regnamespace and has_function_privilege(r.oid, p.oid, 'EXECUTE')
       and not (r.is_auth and p.proname in ('admit_self', 'admit_check_self', 'is_pending_self'));
    if v is not null then raise exception 'assert: role % can effectively execute account_fence function(s): %', r.rolname, v using errcode = 'QD093'; end if;
    select string_agg(p.oid::regprocedure::text, ', ') into v
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname like 'account_deletion\_%' and has_function_privilege(r.oid, p.oid, 'EXECUTE')
       and not r.is_service;
    if v is not null then raise exception 'assert: role % can effectively execute account_deletion entry: %', r.rolname, v using errcode = 'QD093'; end if;
    if has_function_privilege(r.oid, 'public.purge_user_data(uuid)', 'EXECUTE')
       or has_function_privilege(r.oid, 'public.capture_history_forget_owner(uuid)', 'EXECUTE') then
      if r.principal = any(api) then
        raise exception 'assert: role % can still execute a legacy erasure helper', r.rolname using errcode = 'QD093';
      end if;
    end if;
    -- no API-reachable privilege on any account_fence table or schema beyond USAGE for the authenticated self helpers
    select string_agg(c.relname, ', ') into v
      from pg_class c where c.relnamespace = 'account_fence'::regnamespace and c.relkind = 'r'
       and (has_table_privilege(r.oid, c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
            or has_any_column_privilege(r.oid, c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'));
    if v is not null then raise exception 'assert: role % has privileges on account_fence tables: %', r.rolname, v using errcode = 'QD093'; end if;
    if has_schema_privilege(r.oid, 'account_fence', 'CREATE') or (not r.is_auth and has_schema_privilege(r.oid, 'account_fence', 'USAGE')) then
      raise exception 'assert: role % has account_fence schema privileges beyond the authenticated USAGE', r.rolname using errcode = 'QD093';
    end if;
  end loop;
  if has_function_privilege('anon', 'public.purge_user_data(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.capture_history_forget_owner(uuid)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.purge_user_data(uuid)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.capture_history_forget_owner(uuid)', 'EXECUTE') then
    raise exception 'assert: legacy erasure helper still executable by anon/service_role' using errcode = 'QD093';
  end if;

  -- F4 operator recovery functions (failed_jobs, requeue, cancel): owned by the narrow owner, SECURITY DEFINER with a pinned search_path, and EXECUTE for the
  -- migration principal (and the owner) only; never PUBLIC, never an API role (the loop above already rejects API reachability).
  select string_agg(p.oid::regprocedure::text, ', ') into v
    from pg_proc p where p.pronamespace = 'account_fence'::regnamespace
     and p.proname in ('operator_failed_jobs', 'operator_requeue_failed_job', 'operator_cancel_failed_job')
     and (pg_get_userbyid(p.proowner) <> 'account_fence_owner' or not p.prosecdef
          or p.proconfig is distinct from array['search_path=pg_catalog, pg_temp']
          or p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a
                      where a.privilege_type <> 'EXECUTE' or a.grantee = 0
                         or a.grantee not in (p.proowner, 'postgres'::regrole::oid)));
  if v is not null then raise exception 'assert: operator recovery function has unexpected owner/attributes/ACL: %', v using errcode = 'QD093'; end if;
  if (select count(*) from pg_proc p where p.pronamespace = 'account_fence'::regnamespace
       and p.proname in ('operator_failed_jobs', 'operator_requeue_failed_job', 'operator_cancel_failed_job')) <> 3 then
    raise exception 'assert: expected exactly the three operator recovery functions' using errcode = 'QD093';
  end if;

  -- the narrow owner: not superuser/bypass/login; NO membership path to it for any non-superuser (version-
  -- appropriate: PG16 USAGE|SET, PG15 MEMBER); no ADMIN OPTION for anyone but the migration role; no lingering CREATE.
  if exists (select 1 from pg_roles pr where pr.rolname = 'account_fence_owner'
              and (pr.rolsuper or pr.rolbypassrls or pr.rolcanlogin or pr.rolcreaterole or pr.rolcreatedb or pr.rolreplication or pr.rolinherit)) then
    raise exception 'assert: account_fence_owner is over-privileged' using errcode = 'QD093';
  end if;
  if v_ver >= 160000 then
    select string_agg(pr.rolname, ', ') into v from pg_roles pr
     where pr.rolname <> 'account_fence_owner' and not pr.rolsuper
       and (pg_has_role(pr.oid, 'account_fence_owner', 'USAGE') or pg_has_role(pr.oid, 'account_fence_owner', 'SET'));
  else
    select string_agg(pr.rolname, ', ') into v from pg_roles pr
     where pr.rolname <> 'account_fence_owner' and not pr.rolsuper and pg_has_role(pr.oid, 'account_fence_owner', 'MEMBER');
  end if;
  if v is not null then raise exception 'assert: membership path to account_fence_owner: %', v using errcode = 'QD093'; end if;
  select string_agg(m.member::regrole::text, ', ') into v from pg_auth_members m
   where m.roleid = v_fence and m.admin_option and m.member::regrole::text <> current_user
     and not (select pr.rolsuper from pg_roles pr where pr.oid = m.member);
  if v is not null then raise exception 'assert: ADMIN OPTION on account_fence_owner held by: %', v using errcode = 'QD093'; end if;
  if has_schema_privilege('account_fence_owner', 'public', 'CREATE') then
    raise exception 'assert: account_fence_owner still has CREATE on schema public' using errcode = 'QD093';
  end if;
end
$assert$;

-- ════════════════════════════════════════════════════════════════════════════
-- 11. Scheduling (D5 purge, contract section 8 worker). Guarded: nothing is scheduled when pg_cron is absent.
-- ════════════════════════════════════════════════════════════════════════════
-- Worker dispatcher: the 0098 run_cron_daily_reminders pattern exactly (vault `project_url` + a dedicated vault worker
-- secret, fail closed with a LOG line when either is missing, net.http_post with a Bearer header). OWNER ACTION (NOT
-- performed here): set the Edge secret ACCOUNT_DELETION_WORKER_SECRET and store the SAME value in Vault as
-- 'account_deletion_worker_secret'; until then every tick is a logged skip. Owned by the migration role (vault access);
-- nothing but pg_cron (running as that role) needs EXECUTE, so every API role is revoked and none is granted.
create function public.run_account_deletion_worker()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  project_url   text;
  worker_secret text;
begin
  select decrypted_secret into project_url
    from vault.decrypted_secrets where name = 'project_url' limit 1;
  select decrypted_secret into worker_secret
    from vault.decrypted_secrets where name = 'account_deletion_worker_secret' limit 1;

  if project_url is null or worker_secret is null then
    raise log 'account_deletion_worker skipped: worker secret not configured';
    return;
  end if;

  perform net.http_post(
    url := project_url || '/functions/v1/account-deletion-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := '{}'::jsonb
  );
end;
$$;
revoke all on function public.run_account_deletion_worker() from public, anon, authenticated, service_role;
do $assert$
begin
  if has_function_privilege('anon', 'public.run_account_deletion_worker()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.run_account_deletion_worker()', 'EXECUTE')
     or has_function_privilege('service_role', 'public.run_account_deletion_worker()', 'EXECUTE') then
    raise exception 'assert: run_account_deletion_worker is executable by an API role' using errcode = 'QD093';
  end if;
end
$assert$;

-- cron.schedule upserts by job name (0065/0112 convention), so re-running is safe. rollback.sql unschedules both names.
do $cron$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron') then
    perform cron.schedule('account-deletion-worker', '*/5 * * * *', $job$select public.run_account_deletion_worker()$job$);
    perform cron.schedule('account-deletion-purge-expired', '17 3 * * *', $job$select account_fence.purge_expired_deletion_records()$job$);
  end if;
end
$cron$;

-- F1 / E5: quiesce the legacy 30-day worker. The job 'purge-scheduled-deletions-job' (0065) would otherwise sweep Storage for an
-- overdue legacy profile and then fail forever on the revoked purge_user_data. Its exact schedule, command and active flag were
-- recorded in account_fence.rollback_cron_snapshot (section 0); rollback.sql re-schedules it from that record. Profiles that only
-- have delete_scheduled_at set are NOT touched or accelerated: the user may cancel, or choose immediate deletion with fresh
-- confirmation. The queue was proven empty by the preflight (QD096) and legacy_queue_guard refuses every later INSERT (QD003).
do $cron$
begin
  if exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'purge-scheduled-deletions-job') then
    perform cron.unschedule('purge-scheduled-deletions-job');
  end if;
end
$cron$;

commit;

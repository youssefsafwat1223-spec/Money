-- baseline.sql — READ-ONLY catalog report. NOT EXECUTED by its author.
-- Run only against the disposable local database created by run.sh. Output is
-- evidence of the CURRENT authority, to be diffed before/after the fence.
\set ON_ERROR_STOP on
\pset pager off
\echo '== extensions'
select extname, extversion from pg_extension order by 1;

\echo '== candidate functions: owner, security, volatility, proconfig, ACL'
select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args,
       pg_get_userbyid(p.proowner) as owner, p.prosecdef as definer, p.provolatile,
       p.proconfig, p.proacl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'account_fence', 'account_fence_impl')
   and p.proname in (
     'stamp_sync_seq','sync_lock_epoch','purge_user_data','request_account_deletion','cancel_account_deletion',
     'set_default_account','add_goal_contribution','record_bill_payment','delete_bill_payment','plan_transactions',
     'delete_user_account_safely','create_subscription_and_record_payment','delete_user_category_safely',
     'import_financial_package','record_engagement_event','record_metric','commit_backup_generation',
     'apply_referral_code','request_referral_qualification','get_referral_summary','get_entitlement_decision',
     'record_coupon_event','link_capture_device','set_capture_consent','revoke_capture_consent',
     'legacy_link_capture_device','legacy_set_device_consent','unlink_capture_device','capture_claim',
     'capture_ai_dispatch','capture_finalize','capture_ack','capture_sync_list','capture_retry_fence',
     'capture_queue_push','bump_capture_rate_limit','claim_ai_idempotency','complete_ai_idempotency',
     'award_gamification_for_transaction','referral_admin_claim','admin_mutate_entitlement','admin_reject_referral',
     'admin_reverse_referral','admin_adjust_referral_progress','admin_rotate_referral_code',
     'admin_publish_reward_rule','admin_deactivate_reward_rule','backups_owner_is_live')
 order by 1, 2, 3;

\echo '== overload check: more than one signature per name in public'
select proname, count(*) from pg_proc where pronamespace = 'public'::regnamespace
 group by 1 having count(*) > 1 order by 1;

\echo '== table privileges for API roles on owner tables'
select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) as privs
  from information_schema.role_table_grants
 where table_schema = 'public'
   and table_name in ('profiles','backups','notification_logs','feature_flag_overrides','financial_import_runs',
                      'capture_devices','processed_captures','capture_rate_limits','ai_request_idempotency',
                      'referrals','referral_codes','referral_reward_progress','referral_reward_grants',
                      'user_entitlement_state','entitlement_events','referral_reward_rules','referral_admin_audit',
                      'user_sync_state','account_purge_queue')
   and grantee in ('anon','authenticated','service_role','public')
 group by 1, 2 order by 1, 2;

\echo '== row security and policies'
select c.relname, c.relrowsecurity, c.relforcerowsecurity from pg_class c
 where c.relnamespace = 'public'::regnamespace and c.relname in
   ('profiles','backups','notification_logs','feature_flag_overrides','financial_import_runs','capture_devices','processed_captures')
 order by 1;
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
  from pg_policies where schemaname = 'public'
   and tablename in ('profiles','backups','notification_logs','feature_flag_overrides','financial_import_runs')
 order by 2, 3;

\echo '== triggers on candidate tables'
select c.relname, t.tgname, pg_get_triggerdef(t.oid) as def
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
 where not t.tgisinternal and c.relnamespace = 'public'::regnamespace
   and c.relname in ('capture_devices','processed_captures','notification_logs','referrals','referral_codes',
                     'referral_reward_progress','referral_reward_grants','user_entitlement_state','entitlement_events',
                     'referral_reward_rules','referral_admin_audit','profiles','account_purge_queue',
                     'user_budgets','user_settings','user_transactions')
 order by 1, 2;

\echo '== foreign keys into auth.users (action: a=no action, c=cascade, n=set null)'
select conrelid::regclass as child, conname, confdeltype as on_delete, pg_get_constraintdef(oid) as def
  from pg_constraint where contype = 'f' and confrelid = 'auth.users'::regclass
 order by 1, 2;

\echo '== PostgREST exposed schemas (authenticator role config)'
select rolname, rolconfig from pg_roles where rolname in ('authenticator','anon','authenticated','service_role');

\echo '== ordinary-writer gap reproduction: no pending predicate exists before the fence'
select not exists (select 1 from pg_namespace where nspname = 'account_fence') as fence_absent;

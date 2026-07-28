-- Wire the 30-day account-deletion purge worker (MALI-005).
--
-- Before this migration the purge worker existed but was never invoked, and
-- its ordering lost the retry handle: purge_user_data deleted the profiles row
-- (the "due" discovery marker) first, so a later Storage/auth failure left an
-- orphaned auth user + blob with nothing left to rediscover the account.
--
-- This migration makes deletion a durable, retryable saga:
--
--   1. account_purge_queue — a service-only bookkeeping table with NO foreign
--      key to auth.users, so it survives auth.admin.deleteUser (every other
--      user table cascades). Each step (storage / sql / auth) is timestamped;
--      the worker resumes exactly where it failed on the next run.
--   2. purge_user_data() — extended to cover every user-owned table added
--      after 0042: custom categories, import runs, cards, settings,
--      gamification, notification logs (their content includes merchant and
--      amount text, so erasure deletes them instead of the SET NULL unlink),
--      and capture rate-limit counters keyed by the user's device hashes.
--   3. run_purge_scheduled_deletions() — SECURITY DEFINER cron entry point
--      following the established vault + pg_net pattern (0033/0052/0057).
--      Execute is revoked from PUBLIC/anon/authenticated: only cron (as the
--      table owner role) may fire it.
--
-- Operational prerequisite (one-time, per environment):
--   supabase secrets set PURGE_WORKER_SECRET=...           (Edge function env)
--   vault: insert 'purge_worker_secret' with the same value (SQL side)
--   vault: 'project_url' already exists for 0057.

-- 1 ── Durable saga state ────────────────────────────────────────────────────

create table if not exists public.account_purge_queue (
  user_id            uuid primary key,          -- deliberately NOT a FK
  blob_path          text null,
  enqueued_at        timestamptz not null default now(),
  storage_deleted_at timestamptz null,
  sql_purged_at      timestamptz null,
  auth_deleted_at    timestamptz null,
  attempts           integer     not null default 0,
  last_stage         text        null,
  last_error         text        null
);

alter table public.account_purge_queue enable row level security;
-- No policies on purpose: only the service role (which bypasses RLS) touches
-- this table. Clients can neither see nor cancel a purge already in flight.

-- 2 ── Extend purge_user_data to the post-0042 schema ────────────────────────

create or replace function public.purge_user_data(p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  -- Children before parents (FK order), satellites before their anchors.

  -- Capture pipeline satellites that do NOT cascade from auth.users:
  -- rate-limit counters are keyed by install hash only, so resolve them
  -- through the user's registered devices before those rows are deleted.
  delete from public.capture_rate_limits
  where install_id_hash in (
    select install_id_hash from public.capture_devices
    where user_id = p_user_id
  );

  -- Notification logs carry merchant/amount text in their payloads. The
  -- schema default (ON DELETE SET NULL) merely unlinks them; account erasure
  -- must remove the content itself. notification_retry_queue rows cascade
  -- from notification_logs.
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
  delete from public.feature_flag_overrides    where user_id = p_user_id;
  delete from public.sender_bank_mappings      where user_id = p_user_id;
  delete from public.capture_devices           where user_id = p_user_id;
  delete from public.backups                   where user_id = p_user_id;
  delete from public.profiles                  where id      = p_user_id;
end;
$$;

-- CREATE OR REPLACE preserves ACLs, but restate them so a fresh install of
-- this file alone is correctly locked down.
revoke all on function public.purge_user_data(uuid) from public, anon, authenticated;
grant execute on function public.purge_user_data(uuid) to service_role;

-- 3 ── Cron entry point (vault + pg_net, same pattern as 0057) ───────────────

create extension if not exists pg_net;

create or replace function public.run_purge_scheduled_deletions()
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
    from vault.decrypted_secrets where name = 'purge_worker_secret' limit 1;

  if project_url is null or worker_secret is null then
    raise log 'purge_scheduled_deletions skipped: Vault secrets not configured';
    return;
  end if;

  perform net.http_post(
    url := project_url || '/functions/v1/purge-scheduled-deletions',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || worker_secret
    ),
    body := '{}'::jsonb
  );
end;
$$;

-- Unlike 0057's cron function (see MALI-004), lock this one down explicitly:
-- nothing callable by clients may trigger the purge sweep.
revoke all on function public.run_purge_scheduled_deletions() from public, anon, authenticated;
grant execute on function public.run_purge_scheduled_deletions() to service_role;

-- cron.schedule upserts by job name, so re-running this migration is safe.
select cron.schedule(
  'purge-scheduled-deletions-job',
  '30 3 * * *',
  $$select public.run_purge_scheduled_deletions()$$
);

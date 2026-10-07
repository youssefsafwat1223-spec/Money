-- 0112_capture_notifications_retention.sql — CAP-3 (manifest §4.8, §7 "0113 retention/
-- notifications" = actual 0112 per ledger D-1; R7 notifications).
--
--  1. Retention (Q8): unconsumed processed/retryable/rejected rows are content-nulled
--     and become `expired` after 7 days; `consumed` tombstones are deleted 30 days
--     after consume; `expired` / abandoned rows are deleted 30 days after creation.
--     notification_logs are pruned after 30 days (retry rows cascade).
--     the existing prune_ai_request_idempotency() (0071, never scheduled) is scheduled.
--  2. Retry queue: UNIQUE(notification_log_id) (duplicates removed first), so a retry
--     is enqueued at most once per notification.
--  3. No re-push after acceptance: processed_captures.push_attempted_at is set, in the
--     same transaction as the fenced hand-off, by capture_queue_push. A push is handed
--     off AT MOST ONCE per capture; a replay never re-offers it. Retries of a transient
--     APNs failure belong to the retry queue alone.
--  4. capture_retry_fence(): the retry worker's fence (revoked / cloud consent / owner
--     and consent snapshot / capture still pending / not already sent), under FOR SHARE
--     on the device row, returning the CURRENT owner's token.
--  5. notification_logs.install_id_hash (the raw install_id column stays: the client's
--     opened-sync still writes it).

-- ── 1. columns ───────────────────────────────────────────────────────────────
alter table public.processed_captures
  add column if not exists push_attempted_at timestamptz;

-- Rows that already went through a push hand-off must never be re-offered.
update public.processed_captures
   set push_attempted_at = coalesce(apns_push_sent_at, created_at)
 where push_attempted_at is null
   and (notification_log_id is not null or apns_push_sent_at is not null);

alter table public.notification_logs
  add column if not exists install_id_hash text;

-- Same derivation as _shared/capture_auth.installHash: first 32 hex of sha256.
update public.notification_logs
   set install_id_hash = left(encode(sha256(convert_to(install_id, 'utf8')), 'hex'), 32)
 where install_id_hash is null;

create index if not exists idx_notification_logs_created
  on public.notification_logs (created_at);

-- ── 2. retry queue: one retry row per notification ───────────────────────────
delete from public.notification_retry_queue q
 using (
   select id, row_number() over (
            partition by notification_log_id
            order by (resolved_at is null) desc, created_at desc, id) as rn
     from public.notification_retry_queue
 ) d
 where q.id = d.id and d.rn > 1;

alter table public.notification_retry_queue
  drop constraint if exists notification_retry_queue_notification_log_id_key,
  add constraint notification_retry_queue_notification_log_id_key unique (notification_log_id);

-- ── 3. fenced hand-off, at most once ─────────────────────────────────────────
-- Same body as 0111 plus: (a) refuses when a hand-off already happened, (b) marks
-- push_attempted_at in the same statement that reserves it, (c) install_id_hash.
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
begin
  select * into v_dev from public.capture_devices where install_id_hash = p_install_id_hash;
  if not found or v_dev.apns_token is null or v_dev.apns_environment is null
     or p_install_id is null or p_install_id = '' then
    return null;
  end if;
  select notification_log_id into v_log from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
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

-- Adds push_attempted_at (a timestamp, no content).
create or replace function public.capture_row_json(r public.processed_captures)
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'payload_id', r.payload_id,
    'status', r.status,
    'parsed', r.parsed,
    'notification', r.notification,
    'created_at', r.created_at,
    'apns_push_sent_at', r.apns_push_sent_at,
    'push_attempted_at', r.push_attempted_at,
    'notification_log_id', r.notification_log_id,
    'state', r.state,
    'attempts', r.attempts,
    'next_attempt_at', r.next_attempt_at,
    'failure_reason', r.failure_reason);
$$;

-- ── 4. retry fence ───────────────────────────────────────────────────────────
-- Re-runs the terminal fence (§4.1) for a queued retry. allowed=true carries the
-- device's CURRENT token and the notification type only (never content). Any other
-- result means: do not call APNs, resolve the retry row.
--   reason: gone | already_sent | not_pending | credential_revoked | consent_revoked
--           | owner_changed | no_token | no_content
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
begin
  select * into d from public.capture_devices
   where install_id_hash = p_install_id_hash for share;
  select * into r from public.processed_captures
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id for share;
  if d.install_id_hash is null or r.payload_id is null then
    return jsonb_build_object('allowed', false, 'reason', 'gone');
  end if;
  if r.apns_push_sent_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'already_sent');
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

-- ── 5. retention ─────────────────────────────────────────────────────────────
create or replace function public.run_prune_processed_captures()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_expired bigint;
  v_deleted bigint;
  v_fingerprints bigint;
  v_logs bigint;
begin
  -- 7 days unconsumed: content nulled, state expired (a device then falls back to
  -- its local parser, §4.8).
  update public.processed_captures
     set state = 'expired', parsed = '{}'::jsonb, notification = '{}'::jsonb,
         sanitized_text = null, lease_until = null, next_attempt_at = null
   where state in ('processed', 'retryable', 'rejected')
     and created_at < now() - interval '7 days';
  get diagnostics v_expired = row_count;

  -- Tombstones: 30 days after consume. Expired / abandoned rows: 30 days after creation.
  delete from public.processed_captures
   where (state = 'consumed' and coalesce(consumed_at, created_at) < now() - interval '30 days')
      or (state <> 'consumed' and created_at < now() - interval '30 days');
  get diagnostics v_deleted = row_count;

  delete from public.capture_fingerprints where seen_at < now() - interval '7 days';
  get diagnostics v_fingerprints = row_count;

  -- notification_retry_queue rows cascade from notification_logs.
  delete from public.notification_logs where created_at < now() - interval '30 days';
  get diagnostics v_logs = row_count;

  raise log 'prune_processed_captures: expired=% deleted=% fingerprints=% notification_logs=%',
    v_expired, v_deleted, v_fingerprints, v_logs;
end;
$$;

create or replace function public.prune_processed_captures()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.run_prune_processed_captures();
end;
$$;

-- Hourly so "unconsumed content is kept at most 7 days" holds to the hour.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'prune-processed-captures-daily') then
    perform cron.unschedule('prune-processed-captures-daily');
  end if;
end $$;
select cron.schedule('prune-processed-captures-hourly', '15 * * * *', $$select public.run_prune_processed_captures()$$);
select cron.schedule('prune-ai-request-idempotency-daily', '25 3 * * *', $$select public.prune_ai_request_idempotency()$$);

revoke all on function public.capture_queue_push(text, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.capture_row_json(public.processed_captures) from public, anon, authenticated;
revoke all on function public.capture_retry_fence(text, text) from public, anon, authenticated;
revoke all on function public.run_prune_processed_captures() from public, anon, authenticated;
revoke all on function public.prune_processed_captures() from public, anon, authenticated;
grant execute on function public.capture_retry_fence(text, text) to service_role;

-- 0112_capture_notifications_retention.sql — CAP-3 (manifest §4.8, §7 "0113 retention/
-- notifications" = actual 0112 per ledger D-1; R7 notifications).
--
--  1. Retention (Q8): unconsumed processed/retryable/rejected rows are content-nulled
--     and become `expired` after 7 days (physical GC, hourly, best effort; the exact 168 h guarantee
--     is the logical fence in item 6); `consumed` tombstones are deleted 30 days
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
--  6. Logical expiry fence (user decision 2026-10-07, F1; Astra required changes, contract C.6):
--     "Unconsumed sanitized capture content expires 168 hours after its immutable server
--     creation time." Content is LIVE iff clock_timestamp() < created_at + interval '168 hours'
--     (database clock only; NEVER now(), which is the transaction START and would let a lock
--     wait or a long transaction cross the boundary unnoticed). capture_content_live() is the
--     single predicate, VOLATILE, and every RPC evaluates it AT its authorisation
--     linearisation point, i.e. AFTER the device / row locks it needs are held. At exactly the
--     boundary and after it the content (parsed, notification, sanitized_text,
--     validator_result) is unavailable to every server path: no NEW content read, AI dispatch,
--     finalize, notification enqueue or sync-captures return. Every RPC that meets an expired
--     row nulls the content and moves it to `expired` (a consumed tombstone is never touched;
--     nothing revives an expired row). created_at is immutable (trigger below). Edge functions
--     never read the table directly: sync-captures reads through capture_sync_list().
--     IN-FLIGHT work authorised before expiry: the AI request may finish, but capture_finalize
--     and capture_queue_push re-check the fence with clock_timestamp() AFTER acquiring their
--     locks and refuse when expired: no result is stored and no push is handed off.
--
--     APPLICATION-ACCESS EXPIRY  = exactly 168 hours after created_at, enforced by the
--       predicate above on every server path, to the database clock. This is the guarantee.
--     PHYSICAL CLEANUP          = best effort: the hourly job (run_prune_processed_captures,
--       15 * * * *) nulls expired content and deletes old rows. It can be delayed by outages,
--       lock contention or a paused cron worker, and NO hard bound on the delay is claimed.
--       Unreachable-but-unerased bytes are possible between the boundary and the next run.
--     BACKUP / PITR RETENTION   = a separate retention domain (Supabase backups and
--       point-in-time recovery). Content written before the boundary may persist in backups
--       for the backup retention period; nothing here shortens or erases it.
--     No cryptographic erasure is performed or claimed. All retention VALUES are unchanged
--       (168 h unconsumed, 30 d tombstones, 30 d abandoned rows, 30 d notification logs).

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

-- ── 2b. logical expiry fence (F1) ────────────────────────────────────────────
-- THE predicate: content is live iff clock_timestamp() < created_at + 168 hours (the actual
-- database time at the call, not the transaction start). VOLATILE, so the planner can never
-- hoist or cache it; callers invoke it after taking their locks. NULL created_at fails closed.
create or replace function public.capture_content_live_at(p_created_at timestamptz, p_at timestamptz)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select p_created_at is not null and p_at is not null and p_at < p_created_at + interval '168 hours';
$$;

create or replace function public.capture_content_live(p_created_at timestamptz)
returns boolean
language sql
volatile
set search_path = public, pg_temp
as $$
  select public.capture_content_live_at(p_created_at, clock_timestamp());
$$;

-- created_at is the immutable server creation time the fence is measured from: any UPDATE that
-- changes it is rejected (a row is never "re-created" to extend its life).
create or replace function public.processed_captures_created_at_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'processed_captures.created_at is immutable' using errcode = '23514';
end;
$$;

drop trigger if exists trg_processed_captures_created_at_immutable on public.processed_captures;
create trigger trg_processed_captures_created_at_immutable
  before update on public.processed_captures
  for each row when (new.created_at is distinct from old.created_at)
  execute function public.processed_captures_created_at_guard();

-- Opportunistic expiry of ONE row that is past the fence: content nulled, state expired.
-- Only the four live-able states are touched, so a consumed tombstone (already nulled,
-- consumed_at intact) and an already-expired row are left exactly as they are.
create or replace function public.capture_expire_row(
  p_install_id_hash text,
  p_payload_id text
) returns void
language sql
volatile
set search_path = public, pg_temp
as $$
  update public.processed_captures
     set state = 'expired', parsed = '{}'::jsonb, notification = '{}'::jsonb,
         sanitized_text = null, validator_result = null, lease_until = null, next_attempt_at = null
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id
     and state in ('processing', 'processed', 'retryable', 'rejected')
     and not public.capture_content_live(created_at);
$$;

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
  v_created timestamptz;
begin
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

-- Adds push_attempted_at (a timestamp, no content). F1: past the expiry fence it emits
-- no content and reports state expired (a consumed tombstone stays consumed), whatever
-- the stored row still says; VOLATILE because the fence reads clock_timestamp().
create or replace function public.capture_row_json(r public.processed_captures)
returns jsonb
language sql
volatile
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'payload_id', r.payload_id,
    'status', r.status,
    'parsed', case when l.live then r.parsed else '{}'::jsonb end,
    'notification', case when l.live then r.notification else '{}'::jsonb end,
    'created_at', r.created_at,
    'apns_push_sent_at', r.apns_push_sent_at,
    'push_attempted_at', r.push_attempted_at,
    'notification_log_id', r.notification_log_id,
    'state', case when l.live or r.state = 'consumed' then r.state else 'expired' end,
    'attempts', r.attempts,
    'next_attempt_at', case when l.live then r.next_attempt_at end,
    'failure_reason', r.failure_reason)
  from (select public.capture_content_live(r.created_at) as live) l;
$$;

-- ── 4. retry fence ───────────────────────────────────────────────────────────
-- Re-runs the terminal fence (§4.1) for a queued retry. allowed=true carries the
-- device's CURRENT token and the notification type only (never content). Any other
-- result means: do not call APNs, resolve the retry row.
--   reason: gone | already_sent | not_pending | credential_revoked | consent_revoked
--           | owner_changed | no_token | no_content | expired
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

-- ── 6. logical expiry fence (F1) applied to the 0111 RPCs ─────────────────────
-- Same bodies as 0111 plus the capture_content_live() checks marked F1.
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

-- sync-captures read path. Replaces the edge function's direct table read so the fence
-- uses the DATABASE clock: due rows in the caller's scope are nulled and expired first,
-- then only live processed / rejected (/ retryable for v2) rows come back, in the shape
-- of the former select (no `state` key for the legacy contract).
create or replace function public.capture_sync_list(
  p_install_id_hash text,
  p_user_id uuid,
  p_include_state boolean
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  update public.processed_captures
     set state = 'expired', parsed = '{}'::jsonb, notification = '{}'::jsonb,
         sanitized_text = null, validator_result = null, lease_until = null, next_attempt_at = null
   where install_id_hash = p_install_id_hash
     and claimed_user_id is not distinct from p_user_id
     and state in ('processing', 'processed', 'retryable', 'rejected')
     and not public.capture_content_live(created_at);

  select coalesce(jsonb_agg(j order by created_at), '[]'::jsonb) into v_rows
    from (
      select created_at,
             jsonb_build_object(
               'payload_id', payload_id, 'status', status,
               'parsed', parsed, 'notification', notification,
               'sanitized_text', sanitized_text, 'failure_reason', failure_reason,
               'created_at', created_at)
             || case when p_include_state then jsonb_build_object('state', state) else '{}'::jsonb end as j
        from public.processed_captures
       where install_id_hash = p_install_id_hash
         and claimed_user_id is not distinct from p_user_id
         and (state in ('processed', 'rejected') or (p_include_state and state = 'retryable'))
         and public.capture_content_live(created_at)
       order by created_at
       limit 50
    ) t;
  return v_rows;
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

-- Hourly PHYSICAL cleanup (best effort, unchanged). The 168 h guarantee is the logical fence above.
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
revoke all on function public.capture_content_live(timestamptz) from public, anon, authenticated;
revoke all on function public.capture_content_live_at(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.capture_expire_row(text, text) from public, anon, authenticated;
revoke all on function public.capture_claim(text, text, text, text, uuid, integer, integer, bigint) from public, anon, authenticated;
revoke all on function public.capture_ai_dispatch(text, text, integer) from public, anon, authenticated;
revoke all on function public.capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb)
  from public, anon, authenticated;
revoke all on function public.capture_sync_list(text, uuid, boolean) from public, anon, authenticated;
grant execute on function public.capture_claim(text, text, text, text, uuid, integer, integer, bigint) to service_role;
grant execute on function public.capture_ai_dispatch(text, text, integer) to service_role;
grant execute on function public.capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb)
  to service_role;
grant execute on function public.capture_sync_list(text, uuid, boolean) to service_role;

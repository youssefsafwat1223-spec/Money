-- 0111_capture_state_machine.sql — CAP-1 (manifest §4.1, §4.6, §4.8, §7).
--
-- processed_captures becomes a leased state machine:
--   processing{lease_until, lease_token, attempts} -> processed | retryable | rejected
--   -> consumed (tombstone, content nulled) | expired (content nulled)
-- The legacy `status` column stays populated (processed|duplicate|rejected) so
-- build-50 responses are unchanged. In-flight / content-less rows carry the
-- neutral placeholder status 'rejected' and are never returned by the legacy
-- readers (they select state in ('processed','rejected') with content).
--
-- supabase-js cannot hold a multi-statement transaction, so the gates and fences
-- that must run under FOR SHARE on the capture_devices row are plpgsql RPCs
-- (service_role only), called by the process-ios-sms / sync-captures edge
-- functions:
--   capture_claim        §4.1 gate + §4.8 claim table, one snapshot; owner binding on ANY schema
--                        version when owner_uid is present, and the OWNERLESS (build-50) rule: an
--                        ownerless upload is refused (owner_conflict, no content, no AI) when its
--                        received_at is missing / unparseable, later than clock_timestamp() + 5
--                        minutes, or <= capture_devices.owner_changed_at (0110): it predates the
--                        current owner's link and cannot be attributed to that owner.
--                        RESIDUAL (build 50): received_at is client-supplied, so a build-50 client
--                        whose clock runs ahead (bounded by 5 min) or that forges it can still land
--                        a pre-relink capture under the new owner. Full closure needs
--                        min_client_build at P6 (NOT done now).
--   capture_ai_dispatch  §4.6 AI linearization point
--   capture_finalize     terminal fence + result + notification_logs row, one tx
--   capture_ack          tombstone, never from 'processing'
--
-- Reclassification of transient-AI rejected rows -> retryable is DELIBERATELY NOT
-- DONE: process-ios-sms has only ever stored failure_reason = 'not_parseable'
-- for every rejection (AI timeout/HTTP error, "not a transaction", validator
-- reject, ignored text, AI off), so transient and final rejections are
-- indistinguishable in stored data. See the P1 report (ESCALATION).

alter table public.processed_captures
  add column if not exists state text,
  add column if not exists lease_until timestamptz,
  add column if not exists lease_token integer not null default 0,
  add column if not exists attempts integer not null default 0,
  add column if not exists next_attempt_at timestamptz,
  add column if not exists owner_uid uuid,
  add column if not exists consent_owner_uid uuid,
  add column if not exists consent_version integer,
  add column if not exists ai_started_at timestamptz,
  add column if not exists ai_consent_version integer,
  add column if not exists ai_invoked boolean not null default false,
  add column if not exists validator_result jsonb,
  add column if not exists possible_duplicate boolean not null default false,
  add column if not exists consumed_at timestamptz,
  add column if not exists consumed_by_install_hash text,
  add column if not exists client_owner_generation bigint;

-- Legacy-status mapping for existing rows.
update public.processed_captures
   set state = case when status = 'rejected' then 'rejected' else 'processed' end,
       possible_duplicate = (status = 'duplicate')
 where state is null;

alter table public.processed_captures
  alter column state set not null,
  drop constraint if exists processed_captures_state_check,
  add constraint processed_captures_state_check check (
    state in ('processing', 'processed', 'retryable', 'rejected', 'consumed', 'expired')
  );

-- Old function versions (still deployed between migration and function deploy)
-- insert without `state`; derive it from the legacy status so they keep working.
create or replace function public.processed_captures_default_state()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.state is null then
    new.state := case when new.status = 'rejected' then 'rejected' else 'processed' end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_processed_captures_default_state on public.processed_captures;
create trigger trg_processed_captures_default_state
  before insert on public.processed_captures
  for each row execute function public.processed_captures_default_state();

-- state is NOT NULL but supplied by the trigger for legacy inserts.
create index if not exists idx_processed_captures_install_state_created
  on public.processed_captures (install_id_hash, state, created_at);

-- ── internal: queue the notification_logs row (caller holds the device lock) ─
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
  update public.processed_captures set notification_log_id = v_log
   where install_id_hash = p_install_id_hash and payload_id = p_payload_id;
  insert into public.notification_logs
    (id, user_id, install_id, notification_type, channel, status, queued_at,
     related_entity_type, related_entity_id, device_platform, apns_environment)
  values
    (v_log, p_user_id, p_install_id, p_notification_type, 'apns', 'queued', now(),
     'payload', p_payload_id, 'ios', v_dev.apns_environment)
  on conflict (id) do update
    set status = 'queued', queued_at = now(), user_id = excluded.user_id,
        apns_environment = excluded.apns_environment;
  return jsonb_build_object(
    'notification_log_id', v_log,
    'apns_token', v_dev.apns_token,
    'apns_environment', v_dev.apns_environment);
end;
$$;

revoke all on function public.capture_queue_push(text, text, text, uuid, text)
  from public, anon, authenticated;

-- ── internal: the legacy-shaped row ──────────────────────────────────────────
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
    'notification_log_id', r.notification_log_id,
    'state', r.state,
    'attempts', r.attempts,
    'next_attempt_at', r.next_attempt_at,
    'failure_reason', r.failure_reason);
$$;

revoke all on function public.capture_row_json(public.processed_captures)
  from public, anon, authenticated;

-- ── internal: strict ISO-8601 parse of a client-supplied received_at ──────────
-- NULL for missing, malformed, or timezone-less text (a local time is ambiguous), so the
-- ownerless rule in capture_claim treats all of those as "cannot be attributed".
create or replace function public.capture_parse_received_at(p_text text)
returns timestamptz
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
  if p_text is null
     or p_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}([.][0-9]{1,9})?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' then
    return null;
  end if;
  return p_text::timestamptz;
exception when others then
  return null;
end;
$$;

revoke all on function public.capture_parse_received_at(text) from public, anon, authenticated;

-- ── capture_claim ────────────────────────────────────────────────────────────
-- p_contract: 2 = v2, 1 = legacy. p_owner_uid is the stamped owner on ANY contract when
-- present (owner-bound); NULL = ownerless (build 50). p_received_at is the client's raw
-- received_at text (ownerless rule); p_owner_generation is stored for diagnostics only.
-- Returns {outcome: ...}:
--   denied{code}                    gate refused (credential_revoked | capture_owner_mismatch | consent_required)
--   claimed{lease_token,attempts,claimed_user_id,consent_owner_uid,consent_version,ai_allowed}
--   in_progress | owner_conflict{reason?} | id_conflict
--   replay{row, push?}              stored processed/rejected/retryable/consumed/expired
create or replace function public.capture_claim(
  p_install_id_hash text,
  p_install_id text,
  p_payload_id text,
  p_raw_fingerprint text,
  p_owner_uid uuid,
  p_contract integer,
  p_lease_seconds integer default 60,
  p_received_at text default null,
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
  v_recv timestamptz;
  v_reject text;
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
    -- OWNERLESS (true build 50): the only evidence is the client's received_at. It must
    -- parse, not lie in the future (5 min clock-skew bound) and be AFTER the current
    -- owner's link; otherwise the capture predates this owner and is never attributed to it.
    v_recv := public.capture_parse_received_at(p_received_at);
    if v_recv is null then
      v_reject := 'received_at_invalid';
    elsif v_recv > clock_timestamp() + interval '5 minutes' then
      v_reject := 'received_at_future';
    elsif d.owner_changed_at is not null and v_recv <= d.owner_changed_at then
      v_reject := 'received_before_owner_change';
    end if;
    if v_reject is not null then
      return jsonb_build_object('outcome', 'owner_conflict', 'reason', v_reject);
    end if;
  end if;
  if d.cloud_processing_enabled is not true then
    return jsonb_build_object('outcome', 'denied', 'code', 'consent_required');
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

-- ── capture_ai_dispatch ──────────────────────────────────────────────────────
-- THE linearization point of AI consent. Returns {allowed:true} or
-- {allowed:false, reason: consent_revoked | owner_changed | lease_lost}.
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

-- ── capture_finalize ─────────────────────────────────────────────────────────
-- Terminal transition under the full fence. p_state: processed | rejected |
-- retryable. A fenced-out worker writes NO content and gets push_allowed=false.
-- The notification_logs row is queued in the SAME transaction; APNs may be
-- called only after this returns push_allowed = true.
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

-- ── capture_ack ──────────────────────────────────────────────────────────────
-- Tombstone, scoped to the device's current user (NULL = guest). Never consumes
-- a row in 'processing'. Content is nulled in the same statement.
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

revoke all on function public.capture_claim(text, text, text, text, uuid, integer, integer, text, bigint)
  from public, anon, authenticated;
revoke all on function public.capture_ai_dispatch(text, text, integer) from public, anon, authenticated;
revoke all on function public.capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb)
  from public, anon, authenticated;
revoke all on function public.capture_ack(text, uuid, text[]) from public, anon, authenticated;
grant execute on function public.capture_claim(text, text, text, text, uuid, integer, integer, text, bigint) to service_role;
grant execute on function public.capture_ai_dispatch(text, text, integer) to service_role;
grant execute on function public.capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb)
  to service_role;
grant execute on function public.capture_ack(text, uuid, text[]) to service_role;

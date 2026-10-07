-- 0110_capture_consent_projection.sql — CAP-2 (manifest §4.1, §4.6, §7).
--
-- capture_devices becomes the per-install PROJECTION of one user's consent:
--   consent_owner_uid  whose consent the two flags currently express
--   consent_version    monotonic version of that consent (per owner)
-- The capture gate requires user_id == consent_owner_uid (see 0111), so a
-- device re-linked to another user can never be processed on the previous
-- user's consent.
--
-- RPCs (all SECURITY DEFINER, pinned search_path):
--   link_capture_device(...)            JWT   one UPDATE replaces the projection
--   set_capture_consent(...)            JWT   owner-scoped, version > stored
--   legacy_link_capture_device(...)     service  build-50 link: owner change resets consent
--   legacy_set_device_consent(...)      service  build-50 consent write (owner-scoped)
--   capture_revoke_fanout(...)          internal one tx: row lock + user_settings + content nulling
--
-- Depends (by name only, resolved at call time) on 0109 user_settings
-- (consent_version, consent_granted_at). Additive; rollback drops it all.

alter table public.capture_devices
  add column if not exists consent_owner_uid uuid null,
  add column if not exists consent_version integer not null default 0;

-- Linked rows: their flags were set by (and for) the linked user.
update public.capture_devices
   set consent_owner_uid = user_id
 where user_id is not null and consent_owner_uid is null;

-- ── Revoke fan-out (internal) ────────────────────────────────────────────────
-- Caller MUST already hold the capture_devices row lock for p_install_id_hash,
-- so this runs in the same transaction as the projection update:
--   1. user_settings consent mirror, monotonic version;
--   2. unconsumed results for (install, user) lose their content. Rows still in
--      'processing' are untouched: the terminal fence (0111) rejects their write.
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
  if p_user_id is not null then
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

revoke all on function public.capture_revoke_fanout(text, uuid, boolean, boolean, integer)
  from public, anon, authenticated;

-- ── JWT: link_capture_device(consent) ────────────────────────────────────────
-- Called with the user's JWT after the replica is admitted. The device secret
-- (hash computed by the edge function) proves the caller holds the install.
-- One UPDATE sets user_id, consent_owner_uid, both flags and consent_version.
-- Owner change replaces the whole projection; the same owner only ever moves
-- consent forward (version > stored).
create or replace function public.link_capture_device(
  p_install_id_hash text,
  p_device_secret_hash text,
  p_cloud boolean,
  p_ai boolean,
  p_version integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.capture_devices%rowtype;
  v_changed boolean;
begin
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

  -- The link is the authoritative projection of the replica's consent (§4.6):
  -- flags and version are replaced as sent, so a fresh replica (lower version)
  -- can never leave a stale server TRUE behind.
  update public.capture_devices
     set user_id = v_uid,
         consent_owner_uid = v_uid,
         cloud_processing_enabled = coalesce(p_cloud, false),
         ai_consent_granted = coalesce(p_ai, false),
         consent_version = greatest(coalesce(p_version, 0), 0),
         last_seen_at = now()
   where install_id_hash = p_install_id_hash;

  if not v_changed
     and ((v_row.cloud_processing_enabled and not coalesce(p_cloud, false))
       or (v_row.ai_consent_granted and not coalesce(p_ai, false))) then
    perform public.capture_revoke_fanout(p_install_id_hash, v_uid, coalesce(p_cloud, false),
      coalesce(p_ai, false), greatest(coalesce(p_version, 0), 0));
  end if;

  return jsonb_build_object('ok', true, 'owner_changed', v_changed);
end;
$$;

revoke all on function public.link_capture_device(text, text, boolean, boolean, integer)
  from public, anon, authenticated;
grant execute on function public.link_capture_device(text, text, boolean, boolean, integer)
  to authenticated;

-- ── JWT: set_capture_consent ─────────────────────────────────────────────────
-- Writes only WHERE user_id = jwt.uid AND consent_owner_uid = jwt.uid, and only
-- when the version moves forward. A revocation (cloud or AI true -> false) runs
-- the fan-out in the SAME transaction, under the row lock taken here.
create or replace function public.set_capture_consent(
  p_install_id_hash text,
  p_device_secret_hash text,
  p_cloud boolean,
  p_ai boolean,
  p_version integer
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
begin
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
  if p_version is null or p_version <= v_row.consent_version then
    -- A stale version may still narrow consent, never widen it.
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
    return jsonb_build_object('ok', true, 'applied', false, 'reason', 'stale_version',
      'consent_version', v_row.consent_version);
  end if;

  update public.capture_devices
     set cloud_processing_enabled = v_cloud,
         ai_consent_granted = v_ai,
         consent_version = p_version
   where install_id_hash = p_install_id_hash;

  if (v_row.cloud_processing_enabled and not v_cloud) or (v_row.ai_consent_granted and not v_ai) then
    perform public.capture_revoke_fanout(p_install_id_hash, v_uid, v_cloud, v_ai, p_version);
  end if;
  return jsonb_build_object('ok', true, 'applied', true);
end;
$$;

revoke all on function public.set_capture_consent(text, text, boolean, boolean, integer)
  from public, anon, authenticated;
grant execute on function public.set_capture_consent(text, text, boolean, boolean, integer)
  to authenticated;

-- ── service: legacy (build-50) link ──────────────────────────────────────────
-- The edge function has verified the device secret and the user JWT. When the
-- owner changes, the consent projection is REPLACED atomically: consent_owner_uid
-- = new user, both flags false, version reset. Same owner: only last_seen_at.
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
         last_seen_at = now()
   where install_id_hash = p_install_id_hash;
  return true;
end;
$$;

revoke all on function public.legacy_link_capture_device(text, uuid) from public, anon, authenticated;
grant execute on function public.legacy_link_capture_device(text, uuid) to service_role;

-- ── service: legacy device-credential consent write ──────────────────────────
-- Writes only a row whose consent belongs to its linked user
-- (consent_owner_uid IS NOT DISTINCT FROM user_id; for a never-linked guest row
-- both are NULL, which keeps today's guest behaviour). Every change bumps the
-- version so in-flight workers fail the terminal fence. A revocation fans out.
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
  select * into v_row from public.capture_devices
   where install_id_hash = p_install_id_hash for update;
  if not found or v_row.revoked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'invalid_device_secret');
  end if;
  if v_row.consent_owner_uid is distinct from v_row.user_id then
    return jsonb_build_object('ok', false, 'error', 'capture_owner_mismatch');
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

revoke all on function public.legacy_set_device_consent(text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.legacy_set_device_consent(text, boolean, boolean) to service_role;

-- ── service: unlink (device-credential) ──────────────────────────────────────
-- Unlink nulls user_id, consent_owner_uid and both flags (manifest §4.6), in one
-- statement, so a later link can never inherit the previous owner's consent.
create or replace function public.unlink_capture_device(p_install_id_hash text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.capture_devices
     set user_id = null,
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

revoke all on function public.unlink_capture_device(text) from public, anon, authenticated;
grant execute on function public.unlink_capture_device(text) to service_role;

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
--   revoke_capture_consent(...)         JWT   one-shot narrow-only revoke (jwt = owner = projection owner)
--   legacy_link_capture_device(...)     service  build-50 link: owner change resets consent
--   legacy_set_device_consent(...)      service  build-50 consent write (owner-scoped)
--   capture_revoke_fanout(...)          internal one tx: row lock + user_settings + content nulling
--
-- Astra required changes (contract G, C.1/C.2/C.3):
--   owner_generation         the SERVER's own counter, +1 on every owner change (diagnostics + atomic reset).
--   consent_client_generation / last_revoke_generation
--                            the client's transition generation per owner. A link/set whose generation is
--                            older than the stored one, or <= a recorded revoke, can only NARROW (stored AND
--                            requested) or is a no-op; it can never widen. An owner change resets both
--                            atomically (the new owner starts fresh). p_client_generation defaults to 0 (old
--                            clients), and a generation-0 write can never widen past a recorded revoke.
--
-- Astra required changes (contract H, H1):
--   capture_install_owner_history  trusted per-install owner history that survives deletion of the
--                            capture_devices row, maintained by a trigger so every writer is covered;
--                            capture_claim (0111) admits an OWNERLESS (build-50) upload only for an
--                            install proven to have had exactly one owner who never changed. The G1 client-timestamp
--                            ownerless rule is gone (never deployed).
--
-- Depends (by name only, resolved at call time) on 0109 user_settings
-- (consent_version, consent_granted_at). Additive; rollback drops it all.

alter table public.capture_devices
  add column if not exists consent_owner_uid uuid null,
  add column if not exists consent_version integer not null default 0,
  add column if not exists owner_generation bigint not null default 0,
  add column if not exists consent_client_generation bigint not null default 0,
  add column if not exists last_revoke_generation bigint null;

-- Linked rows: their flags were set by (and for) the linked user.
update public.capture_devices
   set consent_owner_uid = user_id
 where user_id is not null and consent_owner_uid is null;

-- ── H1: trusted install owner history (build-50 ownerless uploads, option B) ──
-- A build-50 upload carries no owner_uid, so the server may attribute it to the current owner
-- ONLY if it can prove, from history the client cannot influence, that this install has had
-- exactly one owner and that the owner never changed (not A->B, not A->unlink->A, not A->B->A).
-- The history is keyed by install_id_hash and SURVIVES deletion of the capture_devices row, so a
-- delete + re-register can never restore eligibility.
--   trusted          true only for an install whose row was created AFTER this migration. Every
--                    install that already existed here is recorded untrusted (never eligible).
--   first_owner_uid  the first non-null owner, set once. Nulled (never reassigned) by account deletion.
--   transitioned     true forever once the owner changed away from a non-null value, a different
--                    owner appeared, the row was deleted, or the row was re-created over existing
--                    history. Monotonic: guarded by trg_capture_install_owner_history_guard.
-- Maintained by a trigger on capture_devices (INSERT / UPDATE OF install_id_hash, user_id,
-- consent_owner_uid / DELETE), so EVERY writer is covered: link, legacy link, unlink, register /
-- re-register (upsert), purge, and any future direct UPDATE. A missing history row is never eligible.
-- Eligible (checked in capture_claim, 0111) <=> trusted AND NOT transitioned AND
-- first_owner_uid = user_id = consent_owner_uid. RLS denies every client role.
create table if not exists public.capture_install_owner_history (
  install_id_hash text primary key,
  trusted boolean not null,
  first_owner_uid uuid null,
  transitioned boolean not null default false,
  transitioned_at timestamptz null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

alter table public.capture_install_owner_history enable row level security;
drop policy if exists capture_install_owner_history_no_direct_access on public.capture_install_owner_history;
create policy capture_install_owner_history_no_direct_access
  on public.capture_install_owner_history
  using (false)
  with check (false);
revoke all on table public.capture_install_owner_history from public, anon, authenticated;

-- Installs that exist at migration time have no trustworthy history: untrusted, never eligible.
insert into public.capture_install_owner_history
  (install_id_hash, trusted, first_owner_uid, transitioned, transitioned_at)
select install_id_hash, false, null, true, clock_timestamp()
  from public.capture_devices
on conflict (install_id_hash) do nothing;

-- Monotonic guard: no widening, ever, whoever writes.
create or replace function public.capture_install_owner_history_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'capture_install_owner_history rows are never deleted' using errcode = '42501';
  end if;
  if new.install_id_hash is distinct from old.install_id_hash then
    raise exception 'capture_install_owner_history.install_id_hash is immutable' using errcode = '42501';
  end if;
  if old.transitioned and not new.transitioned then
    raise exception 'capture_install_owner_history: transitioned never returns to false' using errcode = '42501';
  end if;
  if not old.trusted and new.trusted then
    raise exception 'capture_install_owner_history: an untrusted install never becomes trusted' using errcode = '42501';
  end if;
  if old.first_owner_uid is not null and new.first_owner_uid is distinct from old.first_owner_uid
     and not (new.first_owner_uid is null and new.transitioned) then
    raise exception 'capture_install_owner_history: first_owner_uid is never rewritten' using errcode = '42501';
  end if;
  if old.first_owner_uid is null and new.first_owner_uid is not null
     and (new.transitioned or not new.trusted) then
    raise exception 'capture_install_owner_history: no owner is assigned to a transitioned or untrusted install' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_capture_install_owner_history_guard on public.capture_install_owner_history;
create trigger trg_capture_install_owner_history_guard
  before update or delete on public.capture_install_owner_history
  for each row execute function public.capture_install_owner_history_guard();

-- Tracker on capture_devices. SECURITY DEFINER so the writer's role needs no access to the table.
create or replace function public.capture_device_history_track()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  h public.capture_install_owner_history%rowtype;
  v_new_clean boolean;
begin
  if tg_op = 'DELETE' then
    -- The row is gone; the install can never be proven single-owner again.
    insert into public.capture_install_owner_history
      (install_id_hash, trusted, first_owner_uid, transitioned, transitioned_at)
    values (old.install_id_hash, false, null, true, clock_timestamp())
    on conflict (install_id_hash) do update
      set transitioned = true,
          transitioned_at = coalesce(capture_install_owner_history.transitioned_at, clock_timestamp()),
          updated_at = clock_timestamp();
    return old;
  end if;

  if tg_op = 'INSERT' then
    -- A clean row is unowned (user_id and consent_owner_uid NULL) or owned (both the same uid).
    v_new_clean := (new.user_id is null and new.consent_owner_uid is null)
                or coalesce(new.user_id = new.consent_owner_uid, false);
    insert into public.capture_install_owner_history
      (install_id_hash, trusted, first_owner_uid, transitioned, transitioned_at)
    values (new.install_id_hash, true, case when v_new_clean then new.user_id end,
            not v_new_clean, case when not v_new_clean then clock_timestamp() end)
    on conflict (install_id_hash) do update
      -- history already existed: this row is a re-creation (or a pre-tracking install), never a first.
      set transitioned = true,
          transitioned_at = coalesce(capture_install_owner_history.transitioned_at, clock_timestamp()),
          updated_at = clock_timestamp();
    return new;
  end if;

  -- UPDATE OF install_id_hash, user_id, consent_owner_uid
  if new.install_id_hash is distinct from old.install_id_hash then
    raise exception 'capture_devices.install_id_hash is immutable' using errcode = '42501';
  end if;
  if new.user_id is not distinct from old.user_id
     and new.consent_owner_uid is not distinct from old.consent_owner_uid then
    return new;
  end if;
  select * into h from public.capture_install_owner_history
   where install_id_hash = new.install_id_hash for update;
  if not found then
    -- No history for an existing row: untrusted, and the change is recorded as a transition.
    insert into public.capture_install_owner_history
      (install_id_hash, trusted, first_owner_uid, transitioned, transitioned_at)
    values (new.install_id_hash, false, null, true, clock_timestamp());
    return new;
  end if;
  if h.transitioned then
    return new;
  end if;
  v_new_clean := coalesce(new.user_id = new.consent_owner_uid, false);
  if h.trusted and v_new_clean and h.first_owner_uid is null
     and old.user_id is null and old.consent_owner_uid is null then
    -- The first (and so far only) owner appears on a never-owned install.
    update public.capture_install_owner_history
       set first_owner_uid = new.user_id, updated_at = clock_timestamp()
     where install_id_hash = new.install_id_hash;
  else
    -- Owner left (to NULL), another owner appeared, or the row became inconsistent: forever.
    update public.capture_install_owner_history
       set transitioned = true, transitioned_at = clock_timestamp(), updated_at = clock_timestamp()
     where install_id_hash = new.install_id_hash;
  end if;
  return new;
end;
$$;

revoke all on function public.capture_device_history_track() from public, anon, authenticated;

drop trigger if exists trg_capture_devices_owner_history on public.capture_devices;
create trigger trg_capture_devices_owner_history
  after insert or delete or update of install_id_hash, user_id, consent_owner_uid
  on public.capture_devices
  for each row execute function public.capture_device_history_track();

-- Account deletion (GDPR): forget the uid but keep the install ineligible (fail closed).
-- Called by purge_user_data (0113). Also covers a history row whose device row is held by someone
-- else (or already gone), which deleting the user's own device rows cannot reach.
create or replace function public.capture_history_forget_owner(p_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  update public.capture_install_owner_history
     set first_owner_uid = null,
         transitioned = true,
         transitioned_at = coalesce(transitioned_at, clock_timestamp()),
         updated_at = clock_timestamp()
   where first_owner_uid = p_user_id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.capture_history_forget_owner(uuid) from public, anon, authenticated;
grant execute on function public.capture_history_forget_owner(uuid) to service_role;

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
-- Owner change replaces the whole projection AND resets the per-owner ordering
-- (owner_generation + 1, client generation = the sent one, no recorded revoke). For the same owner a link whose client generation is
-- older than the stored one, or <= a recorded revoke, can only narrow (stored AND
-- requested); otherwise the link is authoritative (flags and version as sent).
-- Works for iOS and Android rows alike: the row only needs a registered install and
-- its device secret.
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

revoke all on function public.link_capture_device(text, text, boolean, boolean, integer, bigint)
  from public, anon, authenticated;
grant execute on function public.link_capture_device(text, text, boolean, boolean, integer, bigint)
  to authenticated;

-- ── JWT: set_capture_consent ─────────────────────────────────────────────────
-- Writes only WHERE user_id = jwt.uid AND consent_owner_uid = jwt.uid, only when the
-- version moves forward AND the client generation is neither older than the stored one
-- nor <= a recorded revoke (C.2). Anything else may still narrow, never widen. A
-- revocation (cloud or AI true -> false) runs the fan-out in the SAME transaction, under
-- the row lock taken here.
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

revoke all on function public.set_capture_consent(text, text, boolean, boolean, integer, bigint)
  from public, anon, authenticated;
grant execute on function public.set_capture_consent(text, text, boolean, boolean, integer, bigint)
  to authenticated;

-- ── JWT: revoke_capture_consent (C.3) ────────────────────────────────────────
-- The one-shot revoke of the ON -> OFF transition, the same contract for iOS and Android:
--   jwt.uid = p_owner_uid = consent_owner_uid = user_id, device secret matches.
-- NARROWS ONLY: cloud = false, ai = false, then the fan-out nulls unconsumed content for
-- (install, owner). Records last_revoke_generation = p_transition_generation, so any
-- LATER-ARRIVING link/set with a generation <= it can no longer widen. Idempotent per
-- (install, owner, transition_generation): a repeat, or anything already covered by a
-- recorded revoke >= it, is a no-op. A revoke older than the consent generation the owner
-- has since re-enabled under is a no-op too. When the row's projection owner is not the
-- caller (e.g. an Android row that was never JWT-linked) the revoke is a server no-op.
-- Returns {ok, applied, reason}.
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

revoke all on function public.revoke_capture_consent(text, text, uuid, bigint, integer)
  from public, anon, authenticated;
grant execute on function public.revoke_capture_consent(text, text, uuid, bigint, integer)
  to authenticated;

-- ── service: legacy (build-50) link ──────────────────────────────────────────
-- The edge function has verified the device secret and the user JWT. When the
-- owner changes, the consent projection is REPLACED atomically: consent_owner_uid
-- = new user, both flags false, version reset, and the ordering restarts (owner_generation
-- + 1, client generation 0, no recorded revoke).
-- Same owner: only last_seen_at.
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
         owner_generation = case when v_changed then v_row.owner_generation + 1 else v_row.owner_generation end,
         consent_client_generation = case when v_changed then 0 else v_row.consent_client_generation end,
         last_revoke_generation = case when v_changed then null else v_row.last_revoke_generation end,
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
-- This writer carries no client generation (= 0), so once a revoke is recorded for the
-- row's owner it can only narrow (C.2: a generation-0 write never widens past a revoke).
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

revoke all on function public.legacy_set_device_consent(text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.legacy_set_device_consent(text, boolean, boolean) to service_role;

-- ── service: unlink (device-credential) ──────────────────────────────────────
-- Unlink nulls user_id, consent_owner_uid and both flags (manifest §4.6), in one
-- statement, so a later link can never inherit the previous owner's consent. Dropping an
-- owner is an owner change: owner_generation moves and the ordering resets (and the install's
-- ownerless-eligibility history records the transition, see capture_install_owner_history).
create or replace function public.unlink_capture_device(p_install_id_hash text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
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

revoke all on function public.unlink_capture_device(text) from public, anon, authenticated;
grant execute on function public.unlink_capture_device(text) to service_role;

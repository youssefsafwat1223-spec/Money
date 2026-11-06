-- Restore dispatch without resetting consumed attempt counters. The additive column is retained.
CREATE OR REPLACE FUNCTION public.capture_ai_dispatch(p_install_id_hash text, p_payload_id text, p_lease_token integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;

REVOKE ALL ON FUNCTION public.capture_ai_dispatch(text,text,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.capture_ai_dispatch(text,text,integer) TO service_role;

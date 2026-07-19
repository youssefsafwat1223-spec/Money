import {
  bumpCaptureEndpointRateLimit,
  corsHeaders,
  json,
  readString,
  serviceClient,
  verifyDevice,
} from '../_shared/capture_auth.ts';

const SYNC_CAPTURES_LIMIT_PER_DAY = 240;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const supabase = serviceClient();
  const auth = await verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (await bumpCaptureEndpointRateLimit(supabase, auth.installIdHash, 'sync-captures', SYNC_CAPTURES_LIMIT_PER_DAY)) {
    return json({ error: 'rate_limit_exceeded' }, 429);
  }

  const ackIds = Array.isArray(body.ackPayloadIds)
    ? body.ackPayloadIds.filter((value): value is string => typeof value === 'string' && value.trim().length > 0)
    : [];
  if (ackIds.length > 0) {
    let ackQuery = supabase
      .from('processed_captures')
      .delete()
      .eq('install_id_hash', auth.installIdHash)
      .in('payload_id', ackIds);
    ackQuery = auth.userId == null ? ackQuery.is('claimed_user_id', null) : ackQuery.eq('claimed_user_id', auth.userId);
    const { error } = await ackQuery;
    if (error) return json({ error: 'ack_failed' }, 500);
  }

  // Claim legacy/unowned rows for the currently linked user before returning
  // them. Rows already stamped for another user are never changed or exposed.
  if (auth.userId != null) {
    const { error: claimError } = await supabase
      .from('processed_captures')
      .update({ claimed_user_id: auth.userId })
      .eq('install_id_hash', auth.installIdHash)
      .is('claimed_user_id', null);
    if (claimError) return json({ error: 'claim_failed' }, 500);
  }

  let captureQuery = supabase
    .from('processed_captures')
    .select('payload_id,status,parsed,notification,sanitized_text,failure_reason,created_at')
    .eq('install_id_hash', auth.installIdHash)
    .order('created_at', { ascending: true })
    .limit(50);
  captureQuery = auth.userId == null
    ? captureQuery.is('claimed_user_id', null)
    : captureQuery.eq('claimed_user_id', auth.userId);
  const { data, error } = await captureQuery;
  if (error) return json({ error: 'sync_failed' }, 500);

  return json({ captures: data ?? [] });
});

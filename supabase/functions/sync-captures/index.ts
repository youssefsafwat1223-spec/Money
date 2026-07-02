import { corsHeaders, json, readString, serviceClient, verifyDevice } from '../_shared/capture_auth.ts';

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

  const ackIds = Array.isArray(body.ackPayloadIds)
    ? body.ackPayloadIds.filter((value): value is string => typeof value === 'string' && value.trim().length > 0)
    : [];
  if (ackIds.length > 0) {
    const { error } = await supabase
      .from('processed_captures')
      .delete()
      .eq('install_id_hash', auth.installIdHash)
      .in('payload_id', ackIds);
    if (error) return json({ error: 'ack_failed' }, 500);
  }

  const { data, error } = await supabase
    .from('processed_captures')
    .select('payload_id,status,parsed,notification,sanitized_text,failure_reason,created_at')
    .eq('install_id_hash', auth.installIdHash)
    .order('created_at', { ascending: true })
    .limit(50);
  if (error) return json({ error: 'sync_failed' }, 500);

  return json({ captures: data ?? [] });
});

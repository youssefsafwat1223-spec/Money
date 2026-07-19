import {
  bumpCaptureEndpointRateLimit,
  corsHeaders,
  json,
  readString,
  serviceClient,
  verifyDevice,
} from '../_shared/capture_auth.ts';

const REGISTER_PUSH_TOKEN_LIMIT_PER_DAY = 60;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const apnsToken = readString(body, 'apnsToken', 'apns_token');
  const environment = readString(body, 'apnsEnvironment', 'apns_environment');
  if (!apnsToken || !['sandbox', 'production'].includes(environment)) {
    return json({ error: 'missing_push_token' }, 400);
  }

  const supabase = serviceClient();
  const auth = await verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  // iOS may deliver the same APNs token repeatedly on startup/resume. Treat
  // that as an idempotent success before consuming rate-limit budget; only
  // actual token/environment changes count toward the abuse limit.
  const current = await supabase
    .from('capture_devices')
    .select('apns_token,apns_environment')
    .eq('install_id_hash', auth.installIdHash)
    .maybeSingle();
  if (current.error) return json({ error: 'token_lookup_failed' }, 500);
  if (
    current.data?.apns_token === apnsToken &&
    current.data?.apns_environment === environment
  ) {
    return json({ ok: true, unchanged: true });
  }
  if (
    await bumpCaptureEndpointRateLimit(
      supabase,
      auth.installIdHash,
      'register-push-token',
      REGISTER_PUSH_TOKEN_LIMIT_PER_DAY,
    )
  ) {
    return json({ error: 'rate_limit_exceeded' }, 429);
  }

  const { error } = await supabase
    .from('capture_devices')
    .update({
      apns_token: apnsToken,
      apns_environment: environment,
      token_updated_at: new Date().toISOString(),
      last_seen_at: new Date().toISOString(),
    })
    .eq('install_id_hash', auth.installIdHash);
  if (error) return json({ error: 'token_update_failed' }, 500);

  return json({ ok: true });
});

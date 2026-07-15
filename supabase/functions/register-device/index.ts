import { bumpCaptureEndpointRateLimit, corsHeaders, installHash, json, readString, serviceClient, sha256Hex } from '../_shared/capture_auth.ts';

const REGISTER_DEVICE_LIMIT_PER_DAY = 20;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const platform = readString(body, 'platform') || 'ios';
  if (!installId) return json({ error: 'missing_install_id' }, 400);

  const supabase = serviceClient();
  const installIdHash = await installHash(installId);
  if (await bumpCaptureEndpointRateLimit(supabase, installIdHash, 'register-device', REGISTER_DEVICE_LIMIT_PER_DAY)) {
    return json({ error: 'rate_limit_exceeded' }, 429);
  }
  const existing = await supabase
    .from('capture_devices')
    .select('created_at')
    .eq('install_id_hash', installIdHash)
    .maybeSingle();

  // Rotate/reissue the relay secret on every explicit registration. This does
  // not expose ledger data; it only authorizes this install's relay rows.
  const secretBytes = crypto.getRandomValues(new Uint8Array(32));
  const deviceSecret = Array.from(secretBytes)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
  const now = new Date().toISOString();
  const { error } = await supabase.from('capture_devices').upsert({
    install_id_hash: installIdHash,
    device_secret_hash: await sha256Hex(deviceSecret),
    platform,
    created_at: existing.data?.created_at ?? now,
    last_seen_at: now,
  }, { onConflict: 'install_id_hash' });

  if (error) return json({ error: 'register_failed' }, 500);
  return json({ deviceSecret, installIdHash });
});

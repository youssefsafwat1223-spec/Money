import { corsHeaders, json, readString, serviceClient, verifyDevice } from '../_shared/capture_auth.ts';

// Device-authenticated unlink. The relay secret remains valid so the App
// Intent can capture while signed out; user ownership and APNs delivery are
// revoked immediately. Existing claimed captures remain owned by their user.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);
  const supabase = serviceClient();
  const auth = await verifyDevice(
    supabase,
    readString(body, 'installId', 'install_id'),
    readString(body, 'deviceSecret', 'device_secret'),
  );
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  const { error } = await supabase
    .from('capture_devices')
    .update({
      user_id: null,
      apns_token: null,
      token_updated_at: null,
      last_seen_at: new Date().toISOString(),
    })
    .eq('install_id_hash', auth.installIdHash);
  if (error) return json({ error: 'unlink_failed' }, 500);
  return json({ ok: true });
});

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  corsHeaders,
  bumpCaptureEndpointRateLimit,
  json,
  readString,
  serviceClient,
  verifyDevice,
} from '../_shared/capture_auth.ts';

const LINK_CAPTURE_DEVICE_LIMIT_PER_DAY = 30;

// Links an already-registered capture device to the authenticated Supabase user.
//
// Called by Flutter after sign-in (or session restore). Never called by the iOS
// App Intent — the extension must not carry a user JWT.
//
// Requires two independent credentials:
//   1. installId + deviceSecret  →  proves caller owns the device
//   2. Authorization: Bearer <jwt>  →  proves caller is the Supabase user
//
// Only updates user_id and last_seen_at. Does NOT rotate device_secret_hash,
// so the App Intent's stored secret remains valid.

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');

  // Step 1: verify device credentials.
  const supabase = serviceClient();
  const auth = await verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (await bumpCaptureEndpointRateLimit(supabase, auth.installIdHash, 'link-capture-device', LINK_CAPTURE_DEVICE_LIMIT_PER_DAY)) {
    return json({ error: 'rate_limit_exceeded' }, 429);
  }

  // Step 2: verify user JWT from Authorization header.
  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) {
    return json({ error: 'missing_jwt' }, 401);
  }
  const jwt = authHeader.slice(7);

  const userClient = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: `Bearer ${jwt}` } } },
  );
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) return json({ error: 'invalid_jwt' }, 401);

  // Step 3: link device to user. No secret rotation.
  const { error } = await supabase
    .from('capture_devices')
    .update({
      user_id: user.id,
      last_seen_at: new Date().toISOString(),
    })
    .eq('install_id_hash', auth.installIdHash);

  if (error) return json({ error: 'link_failed' }, 500);

  return json({ ok: true });
});

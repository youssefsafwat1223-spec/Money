import {
  bumpCaptureEndpointRateLimit,
  corsHeaders,
  installHash,
  json,
  readString,
  serviceClient,
  sha256Hex,
} from '../_shared/capture_auth.ts';

const REGISTER_DEVICE_LIMIT_PER_DAY = 20;

/// Mints (or rotates) this install's relay secret.
///
/// Exported so the authorization behaviour can be exercised BEHAVIOURALLY.
/// `Deno.serve` below is the only production entry point and simply calls it.
/// The Supabase client is injectable purely so tests can drive the rotation
/// path against a fake; the defect this function was fixed for is invisible to
/// any test that only reads source text.
///
/// AUTHORIZATION MODEL. This endpoint is reachable with the **public anon
/// key** — it must be, because the iOS App Intent has no user JWT and the
/// Flutter client calls it before sign-in. It therefore authenticates nothing:
/// whoever presents an `installId` gets a fresh secret for it.
///
/// That was survivable only if a rotated secret conveys no user's data. It did
/// not: the upsert previously omitted `user_id`, so `ON CONFLICT` left an
/// existing link intact, and `sync-captures` then served that user's capture
/// rows to the holder of the freshly minted secret. The raw `installId` lives
/// in plaintext App Group `UserDefaults` (AUTH-25), so this was reachable with
/// a value the device hands out rather than a secret.
///
/// The fix is to make rotation and linkage mutually exclusive: minting a new
/// secret CLEARS `user_id`. An attacker who rotates therefore holds a valid
/// secret for an **unlinked** device, and `sync-captures` returns only rows
/// whose `claimed_user_id IS NULL` — never the victim's. Re-linking requires
/// `link-capture-device`, which demands the device secret *and* a user JWT.
///
/// This is self-healing for the real device and not for an attacker: the app
/// calls `linkToCurrentUser()` on every cold start, and that path already
/// re-registers and re-links when its stored secret is rejected. An attacker's
/// rotation is overwritten by the victim's next rotation, and the attacker's
/// secret dies with it.
///
/// `revoked_at` is deliberately NOT cleared here. Rotation is a device-owner
/// action; revocation is an operator action, and it must survive.
export async function handleRegisterDevice(
  req: Request,
  makeClient: () => ReturnType<typeof serviceClient> = serviceClient,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const platform = readString(body, 'platform') || 'ios';
  if (!installId) return json({ error: 'missing_install_id' }, 400);

  const supabase = makeClient();
  const installIdHash = await installHash(installId);
  if (await bumpCaptureEndpointRateLimit(supabase, installIdHash, 'register-device', REGISTER_DEVICE_LIMIT_PER_DAY)) {
    return json({ error: 'rate_limit_exceeded' }, 429);
  }
  const existing = await supabase
    .from('capture_devices')
    .select('created_at')
    .eq('install_id_hash', installIdHash)
    .maybeSingle();

  // Rotate/reissue the relay secret on every explicit registration.
  const secretBytes = crypto.getRandomValues(new Uint8Array(32));
  const deviceSecret = Array.from(secretBytes)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
  const now = new Date().toISOString();
  const { error } = await supabase.from('capture_devices').upsert({
    install_id_hash: installIdHash,
    device_secret_hash: await sha256Hex(deviceSecret),
    platform,
    // Explicitly null, and load-bearing: omitting it is what let a rotated
    // secret inherit someone else's account. See the note above.
    user_id: null,
    created_at: existing.data?.created_at ?? now,
    last_seen_at: now,
  }, { onConflict: 'install_id_hash' });

  if (error) return json({ error: 'register_failed' }, 500);
  return json({ deviceSecret, installIdHash });
}

Deno.serve((req) => handleRegisterDevice(req));

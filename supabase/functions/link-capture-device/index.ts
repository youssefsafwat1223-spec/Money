import {
  bumpCaptureEndpointRateLimit,
  corsHeaders,
  json,
  readString,
  serviceClient,
  sha256Hex,
  verifyDevice,
  verifyUserJwt,
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
// Does NOT rotate device_secret_hash, so the App Intent's stored secret stays valid.
//
// Legacy (build-50) contract: sets user_id; when the owner changes the consent
// projection is REPLACED (consent_owner_uid = new user, both flags false, version
// reset) in one statement (legacy_link_capture_device).
// v2 (schema_version 2 + consent {cloud_processing_enabled, ai_consent_granted,
// version}): link_capture_device RPC called AS THE USER — one UPDATE sets user_id,
// consent_owner_uid, both flags and consent_version.

type LinkCaptureDeviceDependencies = {
  createServiceClient: typeof serviceClient;
  verifyDevice: typeof verifyDevice;
  verifyUserJwt: typeof verifyUserJwt;
};

const defaultDependencies: LinkCaptureDeviceDependencies = {
  createServiceClient: serviceClient,
  verifyDevice,
  verifyUserJwt,
};

export async function handleLinkCaptureDevice(
  req: Request,
  dependencies: LinkCaptureDeviceDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const v2 = body.schema_version === 2 || body.schemaVersion === 2;

  // Step 1: verify device credentials (a revoked device is refused).
  const supabase = dependencies.createServiceClient();
  const auth = await dependencies.verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  if (
    await bumpCaptureEndpointRateLimit(
      supabase,
      auth.installIdHash,
      'link-capture-device',
      LINK_CAPTURE_DEVICE_LIMIT_PER_DAY,
    )
  ) {
    return json({ error: 'rate_limit_exceeded' }, 429);
  }

  // Step 2: verify user JWT from Authorization header.
  const jwt = await dependencies.verifyUserJwt(req);
  if (!jwt.ok) return json({ error: jwt.error }, jwt.status);

  // Step 3: link device to user. No secret rotation.
  if (!v2) {
    const { data, error } = await supabase.rpc('legacy_link_capture_device', {
      p_install_id_hash: auth.installIdHash,
      p_user_id: jwt.userId,
    });
    if (error) return json({ error: 'link_failed' }, 500);
    if (data !== true) return json({ error: 'credential_revoked' }, 401);
    return json({ ok: true });
  }

  const consent = (body.consent ?? {}) as Record<string, unknown>;
  const version = typeof consent.version === 'number' ? Math.trunc(consent.version) : NaN;
  if (!Number.isFinite(version) || version < 0) return json({ error: 'invalid_consent' }, 400);
  const { data, error } = await jwt.client.rpc('link_capture_device', {
    p_install_id_hash: auth.installIdHash,
    p_device_secret_hash: await sha256Hex(deviceSecret),
    p_cloud: consent.cloud_processing_enabled === true,
    p_ai: consent.ai_consent_granted === true,
    p_version: version,
  });
  if (error) return json({ error: 'link_failed' }, 500);
  const result = (data ?? {}) as Record<string, unknown>;
  if (result.ok !== true) return json({ error: result.error ?? 'link_failed' }, 401);
  return json({ ok: true, owner_changed: result.owner_changed === true });
}

if (import.meta.main) Deno.serve((req) => handleLinkCaptureDevice(req));

import { corsHeaders, json, readString, serviceClient, verifyDevice } from '../_shared/capture_auth.ts';

// Device-authenticated unlink. The relay secret remains valid so the App
// Intent can capture while signed out; user ownership, the consent projection
// (consent_owner_uid and both flags) and APNs delivery are revoked in one
// statement. Existing claimed captures remain owned by their user.
type UnlinkCaptureDeviceDependencies = {
  createServiceClient: typeof serviceClient;
  verifyDevice: typeof verifyDevice;
};

export async function handleUnlinkCaptureDevice(
  req: Request,
  dependencies: UnlinkCaptureDeviceDependencies = { createServiceClient: serviceClient, verifyDevice },
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);
  const supabase = dependencies.createServiceClient();
  const auth = await dependencies.verifyDevice(
    supabase,
    readString(body, 'installId', 'install_id'),
    readString(body, 'deviceSecret', 'device_secret'),
  );
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  const { error } = await supabase.rpc('unlink_capture_device', { p_install_id_hash: auth.installIdHash });
  if (error) return json({ error: 'unlink_failed' }, 500);
  return json({ ok: true });
}

if (import.meta.main) Deno.serve((req) => handleUnlinkCaptureDevice(req));

// MALI-060n — server-side consent write path for a verified capture device.
//
// Consent is authoritative on the server (capture_devices), never a per-request
// caller-supplied boolean. The client calls this after registration and on every
// consent change (grant OR revoke). Revoking here takes effect immediately: the
// next AI/cloud request from this device reads the updated row and is refused,
// and the revoke fan-out (same transaction) nulls unconsumed stored content.
//
// Legacy (build-50) contract: verified DEVICE secret only; writes only a row whose
// consent belongs to its linked user (consent_owner_uid = user_id; a never-linked
// guest row, NULL = NULL, keeps working).
// v2 (schema_version 2): requires the device secret AND the user JWT; the
// set_capture_consent RPC writes WHERE user_id = jwt.uid AND consent_owner_uid =
// jwt.uid AND version > stored.
import {
  bumpCaptureEndpointRateLimit,
  corsHeaders,
  readString,
  serviceClient,
  sha256Hex,
  verifyDevice,
  verifyUserJwt,
} from '../_shared/capture_auth.ts';
import { apiError, correlationId, readJsonBody, resolveVerifiedIdentity, schemaError } from '../_shared/ai_endpoint.ts';

const DAILY_LIMIT_PER_IDENTITY = 200;
const MAX_BODY_BYTES = 2048;

type SetDeviceConsentDependencies = {
  createServiceClient: typeof serviceClient;
  resolveVerifiedIdentity: typeof resolveVerifiedIdentity;
  verifyDevice: typeof verifyDevice;
  verifyUserJwt: typeof verifyUserJwt;
};

const defaultDependencies: SetDeviceConsentDependencies = {
  createServiceClient: serviceClient,
  resolveVerifiedIdentity,
  verifyDevice,
  verifyUserJwt,
};

const ok = (payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

export async function handleSetDeviceConsent(
  req: Request,
  dependencies: SetDeviceConsentDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  const cid = correlationId();
  if (req.method !== 'POST') return apiError('invalid_payload', { correlationId: cid });

  const supabase = dependencies.createServiceClient();

  const bodyRes = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyRes.ok) return apiError(bodyRes.code, { correlationId: cid });
  const body = bodyRes.body;

  const aiConsent = body.ai_consent_granted === true;
  const cloudConsent = body.cloud_processing_enabled === true;

  if ((body.schema_version ?? body.schemaVersion) === 2) {
    const installId = readString(body, 'installId', 'install_id');
    const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
    const auth = await dependencies.verifyDevice(supabase, installId, deviceSecret);
    if (!auth.ok) {
      return apiError(auth.error === 'credential_revoked' ? 'credential_revoked' : 'invalid_device_credential', {
        correlationId: cid,
      });
    }
    const jwt = await dependencies.verifyUserJwt(req);
    if (!jwt.ok) return apiError('authentication_required', { correlationId: cid });
    const version = typeof body.consent_version === 'number' ? Math.trunc(body.consent_version) : NaN;
    if (!Number.isFinite(version) || version < 0) return apiError('invalid_payload', { correlationId: cid });
    if (
      await bumpCaptureEndpointRateLimit(
        supabase,
        `d:${auth.installIdHash}`,
        'set-device-consent',
        DAILY_LIMIT_PER_IDENTITY,
      )
    ) {
      return apiError('rate_limited', { correlationId: cid, retryable: true });
    }
    const { data, error } = await jwt.client.rpc('set_capture_consent', {
      p_install_id_hash: auth.installIdHash,
      p_device_secret_hash: await sha256Hex(deviceSecret),
      p_cloud: cloudConsent,
      p_ai: aiConsent,
      p_version: version,
    });
    if (error) return apiError('internal_error', { correlationId: cid });
    const result = (data ?? {}) as Record<string, unknown>;
    if (result.error === 'capture_owner_mismatch') {
      return new Response(JSON.stringify({ error: 'capture_owner_mismatch', correlation_id: cid }), {
        status: 409,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    if (result.ok !== true) {
      return apiError(result.error === 'credential_revoked' ? 'credential_revoked' : 'invalid_device_credential', {
        correlationId: cid,
      });
    }
    return ok({
      ok: true,
      applied: result.applied === true,
      ai_consent_granted: aiConsent,
      cloud_processing_enabled: cloudConsent,
    });
  }

  const schemaBad = schemaError(body, cid);
  if (schemaBad) return schemaBad;

  const identity = await dependencies.resolveVerifiedIdentity(req, supabase, body, cid);
  if (!identity.ok) return identity.response;

  // Only a verified DEVICE can set its own consent row.
  if (identity.identity.kind !== 'device' || !identity.identity.installIdHash) {
    return apiError('invalid_device_credential', { correlationId: cid });
  }

  const limited = await bumpCaptureEndpointRateLimit(
    supabase,
    identity.identity.ownerKey,
    'set-device-consent',
    DAILY_LIMIT_PER_IDENTITY,
  );
  if (limited) return apiError('rate_limited', { correlationId: cid, retryable: true });

  const { data, error } = await supabase.rpc('legacy_set_device_consent', {
    p_install_id_hash: identity.identity.installIdHash,
    p_cloud: cloudConsent,
    p_ai: aiConsent,
  });
  if (error) return apiError('internal_error', { correlationId: cid });
  const result = (data ?? {}) as Record<string, unknown>;
  if (result.ok !== true) {
    // Consent that does not belong to the row's linked user is never overwritten.
    return new Response(JSON.stringify({ error: result.error ?? 'capture_owner_mismatch', correlation_id: cid }), {
      status: 409,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  return ok({ ok: true, ai_consent_granted: aiConsent, cloud_processing_enabled: cloudConsent });
}

if (import.meta.main) Deno.serve((req) => handleSetDeviceConsent(req));

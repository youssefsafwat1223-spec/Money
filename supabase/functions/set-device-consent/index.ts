// MALI-060n — server-side consent write path for a verified capture device.
//
// Consent is authoritative on the server (capture_devices), never a per-request
// caller-supplied boolean. The client calls this after registration and on every
// consent change (grant OR revoke). Revoking here takes effect immediately: the
// next AI/cloud request from this device reads the updated row and is refused.
// Requires a VERIFIED device secret; a user JWT alone cannot set device consent.
import { bumpCaptureEndpointRateLimit, corsHeaders, serviceClient } from '../_shared/capture_auth.ts';
import { apiError, correlationId, readJsonBody, resolveVerifiedIdentity, schemaError } from '../_shared/ai_endpoint.ts';

const DAILY_LIMIT_PER_IDENTITY = 200;
const MAX_BODY_BYTES = 2048;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  const cid = correlationId();
  if (req.method !== 'POST') return apiError('invalid_payload', { correlationId: cid });

  const supabase = serviceClient();

  const bodyRes = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyRes.ok) return apiError(bodyRes.code, { correlationId: cid });
  const body = bodyRes.body;

  const schemaBad = schemaError(body, cid);
  if (schemaBad) return schemaBad;

  const identity = await resolveVerifiedIdentity(req, supabase, body, cid);
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

  const aiConsent = body.ai_consent_granted === true;
  const cloudConsent = body.cloud_processing_enabled === true;

  const { error } = await supabase
    .from('capture_devices')
    .update({ ai_consent_granted: aiConsent, cloud_processing_enabled: cloudConsent })
    .eq('install_id_hash', identity.identity.installIdHash);
  if (error) return apiError('internal_error', { correlationId: cid });

  return new Response(
    JSON.stringify({ ok: true, ai_consent_granted: aiConsent, cloud_processing_enabled: cloudConsent }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
});

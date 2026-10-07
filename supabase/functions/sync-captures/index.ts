import {
  bumpCaptureEndpointRateLimit,
  corsHeaders,
  json,
  readString,
  serviceClient,
  verifyDevice,
  verifyUserJwt,
} from '../_shared/capture_auth.ts';
import { capturesForResponse } from './money.ts';

const SYNC_CAPTURES_LIMIT_PER_DAY = 240;

type SyncCapturesDependencies = {
  createServiceClient: typeof serviceClient;
  verifyDevice: typeof verifyDevice;
  verifyUserJwt: typeof verifyUserJwt;
};

const defaultDependencies: SyncCapturesDependencies = {
  createServiceClient: serviceClient,
  verifyDevice,
  verifyUserJwt,
};

// Legacy (build-50, device-credential) contract: unchanged request/response shape.
// v2 (schema_version 2): additionally requires the user JWT and scopes
//   jwt.uid == capture_devices.user_id == processed_captures.claimed_user_id,
// and returns `state` (processed | rejected | retryable) per capture.
// Neither contract ever claims ownerless rows: ownership is stamped at capture
// time by process-ios-sms and is never inferred from the device link.
export async function handleSyncCaptures(
  req: Request,
  dependencies: SyncCapturesDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const v2 = body.schema_version === 2 || body.schemaVersion === 2;
  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const supabase = dependencies.createServiceClient();
  const auth = await dependencies.verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  if (v2) {
    const jwt = await dependencies.verifyUserJwt(req);
    if (!jwt.ok) return json({ error: jwt.error }, jwt.status);
    if (auth.userId == null || jwt.userId !== auth.userId) {
      return json({ error: 'capture_owner_mismatch' }, 409);
    }
  }
  if (await bumpCaptureEndpointRateLimit(supabase, auth.installIdHash, 'sync-captures', SYNC_CAPTURES_LIMIT_PER_DAY)) {
    return json({ error: 'rate_limit_exceeded' }, 429);
  }

  const ackIds = Array.isArray(body.ackPayloadIds)
    ? body.ackPayloadIds.filter((value): value is string => typeof value === 'string' && value.trim().length > 0)
    : [];
  if (ackIds.length > 0) {
    // Tombstone (state -> consumed, content nulled), only for rows claimed by the
    // device's current user (NULL = the legacy guest scope) and never from 'processing'.
    const { error } = await supabase.rpc('capture_ack', {
      p_install_id_hash: auth.installIdHash,
      p_user_id: auth.userId,
      p_payload_ids: ackIds,
    });
    if (error) return json({ error: 'ack_failed' }, 500);
  }

  let captureQuery = supabase
    .from('processed_captures')
    .select(
      v2
        ? 'payload_id,status,state,parsed,notification,sanitized_text,failure_reason,created_at'
        : 'payload_id,status,parsed,notification,sanitized_text,failure_reason,created_at',
    )
    .eq('install_id_hash', auth.installIdHash)
    .in('state', v2 ? ['processed', 'rejected', 'retryable'] : ['processed', 'rejected'])
    .order('created_at', { ascending: true })
    .limit(50);
  captureQuery = auth.userId == null
    ? captureQuery.is('claimed_user_id', null)
    : captureQuery.eq('claimed_user_id', auth.userId);
  const { data, error } = await captureQuery;
  if (error) return json({ error: 'sync_failed' }, 500);

  return json({ captures: capturesForResponse(data ?? []) });
}

if (import.meta.main) Deno.serve((req) => handleSyncCaptures(req));

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
};

export function serviceClient() {
  return createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  );
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
    },
  });
}

export async function sha256Hex(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export async function installHash(installId: string): Promise<string> {
  return (await sha256Hex(installId)).slice(0, 32);
}

export function readString(data: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const value = data[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return '';
}

// Constant-time comparison for secret hashes — avoids leaking timing
// information via early-exit string equality (`!==`). Accepts `unknown` and
// never throws: a malformed value (wrong type, null, undefined) fails closed
// (returns false) rather than crashing the request. Both real callers always
// pass fixed-length (64-char) SHA-256 hex digests, so the length check below
// does not itself leak anything secret-dependent — length is not the secret.
export function timingSafeEqual(a: unknown, b: unknown): boolean {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export async function verifyDevice(
  supabase: ReturnType<typeof serviceClient>,
  installId: string,
  deviceSecret: string,
): Promise<
  | { ok: true; installIdHash: string; userId: string | null }
  | { ok: false; status: number; error: string }
> {
  if (!installId || !deviceSecret) {
    return { ok: false, status: 400, error: 'missing_device_credentials' };
  }
  const installIdHash = await installHash(installId);
  const deviceSecretHash = await sha256Hex(deviceSecret);
  const { data, error } = await supabase
    .from('capture_devices')
    .select('device_secret_hash, user_id')
    .eq('install_id_hash', installIdHash)
    .maybeSingle();
  if (error) return { ok: false, status: 500, error: 'device_lookup_failed' };
  if (!data || !timingSafeEqual(data.device_secret_hash, deviceSecretHash)) {
    return { ok: false, status: 401, error: 'invalid_device_secret' };
  }
  await supabase
    .from('capture_devices')
    .update({ last_seen_at: new Date().toISOString() })
    .eq('install_id_hash', installIdHash);
  return { ok: true, installIdHash, userId: (data.user_id as string | null) ?? null };
}

export async function bumpCaptureEndpointRateLimit(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  endpoint: string,
  limit: number,
): Promise<boolean> {
  const key = `${installIdHash}:${endpoint}`;
  const atomic = await supabase.rpc('bump_capture_rate_limit', {
    p_install_id_hash: key,
    p_limit: limit,
  });
  if (!atomic.error && typeof atomic.data === 'boolean') return atomic.data;

  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('capture_rate_limits')
    .select('call_count')
    .eq('install_id_hash', key)
    .eq('date', today)
    .maybeSingle();
  const current = (data?.call_count ?? 0) as number;
  if (current >= limit) return true;
  await supabase.from('capture_rate_limits').upsert({
    install_id_hash: key,
    date: today,
    call_count: current + 1,
  }, { onConflict: 'install_id_hash,date' });
  return false;
}

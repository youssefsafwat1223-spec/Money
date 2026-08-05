// MALI-060n / MALI-039 — behavioral privacy canaries for the AI-endpoint
// contract. Inject a canary for every sensitive class and assert it never
// appears in a typed error body, an idempotency hash, or a safeLog line.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { apiError, type ApiErrorCode, payloadHash, safeLog } from './ai_endpoint.ts';

const CANARIES: Record<string, string> = {
  sms: 'ACME purchase 512.34 SAR at STARBUCKS on card 4417883322110099',
  merchant: 'StarbucksRiyadhCanary',
  token: 'eyJhbGciOiJIUzI1NiJ9.canary.sig',
  deviceSecret: 'a1b2c3d4e5f6devicesecretcanary',
  url: 'https://img.logo.dev/starbucks.com?token=canary',
  prompt: 'You are a bank SMS parser. SMS: 512.34 STARBUCKS',
  upstreamError: 'places_403 quota exceeded for project canary',
};

const ALL_CODES: ApiErrorCode[] = [
  'authentication_required',
  'invalid_device_credential',
  'credential_revoked',
  'consent_required',
  'rate_limited',
  'payload_too_large',
  'invalid_payload',
  'unsupported_schema',
  'request_replay_mismatch',
  'upstream_timeout',
  'upstream_unavailable',
  'upstream_rejected',
  'internal_error',
];

Deno.test('no typed error body can carry a sensitive canary', async () => {
  for (const code of ALL_CODES) {
    const res = apiError(code, { correlationId: 'cid', retryAfterSeconds: 5 });
    const wire = await res.text();
    for (const canary of Object.values(CANARIES)) {
      assertEquals(wire.includes(canary), false, `${code} leaked ${canary}`);
    }
  }
});

Deno.test('payloadHash emits a hash, never the raw payload', async () => {
  const hash = await payloadHash(['owner', 'parse-sms', CANARIES.sms]);
  for (const canary of Object.values(CANARIES)) {
    assertEquals(hash.includes(canary), false);
  }
  // A 64-char lowercase hex sha256.
  assertEquals(/^[0-9a-f]{64}$/.test(hash), true);
});

Deno.test('safeLog only emits the fields the caller passed (no smuggled payload)', () => {
  const original = console.log;
  const lines: string[] = [];
  console.log = (line: string) => lines.push(line);
  try {
    safeLog({ event: 'parse_result', correlation_id: 'cid', result: 'ok', latency: 'lt_1s' });
  } finally {
    console.log = original;
  }
  assertEquals(lines.length, 1);
  for (const canary of Object.values(CANARIES)) {
    assertEquals(lines[0].includes(canary), false);
  }
  const parsed = JSON.parse(lines[0]);
  assertEquals(Object.keys(parsed).sort(), ['correlation_id', 'event', 'latency', 'result']);
});

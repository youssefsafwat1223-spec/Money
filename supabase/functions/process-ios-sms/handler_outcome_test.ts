import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';

// Handler-level pins for the binary capture outcome (WP4-Lite): status is only
// ever processed | rejected | duplicate for NEW captures, AI calls are counted
// through a stubbed fetch, and replay / response shape are unchanged.

type Row = Record<string, unknown>;

function fakeSupabase(opts: { aiConsent?: boolean; duplicateOf?: string } = {}) {
  const captures = new Map<string, Row>();
  const state = { inserts: 0 };
  const from = (table: string) => {
    const f: { op: string; row?: Row; eq: Record<string, unknown> } = { op: 'select', eq: {} };
    const result = (): { data: unknown; error: unknown } => {
      if (table === 'capture_devices') {
        return {
          data: {
            ai_consent_granted: opts.aiConsent ?? true,
            cloud_processing_enabled: true,
            revoked_at: null,
            apns_token: null,
          },
          error: null,
        };
      }
      if (table === 'processed_captures') {
        if (f.op === 'insert') {
          const row = {
            ...f.row!,
            created_at: '2026-09-07T19:30:00Z',
            apns_push_sent_at: null,
            notification_log_id: null,
          };
          captures.set(f.row!.payload_id as string, row);
          state.inserts++;
          return { data: row, error: null };
        }
        return { data: captures.get(f.eq.payload_id as string) ?? null, error: null };
      }
      if (table === 'capture_fingerprints') {
        if (f.op === 'insert') {
          return opts.duplicateOf
            ? { data: null, error: { code: '23505', message: 'dup' } }
            : { data: null, error: null };
        }
        return { data: opts.duplicateOf ? [{ payload_id: opts.duplicateOf, fingerprint: 'x' }] : [], error: null };
      }
      return { data: null, error: null };
    };
    const b: Record<string, unknown> = {
      select: () => b,
      insert: (row: Row) => {
        f.op = 'insert';
        f.row = row;
        return b;
      },
      update: () => {
        f.op = 'update';
        return b;
      },
      eq: (k: string, v: unknown) => {
        f.eq[k] = v;
        return b;
      },
      in: () => b,
      maybeSingle: () => Promise.resolve(result()),
      single: () => Promise.resolve(result()),
      then: (resolve: (v: unknown) => unknown) => Promise.resolve(result()).then(resolve),
    };
    return b;
  };
  return {
    state,
    captures,
    client: { from, rpc: () => Promise.resolve({ data: false, error: null }) },
  };
}

function stubGemini(candidate: Record<string, unknown> | null) {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const stub = {
    calls: 0,
    restore: () => {
      globalThis.fetch = original;
      if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
      else Deno.env.set('GEMINI_API_KEY', previousKey);
    },
  };
  globalThis.fetch = (() => {
    stub.calls++;
    const body = candidate == null
      ? {}
      : { candidates: [{ content: { parts: [{ text: JSON.stringify(candidate) }] } }] };
    return Promise.resolve(new Response(JSON.stringify(body)));
  }) as typeof fetch;
  return stub;
}

function request(body: Record<string, unknown>): Request {
  return new Request('https://example.test/process-ios-sms', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ schema_version: 1, installId: 'i', deviceSecret: 's', ...body }),
  });
}

const deps = (fake: ReturnType<typeof fakeSupabase>) => ({
  createServiceClient: (() => fake.client) as never,
  verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: null })) as never,
});

async function call(
  fake: ReturnType<typeof fakeSupabase>,
  body: Record<string, unknown>,
  candidate: Record<string, unknown> | null = null,
) {
  const stub = stubGemini(candidate);
  try {
    const res = await handleProcessIosSms(request(body), deps(fake));
    return { status: res.status, json: await res.json(), calls: stub.calls };
  } finally {
    stub.restore();
  }
}

const RESOLVED = 'Purchase of EGP 250.00 at CARREFOUR with card ending 1234 on 2026-09-07';
const UNRESOLVED = 'Purchase $20.00 at SHOP';
const GOOD_AI = {
  amount: 20,
  amount_text: '20.00',
  currency: 'USD',
  merchant: 'SHOP',
  type: 'payment',
  direction: 'debit',
};

Deno.test('resolved capture: processed, zero AI calls', async () => {
  const fake = fakeSupabase();
  const r = await call(fake, { payloadId: 'p1', sanitizedText: RESOLVED, allowAi: true }, GOOD_AI);
  assertEquals(r.calls, 0);
  assertEquals(r.json.capture.status, 'processed');
  assertEquals(r.json.capture.parsed.amount, 250);
});

Deno.test('clean card/ATM SMS without merchant: processed, zero AI calls, AI allowed or not', async () => {
  const texts = [
    'Debited SAR 50.00 from card ending 1234',
    'ATM withdrawal of SAR 500.00 card 1234',
    'تم خصم 50.00 ر.س من بطاقتك 1234',
  ];
  for (const [i, text] of texts.entries()) {
    for (const allowAi of [true, false]) {
      const r = await call(fakeSupabase(), { payloadId: `c${i}${allowAi}`, sanitizedText: text, allowAi }, GOOD_AI);
      assertEquals(r.calls, 0, text);
      assertEquals(r.json.capture.status, 'processed', text);
    }
  }
});

Deno.test('direction unknown: still goes to AI (one call) when allowed, rejected when not', async () => {
  const text = 'Your card 1234 was used for EGP 99.50';
  const ai = { amount: 99.5, amount_text: '99.50', currency: 'EGP', type: 'payment', direction: 'debit' };
  const a = await call(fakeSupabase(), { payloadId: 'u1', sanitizedText: text, allowAi: true }, ai);
  assertEquals(a.calls, 1);
  const b = await call(fakeSupabase(), { payloadId: 'u2', sanitizedText: text, allowAi: false }, ai);
  assertEquals([b.calls, b.json.capture.status], [0, 'rejected']);
});

Deno.test('unresolved + AI allowed + validator pass: processed after exactly one AI call', async () => {
  const fake = fakeSupabase();
  const r = await call(fake, { payloadId: 'p2', sanitizedText: UNRESOLVED, allowAi: true }, GOOD_AI);
  assertEquals(r.calls, 1);
  assertEquals(r.json.capture.status, 'processed');
  assertEquals(r.json.capture.parsed.currency, 'USD');
  assertEquals(r.json.capture.parsed.parserSource, 'ai_hybrid');
});

Deno.test('unresolved + AI candidate fails validation: rejected', async () => {
  const fake = fakeSupabase();
  const r = await call(fake, { payloadId: 'p3', sanitizedText: UNRESOLVED, allowAi: true }, {
    ...GOOD_AI,
    amount: 21,
    amount_text: '21.00',
  });
  assertEquals(r.calls, 1);
  assertEquals(r.json.capture.status, 'rejected');
  assertEquals(r.json.capture.sanitized_text, UNRESOLVED);
  assertEquals(r.json.capture.notification.type, 'received');
});

Deno.test('unresolved + AI not requested: zero AI calls, rejected', async () => {
  const r = await call(fakeSupabase(), { payloadId: 'p4', sanitizedText: UNRESOLVED }, GOOD_AI);
  assertEquals(r.calls, 0);
  assertEquals(r.json.capture.status, 'rejected');
});

Deno.test('unresolved + AI consent not granted server-side: zero AI calls, rejected', async () => {
  const r = await call(fakeSupabase({ aiConsent: false }), {
    payloadId: 'p5',
    sanitizedText: UNRESOLVED,
    allowAi: true,
  }, GOOD_AI);
  assertEquals(r.calls, 0);
  assertEquals(r.json.capture.status, 'rejected');
});

Deno.test('ignored message: zero AI calls, rejected (not_parseable)', async () => {
  const fake = fakeSupabase();
  const r = await call(fake, {
    payloadId: 'p6',
    sanitizedText: 'Your OTP is 123456 for EGP 10.00 purchase',
    allowAi: true,
  }, {
    amount: 10,
    amount_text: '10.00',
    currency: 'EGP',
    type: 'payment',
  });
  assertEquals(r.calls, 0);
  assertEquals(r.json.capture.status, 'rejected');
  assertEquals(fake.captures.get('p6')!.failure_reason, 'not_parseable');
});

Deno.test('no new capture is ever needs_review (regardless of AI confidence or missing category)', async () => {
  const cases: Array<[string, boolean, Record<string, unknown> | null]> = [
    [RESOLVED, true, null],
    ['EGP 99.50 spent', false, null], // amount+currency+direction, no merchant: RESOLVED
    ['EGP 99.50 ZARA online', true, {
      amount: 99.5,
      amount_text: '99.50',
      currency: 'EGP',
      merchant: 'ZARA',
      confidence: 0.01,
    }],
    ['EGP 99.50 ZARA online', true, {
      amount: 99.5,
      amount_text: '99.50',
      currency: 'EGP',
      merchant: 'ZARA',
      confidence: 0.99,
    }],
    [UNRESOLVED, true, { ...GOOD_AI, confidence: 0.01 }],
    [UNRESOLVED, true, { ...GOOD_AI, confidence: 0.99 }],
  ];
  const seen: string[] = [];
  for (const [i, [text, allowAi, cand]] of cases.entries()) {
    const r = await call(fakeSupabase(), { payloadId: `n${i}`, sanitizedText: text, allowAi }, cand);
    seen.push(r.json.capture.status);
    assert(
      ['processed', 'rejected', 'duplicate'].includes(r.json.capture.status),
      `${text} -> ${r.json.capture.status}`,
    );
  }
  // low vs high AI confidence produce identical statuses
  assertEquals(seen[2], seen[3]);
  assertEquals(seen[4], seen[5]);
});

Deno.test('fingerprint duplicate still yields duplicate', async () => {
  const r = await call(fakeSupabase({ duplicateOf: 'other' }), { payloadId: 'd1', sanitizedText: RESOLVED }, null);
  assertEquals(r.json.capture.status, 'duplicate');
  assertEquals(r.json.capture.parsed.possibleDuplicateOfPayloadId, 'other');
});

Deno.test('idempotent replay returns the stored row: no new insert, no AI call', async () => {
  const fake = fakeSupabase();
  const first = await call(fake, { payloadId: 'r1', sanitizedText: UNRESOLVED, allowAi: true }, GOOD_AI);
  assertEquals(first.calls, 1);
  assertEquals(fake.state.inserts, 1);
  const second = await call(fake, { payloadId: 'r1', sanitizedText: UNRESOLVED, allowAi: true }, GOOD_AI);
  assertEquals(second.calls, 0);
  assertEquals(fake.state.inserts, 1);
  assertEquals(second.json.idempotent, true);
  assertEquals(second.json.capture.status, first.json.capture.status);
  assertEquals(second.json.capture.parsed, first.json.capture.parsed);
});

Deno.test('old-client request (snake_case, no allowAi/tz/locale): response shape unchanged', async () => {
  const r = await call(
    fakeSupabase(),
    { payload_id: 'o1', sms_text: RESOLVED, sender: 'BANK' },
    null,
  );
  assertEquals(r.status, 200);
  assertEquals(Object.keys(r.json).sort(), ['capture', 'pushSent']);
  assertEquals(r.json.pushSent, false);
  const capture = r.json.capture as Record<string, unknown>;
  for (
    const key of [
      'payload_id',
      'status',
      'parsed',
      'notification',
      'created_at',
      'apns_push_sent_at',
      'notification_log_id',
    ]
  ) {
    assert(key in capture, key);
  }
  const known = new Set([
    'amount',
    'amount_text',
    'currency',
    'type',
    'merchant',
    'category',
    'confidence',
    'duplicateStatus',
    'possibleDuplicateOfPayloadId',
    'possibleDuplicateOfTransactionId',
    'occurredAt',
    'last4',
    'direction',
    'comparisonTimestamp',
    'comparisonTimestampSource',
    'rawMessage',
    'senderId',
    'parserSource',
    'serverTransactionId',
  ]);
  for (const key of Object.keys(capture.parsed as Record<string, unknown>)) {
    assert(known.has(key), `unexpected parsed key ${key}`);
  }
  assertEquals(r.json.capture.status, 'processed');
});

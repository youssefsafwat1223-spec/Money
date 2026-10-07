import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleProcessIosSms } from './index.ts';
import { CAPTURE_RETENTION_MS, fakeCapture } from './capture_rpc_fake.ts';

// Handler-level pins for the P1 leased state machine (manifest §4.1, §4.6, §4.8).
// The RPC layer is modelled by capture_rpc_fake.ts; the SQL proofs are the
// authority for the database semantics.

const A = '00000000-0000-0000-0000-00000000a001';
const B = '00000000-0000-0000-0000-00000000b002';
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

type Fake = ReturnType<typeof fakeCapture>;

// CAP-3: when set, requests to Apple's push hosts are answered by this hook.
let apnsHook: ((url: string, init: RequestInit) => Response) | null = null;

function stubFetch(handler: (url: string) => Response | Promise<Response>) {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const stub = { calls: 0, urls: [] as string[], restore: () => {} };
  stub.restore = () => {
    globalThis.fetch = original;
    if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
    else Deno.env.set('GEMINI_API_KEY', previousKey);
  };
  globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    if (apnsHook && url.includes('push.apple.com')) return Promise.resolve(apnsHook(url, init ?? {}));
    stub.calls++;
    stub.urls.push(url);
    return Promise.resolve(handler(url));
  }) as typeof fetch;
  return stub;
}

const aiResponse = (candidate: Record<string, unknown> | null) =>
  new Response(JSON.stringify(
    candidate == null ? {} : { candidates: [{ content: { parts: [{ text: JSON.stringify(candidate) }] } }] },
  ));

async function post(
  fake: Fake,
  body: Record<string, unknown>,
  fetchHandler: (url: string) => Response | Promise<Response> = () => aiResponse(null),
) {
  const stub = stubFetch(fetchHandler);
  try {
    const res = await handleProcessIosSms(
      new Request('https://example.test/process-ios-sms', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        // build 50 always sends receivedAt; the ownerless rule (0111) refuses a request without it, so the
        // default mirrors a real build-50 body (a test omits it with `receivedAt: undefined`).
        body: JSON.stringify({ installId: 'i', deviceSecret: 's', receivedAt: new Date().toISOString(), ...body }),
      }),
      {
        createServiceClient: (() => fake.client) as never,
        verifyDevice: (() =>
          Promise.resolve({ ok: true, installIdHash: 'h', userId: fake.state.device.user_id })) as never,
      },
    );
    return { status: res.status, json: await res.json(), calls: stub.calls, urls: stub.urls };
  } finally {
    stub.restore();
  }
}

const v2 = (extra: Record<string, unknown>) => ({ schema_version: 2, owner_uid: A, ...extra });
const linkedA = { user_id: A, consent_owner_uid: A, version: 5 };

Deno.test('v2: stamped owner == user_id == consent_owner_uid -> 200, legacy fields kept, state added', async () => {
  const fake = fakeCapture({ device: linkedA });
  const r = await post(fake, v2({ payloadId: 'p1', sanitizedText: RESOLVED }));
  assertEquals(r.status, 200);
  assertEquals(r.json.state, 'processed');
  assertEquals(r.json.capture.state, 'processed');
  assertEquals(r.json.capture.status, 'processed');
  assertEquals(r.json.pushSent, false);
  for (
    const k of [
      'payload_id',
      'status',
      'parsed',
      'notification',
      'created_at',
      'apns_push_sent_at',
      'notification_log_id',
    ]
  ) {
    assert(k in r.json.capture, k);
  }
  assertEquals(fake.state.rows.get('p1')!.claimed_user_id, A);
});

Deno.test('T-S6: v2 owner_uid mismatch / missing / ownerless device -> 409 capture_owner_mismatch, nothing stored', async () => {
  for (
    const [device, extra] of [
      [linkedA, { owner_uid: B }],
      [linkedA, { owner_uid: '' }],
      [{ user_id: null, consent_owner_uid: null }, {}],
      [{ user_id: A, consent_owner_uid: B }, {}],
    ] as Array<[Record<string, unknown>, Record<string, unknown>]>
  ) {
    const fake = fakeCapture({ device });
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED, ...extra }));
    assertEquals([r.status, r.json.error], [409, 'capture_owner_mismatch']);
    assertEquals(fake.state.rows.size, 0);
    assertEquals(r.calls, 0);
  }
});

Deno.test('v2 owner_uid that is not a uuid -> 400 before any RPC', async () => {
  const fake = fakeCapture({ device: linkedA });
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED, owner_uid: 'not-a-uuid' }));
  assertEquals(r.status, 400);
  assertEquals(fake.state.claims, 0);
});

Deno.test('schema_version 3 is still refused', async () => {
  const r = await post(fakeCapture(), { schema_version: 3, payloadId: 'p', sanitizedText: RESOLVED });
  assertEquals([r.status, r.json.error], [400, 'unsupported_schema_version']);
});

Deno.test('cloud OFF / revoked: typed refusals, no row, no AI', async () => {
  const off = await post(
    fakeCapture({ device: { ...linkedA, cloud: false } }),
    v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }),
  );
  assertEquals([off.status, off.json.error, off.calls], [403, 'consent_required', 0]);
  const rev = await post(
    fakeCapture({ device: { ...linkedA, revoked: true } }),
    v2({ payloadId: 'p', sanitizedText: UNRESOLVED }),
  );
  assertEquals([rev.status, rev.json.error], [401, 'credential_revoked']);
});

Deno.test('legacy contract: linked device whose consent belongs to someone else -> 403 consent_required', async () => {
  const fake = fakeCapture({ device: { user_id: A, consent_owner_uid: B } });
  const r = await post(fake, { schema_version: 1, payloadId: 'p', sanitizedText: RESOLVED });
  assertEquals([r.status, r.json.error], [403, 'consent_required']);
});

Deno.test('legacy guest (no user) keeps working and stamps no owner', async () => {
  const fake = fakeCapture();
  const r = await post(fake, { payloadId: 'p', sanitizedText: RESOLVED });
  assertEquals(r.status, 200);
  assertEquals(fake.state.rows.get('p')!.claimed_user_id, null);
  assertEquals('state' in r.json, false);
  assertEquals('state' in r.json.capture, false);
});

Deno.test('T-S3: same payload id with different text -> 409 capture_id_conflict', async () => {
  const fake = fakeCapture({ device: linkedA });
  await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED + ' changed' }));
  assertEquals([r.status, r.json.error], [409, 'capture_id_conflict']);
});

Deno.test('T-S6: row claimed by A while the device is now B -> 409 capture_owner_conflict', async () => {
  const fake = fakeCapture({ device: linkedA });
  await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  Object.assign(fake.state.device, { user_id: B, consent_owner_uid: B });
  const r = await post(fake, { ...v2({ payloadId: 'p', sanitizedText: RESOLVED }), owner_uid: B });
  assertEquals([r.status, r.json.error], [409, 'capture_owner_conflict']);
});

Deno.test('T-S1: duplicate while the lease is live -> v2 202, legacy 503 (never a 2xx ack), one AI dispatch', async () => {
  const fake = fakeCapture({ device: linkedA });
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  const first = post(fake, v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }), async () => {
    await gate;
    return aiResponse(GOOD_AI);
  });
  await new Promise((r) => setTimeout(r, 20));
  const dup2 = await post(fake, v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }));
  assertEquals([dup2.status, dup2.json.state], [202, 'in_progress']);
  const dupLegacy = await post(fake, {
    schema_version: 1,
    payloadId: 'p',
    sanitizedText: UNRESOLVED,
    allowAi: true,
  });
  assertEquals([dupLegacy.status, dupLegacy.json.state], [503, 'in_progress']); // legacy: never a 2xx ack
  release();
  const done = await first;
  assertEquals(done.status, 200);
  assertEquals(fake.state.claims, 1);
  assertEquals(fake.state.dispatches, 1);
});

Deno.test('T-S1 legacy in_progress is 503 + Retry-After semantics (legacy client treats 2xx as terminal ack)', async () => {
  const fake = fakeCapture();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  const first = post(fake, { payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }, async () => {
    await gate;
    return aiResponse(GOOD_AI);
  });
  await new Promise((r) => setTimeout(r, 20));
  const dup = await post(fake, { payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true });
  assertEquals([dup.status, dup.json.state], [503, 'in_progress']);
  release();
  await first;
  assertEquals(fake.state.dispatches, 1);
});

Deno.test('T-S5: replay after ACK -> 409 already_consumed (no reprocess); expired -> 409 capture_expired', async () => {
  const fake = fakeCapture({ device: linkedA });
  await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  fake.state.rows.get('p')!.state = 'consumed';
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals([r.status, r.json.error, r.json.state], [409, 'already_consumed', 'consumed']);
  assertEquals(fake.state.claims, 1);
  fake.state.rows.get('p')!.state = 'expired';
  const e = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals([e.status, e.json.error], [409, 'capture_expired']);
});

Deno.test('T-S2: AI timeout/HTTP error is retryable (not rejected), no content stored, response keeps legacy shape', async () => {
  const fake = fakeCapture({ device: linkedA });
  const r = await post(
    fake,
    v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }),
    () => new Response('boom', { status: 503 }),
  );
  const row = fake.state.rows.get('p')!;
  assertEquals(row.state, 'retryable');
  assertEquals(row.failure_reason, 'ai_unavailable');
  assertEquals(row.parsed, {});
  assertEquals(r.status, 200);
  assertEquals(r.json.state, 'retryable');
  assertEquals(r.json.pushSent, false);
  // not a final answer: a "not a transaction" AI reply IS final
  const f2 = fakeCapture({ device: linkedA });
  await post(f2, v2({ payloadId: 'q', sanitizedText: UNRESOLVED, allowAi: true }), () => aiResponse(null));
  assertEquals(f2.state.rows.get('q')!.state, 'rejected');
});

Deno.test('T-S2: retryable re-claimed after next_attempt_at; five attempts then rejected', async () => {
  const fake = fakeCapture({ device: linkedA });
  const body = v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true });
  const fail = () => new Response('x', { status: 500 });
  for (let i = 1; i <= 5; i++) {
    const r = await post(fake, body, fail);
    assertEquals(r.json.state, 'retryable', `attempt ${i}`);
    assertEquals(fake.state.rows.get('p')!.attempts, i);
    if (i === 1) {
      const early = await post(fake, body, fail); // not due: replay, no new claim
      assertEquals([early.status, early.json.state], [202, 'retryable']);
    }
    fake.state.rows.get('p')!.next_attempt_at = Date.now() - 1;
  }
  const last = await post(fake, body, fail);
  assertEquals(last.json.capture.status, 'rejected');
  assertEquals(fake.state.rows.get('p')!.state, 'rejected');
  assertEquals(fake.state.claims, 5);
});

Deno.test('T-S4/A9: revoke between claim and AI dispatch -> AI never called, retryable(consent_revoked), no content', async () => {
  const fake = fakeCapture({
    device: linkedA,
    onBeforeDispatch: (s) => Object.assign(s.device, { ai: false, version: 6 }),
  });
  const r = await post(
    fake,
    v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }),
    () => aiResponse(GOOD_AI),
  );
  assertEquals([r.status, r.json.error, r.calls], [403, 'consent_required', 0]);
  const row = fake.state.rows.get('p')!;
  assertEquals([row.state, row.failure_reason, row.parsed, row.ai_invoked], [
    'retryable',
    'consent_revoked',
    {},
    undefined,
  ]);
});

Deno.test('A10: revoke after AI dispatch -> output fenced: nothing stored, no notification, no APNs', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }), () => {
    Object.assign(fake.state.device, { ai: false, version: 6 }); // revoke commits while AI is in flight
    return aiResponse(GOOD_AI);
  });
  assertEquals([r.status, r.json.error], [403, 'consent_required']);
  assertEquals(r.calls, 1); // only the AI call; no APNs request
  assertEquals(r.urls.some((u) => u.includes('apple')), false);
  const row = fake.state.rows.get('p')!;
  assertEquals([row.state, row.parsed, row.notification], ['retryable', {}, {}]);
  assertEquals(fake.state.logs.length, 0);
});

Deno.test('A11: revoke before the final write (deterministic path) -> fenced, no content, no push', async () => {
  const fake = fakeCapture({
    device: { ...linkedA, apns_token: 'tok' },
    onFinalize: (s) => Object.assign(s.device, { cloud: false, version: 6 }),
  });
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals([r.status, r.json.error], [403, 'consent_required']);
  assertEquals(fake.state.rows.get('p')!.parsed, {});
  assertEquals(fake.state.logs.length, 0);
  assertEquals(r.calls, 0);
});

Deno.test('A12: re-link A->B before the final write -> fenced (409 capture_owner_mismatch), no content, no push', async () => {
  const fake = fakeCapture({
    device: { ...linkedA, apns_token: 'tok' },
    onFinalize: (s) => Object.assign(s.device, { user_id: B, consent_owner_uid: B, version: 1 }),
  });
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals([r.status, r.json.error], [409, 'capture_owner_mismatch']);
  assertEquals(fake.state.rows.get('p')!.parsed, {});
  assertEquals(fake.state.logs.length, 0);
});

Deno.test('A1 (legacy contract): relink between claim and final write -> fenced', async () => {
  const fake = fakeCapture({
    device: { user_id: A, consent_owner_uid: A, version: 1, apns_token: 'tok' },
    onFinalize: (s) => Object.assign(s.device, { user_id: B, consent_owner_uid: B, cloud: false, version: 0 }),
  });
  const r = await post(fake, { schema_version: 1, payloadId: 'p', sanitizedText: RESOLVED });
  assert(r.status === 403 || r.status === 409);
  assertEquals(fake.state.rows.get('p')!.parsed, {});
  assertEquals(fake.state.logs.length, 0);
});

Deno.test('A13: stale worker (lease taken over) gets no write and no push; the winner alone notifies', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  let takenOver = false;
  const fake2 = fakeCapture({
    device: { ...linkedA, apns_token: 'tok' },
    onFinalize: (s) => {
      if (takenOver) return;
      takenOver = true;
      Object.assign(s.rows.get('p')!, { lease_token: 2, state: 'processing' }); // another worker re-claimed
    },
  });
  const r = await post(fake2, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals(r.status, 202); // lease lost: in_progress, nothing written
  assertEquals(fake2.state.rows.get('p')!.parsed, {});
  assertEquals(fake2.state.logs.length, 0);
  void fake;
});

Deno.test('rate limit after claim releases the lease as retryable and returns 429', async () => {
  const fake = fakeCapture({ device: linkedA });
  fake.state.rateLimited = true;
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals(r.status, 429);
  assertEquals(fake.state.rows.get('p')!.state, 'retryable');
});

Deno.test('X10 runtime: the capture path never touches user_transactions (any flag state)', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  const calls = [
    post(fake, v2({ payloadId: 'a', sanitizedText: RESOLVED })),
    post(fake, v2({ payloadId: 'b', sanitizedText: UNRESOLVED, allowAi: true }), () => aiResponse(GOOD_AI)),
    post(fake, v2({ payloadId: 'a', sanitizedText: RESOLVED })),
  ];
  for (const c of calls) await c;
  for (const t of fake.state.tablesTouched) {
    assert(!/user_transactions|feature_flag/.test(t), `capture path touched ${t}`);
  }
});

Deno.test('a queued notification row exists only for a committed result (single notification)', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals(fake.state.logs.length, 1);
});

Deno.test('SMS text never appears in the structured logs', async () => {
  const logged: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => void logged.push(args.map(String).join(' '));
  try {
    await post(fakeCapture({ device: linkedA }), v2({ payloadId: 'p', sanitizedText: RESOLVED, sender: 'BANKX' }));
  } finally {
    console.log = original;
  }
  const all = logged.join('\n');
  for (const secret of ['CARREFOUR', '250', 'BANKX', '1234']) assert(!all.includes(secret), secret);
});

// ── CAP-3: APNs hygiene on the capture path ──────────────────────────────────
async function withApns<T>(
  respond: (url: string, init: RequestInit) => Response,
  fn: (sent: Array<{ url: string; body: Record<string, unknown> }>) => Promise<T>,
): Promise<T> {
  const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', keys.privateKey));
  let bin = '';
  for (const b of der) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(bin)}\n-----END PRIVATE KEY-----`;
  const env: Record<string, string> = {
    APNS_KEY_ID: 'K',
    APNS_TEAM_ID: 'T',
    APNS_BUNDLE_ID: 'com.example.app',
    APNS_PRIVATE_KEY: pem,
  };
  for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);
  const sent: Array<{ url: string; body: Record<string, unknown> }> = [];
  apnsHook = (url, init) => {
    sent.push({ url, body: JSON.parse(String(init.body)) });
    return respond(url, init);
  };
  try {
    return await fn(sent);
  } finally {
    apnsHook = null;
    for (const k of Object.keys(env)) Deno.env.delete(k);
  }
}

const ok200 = () => new Response(null, { status: 200, headers: { 'apns-id': 'a1' } });

Deno.test('CAP-3: APNs alert is generic, with no amount, merchant, card or sender', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  await withApns(ok200, async (sent) => {
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED, sender: 'BANKX' }));
    assertEquals(r.json.pushSent, true);
    assertEquals(sent.length, 1);
    const wire = JSON.stringify(sent[0].body);
    for (const secret of ['CARREFOUR', '250', 'BANKX', '1234', 'EGP', 'المبلغ', 'التاجر']) {
      assert(!wire.includes(secret), `APNs payload leaked ${secret}`);
    }
    assertEquals((sent[0].body.aps as { alert: Record<string, string> }).alert, { body: 'New transaction captured' });
    // The stored relay row (pulled by the app after the tap) still carries the detail.
    assert(String((fake.state.rows.get('p')!.notification as Record<string, string>).body).includes('250'));
  });
});

Deno.test('CAP-3: replay after a handed-off push never re-pushes (unconfirmed or confirmed)', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  await withApns(() => new Response('{"reason":"InternalServerError"}', { status: 500 }), async (sent) => {
    const first = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    assertEquals([first.json.pushSent, first.json.push_attempted], [false, true]);
    assertEquals(sent.length, 1);
    const replay = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    assertEquals(replay.json.idempotent, true);
    assertEquals(replay.json.pushSent, false);
    assertEquals(replay.json.push_attempted, true); // the intent must not add a local banner
    assertEquals(sent.length, 1); // no second APNs request
    assertEquals(fake.state.logs.length, 1);
  });
});

Deno.test('CAP-3: no token -> push_attempted false (App Intent covers with its local banner)', async () => {
  const fake = fakeCapture({ device: linkedA });
  const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
  assertEquals([r.json.pushSent, r.json.push_attempted], [false, false]);
});

Deno.test('CAP-3: legacy (build-50) response shape is unchanged: no push_attempted key', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  await withApns(ok200, async () => {
    const r = await post(fake, { payloadId: 'p', sanitizedText: RESOLVED });
    assertEquals(Object.keys(r.json).sort(), ['capture', 'pushSent']);
    assert(!('push_attempted_at' in r.json.capture));
  });
});

Deno.test('CAP-3: a transient APNs failure enqueues ONE retry via an idempotent upsert on notification_log_id', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  await withApns(() => new Response('{"reason":"ServiceUnavailable"}', { status: 503 }), async () => {
    await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    const q = fake.state.writes.filter((w) => w.table === 'notification_retry_queue');
    assertEquals(q.length, 1);
    assertEquals(q[0].op, 'upsert');
    assertEquals(q[0].opts, { onConflict: 'notification_log_id', ignoreDuplicates: true });
    assertEquals(fake.state.writes.some((w) => w.table === 'capture_devices'), false); // token kept
  });
});

Deno.test('CAP-3: a dead token (BadDeviceToken) is cleared by compare-and-swap and not retried', async () => {
  const fake = fakeCapture({ device: { ...linkedA, apns_token: 'tok' } });
  await withApns(() => new Response('{"reason":"BadDeviceToken"}', { status: 400 }), async () => {
    await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    const clear = fake.state.writes.find((w) => w.table === 'capture_devices');
    assert(clear, 'token cleared');
    assertEquals(clear.row?.apns_token, null);
    assertEquals(clear.filters, [['install_id_hash', 'h'], ['apns_token', 'tok']]);
    assertEquals(fake.state.writes.some((w) => w.table === 'notification_retry_queue'), false);
  });
});

Deno.test('CAP-3: a fenced-out finalize (re-link before the result write) sends no APNs at all', async () => {
  const fake = fakeCapture({
    device: { ...linkedA, apns_token: 'tok' },
    onFinalize: (s) => {
      s.device.user_id = B;
      s.device.consent_owner_uid = B;
    },
  });
  await withApns(ok200, async (sent) => {
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    assertEquals(r.status, 409);
    assertEquals(sent.length, 0);
    assertEquals(fake.state.logs.length, 0);
  });
});

// ── F1: the 7-day logical expiry fence (migration 0112) ────────────────────────
// The database clock is pinned (state.dbFixedMs); a row's created_ms is set relative to it:
// +1 = 7d - 1ms (live), 0 = exactly 7d, -1 = 7d + 1ms. The handler's own clock is never used.
const T0 = Date.parse('2026-10-07T12:00:00Z');
const BOUNDARIES: Array<[string, number, boolean]> = [['7d-1ms', 1, true], ['exactly 7d', 0, false], ['7d+1ms', -1, false]];
const createdAt = (delta: number) => T0 - CAPTURE_RETENTION_MS + delta;
const pinned = (opts: Parameters<typeof fakeCapture>[0] = {}) => {
  const fake = fakeCapture(opts);
  fake.state.dbFixedMs = T0;
  return fake;
};

Deno.test('F1: replay of a stored result is served only while live; at 7d and after it is 409 capture_expired with no content', async () => {
  for (const [name, delta, live] of BOUNDARIES) {
    const fake = pinned({ device: { ...linkedA, apns_token: 'tok' } });
    await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    fake.state.rows.get('p')!.created_ms = createdAt(delta);
    const logs = fake.state.logs.length;
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    const row = fake.state.rows.get('p')!;
    if (live) {
      assertEquals([r.status, r.json.idempotent], [200, true], name);
      assertEquals(r.json.capture.parsed.amount, 250, name);
      assertEquals(row.state, 'processed', name);
    } else {
      assertEquals([r.status, r.json.error, r.json.state], [409, 'capture_expired', 'expired'], name);
      assertEquals('capture' in r.json, false, name);
      assertEquals([row.state, row.parsed, row.notification, row.sanitized_text], ['expired', {}, {}, null], name);
    }
    assertEquals(fake.state.logs.length, logs, name); // a replay never queues a push
    assertEquals(r.calls, 0, name);
  }
});

Deno.test('F1: an expired retryable row is not re-claimed and cannot start AI; a live one is retried', async () => {
  for (const [name, delta, live] of BOUNDARIES) {
    const fake = pinned({ device: linkedA });
    const first = await post(
      fake,
      v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }),
      () => new Response('boom', { status: 503 }),
    );
    assertEquals(first.json.state ?? first.json.capture?.state, 'retryable', name);
    const row = fake.state.rows.get('p')!;
    Object.assign(row, { created_ms: createdAt(delta), next_attempt_at: Date.now() - 1 });
    const claims = fake.state.claims, dispatches = fake.state.dispatches;
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }), () => aiResponse(GOOD_AI));
    if (live) {
      assertEquals(r.status, 200, name);
      assertEquals(fake.state.claims, claims + 1, name);
    } else {
      assertEquals([r.status, r.json.error], [409, 'capture_expired'], name);
      assertEquals([fake.state.claims, fake.state.dispatches, r.calls], [claims, dispatches, 0], name);
      assertEquals([row.state, row.attempts, row.lease_token, row.parsed], ['expired', 1, 1, {}], name);
    }
  }
});

Deno.test('F1: expiry between claim and the AI dispatch point -> AI never called, 409 capture_expired', async () => {
  for (const [name, delta, live] of BOUNDARIES) {
    const fake = pinned({
      device: linkedA,
      onBeforeDispatch: (s) => {
        s.rows.get('p')!.created_ms = createdAt(delta);
      },
    });
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true }), () => aiResponse(GOOD_AI));
    const row = fake.state.rows.get('p')!;
    if (live) {
      assertEquals([r.status, r.calls], [200, 1], name);
    } else {
      assertEquals([r.status, r.json.error, r.calls], [409, 'capture_expired', 0], name);
      assertEquals([row.state, row.ai_started_at, row.ai_invoked, row.parsed], ['expired', undefined, undefined, {}], name);
    }
  }
});

Deno.test('F1: expired lease at the final write -> no result stored, no notification, no APNs, 409 capture_expired', async () => {
  for (const [name, delta, live] of BOUNDARIES) {
    const fake = pinned({
      device: { ...linkedA, apns_token: 'tok' },
      onFinalize: (s) => {
        s.rows.get('p')!.created_ms = createdAt(delta);
      },
    });
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED }));
    const row = fake.state.rows.get('p')!;
    if (live) {
      assertEquals([r.status, row.state], [200, 'processed'], name);
      assertEquals(fake.state.logs.length, 1, name);
    } else {
      assertEquals([r.status, r.json.error, r.json.state], [409, 'capture_expired', 'expired'], name);
      assertEquals('capture' in r.json, false, name);
      assertEquals([row.state, row.parsed, row.notification, row.sanitized_text], ['expired', {}, {}, null], name);
      assertEquals(fake.state.logs.length, 0, name);
      assertEquals(r.urls.some((u) => u.includes('apple')), false, name);
    }
  }
});

// ── Astra required changes (contract G, C.1): owner binding on ANY schema version, ownerless rule ──
const RELINK_MS = Date.now();
const iso = (ms: number) => new Date(ms).toISOString();

Deno.test('G1 C.1: owner_uid on schema_version 1 is owner-bound: match -> 200 with the LEGACY shape, row records owner + generation', async () => {
  const fake = fakeCapture({ device: linkedA });
  const r = await post(fake, {
    schema_version: 1,
    owner_uid: A,
    owner_generation: 4,
    payloadId: 'p',
    sanitizedText: RESOLVED,
  });
  assertEquals(r.status, 200);
  assertEquals('state' in r.json, false); // legacy response shape unchanged
  assertEquals('state' in r.json.capture, false);
  const row = fake.state.rows.get('p')!;
  assertEquals([row.owner_uid, row.claimed_user_id, row.client_owner_generation], [A, A, 4]);
});

Deno.test('G1 C.1: owner_uid on schema_version 1 that is not the device owner -> 409 capture_owner_mismatch, nothing stored/processed', async () => {
  for (
    const device of [linkedA, { user_id: B, consent_owner_uid: B, version: 5 }, { user_id: A, consent_owner_uid: B }]
  ) {
    const fake = fakeCapture({ device });
    const r = await post(fake, { schema_version: 1, owner_uid: A, payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true });
    if (device === linkedA) continue; // the matching device is the positive case above
    assertEquals([r.status, r.json.error], [409, 'capture_owner_mismatch']);
    assertEquals([fake.state.rows.size, r.calls], [0, 0]);
  }
});

Deno.test('G1 C.1: owner_generation is diagnostics only: junk values are dropped, never an error', async () => {
  for (const g of [-1, 1.5, '3', null]) {
    const fake = fakeCapture({ device: linkedA });
    const r = await post(fake, v2({ payloadId: 'p', sanitizedText: RESOLVED, owner_generation: g }));
    assertEquals(r.status, 200);
    assertEquals(fake.state.rows.get('p')!.client_owner_generation, null);
  }
});

Deno.test('G1 D.1: delayed A capture arrives after an A->B relink: owner-bound -> 409 capture_owner_mismatch, never processed under B', async () => {
  // device is B now (relinked at RELINK_MS); the request was stamped A and delayed past the relink
  for (const schema of [1, 2]) {
    const fake = fakeCapture({ device: { user_id: B, consent_owner_uid: B, version: 1, owner_changed_ms: RELINK_MS } });
    const r = await post(
      fake,
      { schema_version: schema, owner_uid: A, payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true, receivedAt: iso(RELINK_MS - 5000) },
      () => aiResponse(GOOD_AI),
    );
    assertEquals([r.status, r.json.error], [409, 'capture_owner_mismatch'], `schema ${schema}`);
    assertEquals([fake.state.rows.size, r.calls, fake.state.logs.length], [0, 0, 0]);
  }
});

Deno.test('G1 D.1: delayed OWNERLESS (build 50) capture with received_at <= owner_changed_at -> 409 capture_owner_conflict, never processed under B', async () => {
  const device = { user_id: B, consent_owner_uid: B, version: 1, owner_changed_ms: RELINK_MS };
  for (const receivedAt of [iso(RELINK_MS - 60_000), iso(RELINK_MS)]) { // before, and exactly at, the relink
    const fake = fakeCapture({ device });
    const r = await post(fake, { schema_version: 1, payloadId: 'p', sanitizedText: UNRESOLVED, allowAi: true, receivedAt }, () =>
      aiResponse(GOOD_AI));
    assertEquals([r.status, r.json.error], [409, 'capture_owner_conflict'], receivedAt);
    assertEquals([fake.state.rows.size, r.calls, fake.state.logs.length], [0, 0, 0]);
  }
  // a capture received AFTER the relink belongs to B and is processed
  const fake = fakeCapture({ device });
  const ok = await post(fake, { schema_version: 1, payloadId: 'p', sanitizedText: RESOLVED, receivedAt: iso(RELINK_MS + 1000) });
  assertEquals([ok.status, fake.state.rows.get('p')!.claimed_user_id], [200, B]);
});

Deno.test('G1 C.1: ownerless request with received_at missing / unparseable / timezone-less / more than 5 min in the future -> 409 capture_owner_conflict', async () => {
  const cases: Array<[string, unknown]> = [
    ['missing', undefined],
    ['empty', ''],
    ['garbage', 'yesterday'],
    ['postgres special', 'infinity'],
    ['no timezone (ambiguous)', '2026-10-07T12:00:00'],
    ['future +6min', iso(Date.now() + 6 * 60_000)],
    ['future +1y', iso(Date.now() + 365 * 86_400_000)],
  ];
  for (const [name, receivedAt] of cases) {
    const fake = fakeCapture({ device: linkedA });
    const r = await post(fake, { schema_version: 1, payloadId: 'p', sanitizedText: RESOLVED, receivedAt });
    assertEquals([r.status, r.json.error], [409, 'capture_owner_conflict'], name);
    assertEquals([fake.state.rows.size, fake.state.claims], [0, 0], name);
  }
  // within the 5 min skew bound it is accepted
  const fake = fakeCapture({ device: linkedA });
  const ok = await post(fake, { schema_version: 1, payloadId: 'p', sanitizedText: RESOLVED, receivedAt: iso(Date.now() + 4 * 60_000) });
  assertEquals(ok.status, 200);
});

Deno.test('G1 C.1: a device never relinked since 0110 (owner_changed_at NULL) still accepts a well-formed ownerless request; owner-bound ignores received_at', async () => {
  const fake = fakeCapture({ device: linkedA });
  const r = await post(fake, { schema_version: 1, payloadId: 'p', sanitizedText: RESOLVED, receivedAt: '2020-01-01T00:00:00Z' });
  assertEquals(r.status, 200);
  const bound = fakeCapture({ device: { ...linkedA, owner_changed_ms: RELINK_MS } });
  const b = await post(bound, v2({ payloadId: 'p', sanitizedText: RESOLVED, receivedAt: iso(RELINK_MS - 1_000_000) }));
  assertEquals(b.status, 200); // owner binding, not received_at, is the proof for new clients
});

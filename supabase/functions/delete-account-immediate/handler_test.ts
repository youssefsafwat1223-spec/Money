import { assert, assertEquals, assertFalse } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createDeleteAccountHandler, type DeletionCoordinatorLike } from './handler.ts';

const SECRET = 'A'.repeat(43);
const UID = '11111111-1111-4111-8111-111111111111';

function coordinator(over: Partial<DeletionCoordinatorLike> = {}): DeletionCoordinatorLike & { seen: unknown[] } {
  const seen: unknown[] = [];
  return {
    seen,
    requestDeletion: async (r) => {
      seen.push(r);
      return { status: 'accepted', duplicate: false, jobId: 'job-secret-id' };
    },
    processJob: async () => ({ outcome: 'completed' }),
    getStatus: async () => ({ status: 'completed', retainedUntilMs: 5 }),
    ...over,
  };
}

const post = (body: unknown, headers: Record<string, string> = { authorization: 'Bearer jwt-abc' }) =>
  new Request('https://x.test/delete-account-immediate', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

const valid = { challenge_id: 'challenge-0001', challenge_response: 'proof', receipt_secret: SECRET };

Deno.test('CORS preflight is answered without touching the coordinator', async () => {
  const c = coordinator();
  const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(
    new Request('https://x.test/', { method: 'OPTIONS' }),
  );
  assertEquals(res.status, 204);
  assertEquals(c.seen.length, 0);
});

Deno.test('only POST is accepted', async () => {
  const res = await createDeleteAccountHandler({ coordinator: coordinator(), workerId: 'w' })(
    new Request('https://x.test/', { method: 'GET' }),
  );
  assertEquals(res.status, 405);
});

Deno.test('a missing bearer token is 401 and never reaches the coordinator', async () => {
  const c = coordinator();
  const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(post(valid, {}));
  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, 'unauthenticated');
  assertEquals(c.seen.length, 0);
});

Deno.test('malformed JSON and unknown actions are 400 invalid_request', async () => {
  const h = createDeleteAccountHandler({ coordinator: coordinator(), workerId: 'w' });
  assertEquals((await h(post('{not json'))).status, 400);
  assertEquals((await h(post({ ...valid, action: 'explode' }))).status, 400);
  assertEquals((await h(post([1, 2]))).status, 400);
});

Deno.test('a client-supplied uid/email is never forwarded to the coordinator', async () => {
  const c = coordinator();
  await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(
    post({ ...valid, uid: UID, user_id: UID, email: 'a@b.c' }),
  );
  const forwarded = JSON.stringify(c.seen[0]);
  assertFalse(forwarded.includes(UID));
  assertFalse(forwarded.includes('a@b.c'));
  assertEquals(Object.keys(c.seen[0] as object).sort(), ['bearerToken', 'challengeId', 'challengeResponse', 'receiptSecret']);
});

Deno.test('completed only when the server confirms it; the body leaks no job id', async () => {
  const res = await createDeleteAccountHandler({ coordinator: coordinator(), workerId: 'w' })(post(valid));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body, { status: 'completed' });
  assertEquals(res.headers.get('cache-control'), 'no-store');
});

Deno.test('accepted but not yet complete is 202 in_progress, never completed', async () => {
  for (
    const st of [
      { status: 'accepted' as const },
      { status: 'pending' as const },
    ]
  ) {
    const c = coordinator({
      processJob: async () => ({ outcome: 'retry_scheduled', stage: 'storage_sweep', code: 'storage_error' }),
      getStatus: async () => st,
    });
    const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(post(valid));
    assertEquals(res.status, 202);
    const body = await res.json();
    assertEquals(body.status, 'in_progress');
    assertFalse(JSON.stringify(body).includes('storage'));
    assertFalse(JSON.stringify(body).includes('job-secret-id'));
  }
});

Deno.test('a status read that cannot confirm completion degrades to in_progress, not completed', async () => {
  const c = coordinator({
    processJob: async () => ({ outcome: 'aborted' }),
    getStatus: async () => ({ status: 'unavailable' }),
  });
  const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(post(valid));
  assertEquals(res.status, 202);
  assertEquals((await res.json()).status, 'in_progress');
});

Deno.test('a throwing processJob after acceptance is still in_progress', async () => {
  const c = coordinator({
    processJob: async () => { throw new Error('boom'); },
    getStatus: async () => ({ status: 'pending' }),
  });
  const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(post(valid));
  assertEquals(res.status, 202);
});

Deno.test('a duplicate request still reports the real state', async () => {
  const c = coordinator({
    requestDeletion: async () => ({ status: 'accepted', duplicate: true, jobId: 'j' }),
    processJob: async () => ({ outcome: 'no_work' }),
    getStatus: async () => ({ status: 'pending' }),
  });
  const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(post(valid));
  assertEquals(res.status, 202);
});

const errorCases: Array<[string, boolean, number]> = [
  ['unauthenticated', false, 401],
  ['invalid_request', false, 400],
  ['challenge_invalid', false, 400],
  ['challenge_expired', false, 400],
  ['challenge_replayed', false, 409],
  ['apple_subject_mismatch', false, 403],
  ['idempotency_conflict', false, 409],
  ['not_configured', false, 503],
  ['store_unavailable', true, 503],
  ['authorization_unavailable', true, 503],
  ['acceptance_unknown', true, 503],
];
for (const [code, retryable, http] of errorCases) {
  Deno.test(`coordinator error ${code} maps to HTTP ${http} with retryable=${retryable}`, async () => {
    const c = coordinator({
      requestDeletion: async () => ({
        status: 'error',
        code: code as never,
        retryable,
        ...(code === 'acceptance_unknown' ? { recovery: 'lookup_receipt' as const } : {}),
      }),
    });
    const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(post(valid));
    assertEquals(res.status, http);
    const body = await res.json();
    assertEquals(body.status, 'error');
    assertEquals(body.code, code);
    assertEquals(body.retryable, retryable);
    if (code === 'acceptance_unknown') assertEquals(body.recovery, 'lookup_receipt');
  });
}

Deno.test('status action reads only the receipt and never starts work', async () => {
  let processed = 0;
  let requested = 0;
  const c = coordinator({
    requestDeletion: async () => { requested++; return { status: 'error', code: 'unexpected', retryable: true }; },
    processJob: async () => { processed++; return { outcome: 'no_work' }; },
    getStatus: async (s) => (s === SECRET ? { status: 'pending' } : { status: 'unknown' }),
  });
  const h = createDeleteAccountHandler({ coordinator: c, workerId: 'w' });
  const ok = await h(post({ action: 'status', receipt_secret: SECRET }));
  assertEquals(ok.status, 200);
  assertEquals((await ok.json()).status, 'in_progress');
  const unknown = await h(post({ action: 'status', receipt_secret: 'B'.repeat(43) }));
  assertEquals(unknown.status, 404);
  assertEquals((await unknown.json()).status, 'unknown');
  assertEquals([processed, requested], [0, 0]);
});

Deno.test('status unavailable is 503 and status completed is 200', async () => {
  const mk = (st: never) =>
    createDeleteAccountHandler({ coordinator: coordinator({ getStatus: async () => st }), workerId: 'w' });
  const un = await mk({ status: 'unavailable' } as never)(post({ action: 'status', receipt_secret: SECRET }));
  assertEquals(un.status, 503);
  const done = await mk({ status: 'completed', retainedUntilMs: 1 } as never)(
    post({ action: 'status', receipt_secret: SECRET }),
  );
  assertEquals(done.status, 200);
  assertEquals(await done.json(), { status: 'completed' });
});

Deno.test('an unexpected exception is a generic retryable 500 with no detail', async () => {
  const c = coordinator({ requestDeletion: async () => { throw new Error('secret-leak'); } });
  const res = await createDeleteAccountHandler({ coordinator: c, workerId: 'w' })(post(valid));
  assertEquals(res.status, 500);
  const text = await res.text();
  assertFalse(text.includes('secret-leak'));
  assert(text.includes('retryable'));
});

Deno.test('E6 receipt-only status requires no bearer and invokes only getStatus', async () => {
  const calls: string[] = [];
  const h = createDeleteAccountHandler({ workerId: 'cached', coordinator: coordinator({
    requestDeletion: async () => { calls.push('request'); throw new Error('must not accept'); },
    processJob: async () => { calls.push('worker'); throw new Error('must not claim'); },
    getStatus: async (secret) => {
      calls.push('status');
      assertEquals(secret, SECRET);
      return { status: 'completed', retainedUntilMs: 1 };
    },
  }) });
  const res = await h(post({ action: 'status', receipt_secret: SECRET }, {}));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: 'completed' });
  assertEquals(res.headers.get('cache-control'), 'no-store');
  assertEquals(calls, ['status']);
});

Deno.test('E6 malformed or conflicting status refuses before any coordinator method, with or without bearer', async () => {
  let calls = 0;
  const h = createDeleteAccountHandler({ workerId: 'cached', coordinator: coordinator({
    requestDeletion: async () => { calls++; throw new Error('unexpected'); },
    processJob: async () => { calls++; throw new Error('unexpected'); },
    getStatus: async () => { calls++; return { status: 'completed', retainedUntilMs: 1 }; },
  }) });
  const headerCases: Record<string, string>[] = [{}, { authorization: 'Bearer jwt' }];
  for (const headers of headerCases) {
    for (const body of [
      { action: 'status' },
      { action: 'status', receipt_secret: 'short' },
      { action: 'status', receipt_secret: 42 },
      { action: 'status', receipt_secret: SECRET, challenge_id: 'conflict' },
      { action: 'status', receipt_secret: SECRET, challenge_response: 'conflict' },
      { action: 'status', receipt_secret: SECRET, uid: UID },
      { action: 'status', receipt_secret: SECRET, extra: true },
    ]) {
      const res = await h(post(body, headers));
      assertEquals(res.status, 400);
      assertEquals(await res.json(), { status: 'error', code: 'invalid_request', retryable: false });
    }
  }
  assertEquals(calls, 0);
});

Deno.test('E6 body and action validation precedes missing request bearer', async () => {
  const c = coordinator();
  const h = createDeleteAccountHandler({ coordinator: c, workerId: 'w' });
  for (const body of ['{not json', [], { ...valid, action: 'other' }, { ...valid, action: null }]) {
    assertEquals((await h(post(body, {}))).status, 400);
  }
  assertEquals((await h(post(valid, {}))).status, 401);
  assertEquals(c.seen, []);
});

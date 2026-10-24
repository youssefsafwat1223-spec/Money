import { assertEquals, assertFalse } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import type { RunOutcome } from '../_shared/account_deletion_coordinator.ts';
import { createWorkerHandler, HARD_MAX_JOBS } from './handler.ts';

const SECRET = 'worker-secret';
const req = (auth?: string) => {
  const headers: Record<string, string> = {};
  if (auth !== undefined) headers.authorization = auth;
  return new Request('https://x/fn', { method: 'POST', headers, body: '{}' });
};
const queue = (outcomes: RunOutcome[]) => {
  const calls: string[] = [];
  return {
    calls,
    processNext: (id: string) => {
      calls.push(id);
      return Promise.resolve(outcomes.shift() ?? { outcome: 'no_work' } as RunOutcome);
    },
  };
};
const make = (c: ReturnType<typeof queue>, extra: { maxJobs?: number; secret?: string } = {}) =>
  createWorkerHandler({ coordinator: () => c, workerSecret: extra.secret ?? SECRET, workerId: 'wid', maxJobs: extra.maxJobs });

Deno.test('worker auth: missing, wrong, empty, non-Bearer and prefix tokens are 403 and never touch the coordinator', async () => {
  const c = queue([{ outcome: 'completed' }]);
  const h = make(c);
  for (const a of [undefined, 'Bearer nope', 'Bearer ', SECRET, `Bearer ${SECRET}x`, `Bearer ${SECRET.slice(0, -1)}`]) {
    assertEquals((await h(req(a))).status, 403, String(a));
  }
  assertEquals(c.calls.length, 0);
});

Deno.test('worker auth: an unset secret rejects even an empty bearer (fail closed)', async () => {
  const c = queue([]);
  const h = make(c, { secret: '' });
  assertEquals((await h(req('Bearer '))).status, 403);
  assertEquals((await h(req('Bearer anything'))).status, 403);
  assertEquals(c.calls.length, 0);
});

Deno.test('worker stops at the first no_work and returns counts only', async () => {
  const c = queue([{ outcome: 'completed' }, { outcome: 'retry_scheduled', stage: 'apple_revoke', code: 'apple_revoke_retryable' }, { outcome: 'failed', stage: 'sql_purge', code: 'sql_purge_error' }, { outcome: 'lease_lost' }]);
  const res = await make(c, { maxJobs: 10 })(req(`Bearer ${SECRET}`));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: 'ok', processed: 4, completed: 1, retry_scheduled: 1, failed: 1, other: 1 });
  assertEquals(c.calls.length, 5); // 4 jobs + the empty claim that stopped it
  assertEquals(new Set(c.calls), new Set(['wid']));
});

Deno.test('worker is bounded by maxJobs and by the hard cap', async () => {
  const many = () => Array.from({ length: 100 }, () => ({ outcome: 'completed' }) as RunOutcome);
  let c = queue(many());
  await make(c, { maxJobs: 3 })(req(`Bearer ${SECRET}`));
  assertEquals(c.calls.length, 3);
  c = queue(many());
  await make(c, { maxJobs: 10_000 })(req(`Bearer ${SECRET}`));
  assertEquals(c.calls.length, HARD_MAX_JOBS);
  c = queue(many());
  await make(c, { maxJobs: 0 })(req(`Bearer ${SECRET}`));
  assertEquals(c.calls.length, 1);
});

Deno.test('worker with nothing to do claims once and reports zeros', async () => {
  const c = queue([]);
  const res = await make(c)(req(`Bearer ${SECRET}`));
  assertEquals(await res.json(), { status: 'ok', processed: 0, completed: 0, retry_scheduled: 0, failed: 0, other: 0 });
  assertEquals(c.calls.length, 1);
});

Deno.test('a coordinator throw is a 500 with counts only and no error text', async () => {
  const c = { processNext: () => Promise.reject(new Error('secret-detail uid=123')) };
  const res = await createWorkerHandler({ coordinator: () => c, workerSecret: SECRET, workerId: 'w' })(req(`Bearer ${SECRET}`));
  assertEquals(res.status, 500);
  assertFalse(JSON.stringify(await res.json()).includes('secret-detail'));
});

Deno.test('response never contains job ids, uids or stages', async () => {
  const c = queue([{ outcome: 'retry_scheduled', stage: 'apple_revoke', code: 'apple_revoke_retryable' }]);
  const text = await (await make(c)(req(`Bearer ${SECRET}`))).text();
  assertFalse(text.includes('apple_revoke'));
});

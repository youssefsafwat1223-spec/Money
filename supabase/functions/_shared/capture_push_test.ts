import { assertEquals } from 'jsr:@std/assert@1';
import { clearDeadApnsToken, enqueueNotificationRetry, GENERIC_CAPTURE_PUSH, isDeadApnsToken } from './capture_push.ts';

Deno.test('generic capture push text is the manifest Q3 wording and carries no data', () => {
  assertEquals(GENERIC_CAPTURE_PUSH, { title: '', body: 'New transaction captured' });
});

Deno.test('dead-token detection: 410 and the permanent token errors only', () => {
  assertEquals(isDeadApnsToken({ httpStatus: 410, errorCode: 'Unregistered' }), true);
  assertEquals(isDeadApnsToken({ httpStatus: 400, errorCode: 'BadDeviceToken' }), true);
  assertEquals(isDeadApnsToken({ httpStatus: 410, errorCode: 'ExpiredToken' }), true);
  assertEquals(isDeadApnsToken({ httpStatus: 503, errorCode: 'ServiceUnavailable' }), false);
  assertEquals(isDeadApnsToken({ httpStatus: null, errorCode: 'timeout' }), false);
  assertEquals(isDeadApnsToken({ httpStatus: 403, errorCode: 'InvalidProviderToken' }), false);
});

Deno.test('token clear is a compare-and-swap on the failing token', async () => {
  const calls: unknown[] = [];
  const builder = {
    update: (v: unknown) => (calls.push(['update', v]), builder),
    eq: (c: string, v: unknown) => (calls.push(['eq', c, v]), builder),
  };
  await clearDeadApnsToken({ from: () => builder } as never, 'h', 'dead');
  const eqs = calls.filter((c) => (c as unknown[])[0] === 'eq');
  assertEquals(eqs, [['eq', 'install_id_hash', 'h'], ['eq', 'apns_token', 'dead']]);
  assertEquals(((calls[0] as unknown[])[1] as Record<string, unknown>).apns_token, null);
});

Deno.test('retry enqueue is an ignore-duplicates upsert keyed on notification_log_id', async () => {
  let args: unknown[] = [];
  await enqueueNotificationRetry({
    from: () => ({ upsert: (...a: unknown[]) => ((args = a), Promise.resolve({})) }),
  } as never, {
    notificationLogId: 'log',
    installIdHash: 'h',
    payloadId: 'p',
    maxAttempts: 5,
    nextAttemptAt: 't',
    lastErrorCode: 'timeout',
  });
  assertEquals(args[1], { onConflict: 'notification_log_id', ignoreDuplicates: true });
  assertEquals((args[0] as Record<string, unknown>).notification_log_id, 'log');
});

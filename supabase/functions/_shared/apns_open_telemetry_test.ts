import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { sendCapturePush } from './apns.ts';

// A real iPhone tap routed correctly to the transaction details screen while
// `notification_logs.opened_at` stayed null for EVERY apns row. The client
// upserts the open by the server's `notification_logs.id` (onConflict: 'id'),
// and the push never carried it — so the open was unattributable by design.
// The whole native/Dart path already existed; only this key was missing.

async function withApnsEnv<T>(run: () => Promise<T>): Promise<T> {
  Deno.env.set('APNS_KEY_ID', 'KEYID12345');
  Deno.env.set('APNS_TEAM_ID', 'TEAMID1234');
  Deno.env.set('APNS_BUNDLE_ID', 'com.youssefsafwat.mali');
  Deno.env.set(
    'APNS_PRIVATE_KEY',
    '-----BEGIN PRIVATE KEY-----\n' +
      'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2\n' +
      'OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r\n' +
      '1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G\n' +
      '-----END PRIVATE KEY-----',
  );
  try {
    return await run();
  } finally {
    Deno.env.delete('APNS_KEY_ID');
    Deno.env.delete('APNS_TEAM_ID');
    Deno.env.delete('APNS_BUNDLE_ID');
    Deno.env.delete('APNS_PRIVATE_KEY');
  }
}

/// Sends one push against a stubbed APNs and returns the decoded JSON body.
async function capturePayload(
  over: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  return await withApnsEnv(async () => {
    const originalFetch = globalThis.fetch;
    let captured: Record<string, unknown> = {};
    globalThis.fetch = ((_url: string | URL, init?: RequestInit) => {
      captured = JSON.parse(String(init?.body ?? '{}'));
      return Promise.resolve(
        new Response(null, { status: 200, headers: { 'apns-id': 'stub-apns-id' } }),
      );
    }) as typeof fetch;
    try {
      const result = await sendCapturePush({
        token: 'device-token',
        environment: 'sandbox',
        payloadId: 'a'.repeat(64),
        title: 'تم رصد عملية شراء 🛒',
        body: 'المبلغ: 25 SAR',
        notificationType: 'new_transaction',
        notificationLogId: 'ab415ae1-b258-485b-9521-86acb1b38bcf',
        ...over,
      });
      assert(result.ok, `expected success, got ${JSON.stringify(result)}`);
      return captured;
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
}

Deno.test('the APNs payload carries notificationLogId — the missing key', async () => {
  const payload = await capturePayload();
  assertEquals(payload.notificationLogId, 'ab415ae1-b258-485b-9521-86acb1b38bcf');
});

Deno.test('notificationLogId travels alongside the existing routing keys', async () => {
  // Routing must be untouched: the tap destination is derived from these.
  const payload = await capturePayload({
    transactionId: 'txn-123',
    smartInboxItemId: 'inbox-9',
  });
  assertEquals(payload.transactionId, 'txn-123');
  assertEquals(payload.smartInboxItemId, 'inbox-9');
  assertEquals(payload.notificationType, 'new_transaction');
  assertEquals(payload.source, 'ios_shortcut');
  assertEquals(payload.notificationLogId, 'ab415ae1-b258-485b-9521-86acb1b38bcf');
});

Deno.test('a missing log id degrades safely to an empty string, not a crash', async () => {
  // Native `clean()` maps "" to nil, and the client SKIPS a null id rather than
  // inventing one from payloadId — no push is ever blocked by telemetry.
  const payload = await capturePayload({ notificationLogId: undefined });
  assertEquals(payload.notificationLogId, '');
  assertEquals(payload.payloadId, 'a'.repeat(64));
});

Deno.test('the alert body is unchanged by the added key', async () => {
  const payload = await capturePayload();
  const aps = payload.aps as { alert: { title: string; body: string } };
  assertEquals(aps.alert.title, 'تم رصد عملية شراء 🛒');
  assertEquals(aps.alert.body, 'المبلغ: 25 SAR');
});

Deno.test('two sends for one payload keep the same collapse id (idempotent replay)', async () => {
  // A duplicate/retried push must collapse onto the same notification, so a
  // duplicate tap resolves to one server row rather than two.
  const first = await capturePayload();
  const second = await capturePayload();
  assertEquals(first.payloadId, second.payloadId);
  assertEquals(first.notificationLogId, second.notificationLogId);
});

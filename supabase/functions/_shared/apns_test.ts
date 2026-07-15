import { assert, assertEquals } from 'jsr:@std/assert@1';
import { sendCapturePush } from './apns.ts';
import { buildApnsCollapseId } from './apns_collapse_id.ts';

const encoder = new TextEncoder();

async function throwawayPkcs8Pem(): Promise<string> {
  const keyPair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  );
  const exported = await crypto.subtle.exportKey('pkcs8', keyPair.privateKey);
  let binary = '';
  for (const byte of new Uint8Array(exported)) binary += String.fromCharCode(byte);
  const base64 = btoa(binary);
  const lines = base64.match(/.{1,64}/g) ?? [base64];
  return `-----BEGIN PRIVATE KEY-----\n${lines.join('\n')}\n-----END PRIVATE KEY-----`;
}

async function withApnsEnv(fn: () => Promise<void>) {
  const privateKey = await throwawayPkcs8Pem();
  Deno.env.set('APNS_KEY_ID', 'TESTKEYID1');
  Deno.env.set('APNS_TEAM_ID', 'TESTTEAMID');
  Deno.env.set('APNS_BUNDLE_ID', 'com.youssefsafwat.mali');
  Deno.env.set('APNS_PRIVATE_KEY', privateKey);
  try {
    await fn();
  } finally {
    Deno.env.delete('APNS_KEY_ID');
    Deno.env.delete('APNS_TEAM_ID');
    Deno.env.delete('APNS_BUNDLE_ID');
    Deno.env.delete('APNS_PRIVATE_KEY');
  }
}

Deno.test('sendCapturePush sends the corrected, length-safe collapse-id header', async () => {
  await withApnsEnv(async () => {
    const originalFetch = globalThis.fetch;
    let capturedHeaders: Headers | null = null;
    globalThis.fetch = (async (_url: string | URL, init?: RequestInit) => {
      capturedHeaders = new Headers(init?.headers);
      return new Response(null, { status: 200, headers: { 'apns-id': 'test-apns-id' } });
    }) as typeof fetch;

    try {
      const payloadId =
        '56e65066ae0f8355e51ab618b04cd4d768ca8056855b8a4461a1a78ea1c720cd';
      const result = await sendCapturePush({
        token: 'device-token',
        environment: 'sandbox',
        payloadId,
        title: 'تم رصد عملية شراء 🛒',
        body: 'المبلغ: 42 SAR',
        notificationType: 'new_transaction',
        transactionId: 'txn-123',
      });

      assert(result.ok, `expected success, got: ${JSON.stringify(result)}`);
      if (capturedHeaders === null) throw new Error('fetch was not called');
      const headers: Headers = capturedHeaders;

      const collapseId = headers.get('apns-collapse-id');
      assert(collapseId !== null);
      assertEquals(encoder.encode(collapseId!).length <= 64, true);
      assertEquals(collapseId, await buildApnsCollapseId(payloadId));

      // Other headers untouched by this fix — still exactly as before.
      assertEquals(headers.get('apns-topic'), 'com.youssefsafwat.mali');
      assertEquals(headers.get('apns-push-type'), 'alert');
      assertEquals(headers.get('apns-priority'), '10');
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

Deno.test('replaying the same payloadId sends the identical collapse-id (correct collapse semantics)', async () => {
  await withApnsEnv(async () => {
    const originalFetch = globalThis.fetch;
    const collapseIdsSent: string[] = [];
    globalThis.fetch = (async (_url: string | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      collapseIdsSent.push(headers.get('apns-collapse-id') ?? '');
      return new Response(null, { status: 200, headers: { 'apns-id': 'test-apns-id' } });
    }) as typeof fetch;

    try {
      const payloadId = 'qa_replay_test_payload_001';
      const message = {
        token: 'device-token',
        environment: 'sandbox' as const,
        payloadId,
        title: 't',
        body: 'b',
        notificationType: 'new_transaction',
      };
      await sendCapturePush(message);
      await sendCapturePush(message); // simulates a client-timeout retry replay

      assertEquals(collapseIdsSent.length, 2);
      assertEquals(collapseIdsSent[0], collapseIdsSent[1]);
      // A real device would show one banner, not two, for these two sends —
      // this is exactly what Apple's collapse behavior guarantees once the
      // id is valid (previously every send failed validation before
      // collapse semantics could even apply).
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

Deno.test('request body still carries routing fields unchanged', async () => {
  await withApnsEnv(async () => {
    const originalFetch = globalThis.fetch;
    let capturedBody: Record<string, unknown> | null = null;
    globalThis.fetch = (async (_url: string | URL, init?: RequestInit) => {
      capturedBody = JSON.parse(init?.body as string);
      return new Response(null, { status: 200, headers: { 'apns-id': 'x' } });
    }) as typeof fetch;

    try {
      await sendCapturePush({
        token: 'device-token',
        environment: 'production',
        payloadId: 'qa_routing_test',
        title: 'تم رصد عملية شراء 🛒',
        body: 'المبلغ: 42 SAR',
        notificationType: 'new_transaction',
        transactionId: 'txn-abc',
        smartInboxItemId: undefined,
      });

      assert(capturedBody !== null);
      const body = capturedBody as Record<string, unknown>;
      assertEquals(body.payloadId, 'qa_routing_test');
      assertEquals(body.transactionId, 'txn-abc');
      assertEquals(body.notificationType, 'new_transaction');
      assertEquals(body.source, 'ios_shortcut');
      const aps = body.aps as { alert: { title: string; body: string } };
      assertEquals(aps.alert.title, 'تم رصد عملية شراء 🛒');
      assertEquals(aps.alert.body, 'المبلغ: 42 SAR');
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

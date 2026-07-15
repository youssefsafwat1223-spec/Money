import { assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';

Deno.test('capture ownership code stamps, filters, and scopes ack by claimed user', async () => {
  const processSource = await Deno.readTextFile(
    new URL('../process-ios-sms/index.ts', import.meta.url),
  );
  const syncSource = await Deno.readTextFile(
    new URL('../sync-captures/index.ts', import.meta.url),
  );
  assertStringIncludes(processSource, 'claimed_user_id: auth.userId');
  assertStringIncludes(syncSource, ".eq('claimed_user_id', auth.userId)");
  assertStringIncludes(syncSource, ".is('claimed_user_id', null)");
  assertEquals(syncSource.includes('claimed_user_id.eq.'), false);
});

Deno.test('unlink revokes user and push ownership but preserves device secret', async () => {
  const source = await Deno.readTextFile(
    new URL('../unlink-capture-device/index.ts', import.meta.url),
  );
  assertStringIncludes(source, 'user_id: null');
  assertStringIncludes(source, 'apns_token: null');
  assertEquals(source.includes('device_secret_hash:'), false);
});

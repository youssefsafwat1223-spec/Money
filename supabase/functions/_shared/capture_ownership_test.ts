import { assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';

Deno.test('capture ownership code stamps, filters, and scopes ack by claimed user', async () => {
  const processSource = await Deno.readTextFile(
    new URL('../process-ios-sms/index.ts', import.meta.url),
  );
  const syncSource = await Deno.readTextFile(
    new URL('../sync-captures/index.ts', import.meta.url),
  );
  // P1: ownership is stamped inside the capture_claim RPC, from the device-row snapshot.
  const claimSql = await Deno.readTextFile(
    new URL('../../migrations/0111_capture_state_machine.sql', import.meta.url),
  );
  assertStringIncludes(processSource, "rpc('capture_claim'");
  assertStringIncludes(claimSql, '(p_payload_id, p_install_id_hash, d.user_id,');
  // F1: sync-captures reads through capture_sync_list (0112), scoped by claimed_user_id.
  const retentionSql = await Deno.readTextFile(
    new URL('../../migrations/0112_capture_notifications_retention.sql', import.meta.url),
  );
  assertStringIncludes(syncSource, "rpc('capture_sync_list'");
  assertStringIncludes(syncSource, 'p_user_id: auth.userId');
  assertEquals(syncSource.includes(".from('processed_captures')"), false);
  assertStringIncludes(retentionSql, 'claimed_user_id is not distinct from p_user_id');
  assertEquals(syncSource.includes('claimed_user_id.eq.'), false);
});

Deno.test('unlink revokes user and push ownership but preserves device secret', async () => {
  // P1: unlink is the unlink_capture_device RPC (0110): one statement, secret untouched.
  const source = await Deno.readTextFile(
    new URL('../unlink-capture-device/index.ts', import.meta.url),
  );
  assertStringIncludes(source, "rpc('unlink_capture_device'");
  const sql = await Deno.readTextFile(
    new URL('../../migrations/0110_capture_consent_projection.sql', import.meta.url),
  );
  const fn = sql.slice(sql.indexOf('function public.unlink_capture_device'));
  assertStringIncludes(fn, 'user_id = null');
  assertStringIncludes(fn, 'consent_owner_uid = null');
  assertStringIncludes(fn, 'apns_token = null');
  assertEquals(fn.includes('device_secret_hash ='), false);
});

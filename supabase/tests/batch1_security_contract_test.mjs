import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');

test('every Batch 1 migration has an explicit rollback', () => {
  for (const version of [35, 36, 37]) {
    const prefix = `00${version}`;
    const migration = [
      `${prefix}_admin_authorization.sql`,
      `${prefix}_capture_device_ownership.sql`,
      `${prefix}_atomic_account_deletion.sql`,
    ][version - 35];
    const rollback = migration.replace('.sql', '_rollback.sql');
    assert.ok(existsSync(new URL(`supabase/migrations/${migration}`, root)));
    assert.ok(existsSync(new URL(`supabase/rollback/${rollback}`, root)));
  }
});

test('capture ownership is stamped, filtered, and revoked without sharing A rows with B', () => {
  const migration = read('supabase/migrations/0036_capture_device_ownership.sql');
  const processCapture = read('supabase/functions/process-ios-sms/index.ts');
  const sync = read('supabase/functions/sync-captures/index.ts');
  const unlink = read('supabase/functions/unlink-capture-device/index.ts');

  assert.match(migration, /claimed_user_id uuid/i);
  // P1: ownership is stamped inside the capture_claim RPC from the device-row snapshot
  // (0111), and unlink is the unlink_capture_device RPC (0110).
  const claim = read('supabase/migrations/0111_capture_state_machine.sql');
  const unlinkSql = read('supabase/migrations/0110_capture_consent_projection.sql');
  assert.match(processCapture, /rpc\('capture_claim'/);
  assert.match(claim, /\(p_payload_id, p_install_id_hash, d\.user_id,/);
  // F1: sync-captures reads through capture_sync_list (0112), scoped to the device user
  // (NULL = the guest scope) by claimed_user_id, never from the table directly.
  assert.match(sync, /rpc\('capture_sync_list'/);
  assert.match(sync, /p_user_id: auth\.userId/);
  assert.doesNotMatch(sync, /\.from\('processed_captures'\)/);
  const retention = read('supabase/migrations/0112_capture_notifications_retention.sql');
  assert.match(retention, /claimed_user_id is not distinct from p_user_id/);
  assert.match(unlink, /unlink_capture_device/);
  const unlinkFn = unlinkSql.slice(unlinkSql.indexOf('function public.unlink_capture_device'));
  assert.match(unlinkFn, /user_id = null/);
  assert.match(unlinkFn, /apns_token = null/);
  assert.doesNotMatch(unlinkFn, /device_secret_hash = null/);
});

test('last account deletion is owner-scoped, locked, and atomic', () => {
  const migration = read('supabase/migrations/0037_atomic_account_deletion.sql');
  assert.match(migration, /security invoker/i);
  assert.match(migration, /v_user_id uuid := auth\.uid\(\)/i);
  assert.match(migration, /user_id = v_user_id[\s\S]+for update/i);
  assert.match(migration, /v_active_count <= 1/i);
  assert.match(migration, /errcode = '23514'/i);
  assert.match(migration, /grant execute[\s\S]+to authenticated/i);
  assert.doesNotMatch(migration, /security definer/i);
});

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
  assert.match(processCapture, /claimed_user_id:\s*auth\.userId/);
  assert.match(sync, /\.eq\(['"]claimed_user_id['"], auth\.userId\)/);
  assert.match(sync, /\.is\(['"]claimed_user_id['"], null\)/);
  assert.match(unlink, /user_id:\s*null/);
  assert.match(unlink, /apns_token:\s*null/);
  assert.doesNotMatch(unlink, /device_secret_hash:\s*null/);
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

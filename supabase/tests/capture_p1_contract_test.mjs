// P1 CAP-1/CAP-2 static guards (no database needed).
//   X10  no user_transactions write is reachable from the server capture path (I-2)
//   T-S11 sync-captures never claims ownerless rows
//   migrations 0110 / 0111 / 0113 shape
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const fn = (p) => readFileSync(join(root, 'functions', p), 'utf8');
const mig = (name) => readFileSync(join(root, 'migrations', name), 'utf8');
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

// Transitive local imports of the capture entrypoints.
function reachable(entry, seen = new Set()) {
  if (seen.has(entry)) return seen;
  seen.add(entry);
  const dir = dirname(entry);
  for (const m of readFileSync(join(root, 'functions', entry), 'utf8').matchAll(/from '(\.[^']+)'/g)) {
    const next = join(dir, m[1]).replace(/\\/g, '/');
    if (existsSync(join(root, 'functions', next))) reachable(next, seen);
  }
  return seen;
}

test('X10: no user_transactions / direct ledger write code is reachable from process-ios-sms or sync-captures', () => {
  assert.equal(existsSync(join(root, 'functions/_shared/ledger.ts')), false, '_shared/ledger.ts must stay deleted');
  for (const entry of ['process-ios-sms/index.ts', 'sync-captures/index.ts']) {
    for (const file of reachable(entry)) {
      const code = strip(readFileSync(join(root, 'functions', file), 'utf8'));
      assert.doesNotMatch(code, /user_transactions/, `${file} touches user_transactions`);
      assert.doesNotMatch(code, /upsertLedgerTransaction|isDirectCaptureWriteEnabled|isLedgerDualWriteEnabled/, file);
      assert.doesNotMatch(code, /capture_direct_supabase_write|ledger_dual_write/, file);
    }
  }
});

test('X10: no capture function or capture RPC writes user_transactions', () => {
  for (const f of ['0110_capture_consent_projection.sql', '0111_capture_state_machine.sql']) {
    assert.doesNotMatch(strip(mig(f)), /user_transactions/, f);
  }
});

test('T-S11: sync-captures never claims, updates or deletes rows directly', () => {
  const code = strip(fn('sync-captures/index.ts'));
  assert.doesNotMatch(code, /\.update\(/);
  assert.doesNotMatch(code, /\.delete\(/);
  assert.doesNotMatch(code, /claimed_user_id:\s*auth\.userId/);
  assert.match(code, /capture_ack/);
});

test('every migration function of this unit is SECURITY DEFINER with a pinned search_path and a lockdown', () => {
  for (const f of ['0110_capture_consent_projection.sql', '0111_capture_state_machine.sql']) {
    const sql = mig(f);
    const defs = [...sql.matchAll(/create or replace function public\.(\w+)\(([\s\S]*?)\)\s*returns[\s\S]*?\$\$;/gi)];
    assert.ok(defs.length >= 4, f);
    for (const [whole, name] of defs) {
      if (/security definer/i.test(whole)) {
        assert.match(whole, /set search_path = public, pg_temp/, `${name} search_path`);
        assert.match(sql, new RegExp(`revoke all on function public\\.${name}\\(`, 'i'), `${name} revoke`);
      }
    }
  }
  const s0110 = mig('0110_capture_consent_projection.sql');
  for (const jwtRpc of ['link_capture_device', 'set_capture_consent']) {
    assert.match(s0110, new RegExp(`grant execute on function public\\.${jwtRpc}\\([^)]*\\)\\s+to authenticated`, 'i'));
  }
  assert.doesNotMatch(s0110, /grant execute on function public\.(legacy_|capture_|unlink)[^;]*authenticated/i);
});

test('0111 leaves reclassification out (indistinguishable stored failure_reason) and documents why', () => {
  const sql = mig('0111_capture_state_machine.sql');
  assert.doesNotMatch(strip(sql), /state\s*=\s*'retryable'\s+where[^;]*status\s*=\s*'rejected'/i);
  assert.match(sql, /DELIBERATELY NOT/);
  // every stored rejection reason the capture path has ever written is the same value
  const idx = fn('process-ios-sms/index.ts');
  assert.match(idx, /'not_parseable'/);
});

test('0113 purge: by claimed_user_id and epoch purge bump', () => {
  const sql = mig('0113_purge_user_data_claimed_captures.sql');
  assert.match(sql, /delete from public\.processed_captures where claimed_user_id = p_user_id/i);
  assert.match(sql, /insert into public\.user_sync_state[\s\S]*'purge'[\s\S]*on conflict \(user_id\) do update/i);
  assert.match(sql, /revoke all on function public\.purge_user_data\(uuid\)/i);
});

test('rollback files exist for 0110, 0111, 0113', () => {
  const dir = join(root, 'rollback');
  const names = readdirSync(dir);
  for (const n of ['0110_capture_consent_projection', '0111_capture_state_machine', '0113_purge_user_data_claimed_captures']) {
    assert.ok(names.includes(`${n}_rollback.sql`), n);
  }
});

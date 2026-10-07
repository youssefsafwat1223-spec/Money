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

test('G1 (Astra required changes) static pins: C.1 owner binding, C.2 ordering, C.3 revoke route, C.6 clock_timestamp fence', () => {
  const idx = fn('process-ios-sms/index.ts');
  // C.1: owner_uid is passed on ANY schema version (not only v2); H1: nothing client-supplied
  // (received_at) reaches the ownerless rule, which is judged by the server's install owner history
  assert.match(idx, /p_owner_uid: ownerUid \|\| null/);
  assert.doesNotMatch(idx, /p_owner_uid: v2 && ownerUid/);
  assert.doesNotMatch(idx, /p_received_at/);
  const s0111 = mig('0111_capture_state_machine.sql');
  const s0112c = mig('0112_capture_notifications_retention.sql');
  for (const src of [s0111, s0112c]) {
    assert.doesNotMatch(src, /capture_parse_received_at|p_received_at|v_recv|owner_changed_at/);
    assert.match(src, /from public\.capture_install_owner_history h/);
    assert.match(src, /h\.trusted and not h\.transitioned/);
    assert.match(src, /h\.first_owner_uid = d\.user_id/);
  }
  assert.doesNotMatch(mig('0110_capture_consent_projection.sql'), /owner_changed_at/);
  // C.2 / C.3: the RPCs, the columns, the edge routes
  const s0110 = mig('0110_capture_consent_projection.sql');
  for (const col of ['owner_generation', 'consent_client_generation', 'last_revoke_generation']) {
    assert.match(s0110, new RegExp(`add column if not exists ${col}\\b`));
  }
  assert.match(s0110, /p_client_generation bigint default 0/);
  assert.match(s0110, /grant execute on function public\.revoke_capture_consent\([^)]*\)\s+to authenticated/i);
  assert.match(fn('set-device-consent/index.ts'), /jwt\.client\.rpc\('revoke_capture_consent'/);
  assert.match(fn('link-capture-device/index.ts'), /p_client_generation/);
  // C.6: clock_timestamp(), VOLATILE, 168 hours, never now() in the predicate; created_at immutable
  const s0112 = mig('0112_capture_notifications_retention.sql');
  const at = s0112.slice(s0112.indexOf('function public.capture_content_live_at'), s0112.indexOf('function public.capture_content_live(') );
  const live = s0112.slice(s0112.indexOf('function public.capture_content_live('), s0112.indexOf('$$;', s0112.indexOf('function public.capture_content_live(')));
  assert.match(at, /p_at < p_created_at \+ interval '168 hours'/);
  assert.match(live, /volatile/);
  assert.match(live, /capture_content_live_at\(p_created_at, clock_timestamp\(\)\)/);
  assert.doesNotMatch(live + at, /\bnow\(\)/);
  assert.match(s0112, /trg_processed_captures_created_at_immutable/);
  assert.match(s0112, /APPLICATION-ACCESS EXPIRY/);
  assert.match(s0112, /PHYSICAL CLEANUP/);
  assert.match(s0112, /BACKUP \/ PITR RETENTION/);
  // retention VALUES unchanged: the hourly physical job still uses the old bodies
  assert.match(s0112, /prune-processed-captures-hourly', '15 \* \* \* \*'/);
});

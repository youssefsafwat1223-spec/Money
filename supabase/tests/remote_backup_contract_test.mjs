// MALI-076n / MALI-014 (Phase-6 Batch 3) — static contract for the remote-backup
// generation pointer (migration 0075) + ownership. Runs without credentials.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const m0075 = read('supabase/migrations/0075_remote_backup_generations.sql');
const m0001 = read('supabase/migrations/0001_init.sql');

test('0075 adds the generation pointer columns (additive, nullable)', () => {
  for (const col of ['generation_id', 'blob_sha256', 'operation_id', 'committed_at']) {
    assert.match(m0075, new RegExp(`ADD COLUMN IF NOT EXISTS ${col}`));
  }
  assert.match(m0075, /ADD COLUMN IF NOT EXISTS status\s+TEXT NOT NULL DEFAULT 'committed'/);
  // Additive only — no destructive rewrite of the existing pointer.
  assert.doesNotMatch(m0075, /DROP TABLE|DROP COLUMN/);
});

test('0075 defines no key/passphrase/plaintext/financial COLUMN', () => {
  const columns = [...m0075.matchAll(/ADD COLUMN IF NOT EXISTS (\w+)/g)].map((m) => m[1]);
  for (const forbidden of ['passphrase', 'content_key', 'db_encryption_key', 'plaintext', 'salt', 'nonce', 'amount', 'merchant']) {
    assert.ok(!columns.some((c) => c.includes(forbidden)), `no column named ${forbidden}: ${columns}`);
  }
  // The stored hash is documented as a transport check, not AEAD auth.
  assert.match(m0075, /not.*AEAD auth/i);
});

test('backup pointer + storage objects are owner-scoped (server-derived id)', () => {
  // Metadata row: owner-scoped RLS.
  assert.match(m0001, /alter table public\.backups enable row level security/);
  assert.match(m0001, /create policy "own backup all" on public\.backups/);
  // Storage objects: each user only accesses their own <uid>/ folder — a leaked
  // path alone is insufficient, and a caller-supplied owner id is not trusted.
  assert.match(m0001, /storage\.foldername\(name\)\)\[1\] = auth\.uid\(\)::text/);
});

test('the Dart adapter derives the owner from the session, never the caller', () => {
  const adapter = read('app/lib/core/backup/supabase_remote_backup_store.dart');
  assert.match(adapter, /_client\.auth\.currentUser\?\.id/); // server session
  // Publication is generation-based (unique path), not a fixed-path overwrite.
  const publisher = read('app/lib/core/backup/remote_backup_store.dart');
  assert.match(publisher, /objectPathFor.*generationId/s);
  assert.match(publisher, /expectedPrevGenerationId/); // CAS on commit
  assert.match(publisher, /downloadVerified/); // size + hash before decrypt
});

test('backupNow publishes a generation (no fixed-path upsert overwrite)', () => {
  const svc = read('app/lib/core/backup/encrypted_backup_service.dart');
  assert.match(svc, /_publisher\.publish\(/);
  // The v3 path no longer overwrites a single fixed backup.enc object.
  assert.doesNotMatch(svc, /uploadBinary\(\s*\n?\s*path,\s*\n?\s*v3Bytes/);
  // disable() is stop-only; delete is a separate explicit action.
  assert.match(svc, /Future<void> deleteRemoteBackups\(\)/);
});

// MALI-076n §12 (closure) — server-atomic generation CAS (migration 0076).
test('0076 commit_backup_generation is a locked-down atomic CAS RPC', () => {
  const m0076 = read('supabase/migrations/0076_backup_generation_cas.sql');
  assert.match(m0076, /CREATE OR REPLACE FUNCTION public\.commit_backup_generation/);
  assert.match(m0076, /SECURITY DEFINER/);
  assert.match(m0076, /SET search_path = public/);
  assert.match(m0076, /v_owner\s+UUID := auth\.uid\(\)/); // owner from auth
  assert.match(m0076, /split_part\(p_object_path, '\/', 1\) <> v_owner::text/); // owner path
  assert.match(m0076, /FROM storage\.objects[\s\S]*bucket_id = 'backups'/); // object exists + size
  assert.match(m0076, /FOR UPDATE/); // row lock
  assert.match(m0076, /'stale_generation'/); // CAS reject
  assert.match(m0076, /'operation_conflict'/); // idempotency guard
  assert.match(m0076, /'replay', true/); // idempotent replay of the winner
  assert.match(m0076, /previous_generation_id\s*=\s*backups\.generation_id/); // retain previous
  assert.match(m0076, /REVOKE ALL ON FUNCTION public\.commit_backup_generation[\s\S]*FROM PUBLIC, anon/);
  assert.match(m0076, /GRANT EXECUTE ON FUNCTION public\.commit_backup_generation[\s\S]*TO authenticated/);
});

test('the adapter commits via the server-atomic RPC + maps typed errors', () => {
  const adapter = read('app/lib/core/backup/supabase_remote_backup_store.dart');
  assert.match(adapter, /rpc\('commit_backup_generation'/);
  assert.match(adapter, /'stale_generation':/);
  assert.match(adapter, /'operation_conflict':/);
  assert.match(adapter, /'ownership_mismatch':/);
});

// MALI-076n §16 — truthful UI state.
test('the UI derives Protected from the typed state, not a boolean', () => {
  const controller = read('app/lib/core/backup/remote_backup_controller.dart');
  assert.match(controller, /RemoteBackupState\.enabledIdle/); // Protected == committed

  // MALI-076n §14 — the single-flight operation coordinator, asserted by
  // SEMANTICS rather than by source formatting. The previous assertion pinned
  // the exact one-line spelling `if (_busy) return null`, so a purely cosmetic
  // reformat to braces broke the gate while the guard was unchanged. These
  // regexes tolerate braces and line breaks and instead pin the three
  // properties that actually make duplicate generations impossible.

  // Scoped to the _run coordinator itself — checking the whole file would be
  // vacuous, because refresh() carries its own earlier `if (_busy)` guard.
  const run = controller.match(/Future<T\?> _run<T>[\s\S]*?\n  \}/);
  assert.ok(run, 'the _run operation coordinator must exist');
  const body = run[0];

  // 1. A busy guard exists and returns null (does not start a second operation).
  assert.match(body, /if\s*\(\s*_busy\s*\)\s*\{?\s*return\s+null\s*;/);

  // 2. The guard runs BEFORE the flag is latched, so a concurrent caller is
  //    rejected rather than racing into the operation.
  const guardAt = body.search(/if\s*\(\s*_busy\s*\)/);
  const latchAt = body.search(/_busy\s*=\s*true\s*;/);
  assert.ok(guardAt !== -1 && latchAt !== -1, 'busy guard and latch must exist');
  assert.ok(guardAt < latchAt, 'the busy guard must precede `_busy = true`');

  // 3. The flag is always released in a finally, so one failed operation can
  //    never wedge the coordinator shut.
  assert.match(body, /finally\s*\{[\s\S]*?_busy\s*=\s*false\s*;/);
  const screen = read('app/lib/features/backup/backup_screen.dart');
  assert.match(screen, /remoteBackupStateLabel\(state\)/);
  assert.match(screen, /state\.isProtected/);
});

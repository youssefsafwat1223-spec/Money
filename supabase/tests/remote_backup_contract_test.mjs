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

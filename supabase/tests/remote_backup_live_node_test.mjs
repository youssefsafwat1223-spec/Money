// MALI-076n / MALI-014 (Phase-6 Batch-3 closure) — credential-gated real Supabase
// Storage/PostgreSQL harness for the remote-backup contracts. These exercise the
// LIVE object ownership, metadata RLS, and the server-atomic generation CAS
// (migration 0076) that the injected fake-store tests CANNOT prove. They SKIP
// cleanly when Supabase credentials / a deployed schema are unavailable — and
// every skip is reported. (This harness must EXIST even while it skips; the fake
// store does not prove effective live RLS or PostgreSQL concurrency.)
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
const live = url && anon && service;
const gate = {
  skip: live
    ? false
    : 'requires SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY and a project with migrations 0075+0076 + the backups bucket deployed',
};

const svc = () => ({ apikey: service, Authorization: `Bearer ${service}`, 'Content-Type': 'application/json' });
const userHeaders = (token) => ({ apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' });

async function makeUser() {
  const email = `bk-${randomUUID()}@example.test`;
  const password = randomUUID();
  const created = await (await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST', headers: svc(),
    body: JSON.stringify({ email, password, email_confirm: true }),
  })).json();
  const token = (await (await fetch(`${url}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: anon, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })).json()).access_token;
  return { id: created.id, token };
}

const rmUser = (id) => fetch(`${url}/auth/v1/admin/users/${id}`, { method: 'DELETE', headers: svc() });

const putObject = (token, path, bytes) =>
  fetch(`${url}/storage/v1/object/backups/${path}`, {
    method: 'POST',
    headers: { apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/octet-stream', 'x-upsert': 'true' },
    body: bytes,
  });

const commitRpc = (token, body) =>
  fetch(`${url}/rest/v1/rpc/commit_backup_generation`, {
    method: 'POST', headers: userHeaders(token), body: JSON.stringify(body),
  }).then((r) => r.json());

test('storage objects are owner-scoped: user A cannot read user B object', gate, async () => {
  const a = await makeUser();
  const b = await makeUser();
  try {
    await putObject(b.token, `${b.id}/g/${randomUUID()}.enc`, Buffer.from('B-secret'));
    // A tries to read a listing of B's folder.
    const res = await fetch(`${url}/storage/v1/object/list/backups`, {
      method: 'POST', headers: userHeaders(a.token),
      body: JSON.stringify({ prefix: `${b.id}/` }),
    });
    const listed = await res.json();
    assert.ok(!Array.isArray(listed) || listed.length === 0, 'A must not see B objects');
  } finally {
    await rmUser(a.id);
    await rmUser(b.id);
  }
});

test('server-atomic CAS: two commits from the same previous → one winner, one stale', gate, async () => {
  const a = await makeUser();
  try {
    const gen1 = randomUUID();
    const path1 = `${a.id}/g/${gen1}.enc`;
    await putObject(a.token, path1, Buffer.from('gen1-blob'));
    const base = {
      p_object_path: path1, p_blob_version: 3, p_size_bytes: 9,
      p_blob_sha256: 'x', p_expected_prev_generation_id: null,
    };
    // Two concurrent first-commits from the SAME (null) previous generation.
    const [r1, r2] = await Promise.all([
      commitRpc(a.token, { ...base, p_generation_id: gen1, p_operation_id: randomUUID() }),
      commitRpc(a.token, { ...base, p_generation_id: randomUUID(), p_operation_id: randomUUID(),
        p_object_path: path1 }),
    ]);
    const oks = [r1, r2].filter((r) => r?.ok === true).length;
    const stales = [r1, r2].filter((r) => r?.error === 'stale_generation').length;
    assert.equal(oks, 1, `exactly one winner: ${JSON.stringify([r1, r2])}`);
    assert.equal(stales, 1, 'the loser is a typed stale_generation');
  } finally {
    await rmUser(a.id);
  }
});

test('idempotent replay: the winning operation replays without a duplicate', gate, async () => {
  const a = await makeUser();
  try {
    const gen = randomUUID();
    const op = randomUUID();
    const path = `${a.id}/g/${gen}.enc`;
    await putObject(a.token, path, Buffer.from('gen-blob'));
    const body = {
      p_generation_id: gen, p_object_path: path, p_blob_version: 3, p_size_bytes: 8,
      p_blob_sha256: 'x', p_operation_id: op, p_expected_prev_generation_id: null,
    };
    const first = await commitRpc(a.token, body);
    assert.equal(first.ok, true);
    const replay = await commitRpc(a.token, body); // lost-response retry
    assert.equal(replay.ok, true);
    assert.equal(replay.replay, true);
  } finally {
    await rmUser(a.id);
  }
});

test('ownership: a caller cannot commit an object under another user folder', gate, async () => {
  const a = await makeUser();
  const b = await makeUser();
  try {
    const res = await commitRpc(a.token, {
      p_generation_id: randomUUID(), p_object_path: `${b.id}/g/x.enc`, p_blob_version: 3,
      p_size_bytes: 1, p_blob_sha256: 'x', p_operation_id: randomUUID(),
      p_expected_prev_generation_id: null,
    });
    assert.equal(res.error, 'ownership_mismatch');
  } finally {
    await rmUser(a.id);
    await rmUser(b.id);
  }
});

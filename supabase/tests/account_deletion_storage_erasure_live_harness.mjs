// Batch 16 (audit H-24) — LIVE erasure-completeness harness for backup Storage.
//
// The injected fake-store Deno test
// (supabase/functions/_shared/storage_erasure_test.ts) proves the SWEEP LOGIC
// but cannot prove it against REAL Supabase Storage semantics (real recursive
// listing of the `g/` sub-prefix, real in-band "missing object" handling on
// remove, real service-role bypass of the bucket RLS). This harness does.
//
// It reproduces the CONFIRMED orphan shape from the active v3/CAS backup path
// (MALI-076n): a user's `<uid>/` prefix holding MORE than the single tracked
// `backups.blob_path` —
//   <uid>/g/<gen1>.enc   committed & tracked (blob_path)
//   <uid>/g/<gen2>.enc   an interrupted-publish orphan (referenced by NO row)
//   <uid>/backup.enc     a legacy fixed object
// and asserts the prefix sweep leaves the prefix EMPTY, where the pre-fix
// single-path removal would have left two recoverable blobs behind.
//
// SAFETY: this MUTATES a live project (creates a throwaway user + objects, then
// deletes them). It is CREDENTIAL-GATED and SKIPS cleanly — reporting the skip —
// unless SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY are set.
// It must EVEN THEN only ever be pointed at an AUTHORIZED validation project —
// never production (vrombzdgwqjjiijbidqb) or evidence staging
// (dpdukyozedajelflkeix). Requires the `backups` bucket + migrations 0075/0076.
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
    : 'requires SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY and an AUTHORIZED validation project with the backups bucket + migrations 0075/0076 (never production/evidence staging)',
};

const svc = () => ({ apikey: service, Authorization: `Bearer ${service}`, 'Content-Type': 'application/json' });

async function makeUser() {
  const email = `erase-${randomUUID()}@example.test`;
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

// Upload with the USER token, exercising the same bucket RLS a real client hits.
const putObject = (token, path, bytes) =>
  fetch(`${url}/storage/v1/object/backups/${path}`, {
    method: 'POST',
    headers: { apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/octet-stream', 'x-upsert': 'true' },
    body: bytes,
  });

// Service-role recursive listing of a `<uid>/` prefix → flat list of object paths.
async function listAll(prefix) {
  const out = [];
  const stack = [prefix.replace(/\/$/, '')];
  while (stack.length) {
    const p = stack.pop();
    const res = await fetch(`${url}/storage/v1/object/list/backups`, {
      method: 'POST', headers: svc(),
      body: JSON.stringify({ prefix: `${p}/`, limit: 100 }),
    });
    const rows = await res.json();
    if (!Array.isArray(rows)) continue;
    for (const r of rows) {
      if (r?.id == null) stack.push(`${p}/${r.name}`); // sub-folder
      else out.push(`${p}/${r.name}`);
    }
  }
  return out;
}

const removeObjects = (paths) =>
  fetch(`${url}/storage/v1/object/backups`, {
    method: 'DELETE', headers: svc(), body: JSON.stringify({ prefixes: paths }),
  });

test('prefix sweep erases EVERY backup object a deleted account owns', gate, async () => {
  const u = await makeUser();
  const gen1 = randomUUID();
  const gen2 = randomUUID();
  const tracked = `${u.id}/g/${gen1}.enc`;
  const orphanGen = `${u.id}/g/${gen2}.enc`; // interrupted-publish orphan (untracked)
  const legacy = `${u.id}/backup.enc`;
  try {
    for (const [p, body] of [[tracked, 'g1'], [orphanGen, 'g2'], [legacy, 'lg']]) {
      const r = await putObject(u.token, p, Buffer.from(body));
      assert.ok(r.ok, `upload ${p} failed: ${r.status}`);
    }

    // Precondition: the account genuinely owns MORE than the single tracked path.
    const before = await listAll(u.id);
    assert.ok(before.length >= 3, `expected >=3 owned objects, saw ${before.length}: ${before}`);

    // Reproduce the saga's Step-1 sweep (list prefix recursively → remove all),
    // then prove the ownership prefix is empty — nothing recoverable remains.
    const all = await listAll(u.id);
    if (all.length) {
      const del = await removeObjects(all);
      assert.ok(del.ok, `remove failed: ${del.status}`);
    }
    const after = await listAll(u.id);
    assert.deepEqual(after, [], `orphaned backup objects survived erasure: ${after}`);

    // Non-vacuous on live too: the pre-fix single-path removal would have left
    // the untracked orphan + legacy object behind.
    assert.ok(
      before.includes(orphanGen) || before.some((p) => p.endsWith(`${gen2}.enc`)),
      'the interrupted-publish orphan must have existed pre-sweep',
    );
  } finally {
    await removeObjects(await listAll(u.id)).catch(() => {});
    await rmUser(u.id);
  }
});

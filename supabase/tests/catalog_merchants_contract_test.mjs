// Contract for 0094_catalog_merchants.sql — the canonical merchant catalog.
//
// Two things are asserted here that cannot be asserted anywhere else:
//
// 1. The PostgreSQL half of `merchant_alias_key_v1` produces byte-identical
//    output to the Dart half, for the shared fixture corpus. The Dart test in
//    app/test/features/coupons/merchant_alias_key_test.dart asserts the same
//    corpus against the same committed `expected` values, so the two
//    implementations are pinned to one number rather than to each other. A
//    JavaScript reimplementation here would test nothing at all — it would only
//    prove that a third implementation agrees with itself.
//
// 2. The write guard and the uniqueness index actually reject what they claim
//    to. Both are the difference between "the device abstains" and "the device
//    attributes a user's spending to the wrong business", and neither is
//    observable from the client.
//
// Live-gated like every file in this directory: it needs a real database
// because the mechanisms under test ARE database mechanisms.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const supabaseUrl = process.env.SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const anonKey = process.env.SUPABASE_ANON_KEY;
const liveTest = Boolean(supabaseUrl) && Boolean(serviceRoleKey);

const fixtures = JSON.parse(
  readFileSync(new URL('../../docs/coupons/merchant_alias_key_v1.fixtures.json', import.meta.url)),
);

function headers(key = serviceRoleKey) {
  return {
    apikey: key,
    authorization: `Bearer ${key}`,
    'content-type': 'application/json',
    prefer: 'return=representation',
  };
}

async function rest(path, options = {}, key = serviceRoleKey) {
  const response = await fetch(`${supabaseUrl}/rest/v1${path}`, {
    ...options,
    headers: { ...headers(key), ...(options.headers ?? {}) },
  });
  const text = await response.text();
  return { response, body: text ? JSON.parse(text) : null };
}

/**
 * Round-trips a value through the REAL PostgreSQL function by inserting an
 * alias and reading back the generated column. There is no RPC for the key
 * function and adding one would widen the API surface for a test; the generated
 * column is the same code path production uses, which makes it the better probe
 * anyway.
 */
async function keyViaDatabase(merchantId, raw, kind) {
  const { response, body } = await rest('/catalog_merchant_aliases', {
    method: 'POST',
    body: JSON.stringify({
      merchant_id: merchantId, alias_raw: raw, alias_kind: kind, is_reviewed: false,
    }),
  });
  if (response.status !== 201) return { error: body };
  const key = body[0].alias_normalized;
  await rest(`/catalog_merchant_aliases?id=eq.${body[0].id}`, { method: 'DELETE' });
  return { key };
}

async function makeMerchant() {
  const slug = `zztest-${randomUUID().slice(0, 8)}`;
  const { response, body } = await rest('/catalog_merchants', {
    method: 'POST',
    body: JSON.stringify({ slug, name_ar: 'اختبار' }),
  });
  assert.equal(response.status, 201, JSON.stringify(body));
  return body[0].id;
}

async function dropMerchant(id) {
  await rest(`/catalog_merchants?id=eq.${id}`, { method: 'DELETE' });
}

test('0094: PostgreSQL agrees with Dart on every name fixture', { skip: !liveTest }, async () => {
  const merchantId = await makeMerchant();
  try {
    for (const c of fixtures.name_cases) {
      // The empty-key CHECK rejects these before we can read a key back; that
      // rejection IS the expected behaviour and is asserted separately below.
      if (c.expected === '') continue;
      // A raw value the write guard forbids cannot be stored at all — also
      // asserted separately.
      const { key, error } = await keyViaDatabase(merchantId, c.input, 'name');
      assert.equal(
        key, c.expected,
        `PostgreSQL and the committed expectation disagree on ${JSON.stringify(c.input)}` +
        ` (${c.why})${error ? ` — ${JSON.stringify(error)}` : ''}`,
      );
    }
  } finally {
    await dropMerchant(merchantId);
  }
});

test('0094: PostgreSQL agrees with Dart on every domain fixture', { skip: !liveTest }, async () => {
  const merchantId = await makeMerchant();
  try {
    for (const c of fixtures.domain_cases) {
      if (c.expected === '') continue;
      const { key } = await keyViaDatabase(merchantId, c.input, 'domain');
      assert.equal(key, c.expected, `${JSON.stringify(c.input)} (${c.why})`);
    }
  } finally {
    await dropMerchant(merchantId);
  }
});

test('0094: alias_normalized cannot be supplied by the caller', { skip: !liveTest }, async () => {
  // GENERATED ALWAYS has no OVERRIDING escape hatch, unlike an identity column,
  // so this is a hard guarantee rather than a convention. Without it an admin
  // request could store a key that does not match its own raw value, and the
  // reviewed alias would resolve to something nobody approved.
  const merchantId = await makeMerchant();
  try {
    const { response } = await rest('/catalog_merchant_aliases', {
      method: 'POST',
      body: JSON.stringify({
        merchant_id: merchantId, alias_raw: 'CARREFOUR', alias_kind: 'name',
        alias_normalized: 'something-else',
      }),
    });
    assert.ok(response.status >= 400, 'the database accepted a supplied alias_normalized');
  } finally {
    await dropMerchant(merchantId);
  }
});

test('0094: the write guard rejects everything the device would strip', { skip: !liveTest }, async () => {
  // If the catalog may hold what the lookup pipeline removes, the same string
  // resolves differently depending on which stage matched it — alias
  // `cafe term 4471` -> A and `cafe` -> B means the unstripped query hits A and
  // the stripped one hits B. The guard is what makes that unreachable.
  const merchantId = await makeMerchant();
  try {
    for (const raw of [
      'POS PURCHASE CARREFOUR', 'CARD PURCHASE NOON', 'PAYMENT TO PANDA',
      'شراء من كارفور', 'مشتريات من بنده',
      'CAFE TERM 4471', 'CARREFOUR BRANCH 12', 'مطعم فرع 45', 'SHOP REF 99',
    ]) {
      const { response } = await rest('/catalog_merchant_aliases', {
        method: 'POST',
        body: JSON.stringify({ merchant_id: merchantId, alias_raw: raw, alias_kind: 'name' }),
      });
      assert.ok(response.status >= 400, `the guard accepted ${JSON.stringify(raw)}`);
    }
  } finally {
    await dropMerchant(merchantId);
  }
});

test('0094: the guard does NOT reject real names that resemble noise', { skip: !liveTest }, async () => {
  // The lexicon is deliberately multi-word-anchored. Bare `payment`, `pos`,
  // `purchase`, `شراء`, `دفع` are plausible starts of real business names, and
  // stripping them would turn PAYMENT SOLUTIONS into a different merchant. A
  // guard that over-rejects makes real merchants uncatalogable.
  const merchantId = await makeMerchant();
  try {
    for (const raw of [
      'PAYMENT SOLUTIONS', 'POS HOUSE', 'PURCHASE POINT',
      'CAFE TRACE', 'STC 5G', '7-ELEVEN', 'FOREVER 21', 'شراء الخير',
    ]) {
      const { response, body } = await rest('/catalog_merchant_aliases', {
        method: 'POST',
        body: JSON.stringify({ merchant_id: merchantId, alias_raw: raw, alias_kind: 'name' }),
      });
      assert.equal(response.status, 201, `the guard rejected the real name ${JSON.stringify(raw)}: ${JSON.stringify(body)}`);
    }
  } finally {
    await dropMerchant(merchantId);
  }
});

test('0094: an empty key is rejected', { skip: !liveTest }, async () => {
  // Every input that folds away produces ''. Stored, they would all share one
  // key and match each other.
  const merchantId = await makeMerchant();
  try {
    for (const raw of ['!!!', '   ', '؟؟؟', '😀']) {
      const { response } = await rest('/catalog_merchant_aliases', {
        method: 'POST',
        body: JSON.stringify({ merchant_id: merchantId, alias_raw: raw, alias_kind: 'name' }),
      });
      assert.ok(response.status >= 400, `an empty key was stored for ${JSON.stringify(raw)}`);
    }
  } finally {
    await dropMerchant(merchantId);
  }
});

test('0094: two merchants cannot hold the same REVIEWED alias in one scope', { skip: !liveTest }, async () => {
  const a = await makeMerchant();
  const b = await makeMerchant();
  try {
    const first = await rest('/catalog_merchant_aliases', {
      method: 'POST',
      body: JSON.stringify({ merchant_id: a, alias_raw: 'ZZUNIQUE BRAND', alias_kind: 'name', is_reviewed: true }),
    });
    assert.equal(first.response.status, 201, JSON.stringify(first.body));

    const clash = await rest('/catalog_merchant_aliases', {
      method: 'POST',
      body: JSON.stringify({ merchant_id: b, alias_raw: 'zzunique brand', alias_kind: 'name', is_reviewed: true }),
    });
    assert.ok(clash.response.status >= 400,
      'two merchants claimed one reviewed alias — the device would resolve to whichever row it saw first');

    // An UNREVIEWED duplicate must still be storable: provider suggestions land
    // unreviewed, and a collision is precisely what the human review queue
    // exists to adjudicate.
    const queued = await rest('/catalog_merchant_aliases', {
      method: 'POST',
      body: JSON.stringify({
        merchant_id: b, alias_raw: 'ZZUNIQUE BRAND', alias_kind: 'name',
        is_reviewed: false, provenance: 'provider',
      }),
    });
    assert.equal(queued.response.status, 201,
      'an unreviewed duplicate must be able to queue for review');
  } finally {
    await dropMerchant(a);
    await dropMerchant(b);
  }
});

test('0094: writes bump the catalog version so devices re-sync', { skip: !liveTest }, async () => {
  // 0006 shipped merchant_keywords with a version row and no bump, pinning every
  // synced device forever. These tables must not repeat it.
  async function version(category) {
    const { body } = await rest(`/catalog_versions?category=eq.${category}&select=version`);
    return Number(body[0].version);
  }
  const before = await version('catalog_merchants');
  const id = await makeMerchant();
  try {
    assert.ok(await version('catalog_merchants') > before, 'merchant insert did not bump');
    const aliasBefore = await version('merchant_aliases');
    await rest('/catalog_merchant_aliases', {
      method: 'POST',
      body: JSON.stringify({ merchant_id: id, alias_raw: 'ZZBUMP TEST', alias_kind: 'name' }),
    });
    assert.ok(await version('merchant_aliases') > aliasBefore, 'alias insert did not bump');
  } finally {
    await dropMerchant(id);
  }
});

test('0094: anon and authenticated can read but never write', { skip: !liveTest || !anonKey }, async () => {
  const { response: readOk } = await rest('/catalog_merchants?select=id&limit=1', {}, anonKey);
  assert.equal(readOk.status, 200, 'the catalog must be readable without auth — it is a catalog');

  const { response: writeBlocked } = await rest('/catalog_merchants', {
    method: 'POST',
    body: JSON.stringify({ slug: 'zzanon-write', name_ar: 'x' }),
  }, anonKey);
  assert.ok(writeBlocked.status >= 400, 'anon could write to the merchant catalog');
});

test('0094: unreviewed aliases are never served to a device', { skip: !liveTest || !anonKey }, async () => {
  // The review step is the entire safety model for provider-suggested aliases.
  // If an unreviewed row reaches a device, review is decorative.
  const id = await makeMerchant();
  try {
    const { body } = await rest('/catalog_merchant_aliases', {
      method: 'POST',
      body: JSON.stringify({
        merchant_id: id, alias_raw: 'ZZUNREVIEWED ALIAS', alias_kind: 'name',
        is_reviewed: false, provenance: 'provider',
      }),
    });
    const aliasId = body[0].id;
    const { body: visible } = await rest(
      `/catalog_merchant_aliases?id=eq.${aliasId}&select=id`, {}, anonKey);
    assert.deepEqual(visible, [], 'an unreviewed alias was visible to anon');
  } finally {
    await dropMerchant(id);
  }
});

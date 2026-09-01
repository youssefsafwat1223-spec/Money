// Regression contract for 0093_merchant_keywords_versioning.sql.
//
// THE DEFECT THIS LOCKS OUT
//
// `merchant_keywords` is versioned at CATEGORY level: catalog-delta returns a
// snapshot only when `catalog_versions.merchant_keywords` exceeds the version a
// device already holds. The row was seeded at 1 by 0006 and no writer ever
// bumped it, so every device that had synced once was pinned forever — keyword
// additions, re-categorisations and deactivations could not reach it.
//
// The failure was SILENT in every direction: writes succeeded, catalog-delta
// returned 200, and the device dutifully applied an empty delta. Nothing except
// a version assertion can catch a regression here, which is why these tests
// assert the counter and the served snapshot rather than the write.
//
// Live-gated like every other file in this directory: it needs a real database
// because the mechanism under test IS a database trigger. A mocked bump would
// assert that the mock bumps.

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const supabaseUrl = process.env.SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const liveTest = Boolean(supabaseUrl) && Boolean(serviceRoleKey);

function headers() {
  return {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    'content-type': 'application/json',
    prefer: 'return=representation',
  };
}

async function rest(path, options = {}) {
  const response = await fetch(`${supabaseUrl}/rest/v1${path}`, {
    ...options,
    headers: { ...headers(), ...(options.headers ?? {}) },
  });
  const text = await response.text();
  return { response, body: text ? JSON.parse(text) : null };
}

/** The single number catalog-delta consults before serving anything. */
async function categoryVersion(category) {
  const { response, body } = await rest(
    `/catalog_versions?category=eq.${category}&select=version`,
  );
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.equal(body.length, 1, `catalog_versions row for ${category} is missing`);
  return Number(body[0].version);
}

async function allVersions() {
  const { response, body } = await rest('/catalog_versions?select=category,version');
  assert.equal(response.status, 200, JSON.stringify(body));
  return Object.fromEntries(body.map((r) => [r.category, Number(r.version)]));
}

async function insertKeyword(keyword) {
  const { response, body } = await rest('/merchant_keywords', {
    method: 'POST',
    body: JSON.stringify({ keyword, category_key: 'other', country_code: 'ALL' }),
  });
  assert.equal(response.status, 201, JSON.stringify(body));
  return body[0].id;
}

async function patchKeyword(id, patch) {
  const { response, body } = await rest(`/merchant_keywords?id=eq.${id}`, {
    method: 'PATCH',
    body: JSON.stringify(patch),
  });
  assert.equal(response.status, 200, JSON.stringify(body));
}

async function deleteKeyword(id) {
  const { response } = await rest(`/merchant_keywords?id=eq.${id}`, { method: 'DELETE' });
  assert.ok(response.status < 300, `delete failed: ${response.status}`);
}

/**
 * Call catalog-delta the way a device does, and report whether the snapshot was
 * withheld. This exercises the REAL gate, not a reimplementation of it.
 */
async function deltaFor(sinceVersion) {
  const response = await fetch(
    `${supabaseUrl}/functions/v1/catalog-delta?category=merchant_keywords&since=${sinceVersion}`,
    { headers: headers() },
  );
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  return {
    version: Number(body?.meta?.version),
    items: body?.items ?? [],
    deletedIds: body?.deleted_ids ?? [],
    withheld: (body?.items ?? []).length === 0 && (body?.deleted_ids ?? []).length === 0,
  };
}

// A keyword string that cannot collide with catalog data or another run.
const probe = () => `ZZTEST_${randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase()}`;

test('0093: INSERT bumps the category version', { skip: !liveTest }, async () => {
  const before = await categoryVersion('merchant_keywords');
  const id = await insertKeyword(probe());
  try {
    assert.ok(
      (await categoryVersion('merchant_keywords')) > before,
      'an inserted keyword did not advance the version — devices will never see it',
    );
  } finally {
    await deleteKeyword(id);
  }
});

test('0093: UPDATE bumps the category version', { skip: !liveTest }, async () => {
  const id = await insertKeyword(probe());
  try {
    const before = await categoryVersion('merchant_keywords');
    await patchKeyword(id, { category_key: 'groceries' });
    assert.ok((await categoryVersion('merchant_keywords')) > before);
  } finally {
    await deleteKeyword(id);
  }
});

test('0093: deactivation bumps the category version', { skip: !liveTest }, async () => {
  // Deactivation REMOVES a row from the served snapshot. If it does not bump,
  // devices keep applying a keyword the admin has switched off — the most
  // user-visible form of this defect.
  const id = await insertKeyword(probe());
  try {
    const before = await categoryVersion('merchant_keywords');
    await patchKeyword(id, { is_active: false });
    assert.ok((await categoryVersion('merchant_keywords')) > before);

    const afterDeactivate = await categoryVersion('merchant_keywords');
    await patchKeyword(id, { is_deleted: true });
    assert.ok(
      (await categoryVersion('merchant_keywords')) > afterDeactivate,
      'soft delete must bump too — it also changes the served snapshot',
    );
  } finally {
    await deleteKeyword(id);
  }
});

test('0093: hard DELETE bumps the category version', { skip: !liveTest }, async () => {
  // The table models soft delete, but nothing PREVENTS a hard delete through
  // PostgREST or SQL. Without a bump the removed keyword lives on every synced
  // device forever, and no admin action can dislodge it.
  const id = await insertKeyword(probe());
  const before = await categoryVersion('merchant_keywords');
  await deleteKeyword(id);
  assert.ok((await categoryVersion('merchant_keywords')) > before);
});

test('0093: a timestamp-only touch does NOT bump', { skip: !liveTest }, async () => {
  // enrich-merchant stamps updated_at on every upsert (index.ts:367). Bumping
  // on that would force the whole fleet to re-download the dictionary daily and
  // would make the version mean "somebody wrote" rather than "something
  // changed". The trigger's WHEN clause covers the served columns only.
  const id = await insertKeyword(probe());
  try {
    const before = await categoryVersion('merchant_keywords');
    await patchKeyword(id, { updated_at: new Date().toISOString() });
    assert.equal(
      await categoryVersion('merchant_keywords'),
      before,
      'a no-op write bumped the version — the fleet will re-sync for nothing',
    );
  } finally {
    await deleteKeyword(id);
  }
});

test('0093: catalog-delta observes the bump', { skip: !liveTest }, async () => {
  const before = await categoryVersion('merchant_keywords');
  const id = await insertKeyword(probe());
  try {
    const delta = await deltaFor(before);
    assert.ok(delta.version > before, 'catalog-delta still reports the old version');
    assert.ok(!delta.withheld, 'catalog-delta withheld a snapshot after a real change');
  } finally {
    await deleteKeyword(id);
  }
});

test(
  '0093: a device pinned at an older version receives the updated snapshot',
  { skip: !liveTest },
  async () => {
    // The whole point. A device in the field holds the version it last synced;
    // before 0093 that pinned it permanently.
    const pinned = await categoryVersion('merchant_keywords');
    const keyword = probe();
    const id = await insertKeyword(keyword);
    try {
      const delta = await deltaFor(pinned);
      assert.ok(!delta.withheld, 'the pinned device was served nothing');
      assert.ok(
        delta.items.some((row) => row.keyword === keyword),
        'the snapshot did not contain the keyword added after the device synced',
      );

      // And it must keep working, not merely unstick once: after the device
      // stores the new version, a SUBSEQUENT change must reach it too.
      const resynced = delta.version;
      assert.ok((await deltaFor(resynced)).withheld, 'no write happened; nothing should be served');
      await patchKeyword(id, { category_key: 'transport' });
      const second = await deltaFor(resynced);
      assert.ok(!second.withheld, 'a subsequent change did not reach a re-synced device');
      assert.ok(second.version > resynced);
    } finally {
      await deleteKeyword(id);
    }
  },
);

test('0093: no unrelated catalog category is disturbed', { skip: !liveTest }, async () => {
  const before = await allVersions();
  const id = await insertKeyword(probe());
  try {
    const after = await allVersions();
    for (const [category, version] of Object.entries(before)) {
      if (category === 'merchant_keywords') continue;
      assert.equal(
        after[category],
        version,
        `writing a merchant keyword moved catalog_versions.${category} — ` +
          'that would force an unrelated catalog to re-sync on every device',
      );
    }
  } finally {
    await deleteKeyword(id);
  }
});

test(
  '0093: the trigger guard covers every served column',
  { skip: !liveTest },
  async () => {
    // The UPDATE trigger fires on an explicit column list. A column added to
    // merchant_keywords later would be served to devices but would NOT bump,
    // silently reintroducing the defect for that column only. Assert the list
    // against the live schema so the next person is forced to update it.
    const guarded = new Set([
      'keyword', 'category_key', 'language', 'country_code',
      'priority', 'is_active', 'is_deleted',
    ]);
    // Deliberately unguarded, documented in the migration.
    const exempt = new Set(['id', 'updated_at']);

    const { response, body } = await rest('/merchant_keywords?select=*&limit=1');
    assert.equal(response.status, 200, JSON.stringify(body));
    if (!body.length) return; // nothing to introspect on an empty table
    for (const column of Object.keys(body[0])) {
      assert.ok(
        guarded.has(column) || exempt.has(column),
        `column '${column}' is served to devices but is not in the 0093 trigger ` +
          'WHEN clause — changes to it would never reach a synced device',
      );
    }
  },
);

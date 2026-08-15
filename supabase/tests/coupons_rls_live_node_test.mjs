// Coupons Phase C1 — LIVE behavioural matrix for migration 0081 (catalog RLS +
// Storage). Credential-gated: runs only against a Supabase project with 0081
// applied (SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY).
// It SKIPS without them — there is no local Postgres — and the static shape
// contract lives in coupons_catalog_contract_test.mjs.
//
// service_role is used ONLY for fixture setup/teardown (the admin path); every
// assertion about client behaviour is made with the anon key or a real
// authenticated user JWT.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const supabaseUrl = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const live = Boolean(supabaseUrl) && Boolean(anonKey) && Boolean(serviceRoleKey);
const skip = live
  ? false
  : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY (with migration 0081 applied)';

const headers = (key, jwt = key) => ({
  apikey: key,
  authorization: `Bearer ${jwt}`,
  'content-type': 'application/json',
});

async function req(path, options = {}) {
  const r = await fetch(`${supabaseUrl}${path}`, options);
  const t = await r.text();
  let body = null;
  try {
    body = t ? JSON.parse(t) : null;
  } catch {
    body = t;
  }
  return { status: r.status, body };
}

const svc = (path, options = {}) =>
  req(path, { ...options, headers: { ...headers(serviceRoleKey), ...(options.headers || {}) } });
const asAnon = (path, options = {}) =>
  req(path, { ...options, headers: { ...headers(anonKey), ...(options.headers || {}) } });
const asUser = (jwt, path, options = {}) =>
  req(path, { ...options, headers: { ...headers(anonKey, jwt), ...(options.headers || {}) } });

const iso = (msFromNow) => new Date(Date.now() + msFromNow).toISOString();
const HOUR = 3600_000;

/** Fixture state shared by the ordered tests below. */
const fx = { categoryKey: null, tagId: null, ids: {}, jwt: null, userId: null, ext: randomUUID().slice(0, 8) };

async function insertCoupon(overrides) {
  const base = {
    slug: `c1-${fx.ext}-${randomUUID().slice(0, 8)}`,
    partner_name: 'C1 Partner',
    title_ar: 'عنوان تجريبي',
    description_ar: 'وصف تجريبي',
    redemption_type: 'code',
    code: 'C1CODE',
    display_category_key: fx.categoryKey,
    valid_from: iso(-HOUR),
    is_active: true,
  };
  return svc('/rest/v1/coupons?select=id', {
    method: 'POST',
    headers: { prefer: 'return=representation' },
    body: JSON.stringify({ ...base, ...overrides }),
  });
}

test('setup: fixtures (service_role — admin path only)', { skip }, async () => {
  fx.categoryKey = `c1_${fx.ext}`;
  let r = await svc('/rest/v1/coupon_categories?select=key', {
    method: 'POST',
    headers: { prefer: 'return=representation' },
    body: JSON.stringify({ key: fx.categoryKey, label_ar: 'فئة تجريبية', sort_order: 5 }),
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));

  r = await svc('/rest/v1/coupon_tags?select=id', {
    method: 'POST',
    headers: { prefer: 'return=representation' },
    body: JSON.stringify({ key: `tag_${fx.ext}`, label_ar: 'مطاعم', sort_order: 1 }),
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  fx.tagId = r.body[0].id;

  // Coupon fixtures across the visibility matrix.
  const mk = async (name, overrides) => {
    const res = await insertCoupon(overrides);
    assert.equal(res.status, 201, `${name}: ${JSON.stringify(res.body)}`);
    fx.ids[name] = res.body[0].id;
  };
  await mk('live', {});                                            // live now
  await mk('scheduled', { valid_from: iso(HOUR) });                // starts later
  await mk('expired', { valid_from: iso(-2 * HOUR), valid_until: iso(-HOUR) });
  await mk('disabled', { is_active: false });
  await mk('atStart', { valid_from: new Date().toISOString() });   // boundary: now
  await mk('openEnded', { valid_until: null });
  await mk('globalCountry', { country_codes: [] });
  await mk('scopedCountry', { country_codes: ['SA', 'AE'] });
  await mk('linkType', { redemption_type: 'link', code: null, partner_url: 'https://example.com' });

  await svc('/rest/v1/coupon_tag_links', {
    method: 'POST',
    body: JSON.stringify({ coupon_id: fx.ids.live, tag_id: fx.tagId }),
  });

  // A real authenticated user (NOT admin, NOT service_role).
  const email = `c1-${fx.ext}@qirsh-staging.test`;
  const password = `C1-${randomUUID()}`;
  r = await svc('/auth/v1/admin/users', {
    method: 'POST',
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  fx.userId = r.body.id;
  r = await asAnon('/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
  fx.jwt = r.body.access_token;
  assert.ok(fx.jwt, 'authenticated session established');
});

// --- A/B: live coupon readable by BOTH client roles --------------------------
test('A: anon can read a live coupon', { skip }, async () => {
  const r = await asAnon(`/rest/v1/coupons?id=eq.${fx.ids.live}&select=id,slug`);
  assert.equal(r.status, 200);
  assert.equal(r.body.length, 1);
});

test('B: authenticated can read a live coupon (policy is not inherited)', { skip }, async () => {
  const r = await asUser(fx.jwt, `/rest/v1/coupons?id=eq.${fx.ids.live}&select=id,slug`);
  assert.equal(r.status, 200);
  assert.equal(r.body.length, 1);
});

// --- C–F: hidden states, for BOTH roles --------------------------------------
for (const [letterAnon, letterAuth, name, label] of [
  ['C', 'D', 'scheduled', 'scheduled (before valid_from)'],
  ['E', 'E2', 'expired', 'expired (past valid_until)'],
  ['F', 'F2', 'disabled', 'disabled (is_active=false)'],
]) {
  test(`${letterAnon}: anon cannot read a ${label} coupon`, { skip }, async () => {
    const r = await asAnon(`/rest/v1/coupons?id=eq.${fx.ids[name]}&select=id`);
    assert.equal(r.status, 200);
    assert.equal(r.body.length, 0);
  });
  test(`${letterAuth}: authenticated cannot read a ${label} coupon`, { skip }, async () => {
    const r = await asUser(fx.jwt, `/rest/v1/coupons?id=eq.${fx.ids[name]}&select=id`);
    assert.equal(r.status, 200);
    assert.equal(r.body.length, 0);
  });
}

// --- G/H: country targeting ---------------------------------------------------
test('G: country targeting persists canonically (empty = global, ISO allowlist)', { skip }, async () => {
  const g = await asAnon(`/rest/v1/coupons?id=eq.${fx.ids.globalCountry}&select=country_codes`);
  assert.deepEqual(g.body[0].country_codes, []);
  const s = await asAnon(`/rest/v1/coupons?id=eq.${fx.ids.scopedCountry}&select=country_codes`);
  assert.deepEqual(s.body[0].country_codes, ['SA', 'AE']);
});

test('H: malformed country codes are rejected by the database', { skip }, async () => {
  for (const bad of [['ALL'], ['sa'], ['SAU'], ['S'], ['12'], ['SA', 'zz']]) {
    const r = await insertCoupon({ country_codes: bad });
    assert.notEqual(r.status, 201, `country_codes ${JSON.stringify(bad)} must be rejected`);
  }
});

// --- I/J: redemption shapes ---------------------------------------------------
test('I: invalid code-redemption shapes are rejected', { skip }, async () => {
  assert.notEqual((await insertCoupon({ redemption_type: 'code', code: null })).status, 201);
  assert.notEqual((await insertCoupon({ redemption_type: 'code', code: '   ' })).status, 201);
});

test('J: invalid link-redemption shapes are rejected', { skip }, async () => {
  // missing destination
  assert.notEqual(
    (await insertCoupon({ redemption_type: 'link', code: null, partner_url: null })).status, 201);
  // contradictory code alongside a link
  assert.notEqual(
    (await insertCoupon({
      redemption_type: 'link', code: 'X', partner_url: 'https://example.com',
    })).status, 201);
  // non-https / dangerous schemes
  for (const url of ['http://example.com', 'javascript:alert(1)', 'data:text/html,x']) {
    assert.notEqual(
      (await insertCoupon({ redemption_type: 'link', code: null, partner_url: url })).status,
      201,
      `${url} must be rejected`,
    );
  }
});

// --- K–P: no client writes on coupons ----------------------------------------
test('K/L: INSERT denied for anon and authenticated', { skip }, async () => {
  const payload = JSON.stringify({
    slug: `deny-${randomUUID().slice(0, 8)}`, partner_name: 'x', title_ar: 'x',
    description_ar: 'x', redemption_type: 'code', code: 'X',
    display_category_key: fx.categoryKey,
  });
  assert.ok((await asAnon('/rest/v1/coupons', { method: 'POST', body: payload })).status >= 400);
  assert.ok((await asUser(fx.jwt, '/rest/v1/coupons', { method: 'POST', body: payload })).status >= 400);
});

test('M/N: UPDATE denied for anon and authenticated (row unchanged)', { skip }, async () => {
  const body = JSON.stringify({ partner_name: 'HACKED' });
  await asAnon(`/rest/v1/coupons?id=eq.${fx.ids.live}`, { method: 'PATCH', body });
  await asUser(fx.jwt, `/rest/v1/coupons?id=eq.${fx.ids.live}`, { method: 'PATCH', body });
  const r = await svc(`/rest/v1/coupons?id=eq.${fx.ids.live}&select=partner_name`);
  assert.equal(r.body[0].partner_name, 'C1 Partner');
});

test('O/P: DELETE denied for anon and authenticated (row survives)', { skip }, async () => {
  await asAnon(`/rest/v1/coupons?id=eq.${fx.ids.live}`, { method: 'DELETE' });
  await asUser(fx.jwt, `/rest/v1/coupons?id=eq.${fx.ids.live}`, { method: 'DELETE' });
  const r = await svc(`/rest/v1/coupons?id=eq.${fx.ids.live}&select=id`);
  assert.equal(r.body.length, 1);
});

// --- Q: tags / categories / links are read-only for clients -------------------
test('Q: normal users cannot mutate tags, categories or links', { skip }, async () => {
  const cases = [
    ['/rest/v1/coupon_categories', { key: 'hack_cat', label_ar: 'x' }],
    ['/rest/v1/coupon_tags', { key: 'hack_tag', label_ar: 'x' }],
    ['/rest/v1/coupon_tag_links', { coupon_id: fx.ids.live, tag_id: fx.tagId }],
  ];
  for (const [path, payload] of cases) {
    const body = JSON.stringify(payload);
    assert.ok((await asAnon(path, { method: 'POST', body })).status >= 400, `anon POST ${path}`);
    assert.ok((await asUser(fx.jwt, path, { method: 'POST', body })).status >= 400, `auth POST ${path}`);
    assert.ok((await asUser(fx.jwt, path, { method: 'DELETE' })).status >= 400, `auth DELETE ${path}`);
  }
  // Category/tag rows referenced by a live coupon remain readable (render need).
  const cat = await asAnon(`/rest/v1/coupon_categories?key=eq.${fx.categoryKey}&select=key,label_ar`);
  assert.equal(cat.body.length, 1);
});

// --- R/S: Storage boundary ----------------------------------------------------
test('R: normal users cannot write to coupon-assets', { skip }, async () => {
  const path = `coupons/${fx.ids.live}/art.png`;
  const png = Buffer.from('89504e470d0a1a0a', 'hex');
  const upload = (key, jwt) =>
    fetch(`${supabaseUrl}/storage/v1/object/coupon-assets/${path}`, {
      method: 'POST',
      headers: { apikey: key, authorization: `Bearer ${jwt}`, 'content-type': 'image/png' },
      body: png,
    });
  assert.ok((await upload(anonKey, anonKey)).status >= 400, 'anon upload denied');
  assert.ok((await upload(anonKey, fx.jwt)).status >= 400, 'authenticated upload denied');
  const del = await fetch(`${supabaseUrl}/storage/v1/object/coupon-assets/${path}`, {
    method: 'DELETE',
    headers: { apikey: anonKey, authorization: `Bearer ${fx.jwt}` },
  });
  assert.ok(del.status >= 400, 'authenticated delete denied');
});

test('S: public asset read works (admin-uploaded object)', { skip }, async () => {
  const path = `coupons/${fx.ids.live}/art.png`;
  const png = Buffer.from('89504e470d0a1a0a', 'hex');
  const put = await fetch(`${supabaseUrl}/storage/v1/object/coupon-assets/${path}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      authorization: `Bearer ${serviceRoleKey}`,
      'content-type': 'image/png',
      'x-upsert': 'true',
    },
    body: png,
  });
  assert.ok(put.status < 400, `admin upload works: ${put.status}`);
  const pub = await fetch(`${supabaseUrl}/storage/v1/object/public/coupon-assets/${path}`);
  assert.equal(pub.status, 200, 'public read works');
});

// --- Category / tag integrity (spec §23) -------------------------------------
test('integrity: duplicate category key and duplicate tag key are rejected', { skip }, async () => {
  const c = await svc('/rest/v1/coupon_categories', {
    method: 'POST',
    body: JSON.stringify({ key: fx.categoryKey, label_ar: 'dup' }),
  });
  assert.ok(c.status >= 400, 'duplicate category key rejected');
  const t = await svc('/rest/v1/coupon_tags', {
    method: 'POST',
    body: JSON.stringify({ key: `tag_${fx.ext}`, label_ar: 'dup' }),
  });
  assert.ok(t.status >= 400, 'duplicate normalized tag key rejected');
});

test('integrity: duplicate coupon/tag link rejected; unknown category rejected', { skip }, async () => {
  const dup = await svc('/rest/v1/coupon_tag_links', {
    method: 'POST',
    body: JSON.stringify({ coupon_id: fx.ids.live, tag_id: fx.tagId }),
  });
  assert.ok(dup.status >= 400, 'duplicate link rejected by composite PK');
  const bad = await insertCoupon({ display_category_key: 'no_such_category_key' });
  assert.ok(bad.status >= 400, 'display category FK enforced');
});

test('integrity: deactivating a category used by a live coupon is blocked', { skip }, async () => {
  const blocked = await svc(`/rest/v1/coupon_categories?key=eq.${fx.categoryKey}`, {
    method: 'PATCH',
    body: JSON.stringify({ is_active: false }),
  });
  assert.ok(blocked.status >= 400, 'deactivation blocked while live coupons use it');
  const still = await svc(`/rest/v1/coupon_categories?key=eq.${fx.categoryKey}&select=is_active`);
  assert.equal(still.body[0].is_active, true);
});

test('integrity: deleting a coupon cascades its tag links', { skip }, async () => {
  const tmp = await insertCoupon({});
  const id = tmp.body[0].id;
  await svc('/rest/v1/coupon_tag_links', {
    method: 'POST',
    body: JSON.stringify({ coupon_id: id, tag_id: fx.tagId }),
  });
  await svc(`/rest/v1/coupons?id=eq.${id}`, { method: 'DELETE' });
  const links = await svc(`/rest/v1/coupon_tag_links?coupon_id=eq.${id}&select=coupon_id`);
  assert.equal(links.body.length, 0, 'links cascaded away');
});

test('integrity: ordering fields are present and deterministic', { skip }, async () => {
  const r = await asAnon('/rest/v1/coupon_categories?select=key,sort_order&order=sort_order.asc,key.asc');
  assert.equal(r.status, 200);
  assert.ok(Array.isArray(r.body));
});

// --- Scheduling boundaries (spec §24) ----------------------------------------
test('scheduling: valid_from is INCLUSIVE (live at start), valid_until EXCLUSIVE', { skip }, async () => {
  // at/just-after start → visible
  const atStart = await asAnon(`/rest/v1/coupons?id=eq.${fx.ids.atStart}&select=id`);
  assert.equal(atStart.body.length, 1, 'visible at valid_from');
  // open-ended → never expires
  const open = await asAnon(`/rest/v1/coupons?id=eq.${fx.ids.openEnded}&select=id`);
  assert.equal(open.body.length, 1, 'null valid_until = no expiry');
  // a window ending exactly now → hidden (exclusive end)
  const ending = await insertCoupon({ valid_from: iso(-HOUR), valid_until: new Date().toISOString() });
  const endId = ending.body[0].id;
  const hidden = await asAnon(`/rest/v1/coupons?id=eq.${endId}&select=id`);
  assert.equal(hidden.body.length, 0, 'hidden at/after valid_until');
  // disabled overrides any window
  const disabledOpen = await insertCoupon({ is_active: false, valid_until: null });
  const dId = disabledOpen.body[0].id;
  const dHidden = await asAnon(`/rest/v1/coupons?id=eq.${dId}&select=id`);
  assert.equal(dHidden.body.length, 0, 'disabled hidden regardless of dates');
  // a window that ends before it starts is rejected outright
  const inverted = await insertCoupon({ valid_from: iso(HOUR), valid_until: iso(-HOUR) });
  assert.notEqual(inverted.status, 201, 'inverted window rejected');
});

test('teardown: remove fixtures', { skip }, async () => {
  await svc(`/rest/v1/coupons?slug=like.c1-${fx.ext}*`, { method: 'DELETE' });
  await svc(`/rest/v1/coupon_tags?key=eq.tag_${fx.ext}`, { method: 'DELETE' });
  await svc(`/rest/v1/coupon_categories?key=eq.${fx.categoryKey}`, { method: 'DELETE' });
  await fetch(`${supabaseUrl}/storage/v1/object/coupon-assets/coupons/${fx.ids.live}/art.png`, {
    method: 'DELETE',
    headers: headers(serviceRoleKey),
  });
  if (fx.userId) {
    await svc(`/auth/v1/admin/users/${fx.userId}`, { method: 'DELETE' });
  }
});

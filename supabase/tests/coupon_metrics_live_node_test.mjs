// Coupons Phase C2 — LIVE analytics matrix for migration 0082 (§28 A–O).
// Credential-gated: runs only against a Supabase project with 0081+0082
// applied. It SKIPS without credentials (no local Postgres); a skipped run is
// NOT live validation.
//
// service_role is used ONLY for fixtures and for the trusted-read assertions an
// Admin route would make; every client-behaviour assertion uses the anon key or
// a real authenticated user JWT.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const supabaseUrl = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const live = Boolean(supabaseUrl) && Boolean(anonKey) && Boolean(serviceRoleKey);
const skip = live
  ? false
  : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY (with migrations 0081+0082 applied)';

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
const svc = (p, o = {}) => req(p, { ...o, headers: { ...headers(serviceRoleKey), ...(o.headers || {}) } });
const asAnon = (p, o = {}) => req(p, { ...o, headers: { ...headers(anonKey), ...(o.headers || {}) } });
const asUser = (jwt, p, o = {}) => req(p, { ...o, headers: { ...headers(anonKey, jwt), ...(o.headers || {}) } });

const rpcAsUser = (jwt, couponId, event) =>
  asUser(jwt, '/rest/v1/rpc/record_coupon_event', {
    method: 'POST',
    body: JSON.stringify({ p_coupon_id: couponId, p_event: event }),
  });

/** Trusted read of one counter (what the Admin route would do). */
async function counter(couponId, event) {
  const r = await svc(
    `/rest/v1/coupon_metrics_daily?coupon_id=eq.${couponId}&event=eq.${event}&select=day,count`,
  );
  return r.body?.[0] ?? null;
}

const fx = { ext: randomUUID().slice(0, 8), categoryKey: null, ids: {}, jwt: null, userId: null };

test('setup: fixtures (service_role — admin path only)', { skip }, async () => {
  fx.categoryKey = `c2_${fx.ext}`;
  let r = await svc('/rest/v1/coupon_categories', {
    method: 'POST',
    body: JSON.stringify({ key: fx.categoryKey, label_ar: 'فئة C2' }),
  });
  assert.ok(r.status < 300, JSON.stringify(r.body));

  const mk = async (name, overrides = {}) => {
    const res = await svc('/rest/v1/coupons?select=id', {
      method: 'POST',
      headers: { prefer: 'return=representation' },
      body: JSON.stringify({
        slug: `c2-${fx.ext}-${name}`,
        partner_name: 'C2 Partner',
        title_ar: 'عنوان',
        description_ar: 'وصف',
        redemption_type: 'code',
        code: 'C2CODE',
        display_category_key: fx.categoryKey,
        valid_from: new Date(Date.now() - 3600_000).toISOString(),
        is_active: true,
        ...overrides,
      }),
    });
    assert.equal(res.status, 201, `${name}: ${JSON.stringify(res.body)}`);
    fx.ids[name] = res.body[0].id;
  };
  await mk('live');
  await mk('expired', {
    valid_from: new Date(Date.now() - 7200_000).toISOString(),
    valid_until: new Date(Date.now() - 3600_000).toISOString(),
  });
  await mk('disabled', { is_active: false });
  await mk('concurrency');

  const email = `c2-${fx.ext}@qirsh-staging.test`;
  const password = `C2-${randomUUID()}`;
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

// --- A/B: atomic increment ----------------------------------------------------
test('A: authenticated impression on a live coupon increments 0 -> 1', { skip }, async () => {
  assert.equal(await counter(fx.ids.live, 'impression'), null, 'no counter before');
  const r = await rpcAsUser(fx.jwt, fx.ids.live, 'impression');
  assert.ok(r.status < 300, `rpc ok: ${JSON.stringify(r.body)}`);
  assert.equal((await counter(fx.ids.live, 'impression')).count, 1);
});

test('B: a second impression increments 1 -> 2', { skip }, async () => {
  await rpcAsUser(fx.jwt, fx.ids.live, 'impression');
  assert.equal((await counter(fx.ids.live, 'impression')).count, 2);
});

// --- C/D/E: independent counters per event ------------------------------------
for (const [letter, event] of [['C', 'detail_view'], ['D', 'code_copy'], ['E', 'cta_click']]) {
  test(`${letter}: ${event} is an independent counter`, { skip }, async () => {
    await rpcAsUser(fx.jwt, fx.ids.live, event);
    assert.equal((await counter(fx.ids.live, event)).count, 1);
    // …and it did not disturb the impression counter.
    assert.equal((await counter(fx.ids.live, 'impression')).count, 2);
  });
}

// --- F/G: validation -----------------------------------------------------------
test('F: an unknown event is rejected (no silent coercion, no row)', { skip }, async () => {
  for (const bad of ['save', 'redeem', 'favorite', 'IMPRESSION', '', null]) {
    const r = await rpcAsUser(fx.jwt, fx.ids.live, bad);
    assert.ok(r.status >= 400, `event ${JSON.stringify(bad)} must be rejected`);
  }
  const rows = await svc(
    `/rest/v1/coupon_metrics_daily?coupon_id=eq.${fx.ids.live}&select=event`,
  );
  const events = rows.body.map((x) => x.event).sort();
  assert.deepEqual(events, ['code_copy', 'cta_click', 'detail_view', 'impression']);
});

test('G: a nonexistent coupon is rejected and creates no metric row', { skip }, async () => {
  const ghost = randomUUID();
  const r = await rpcAsUser(fx.jwt, ghost, 'impression');
  assert.ok(r.status >= 400, 'unknown coupon rejected');
  const rows = await svc(`/rest/v1/coupon_metrics_daily?coupon_id=eq.${ghost}&select=count`);
  assert.equal(rows.body.length, 0);
});

// --- documented V1 rule: existence only, NOT liveness --------------------------
test('V1 rule: events on an expired/disabled coupon are ACCEPTED (expiry race)', { skip }, async () => {
  // A user whose detail sheet was already open must not have a legitimate copy
  // rejected because the coupon expired a second earlier. Directional analytics
  // accept a small post-expiry tail; this is the documented C2 contract.
  assert.ok((await rpcAsUser(fx.jwt, fx.ids.expired, 'code_copy')).status < 300);
  assert.equal((await counter(fx.ids.expired, 'code_copy')).count, 1);
  assert.ok((await rpcAsUser(fx.jwt, fx.ids.disabled, 'detail_view')).status < 300);
  assert.equal((await counter(fx.ids.disabled, 'detail_view')).count, 1);
});

// --- H: anon EXECUTE denied ----------------------------------------------------
test('H: anon EXECUTE on record_coupon_event is denied', { skip }, async () => {
  const r = await asAnon('/rest/v1/rpc/record_coupon_event', {
    method: 'POST',
    body: JSON.stringify({ p_coupon_id: fx.ids.live, p_event: 'impression' }),
  });
  assert.ok(r.status >= 400, `anon must not execute the RPC (got ${r.status})`);
  assert.equal((await counter(fx.ids.live, 'impression')).count, 2, 'counter untouched');
});

// --- I–L: no direct table access for clients ------------------------------------
test('I/J/K/L: authenticated cannot INSERT, UPDATE, DELETE or SELECT the aggregate', { skip }, async () => {
  const ins = await asUser(fx.jwt, '/rest/v1/coupon_metrics_daily', {
    method: 'POST',
    body: JSON.stringify({ day: '2026-01-01', coupon_id: fx.ids.live, event: 'impression', count: 999 }),
  });
  assert.ok(ins.status >= 400, 'INSERT denied');

  const upd = await asUser(fx.jwt, `/rest/v1/coupon_metrics_daily?coupon_id=eq.${fx.ids.live}`, {
    method: 'PATCH',
    body: JSON.stringify({ count: 999 }),
  });
  assert.ok(upd.status >= 400, 'UPDATE denied');

  const del = await asUser(fx.jwt, `/rest/v1/coupon_metrics_daily?coupon_id=eq.${fx.ids.live}`, {
    method: 'DELETE',
  });
  assert.ok(del.status >= 400, 'DELETE denied');

  const sel = await asUser(fx.jwt, `/rest/v1/coupon_metrics_daily?select=count`);
  const denied = sel.status >= 400 || (Array.isArray(sel.body) && sel.body.length === 0);
  assert.ok(denied, `SELECT must expose nothing (status ${sel.status})`);

  // anon likewise sees nothing.
  const anonSel = await asAnon('/rest/v1/coupon_metrics_daily?select=count');
  const anonDenied = anonSel.status >= 400 || (Array.isArray(anonSel.body) && anonSel.body.length === 0);
  assert.ok(anonDenied, 'anon SELECT exposes nothing');

  // The trusted counter is still exactly what the RPC produced.
  assert.equal((await counter(fx.ids.live, 'impression')).count, 2);
});

// --- M: concurrency conserves every increment ----------------------------------
test('M: concurrent increments conserve the total (no lost updates)', { skip }, async () => {
  const N = 25;
  const results = await Promise.all(
    Array.from({ length: N }, () => rpcAsUser(fx.jwt, fx.ids.concurrency, 'impression')),
  );
  const accepted = results.filter((r) => r.status < 300).length;
  assert.equal(accepted, N, 'every concurrent call succeeded');
  assert.equal((await counter(fx.ids.concurrency, 'impression')).count, N);
});

// --- N/O: server owns the day; privilege manifest --------------------------------
test('N: the aggregation day is the server UTC date, not a client choice', { skip }, async () => {
  const row = await counter(fx.ids.live, 'impression');
  const serverDay = new Date().toISOString().slice(0, 10);
  assert.equal(row.day, serverDay, 'day is the server UTC date');
  // The RPC signature has no day parameter: passing one is an error.
  const r = await asUser(fx.jwt, '/rest/v1/rpc/record_coupon_event', {
    method: 'POST',
    body: JSON.stringify({
      p_coupon_id: fx.ids.live, p_event: 'impression', p_day: '2000-01-01',
    }),
  });
  assert.ok(r.status >= 400, 'a client-supplied day is not accepted');
});

test('O: privilege manifest — authenticated may execute, anon may not', { skip }, async () => {
  // Behavioural proof of the grant matrix (H covers anon; this re-proves the
  // positive side after all the negative cases above).
  const ok = await rpcAsUser(fx.jwt, fx.ids.live, 'cta_click');
  assert.ok(ok.status < 300, 'authenticated EXECUTE still granted');
  assert.equal((await counter(fx.ids.live, 'cta_click')).count, 2);
});

test('teardown: remove fixtures (metrics cascade with the coupons)', { skip }, async () => {
  await svc(`/rest/v1/coupons?slug=like.c2-${fx.ext}*`, { method: 'DELETE' });
  // FK ON DELETE CASCADE must have removed every counter with the catalog rows.
  for (const id of Object.values(fx.ids)) {
    const left = await svc(`/rest/v1/coupon_metrics_daily?coupon_id=eq.${id}&select=count`);
    assert.equal(left.body.length, 0, 'metrics cascaded away with the coupon');
  }
  await svc(`/rest/v1/coupon_categories?key=eq.${fx.categoryKey}`, { method: 'DELETE' });
  if (fx.userId) await svc(`/auth/v1/admin/users/${fx.userId}`, { method: 'DELETE' });
});

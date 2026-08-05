// MALI-060n — credential-gated real-backend checks for the process-ios-sms
// request-validation boundary. These POST to a DEPLOYED function and assert the
// front gates (body size / content-type / schema / device auth) fire BEFORE any
// paid Gemini call. They skip cleanly when no Supabase project is configured;
// the static shape (ordering, server-consent gating) is proven in
// backend_hardening_contract_test.mjs, and the bounded-body reader + policy in
// the Deno _shared tests.
import assert from 'node:assert/strict';
import test from 'node:test';

const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const live = url && anon;
const gate = { skip: live ? false : 'requires SUPABASE_URL + SUPABASE_ANON_KEY (deployed process-ios-sms)' };

const endpoint = () => `${url}/functions/v1/process-ios-sms`;
const post = (body, headers = {}) =>
  fetch(endpoint(), {
    method: 'POST',
    headers: { apikey: anon, Authorization: `Bearer ${anon}`, 'Content-Type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

test('oversized body is rejected (413) before any parse', gate, async () => {
  const res = await post({ schema_version: 1, payloadId: 'x', sanitizedText: 'A'.repeat(200000) });
  assert.equal(res.status, 413, `oversized → 413, got ${res.status}`);
});

test('malformed JSON is rejected (400)', gate, async () => {
  const res = await post('{ not valid json');
  assert.equal(res.status, 400, `malformed → 400, got ${res.status}`);
});

test('non-JSON content type is rejected (415)', gate, async () => {
  const res = await post('hello', { 'Content-Type': 'text/plain' });
  assert.equal(res.status, 415, `text/plain → 415, got ${res.status}`);
});

test('unsupported schema_version is rejected (400)', gate, async () => {
  const res = await post({ schema_version: 999, payloadId: 'x', sanitizedText: 'test' });
  assert.equal(res.status, 400, `bad schema → 400, got ${res.status}`);
});

test('a request with a wrong device secret is unauthorized (never reaches AI)', gate, async () => {
  const res = await post({
    schema_version: 1,
    payloadId: `t-${Date.now()}`,
    sanitizedText: 'اشتريت بقيمة 50',
    installId: 'not-a-real-install',
    deviceSecret: 'wrong-secret',
    allowAi: true, // forged — must not matter without a verified, consented device
  });
  assert.ok(res.status === 401 || res.status === 403, `bad secret → 401/403, got ${res.status}`);
});

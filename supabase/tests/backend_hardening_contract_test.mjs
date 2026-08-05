// MALI-075n / MALI-024 / MALI-039 — static source-contract checks for the
// Batch-5 backend hardening (migration 0072). These run WITHOUT credentials and
// prove the migration's security SHAPE; the live RLS/RPC behavior (direct-insert
// denial, per-user quota under real Postgres) is exercised by the credential-
// gated tests and remains external where no local Supabase exists.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const m0072 = read('supabase/migrations/0072_backend_security_hardening.sql');

test('metrics: the unrestricted authenticated insert is removed', () => {
  assert.match(m0072, /DROP POLICY IF EXISTS "metrics insert" ON public\.metrics/);
  assert.match(m0072, /REVOKE INSERT ON public\.metrics FROM authenticated/);
});

test('metrics: record_metric is owner-bound, allowlisted, bounded, quota-limited', () => {
  assert.match(m0072, /CREATE OR REPLACE FUNCTION public\.record_metric/);
  assert.match(m0072, /SECURITY DEFINER/);
  assert.match(m0072, /SET search_path = public/);
  assert.match(m0072, /v_uid\s+UUID\s*:=\s*auth\.uid\(\)/); // owner from auth.uid()
  assert.match(m0072, /IF v_uid IS NULL THEN RETURN/); // authenticated only
  assert.match(m0072, /c_allowed CONSTANT TEXT\[\]/); // event allowlist
  assert.match(m0072, /length\(p_metric_key\) > 64/); // bounded key
  assert.match(m0072, /length\(p_dimension\) > 128/); // bounded dimension
  assert.match(m0072, /c_daily_limit/); // per-user quota
});

test('metrics: record_metric grants — no PUBLIC/anon, authenticated only', () => {
  assert.match(m0072, /REVOKE ALL ON FUNCTION public\.record_metric\(TEXT, TEXT\) FROM PUBLIC/);
  assert.match(m0072, /REVOKE ALL ON FUNCTION public\.record_metric\(TEXT, TEXT\) FROM anon/);
  assert.match(m0072, /GRANT EXECUTE ON FUNCTION public\.record_metric\(TEXT, TEXT\) TO authenticated/);
});

test('SECURITY DEFINER search_path: dead handle_new_user dropped; prune fixed', () => {
  assert.match(m0072, /DROP FUNCTION IF EXISTS public\.handle_new_user\(\)/);
  // prune_processed_captures recreated WITH a fixed search_path + re-locked.
  const prune = m0072.slice(m0072.indexOf('FUNCTION public.prune_processed_captures'));
  assert.match(prune, /SECURITY DEFINER/);
  assert.match(prune, /SET search_path = public/);
  assert.match(m0072, /REVOKE ALL ON FUNCTION public\.prune_processed_captures\(\) FROM PUBLIC/);
  assert.match(m0072, /GRANT EXECUTE ON FUNCTION public\.prune_processed_captures\(\) TO service_role/);
});

test('metrics rate-limit table denies all direct client access', () => {
  assert.match(m0072, /metrics_rate_limits[\s\S]*ENABLE ROW LEVEL SECURITY/);
  assert.match(m0072, /CREATE POLICY metrics_rate_limits_no_direct_access[\s\S]*USING \(false\)[\s\S]*WITH CHECK \(false\)/);
});

test('client routes metrics through the RPC, never a raw table insert', () => {
  const client = read('app/lib/core/backend/metrics_client.dart');
  assert.match(client, /rpc\(\s*'record_metric'/);
  assert.doesNotMatch(client, /from\('metrics'\)\.insert/);
});

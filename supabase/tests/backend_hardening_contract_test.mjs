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

// MALI-044 — merchant-feedback secure retirement.
test('merchant-feedback is retired: requires auth, returns 410, no silent no-op', () => {
  const fn = read('supabase/functions/merchant-feedback/index.ts');
  assert.match(fn, /RETIRED/);
  assert.match(fn, /startsWith\('Bearer '\)/); // no anonymous access
  assert.match(fn, /'unauthorized'.*401|401/s);
  assert.match(fn, /'retired'.*410|410/s);
  assert.doesNotMatch(fn, /received: body\.keywords\.length/); // no silent success
  assert.doesNotMatch(fn, /^\s*\/\/ TODO: insert/m); // the no-op code is gone
});

// MALI-024 — dormant engagement authority is hardened (future path).
test('record_engagement_event derives owner server-side and rejects client authority', () => {
  const m0070 = read('supabase/migrations/0070_engagement_events.sql');
  assert.match(m0070, /v_user_id UUID := auth\.uid\(\)/); // owner from auth.uid()
  assert.match(m0070, /IF v_user_id IS NULL THEN[\s\S]*unauthenticated/);
  assert.match(m0070, /unsupported event version/); // schema version rejected
  assert.match(m0070, /unknown event type/); // unknown type rejected
  assert.match(m0070, /ON CONFLICT \(user_id, event_id\) DO NOTHING/); // idempotent
  assert.match(m0070, /SECURITY DEFINER/);
  assert.match(m0070, /SET search_path = public/);
  // The XP award is a server-side CASE — the client can never supply the amount.
  assert.match(m0070, /v_award := CASE p_event_type/);
});

// MALI-075n §7 — account purge covers the Batch 1–5 tables.
test('purge_user_data erases AI idempotency, engagement, and metrics-quota rows', () => {
  const purge = m0072.slice(m0072.indexOf('FUNCTION public.purge_user_data'));
  assert.match(purge, /DELETE FROM public\.ai_request_idempotency/);
  assert.match(purge, /owner_key = 'u:' \|\| p_user_id::text/); // user key
  assert.match(purge, /'d:' \|\| install_id_hash/); // + device keys
  assert.match(purge, /DELETE FROM public\.user_engagement_events\s+WHERE user_id = p_user_id/);
  assert.match(purge, /DELETE FROM public\.metrics_rate_limits\s+WHERE user_id = p_user_id/);
  // AI-idempotency purge must run BEFORE capture_devices are deleted.
  assert.ok(purge.indexOf('ai_request_idempotency') < purge.indexOf('DELETE FROM public.capture_devices'));
});

// MALI-024 (closure) — gamification aggregates are read-only to normal clients.
test('gamification aggregates: 0073 removes owner write policies + revokes grants', () => {
  const m0073 = read('supabase/migrations/0073_gamification_aggregate_readonly.sql');
  for (const t of ['user_xp_levels', 'user_streaks', 'user_achievements']) {
    assert.match(m0073, new RegExp(`DROP POLICY IF EXISTS ${t}_owner_insert`));
    assert.match(m0073, new RegExp(`DROP POLICY IF EXISTS ${t}_owner_update`));
    assert.match(m0073, new RegExp(`REVOKE INSERT, UPDATE, DELETE ON public\\.${t} FROM authenticated`));
  }
  // The client never writes these tables — it only reads (pull-only projection).
  const sync = read('app/lib/features/gamification/services/gamification_sync_service.dart');
  assert.doesNotMatch(sync, /user_xp_levels'\)[\s\S]{0,80}\.(insert|update|upsert)\(/);
  assert.doesNotMatch(sync, /user_streaks'\)[\s\S]{0,80}\.(insert|update|upsert)\(/);
  assert.doesNotMatch(sync, /user_achievements'\)[\s\S]{0,80}\.(insert|update|upsert)\(/);
});

// MALI-024 §5 — the active legacy award path is exactly-once per transaction.
test('evaluate-gamification claims each transaction before awarding (idempotent)', () => {
  const fn = read('supabase/functions/evaluate-gamification/index.ts');
  // The idempotency claim runs BEFORE any XP award.
  const claimIdx = fn.indexOf('gamification_awarded_transactions');
  const awardIdx = fn.indexOf('const xpAward');
  assert.ok(claimIdx > 0 && claimIdx < awardIdx, 'claim must precede award');
  assert.match(fn, /\.insert\(\{ transaction_id: String\(transaction\.id\)/);
  assert.match(fn, /if \(claim\.error \|\| !claim\.data\)[\s\S]{0,160}return new Response\('OK'\)/);
  // The ledger table denies all direct client access.
  const m0073 = read('supabase/migrations/0073_gamification_aggregate_readonly.sql');
  assert.match(m0073, /gamification_awarded_transactions[\s\S]*ENABLE ROW LEVEL SECURITY/);
  assert.match(m0073, /gamification_awarded_transactions_no_direct_access[\s\S]*USING \(false\)/);
});

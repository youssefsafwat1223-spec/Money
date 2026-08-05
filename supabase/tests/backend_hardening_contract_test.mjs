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

// MALI-024 §5 (closure) — the legacy award is EXACTLY-ONCE via a single-
// transaction RPC (claim + XP fold together), not a non-atomic claim-then-update.
test('award RPC (0074) folds claim + XP into one SECURITY DEFINER transaction', () => {
  const m0074 = read('supabase/migrations/0074_gamification_atomic_award.sql');
  assert.match(m0074, /CREATE OR REPLACE FUNCTION public\.award_gamification_for_transaction/);
  assert.match(m0074, /SECURITY DEFINER/);
  assert.match(m0074, /SET search_path = public/);
  // Ownership is verified server-side (caller identity is not trusted).
  assert.match(m0074, /WHERE id::text = p_transaction_id AND user_id = p_user_id/);
  assert.match(m0074, /'not_owner'/);
  // Claim INSERT and the XP mutation live in the SAME function body → one txn.
  const claimIdx = m0074.indexOf('INSERT INTO gamification_awarded_transactions');
  const xpIdx = m0074.indexOf('INSERT INTO user_xp_levels');
  assert.ok(claimIdx > 0 && xpIdx > claimIdx, 'claim + XP mutation must be one body');
  assert.match(m0074, /ON CONFLICT \(transaction_id\) DO NOTHING/); // atomic claim
  // Canonical result recorded atomically with the award (eligibility record).
  assert.match(m0074, /ADD COLUMN IF NOT EXISTS leveled_up/);
  assert.match(m0074, /ADD COLUMN IF NOT EXISTS achievement_code/);
  // Locked down to service_role only.
  assert.match(m0074, /REVOKE ALL ON FUNCTION public\.award_gamification_for_transaction\(TEXT, UUID\) FROM PUBLIC, anon, authenticated/);
  assert.match(m0074, /GRANT EXECUTE ON FUNCTION public\.award_gamification_for_transaction\(TEXT, UUID\) TO service_role/);
});

test('evaluate-gamification awards via the atomic RPC, pushes after commit (stable id)', () => {
  const fn = read('supabase/functions/evaluate-gamification/index.ts');
  // The Edge Function no longer claims + mutates in separate calls — it delegates
  // the whole award to the single-transaction RPC.
  assert.match(fn, /rpc\(\s*'award_gamification_for_transaction'/);
  assert.doesNotMatch(fn, /from\('user_xp_levels'\)[\s\S]{0,80}\.(update|insert)\(/);
  assert.doesNotMatch(fn, /from\('gamification_awarded_transactions'\)/);
  // Delivery is AFTER the award result, and keyed by a STABLE per-transaction id
  // (APNs collapse-id) so a retry cannot duplicate the notification.
  const awardIdx = fn.indexOf('award_gamification_for_transaction');
  const pushIdx = fn.indexOf('await sendCapturePush(');
  assert.ok(awardIdx > 0 && pushIdx > awardIdx, 'push must follow the award');
  assert.match(fn, /payloadId: `gamification:\$\{transaction\.id\}`/);
  assert.doesNotMatch(fn, /payloadId: crypto\.randomUUID\(\)/); // no per-send random id
  // The ledger table still denies all direct client access.
  const m0073 = read('supabase/migrations/0073_gamification_aggregate_readonly.sql');
  assert.match(m0073, /gamification_awarded_transactions[\s\S]*ENABLE ROW LEVEL SECURITY/);
  assert.match(m0073, /gamification_awarded_transactions_no_direct_access[\s\S]*USING \(false\)/);
});

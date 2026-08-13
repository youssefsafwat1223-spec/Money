// MALI-026 (Phase-9B) — static source-contract checks for the additive
// add_goal_contribution exact-money response fix (migration 0078). These run
// WITHOUT credentials and prove the RPC's response SHAPE + preserved security
// posture; the live behavior (exact ::text round-trip, canonical decode) is
// exercised by the Flutter canonical test and, later, the credential-gated
// staging deploy checkpoint.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const m0078 = read('supabase/migrations/0078_goal_contribution_exact_saved_amount.sql');
const m0031 = read('supabase/migrations/0031_financial_feature_children.sql');

test('0078: adds saved_amount_text via server-side NUMERIC::text (no float/double)', () => {
  assert.match(m0078, /create or replace function public\.add_goal_contribution/i);
  // exact NUMERIC -> text, taken straight from the goal row column.
  assert.match(
    m0078,
    /jsonb_build_object\('saved_amount_text',\s*goal_row\.saved_amount::text\)/,
  );
  // merged onto the existing goal jsonb with || (adds the key, drops nothing).
  assert.match(
    m0078,
    /to_jsonb\(goal_row\)\s*\|\|\s*jsonb_build_object\('saved_amount_text'/,
  );
  // no double/float coercion on the canonical path.
  assert.doesNotMatch(m0078, /::double precision|::float|to_char\(/i);
});

test('0078: legacy contract preserved — raw saved_amount still emitted, never renamed', () => {
  // goal still built from to_jsonb(goal_row), which carries the numeric saved_amount.
  assert.match(m0078, /'goal',\s*to_jsonb\(goal_row\)/);
  // the contribution member is unchanged.
  assert.match(m0078, /'contribution',\s*to_jsonb\(contribution_row\)/);
  // no drop/rename of the legacy field.
  assert.doesNotMatch(m0078, /drop column[\s\S]*saved_amount|rename[\s\S]*saved_amount/i);
});

test('0078: signature + SECURITY INVOKER + search_path identical to 0031', () => {
  const sig =
    /add_goal_contribution\(\s*p_goal_id uuid,\s*p_client_request_id text,\s*p_local_id text,\s*p_amount numeric,\s*p_created_at timestamptz,\s*p_note text default null\s*\)/;
  assert.match(m0031, sig); // baseline shape
  assert.match(m0078, sig); // preserved
  assert.match(
    m0078,
    /returns jsonb language plpgsql security invoker set search_path = public/,
  );
});

test('0078: exactly-once + ownership + transaction semantics preserved', () => {
  assert.match(m0078, /if auth\.uid\(\) is null then raise exception/);
  assert.match(
    m0078,
    /where id = p_goal_id and user_id = auth\.uid\(\) and deleted_at is null for update/,
  );
  assert.match(m0078, /on conflict \(user_id, client_request_id\) do nothing/);
  // saved_amount incremented ONLY on a fresh insert → idempotent replay is a no-op.
  assert.match(m0078, /update public\.user_goals set saved_amount = saved_amount \+ p_amount/);
});

test('0078: EXECUTE authority not broadened (revoke public,anon; grant authenticated only)', () => {
  assert.match(
    m0078,
    /revoke all on function public\.add_goal_contribution\(uuid, text, text, numeric, timestamptz, text\) from public, anon/,
  );
  assert.match(
    m0078,
    /grant execute on function public\.add_goal_contribution\(uuid, text, text, numeric, timestamptz, text\) to authenticated/,
  );
  // never grant EXECUTE back to anon or PUBLIC.
  assert.doesNotMatch(
    m0078,
    /grant execute on function public\.add_goal_contribution[\s\S]*to (anon|public)\b/i,
  );
});

test('0078: introduces NO contribution currency authority (parent goal stays sole authority)', () => {
  assert.doesNotMatch(
    m0078,
    /alter table[\s\S]*user_goal_contributions[\s\S]*add column[\s\S]*currency/i,
  );
  assert.doesNotMatch(m0078, /base_currency|account_currency|transaction_currency/i);
});

test('client canonical branch reads goal.saved_amount_text — the field 0078 now provides', () => {
  const svc = read(
    'app/lib/features/planning_sync/services/planning_child_sync_service.dart',
  );
  assert.match(
    svc,
    /moneyFromPulledValueRequired\(goal\['saved_amount_text'\], currency\)/,
  );
});

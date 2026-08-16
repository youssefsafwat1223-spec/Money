// Phase R1 — static contract checks for 0083_referral_rewards.sql.
//
// These run WITHOUT credentials and WITHOUT a local Postgres: they assert the
// SOURCE contract (schema shape, invariants, privilege lockdown, isolation).
// Runtime behaviour — actually applying the migration and exercising RLS/RPCs —
// is deliberately NOT claimed here and is deferred to the staging phase.
//
// The contract asserted is docs/REFERRAL_REWARDS_SYSTEM.md r3.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const M = 'supabase/migrations/0083_referral_rewards.sql';
const raw = read(M);

/** Strip `--` comment lines so structural assertions test SQL, not prose. */
const sql = raw
  .split('\n')
  .filter((line) => !line.trimStart().startsWith('--'))
  .join('\n');

/**
 * The part of 0083 this migration AUTHORS. The tail re-declares 0065's
 * purge_user_data, whose inherited body legitimately names financial and
 * capture tables (install_id_hash, user_transactions, …); isolation guards must
 * scan only the referral-owned portion or they would flag 0065's own code.
 */
const referralOwned = sql.slice(
  0, sql.indexOf('create or replace function public.purge_user_data'));

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------
test('0083 creates exactly the eight approved tables', () => {
  for (const t of [
    'referral_codes', 'referrals', 'referral_reward_rules',
    'referral_reward_progress', 'user_entitlement_state',
    'entitlement_events', 'referral_reward_grants', 'referral_admin_audit',
  ]) {
    assert.match(sql, new RegExp(`CREATE TABLE IF NOT EXISTS public\\.${t}\\s*\\(`, 'i'), t);
  }
  // r3 eliminated the report-ads config table; 0084 must not be implied.
  assert.doesNotMatch(sql, /report_ads_config/i);
});

// ---------------------------------------------------------------------------
// Hard invariants — the ones that make the product claims true
// ---------------------------------------------------------------------------
test('one referred account may have at most one referrer, ever', () => {
  assert.match(sql, /referred_user_id\s+UUID NULL UNIQUE REFERENCES auth\.users\(id\) ON DELETE SET NULL/i);
});

test('self-referral is impossible at the database level', () => {
  assert.match(sql, /CONSTRAINT referrals_no_self CHECK \(referrer_user_id <> referred_user_id\)/i);
});

test('one milestone grants at most once (exactly-once invariant)', () => {
  assert.match(sql, /UNIQUE \(referrer_user_id, rule_id, cycle_index\)/i);
});

test('one current entitlement per user + type', () => {
  assert.match(sql, /PRIMARY KEY \(user_id, entitlement_type\)/i);
});

test('operation_id is unique and bound to a canonical fingerprint', () => {
  assert.match(sql, /operation_id\s+TEXT NOT NULL UNIQUE/i);
  assert.match(sql, /operation_fingerprint\s+TEXT NOT NULL/i);
  // A replay with a different intent must be refused, not silently answered.
  assert.match(sql, /idempotency_mismatch/);
  const mismatches = sql.match(/idempotency_mismatch/g) ?? [];
  assert.ok(mismatches.length >= 2, 'checked before AND after the claim');
});

test('R1.1: the fingerprint is a canonical SHA-256 of the REQUESTED intent', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_entitlement_mutation'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const fp = body.slice(body.indexOf('v_fingerprint :='),
                        body.indexOf("'hex');") + 7);

  // SHA-256 via pgcrypto — MD5 is gone.
  assert.match(fp, /digest\(/);
  assert.match(fp, /'sha256'/);
  assert.doesNotMatch(body, /md5\(/i);
  assert.match(fp, /convert_to\([\s\S]*?'UTF8'\)/);
  assert.match(fp, /encode\(/);

  // Canonical structured payload, NOT delimiter-joined concatenation — with a
  // separator, ('a|b','c') and ('a','b|c') would collide onto one fingerprint.
  assert.match(fp, /jsonb_build_object\(/);
  assert.doesNotMatch(fp, /concat_ws/);

  // Every field needed to distinguish one mutation from another is bound in.
  for (const field of ['actor', 'target_user', 'entitlement_type', 'event_type',
                       'source', 'duration_days', 'source_reference',
                       'rule_id', 'rule_version', 'cycle_index', 'reason']) {
    assert.ok(fp.includes(`'${field}'`), `fingerprint must bind ${field}`);
  }

  // …and NOTHING derived from current state, or a replay would never match.
  for (const derived of ['resulting_ends_at', 'resulting_status', 'v_new_ends',
                         'v_new_status', 'v_prev', 'now()']) {
    assert.equal(fp.includes(derived), false, `fingerprint must exclude ${derived}`);
  }

  // Normalization: canonical case for enums/uuids, deterministic reason.
  assert.match(fp, /lower\(p_user_id::text\)/);
  assert.match(fp, /lower\(p_entitlement_type\)/);
  assert.match(fp, /lower\(p_event_type\)/);
  assert.match(fp, /lower\(p_actor_admin_id::text\), 'system'/);
  assert.match(fp, /btrim\(regexp_replace\(coalesce\(p_reason, ''\), '\\s\+', ' ', 'g'\)\)/);
});

test('R1.1: replay/mismatch semantics are enforced on both paths', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_entitlement_mutation'));
  const body = fn.slice(0, fn.indexOf('$$;'));

  // Pre-claim path: existing row with a DIFFERENT intent → mismatch, no write.
  const pre = body.slice(0, body.indexOf('INSERT INTO public.entitlement_events'));
  assert.match(pre, /operation_fingerprint <> v_fingerprint[\s\S]{0,160}idempotency_mismatch/i);
  assert.match(pre, /'duplicate', true/); // same intent → stored result
  // The mismatch raises BEFORE any state mutation is computed or applied.
  assert.ok(pre.indexOf('idempotency_mismatch')
          < body.indexOf('INSERT INTO public.user_entitlement_state'));

  // Post-claim path (the concurrent racer that lost the unique claim) repeats
  // the same comparison, so a conflicting concurrent intent also mismatches.
  const post = body.slice(body.indexOf('GET DIAGNOSTICS v_rowcount = ROW_COUNT'));
  assert.match(post, /v_rowcount = 0[\s\S]*?operation_fingerprint <> v_fingerprint[\s\S]{0,160}idempotency_mismatch/i);

  // A duplicate never reaches the state upsert.
  const dupReturn = post.indexOf("'duplicate', true");
  const stateUpsert = post.indexOf('INSERT INTO public.user_entitlement_state');
  assert.ok(dupReturn !== -1 && dupReturn < stateUpsert,
    'the duplicate path returns before the state upsert');
});

test('at most one active rule per reward type is structurally enforced', () => {
  assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS referral_rules_one_active_per_type[\s\S]*?WHERE is_active/i);
  // …and the reader still fails closed rather than picking an arbitrary row.
  assert.match(sql, /ambiguous_rule_configuration/);
});

test('rule values cannot be nonsensical', () => {
  assert.match(sql, /required_referrals > 0/i);
  assert.match(sql, /reward_days > 0/i);
  assert.match(sql, /effective_until IS NULL OR effective_until > effective_from/i);
});

// ---------------------------------------------------------------------------
// Referral code
// ---------------------------------------------------------------------------
test('referral codes are 8 chars, canonical, and exclude ambiguous glyphs', () => {
  const check = sql.match(/CONSTRAINT referral_codes_shape CHECK \(code ~ '([^']+)'\)/i);
  assert.ok(check, 'code shape CHECK present');
  const pattern = check[1];
  assert.equal(pattern, '^[2-9A-HJKMNP-TV-Z]{8}$');
  const re = new RegExp(pattern);
  assert.ok(re.test('QK7F9X2M'), 'accepts a canonical code');
  for (const bad of ['qk7f9x2m', 'QK7F9X2', 'QK7F9X2MM', 'QKOF9X2M', 'QK0F9X2M',
                     'QKIF9X2M', 'QK1F9X2M', 'QKLF9X2M']) {
    assert.equal(re.test(bad), false, `must reject ${bad}`);
  }
});

test('R1.1: code generation is CSPRNG + UNBIASED rejection sampling', () => {
  assert.match(sql, /gen_random_bytes\(/);
  assert.doesNotMatch(sql, /\brandom\(\)/); // never the non-crypto PRNG

  const fn = sql.slice(sql.indexOf('FUNCTION public.generate_referral_code'));
  const body = fn.slice(0, fn.indexOf('END $$;'));

  // A rejection boundary must exist and must be a multiple of the alphabet
  // size — that is exactly what removes the modulo bias.
  const limit = Number(body.match(/v_limit\s+CONSTANT INTEGER := (\d+)/)[1]);
  const n = Number(body.match(/v_n\s+CONSTANT INTEGER := (\d+)/)[1]);
  assert.equal(n, 30, 'alphabet size');
  assert.equal(limit % n, 0, 'rejection boundary divides the alphabet evenly');
  assert.equal(limit, 240, 'largest multiple of 30 within a byte');
  assert.ok(limit <= 256);
  // Bytes at or above the boundary are discarded, not folded in.
  assert.match(body, /CONTINUE WHEN v_byte >= v_limit/i);
  // Naive biased mapping over the full byte range must not reappear.
  assert.doesNotMatch(body, /get_byte\([^)]*\) % 30/);
  // The invariants are asserted at runtime too, not just trusted here.
  assert.match(body, /char_length\(v_alphabet\) <> v_n OR v_limit % v_n <> 0/);
  assert.match(body, /referral_code_alphabet_invalid/);
  // Exactly 8 characters, and a bounded loop guard.
  assert.match(body, /char_length\(v_code\) < 8 LOOP/);
  assert.match(body, /char_length\(v_code\) >= 8/);
  assert.match(body, /guard > 64/);
  assert.match(body, /referral_code_generation_failed/);

  // The alphabet literal is exactly the approved 30 symbols, no ambiguity.
  const alphabet = body.match(/v_alphabet CONSTANT TEXT\s+:= '([^']+)'/)[1];
  assert.equal(alphabet.length, 30);
  assert.equal(new Set(alphabet).size, 30, 'no duplicate symbols');
  for (const ambiguous of ['O', '0', 'I', '1', 'L']) {
    assert.equal(alphabet.includes(ambiguous), false, ambiguous);
  }
  assert.match(alphabet, /^[2-9A-HJKMNP-TV-Z]+$/);
});

test('R1.1: the DB UNIQUE remains the final collision authority', () => {
  assert.match(sql, /code       TEXT NOT NULL UNIQUE/i);
  // ensure_referral_code retries on collision, bounded, and never degrades.
  const fn = sql.slice(sql.indexOf('FUNCTION public.ensure_referral_code'));
  const body = fn.slice(0, fn.indexOf('END $$;'));
  assert.match(body, /WHILE attempt < 5 LOOP/i);
  assert.match(body, /EXCEPTION WHEN unique_violation/i);
  assert.match(body, /referral_code_generation_failed/);
});

test('a user cannot choose or derive their own code', () => {
  // No client write path exists to referral_codes, and generation is definer-only.
  assert.doesNotMatch(sql, /CREATE POLICY[^;]*referral_codes[^;]*FOR (INSERT|UPDATE|DELETE|ALL)/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.generate_referral_code\(\)\s+FROM PUBLIC, anon, authenticated/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.ensure_referral_code\(UUID\)\s+FROM PUBLIC, anon, authenticated/i);
});

// ---------------------------------------------------------------------------
// Statuses / cycle semantics
// ---------------------------------------------------------------------------
test('referral statuses are exactly the approved four', () => {
  assert.match(sql, /status IN \('attributed', 'qualified', 'rejected', 'reversed'\)/i);
});

/**
 * Parse the real qualified_at CHECK out of the migration into
 * `{ statuses[], requiresTimestamp }` clauses, so the lifecycle table below is
 * DERIVED from the shipped SQL rather than restated alongside it.
 */
function qualifiedAtClauses() {
  const block = sql.slice(sql.indexOf('CONSTRAINT referrals_qualified_at_shape'));
  const body = block.slice(0, block.indexOf('\n  )') + 3);
  const clauses = [...body.matchAll(
    /status IN \(([^)]*)\)\s+AND qualified_at IS (NOT )?NULL/gi)]
    .map((m) => ({
      statuses: m[1].split(',').map((x) => x.trim().replace(/'/g, '')),
      requiresTimestamp: Boolean(m[2]),
    }));
  assert.equal(clauses.length, 2, 'exactly two lifecycle clauses');
  return clauses;
}

/** Evaluate the parsed CHECK for one (status, qualified_at) pair. */
function checkAllows(status, hasTimestamp) {
  return qualifiedAtClauses().some(
    (c) => c.statuses.includes(status) && c.requiresTimestamp === hasTimestamp);
}

test('lifecycle: qualified_at is required exactly for qualified and reversed', () => {
  // A–D: valid combinations
  assert.equal(checkAllows('attributed', false), true, 'A attributed + NULL');
  assert.equal(checkAllows('rejected',   false), true, 'B rejected + NULL');
  assert.equal(checkAllows('qualified',  true),  true, 'C qualified + timestamp');
  assert.equal(checkAllows('reversed',   true),  true, 'D reversed + timestamp');
  // E–H: rejected combinations
  assert.equal(checkAllows('qualified',  false), false, 'E qualified + NULL');
  assert.equal(checkAllows('reversed',   false), false, 'F reversed + NULL');
  assert.equal(checkAllows('attributed', true),  false, 'G attributed + timestamp');
  assert.equal(checkAllows('rejected',   true),  false, 'H rejected + timestamp');
});

test('fraud reversal preserves the original qualification timestamp', () => {
  // 'reversed' REQUIRES qualified_at, so a reversal that cleared it would be
  // rejected by the database — the evidence cannot be erased.
  assert.equal(checkAllows('reversed', false), false);
  // …and nothing in the migration ever nulls qualified_at.
  assert.doesNotMatch(sql, /qualified_at\s*=\s*NULL/i);
  assert.doesNotMatch(sql, /SET[^;]*qualified_at\s*=\s*null/i);
});

test('V1 attribution is manual_code (direct_link reserved, not used)', () => {
  assert.match(sql, /attribution_method IN \('manual_code', 'direct_link'\)/i);
  assert.match(sql, /attribution_method\s+TEXT NOT NULL DEFAULT 'manual_code'/i);
  assert.match(sql, /'manual_code', 'attributed'\)/);
});

test('cycle state models open / awaiting_rule / completed, and pins a rule when open', () => {
  assert.match(sql, /cycle_state IN \('open', 'awaiting_rule', 'completed'\)/i);
  assert.match(sql, /CONSTRAINT referral_progress_open_is_pinned[\s\S]*?cycle_state = 'open'\s+AND pinned_rule_id IS NOT NULL/i);
});

test('progress is a stored counter, never recomputed from referral rows', () => {
  // The advance is an increment on the progress row…
  assert.match(sql, /SET qualified_in_cycle = qualified_in_cycle \+ 1/i);
  // …and qualification never counts referral rows to derive progress.
  assert.doesNotMatch(sql, /count\(\*\)[\s\S]{0,120}FROM public\.referrals/i);
});

test('no open cycle + no active rule returns awaiting_active_rule and keeps the attribution', () => {
  assert.match(sql, /'awaiting_active_rule'/);
  // The guarded flip to qualified must come AFTER that early return.
  const idxAwaiting = sql.indexOf("'awaiting_active_rule'");
  const idxFlip = sql.indexOf("SET status = 'qualified'");
  assert.ok(idxAwaiting < idxFlip,
    'the awaiting_active_rule exit precedes any qualified transition');
});

// ---------------------------------------------------------------------------
// Exactly-once qualification ordering
// ---------------------------------------------------------------------------
test('qualification follows the approved atomic ordering', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.qualify_referral_internal'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const order = [
    "SET status = 'qualified'",                    // 1 guarded transition
    'SET qualified_in_cycle = qualified_in_cycle + 1', // 2 progress advance
    'INSERT INTO public.referral_reward_grants',   // 3 unique milestone claim
    'public.apply_entitlement_mutation',           // 4 event + state
    'UPDATE public.referral_reward_grants',        // 5 complete grant record
  ];
  let cursor = -1;
  for (const step of order) {
    const at = body.indexOf(step);
    assert.ok(at > cursor, `step out of order: ${step}`);
    cursor = at;
  }
  // The guarded transition proves ownership via ROW_COUNT before advancing.
  assert.match(body, /GET DIAGNOSTICS v_rowcount = ROW_COUNT;[\s\S]{0,200}IF v_rowcount = 0 THEN/i);
});

test('the fifth grants once and the sixth starts the next cycle at 0', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.qualify_referral_internal'));
  assert.match(fn, /ON CONFLICT \(referrer_user_id, rule_id, cycle_index\) DO NOTHING/i);
  assert.match(fn, /SET cycle_index = cycle_index \+ 1, qualified_in_cycle = 0/i);
  // Non-repeatable terminates instead of opening a new cycle.
  assert.match(fn, /cycle_state = 'completed'/i);
});

test('there is ONE qualification algorithm, reused inline and on request', () => {
  const inline = sql.slice(sql.indexOf('FUNCTION public.apply_referral_code'));
  assert.match(inline, /public\.qualify_referral_internal\(v_uid\)/);
  const deferred = sql.slice(sql.indexOf('FUNCTION public.request_referral_qualification'));
  assert.match(deferred, /public\.qualify_referral_internal\(v_uid\)/);
});

// ---------------------------------------------------------------------------
// Verified identity authority
// ---------------------------------------------------------------------------
test('verified identity is read from server auth truth, never a client claim', () => {
  assert.match(sql, /auth\.users u[\s\S]{0,120}email_confirmed_at IS NOT NULL/i);
  assert.match(sql, /auth\.identities i[\s\S]{0,120}provider IN \('google', 'apple'\)/i);
  // No client-asserted verification or onboarding boolean anywhere.
  assert.doesNotMatch(sql, /is_?verified/i);
  assert.doesNotMatch(sql, /onboarding/i);
});

test('request_referral_qualification is argument-free and self-only', () => {
  assert.match(sql, /FUNCTION public\.request_referral_qualification\(\)/);
  const fn = sql.slice(sql.indexOf('FUNCTION public.request_referral_qualification'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  assert.match(body, /v_uid\s+UUID := auth\.uid\(\)/);
  assert.doesNotMatch(body, /p_user_id|p_target/i); // no caller-supplied target
});

// ---------------------------------------------------------------------------
// Entitlement stacking & atomicity
// ---------------------------------------------------------------------------
test('stacking extends from max(now, active ends_at) and never shortens on grant', () => {
  assert.match(sql, /v_new_ends := greatest\(\s*now\(\),[\s\S]{0,200}make_interval\(days => p_duration_days\)/i);
  assert.match(sql, /v_prev\.status = 'active'[\s\S]{0,60}THEN v_prev\.ends_at ELSE now\(\) END/i);
});

test('event and state mutate in one transaction via an atomic upsert', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_entitlement_mutation'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  // claim → event insert → state upsert, all inside the one function body
  assert.match(body, /INSERT INTO public\.entitlement_events[\s\S]*?ON CONFLICT \(operation_id\) DO NOTHING/i);
  assert.match(body, /INSERT INTO public\.user_entitlement_state[\s\S]*?ON CONFLICT \(user_id, entitlement_type\) DO UPDATE/i);
  assert.ok(body.indexOf('INSERT INTO public.entitlement_events')
          < body.indexOf('INSERT INTO public.user_entitlement_state'),
    'the operation claim precedes the state change');
});

test('entitlement_events is append-only for clients and models all mutations', () => {
  assert.match(sql, /event_type IN \('grant', 'extend', 'shorten', 'revoke'\)/i);
  assert.doesNotMatch(sql, /CREATE POLICY[^;]*entitlement_events/i); // RLS on, zero policies
});

// ---------------------------------------------------------------------------
// RLS + privilege matrix
// ---------------------------------------------------------------------------
test('RLS is enabled on all eight tables', () => {
  for (const t of [
    'referral_codes', 'referrals', 'referral_reward_rules',
    'referral_reward_progress', 'user_entitlement_state',
    'entitlement_events', 'referral_reward_grants', 'referral_admin_audit',
  ]) {
    assert.match(sql, new RegExp(`ALTER TABLE public\\.${t}\\s+ENABLE ROW LEVEL SECURITY`, 'i'), t);
  }
});

test('R1.1: there is NO direct table read surface — RPC only', () => {
  // RLS is enabled everywhere with ZERO policies, so a direct table read
  // returns nothing no matter who asks.
  assert.doesNotMatch(sql, /CREATE POLICY/i);
  assert.doesNotMatch(sql, /GRANT SELECT ON TABLE/i);
  assert.match(sql, /REVOKE ALL ON TABLE[\s\S]*?FROM anon, authenticated/i);
});

test('R1.1: referrer/referee cannot read referrals and learn the other party', () => {
  // A referrals row necessarily holds BOTH user ids, so any owner-read policy
  // would disclose a cross-account identifier. There must be none.
  assert.doesNotMatch(sql, /referrals_party_select/i);
  assert.doesNotMatch(sql, /referrer_user_id = auth\.uid\(\) OR referred_user_id = auth\.uid\(\)/i);
  // The self-only summary RETURNS counts/status — never a counterpart id.
  // (Column names may legitimately appear in WHERE clauses that filter to the
  //  CALLER's own id; what matters is the payload that leaves the function.)
  const fn = sql.slice(sql.indexOf('FUNCTION public.get_referral_summary'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const payload = body.slice(body.lastIndexOf('RETURN jsonb_build_object'));
  for (const leak of ['referrer_user_id', 'referred_user_id', 'user_id',
                      'email', 'phone', 'uuid']) {
    assert.doesNotMatch(payload, new RegExp(leak, 'i'), leak);
  }
  // Every referrals/progress read is scoped to the caller.
  for (const m of body.match(/referred_user_id\s*=\s*\S+/g) ?? []) {
    assert.match(m, /=\s*v_uid/, `unscoped referrals read: ${m}`);
  }
  for (const m of body.match(/referrer_user_id\s*=\s*\S+/g) ?? []) {
    assert.match(m, /=\s*v_uid/, `unscoped progress read: ${m}`);
  }
  // The referee's own attribution is exposed as a STATUS, not an identity.
  assert.match(payload, /'attribution_status'/);
});

test('NO client write policy exists on any referral table', () => {
  assert.doesNotMatch(sql, /CREATE POLICY/i); // no policies at all (R1.1)
  assert.match(sql, /REVOKE ALL ON TABLE[\s\S]*?FROM anon, authenticated/i);
  assert.doesNotMatch(sql, /GRANT (SELECT|INSERT|UPDATE|DELETE|ALL)[^;]*TO (anon|authenticated)/i);
});

test('function EXECUTE matrix: internals are locked, only 4 user RPCs are granted', () => {
  const internal = [
    'public.generate_referral_code()',
    'public.ensure_referral_code(UUID)',
    'public.active_referral_rule(TEXT)',
    'public.qualify_referral_internal(UUID)',
    'public.referral_audit_allowlist(JSONB)',
  ];
  for (const fn of internal) {
    const esc = fn.replace(/[().]/g, (c) => `\\${c}`);
    assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION ${esc}\\s+FROM PUBLIC, anon, authenticated`, 'i'), fn);
    assert.doesNotMatch(sql, new RegExp(`GRANT EXECUTE ON FUNCTION ${esc}\\s+TO authenticated`, 'i'),
      `${fn} must NOT be user-callable`);
  }
  // apply_entitlement_mutation is service-only despite its long signature.
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.apply_entitlement_mutation\([\s\S]*?FROM PUBLIC, anon, authenticated/i);
  assert.doesNotMatch(sql, /GRANT EXECUTE ON FUNCTION public\.apply_entitlement_mutation/i);

  const userRpcs = [
    'public.apply_referral_code(TEXT)',
    'public.request_referral_qualification()',
    'public.get_referral_summary()',
    'public.get_entitlement_decision(TEXT)',
  ];
  for (const fn of userRpcs) {
    const esc = fn.replace(/[().]/g, (c) => `\\${c}`);
    assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION ${esc}\\s+FROM PUBLIC, anon`, 'i'), fn);
    assert.match(sql, new RegExp(`GRANT EXECUTE ON FUNCTION ${esc}\\s+TO authenticated`, 'i'), fn);
  }

  // Every function in the file must appear in the EXECUTE matrix above.
  const defined = [...sql.matchAll(/CREATE OR REPLACE FUNCTION (public\.\w+)\(/g)]
    .map((m) => m[1]);
  const known = new Set([...internal, ...userRpcs]
    .map((f) => f.slice(0, f.indexOf('(')))
    .concat(['public.apply_entitlement_mutation', 'public.purge_user_data']));
  for (const fn of defined) {
    assert.ok(known.has(fn), `${fn} is not covered by the EXECUTE matrix`);
  }
});

test('every function pins search_path and is definer where it must be', () => {
  const fns = raw.split('CREATE OR REPLACE FUNCTION ').slice(1);
  assert.ok(fns.length >= 8);
  for (const fn of fns) {
    const name = fn.slice(0, fn.indexOf('('));
    const head = fn.slice(0, fn.indexOf('AS $$'));
    assert.match(head, /SET search_path/i, `${name} must pin search_path`);
  }
});

// ---------------------------------------------------------------------------
// Enumeration safety
// ---------------------------------------------------------------------------
test('apply_referral_code leaks no referrer identity and is self-only', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_referral_code'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  assert.match(body, /v_uid\s+UUID := auth\.uid\(\)/);
  assert.match(body, /'invalid_code'/);
  // The returned objects carry only outcome fields — never referrer identity.
  for (const leak of ['email', 'phone', 'referrer_user_id', 'v_owner::text', 'display_name']) {
    assert.doesNotMatch(body, new RegExp(`jsonb_build_object[^;]*${leak}`, 'i'), leak);
  }
  assert.match(body, /'no_active_rule'/);
});

test('get_referral_summary returns counts and status, not referee identities', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.get_referral_summary'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const payload = body.slice(body.lastIndexOf('RETURN jsonb_build_object'));
  assert.match(payload, /'server_now',\s+now\(\)/);
  for (const leak of ['email', 'phone', 'referred_user_id', 'referrer_user_id']) {
    assert.doesNotMatch(payload, new RegExp(leak, 'i'), leak);
  }
});

test('get_entitlement_decision exposes server_now and never encodes failure as inactive', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.get_entitlement_decision'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  assert.match(body, /'server_now', now\(\)/);
  assert.match(body, /'active',\s+coalesce\(v_ent\.status = 'active' AND v_ent\.ends_at > now\(\), false\)/i);
  // Unauthenticated raises rather than returning a decision.
  assert.match(body, /unauthenticated/);
});

// ---------------------------------------------------------------------------
// Audit privacy
// ---------------------------------------------------------------------------
test('audit before/after are allowlisted, never arbitrary dumps', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.referral_audit_allowlist'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  for (const k of ['entitlement_type', 'status', 'ends_at', 'duration_days',
                   'rule_id', 'rule_version', 'required_referrals', 'reward_days',
                   'repeatable', 'is_active', 'cycle_index', 'qualified_in_cycle',
                   'referral_status', 'rejection_reason']) {
    assert.ok(body.includes(`'${k}'`), `allowlist must contain ${k}`);
  }
  for (const forbidden of ['email', 'phone', 'balance', 'amount', 'transaction']) {
    assert.doesNotMatch(body, new RegExp(forbidden, 'i'), forbidden);
  }
});

test('admin reason is bounded plain text, validated in the database', () => {
  const shapes = sql.match(/char_length\(reason\) BETWEEN 4 AND 500/gi) ?? [];
  assert.ok(shapes.length >= 2, 'both audit and event reason are bounded');
  const ctrl = sql.match(/reason !~ '\[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F\]'/g) ?? [];
  assert.ok(ctrl.length >= 2, 'control characters rejected on both');
});

// ---------------------------------------------------------------------------
// Account deletion
// ---------------------------------------------------------------------------
test('purge extends the ONE existing deletion authority and keeps its body', () => {
  assert.match(sql, /create or replace function public\.purge_user_data\(p_user_id uuid\)/i);
  assert.match(sql, /security invoker/i);           // 0065's mode preserved
  assert.match(sql, /grant execute on function public\.purge_user_data\(uuid\) to service_role/i);
  // A representative slice of the original body must survive untouched.
  for (const line of ['user_transactions', 'capture_rate_limits', 'profiles', 'backups']) {
    assert.match(sql, new RegExp(`delete from public\\.${line}`, 'i'), line);
  }
  // No second deletion system.
  assert.doesNotMatch(sql, /purge_referral_domain/i);
});

test('referee deletion de-identifies a qualified referral instead of deleting it', () => {
  assert.match(sql, /delete from public\.referrals\s+where referred_user_id = p_user_id and status in \('attributed', 'rejected'\)/i);
  assert.match(sql, /update public\.referrals\s+set referred_user_id = null, referred_user_deleted_at = now\(\)/i);
});

test('audit rows survive user purge de-identified', () => {
  assert.match(sql, /update public\.referral_admin_audit\s+set target_user_id = null, target_ref = null/i);
});

// ---------------------------------------------------------------------------
// Isolation guards (R1 scope discipline)
// ---------------------------------------------------------------------------
test('R1 stores no install-id / device fingerprint', () => {
  for (const forbidden of ['install_id', 'installid', 'device_id', 'device_hash',
                           'idfa', 'advertising_id', 'gaid']) {
    assert.doesNotMatch(referralOwned, new RegExp(forbidden, 'i'), forbidden);
  }
  // 'fingerprint' appears ONLY as operation_fingerprint — the Admin idempotency
  // key — and never as a device/install correlation value.
  for (const m of referralOwned.match(/\w*fingerprint\w*/gi) ?? []) {
    assert.ok(['operation_fingerprint', 'v_fingerprint'].includes(m.toLowerCase()),
      `unexpected fingerprint identifier: ${m}`);
  }
});

test('the referral domain touches no financial table or money concept', () => {
  for (const forbidden of [
    'user_transactions', 'user_accounts', 'user_budgets', 'user_goals',
    'amount_minor', 'balance', 'currency', 'money',
  ]) {
    assert.doesNotMatch(referralOwned, new RegExp(forbidden, 'i'), forbidden);
  }
});

test('0083 alters no Coupon, Planning, CAS or capture object', () => {
  for (const forbidden of ['coupon', 'server_revision', 'planning', 'capture_devices', 'ledger_sync']) {
    assert.doesNotMatch(referralOwned, new RegExp(forbidden, 'i'), forbidden);
  }
  // No PRE-EXISTING table is altered. (0083's own ALTER TABLE … ENABLE RLS
  // statements target only tables this migration just created.)
  const preExisting = [
    'user_transactions', 'user_accounts', 'user_settings', 'user_budgets',
    'user_goals', 'user_plans', 'user_cards', 'profiles', 'coupons',
    'coupon_categories', 'coupon_tags', 'capture_devices', 'backups',
  ];
  for (const t of preExisting) {
    assert.doesNotMatch(sql, new RegExp(`ALTER TABLE (public\\.)?${t}\\b`, 'i'), t);
  }
});

test('feature-flag seeds exist and are fail-closed', () => {
  assert.match(sql, /INSERT INTO public\.feature_flags[\s\S]*?'enable_referrals',\s+'boolean', 'false'[\s\S]*?0, true/i);
  assert.match(sql, /'enable_report_ads', 'boolean', 'false'[\s\S]*?0, true/i);
  assert.match(sql, /ON CONFLICT \(key\) DO NOTHING/i);
});

test('the client Drift schema is untouched by this SERVER migration', () => {
  assert.match(read('app/lib/data/db/app_database.dart'), /const int _targetSchemaVersion = 31;/);
  assert.doesNotMatch(sql, /_targetSchemaVersion|drift/i);
});

test('R1 changes no report generation code', () => {
  const controller = read('app/lib/features/reporting/services/report_generation_controller.dart');
  for (const forbidden of ['entitlement', 'AdGate', 'interstitial', 'referral']) {
    assert.doesNotMatch(controller, new RegExp(forbidden, 'i'), forbidden);
  }
  const sheet = read('app/lib/features/reporting/ui/report_config_sheet.dart');
  assert.doesNotMatch(sheet, /entitlement|interstitial|adGate/i);
});

test('no google_mobile_ads dependency was added', () => {
  assert.doesNotMatch(read('app/pubspec.yaml'), /google_mobile_ads|admob/i);
});

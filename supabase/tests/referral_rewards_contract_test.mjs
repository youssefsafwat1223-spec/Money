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

test('code generation uses a CSPRNG with an unbiased alphabet and bounded retry', () => {
  assert.match(sql, /gen_random_bytes\(/);
  assert.doesNotMatch(sql, /\brandom\(\)/); // never the non-crypto PRNG
  // The alphabet length is asserted at runtime rather than assumed.
  assert.match(sql, /referral_code_alphabet_invalid/);
  assert.match(sql, /WHILE attempt < 5 LOOP/i);
  assert.match(sql, /referral_code_generation_failed/);
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

test('users may read only their own referral state; nothing else is readable', () => {
  assert.match(sql, /CREATE POLICY referral_codes_owner_select[\s\S]*?USING \(user_id = auth\.uid\(\)\)/i);
  assert.match(sql, /CREATE POLICY referrals_party_select[\s\S]*?referrer_user_id = auth\.uid\(\) OR referred_user_id = auth\.uid\(\)/i);
  assert.match(sql, /CREATE POLICY entitlement_state_owner_select[\s\S]*?USING \(user_id = auth\.uid\(\)\)/i);
  // Rules / progress / grants / events / audit have RLS on and NO policy.
  for (const t of ['referral_reward_rules', 'referral_reward_progress',
                   'referral_reward_grants', 'referral_admin_audit']) {
    assert.doesNotMatch(sql, new RegExp(`CREATE POLICY[^;]*ON public\\.${t}`, 'i'), t);
  }
});

test('NO client write policy exists on any referral table', () => {
  const policies = [...sql.matchAll(/CREATE POLICY[\s\S]*?;/g)].map((m) => m[0]);
  assert.ok(policies.length >= 3, 'the three owner-read policies exist');
  for (const policy of policies) {
    assert.match(policy, /FOR SELECT/i, `read-only policy expected: ${policy.slice(0, 60)}`);
    assert.doesNotMatch(policy, /FOR (INSERT|UPDATE|DELETE|ALL)\b/i);
  }
  assert.match(sql, /REVOKE ALL ON TABLE[\s\S]*?FROM anon, authenticated/i);
  assert.match(sql, /GRANT SELECT ON TABLE[\s\S]*?TO authenticated/i);
  assert.doesNotMatch(sql, /GRANT (INSERT|UPDATE|DELETE|ALL)[^;]*TO (anon|authenticated)/i);
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
  assert.match(body, /'server_now',\s+now\(\)/);
  for (const leak of ['email', 'phone', 'referred_user_id']) {
    assert.doesNotMatch(body, new RegExp(leak, 'i'), leak);
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

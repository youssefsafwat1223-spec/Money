// Cross-model audit 2026-08-23 — findings H-10 / H-11 / H-12 (Batch 13).
//
// One concurrency class: `SELECT ... FOR UPDATE` does not serialize competing
// writers when the target row does not exist yet, so two concurrent "first"
// transactions both proceed on a stale (empty) read and a later
// `ON CONFLICT DO UPDATE` clobbers one with the other's precomputed value.
//
// 0085 fixes the class with ONE primitive — `pg_advisory_xact_lock` on a
// deterministic per-authority key, taken before the read. These are STATIC
// contract checks over the EFFECTIVE (last) definition of each function folded
// across migrations in order, so they fail against the pre-0085 tree (where the
// last definition is 0083/0074 without the lock) and pass once 0085 lands.
//
// STATIC SHAPE ONLY. Genuine concurrency proof requires real concurrent
// Postgres execution (see ../tools/concurrency_absent_row_locking_live_harness.mjs);
// this file does not claim to prove locking semantics.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const migrationsDir = new URL('supabase/migrations/', root);

const migrations = readdirSync(migrationsDir)
  .filter((f) => f.endsWith('.sql'))
  .sort((a, b) => Number(a.slice(0, 4)) - Number(b.slice(0, 4)));

/** The body of the LAST `create or replace function public.<name>(` across all
 *  migrations in order — i.e. the definition that is actually in effect. */
function effectiveDefinition(name) {
  let found = null;
  for (const file of migrations) {
    const sql = readFileSync(new URL(file, migrationsDir), 'utf8');
    const re = new RegExp(
      `create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\(`,
      'gi',
    );
    let m;
    while ((m = re.exec(sql)) !== null) {
      const rest = sql.slice(m.index);
      const bodyStart = rest.search(/AS \$\$/);
      const bodyEnd = rest.indexOf('$$;', bodyStart);
      assert.ok(bodyStart > 0 && bodyEnd > bodyStart,
        `${file}: could not delimit ${name}`);
      found = { file, body: rest.slice(0, bodyEnd + 3) };
    }
  }
  assert.ok(found, `no definition of ${name} found`);
  return found;
}

const FUNCS = {
  'apply_entitlement_mutation': {
    finding: 'H-10',
    authority: "'mali_entitlement:'",
  },
  'qualify_referral_internal': {
    finding: 'H-11',
    authority: "'mali_referral_progress:'",
  },
  'award_gamification_for_transaction': {
    finding: 'H-12',
    authority: "'mali_xp:'",
  },
};

test('the effective definition of each function serializes on its authority key',
  () => {
    for (const [name, spec] of Object.entries(FUNCS)) {
      const { body, file } = effectiveDefinition(name);
      assert.match(body, /pg_advisory_xact_lock\s*\(/i,
        `${name} (${spec.finding}) must take a transaction advisory lock — ` +
        `SELECT ... FOR UPDATE cannot serialize an absent authority row ` +
        `(effective def in ${file})`);
      assert.ok(body.includes(spec.authority),
        `${name} must lock on its own authority namespace ${spec.authority}`);
      assert.match(body, /hashtextextended\(/i,
        `${name} must map the authority key into the advisory-lock space`);
    }
  });

test('each function takes exactly ONE advisory lock (uniform ordering)', () => {
  // One lock per call, acquired before any row lock, means no deadlock cycle
  // can be introduced across these functions.
  for (const name of Object.keys(FUNCS)) {
    const { body } = effectiveDefinition(name);
    const locks = (body.match(/pg_advisory_xact_lock\s*\(/gi) || []).length;
    assert.equal(locks, 1,
      `${name} must take exactly one advisory lock, found ${locks}`);
  }
});

/** Strip `--` line comments so prose like "SELECT ... FOR UPDATE below" does
 *  not match statement searches. */
function code(body) {
  return body.split('\n').map((l) => l.replace(/--.*$/, '')).join('\n');
}

test('the advisory lock precedes the specific read it protects', () => {
  // The lock must precede the read-modify-write of the AUTHORITY row it guards
  // — not necessarily the function's very first FOR UPDATE. In
  // qualify_referral_internal the first FOR UPDATE is on `referrals` (needed to
  // resolve the referrer BEFORE the referrer key is even known); the advisory
  // lock correctly precedes the `referral_reward_progress` read it protects.
  const protectedRead = {
    'apply_entitlement_mutation':
      /FROM public\.user_entitlement_state[\s\S]*?FOR UPDATE/i,
    'qualify_referral_internal':
      /FROM public\.referral_reward_progress[\s\S]*?FOR UPDATE/i,
    'award_gamification_for_transaction':
      /FROM user_xp_levels WHERE user_id/i,
  };
  for (const [name, re] of Object.entries(protectedRead)) {
    const src = code(effectiveDefinition(name).body);
    const lockAt = src.search(/pg_advisory_xact_lock/i);
    const readAt = src.search(re);
    assert.ok(lockAt > -1, `${name}: advisory lock missing`);
    assert.ok(readAt > -1, `${name}: protected read not found`);
    assert.ok(lockAt < readAt,
      `${name}: the advisory lock must precede the authority read it protects`);
  }
});

test('qualify locks the referrer AFTER resolving it, but BEFORE the progress read',
  () => {
    // Documents why the lock is not first: no deadlock is introduced because
    // the referrals-row lock (on referred_user_id) and the advisory lock (on
    // the referrer) are disjoint authorities acquired in a fixed order.
    const src = code(effectiveDefinition('qualify_referral_internal').body);
    const referralLock = src.search(/FROM public\.referrals[\s\S]*?FOR UPDATE/i);
    const advisory = src.search(/pg_advisory_xact_lock/i);
    const progressLock =
      src.search(/FROM public\.referral_reward_progress[\s\S]*?FOR UPDATE/i);
    assert.ok(referralLock < advisory && advisory < progressLock,
      'order must be: lock referral row → resolve referrer → advisory lock → ' +
      'progress read');
  });

test('H-11: an open cycle pin is never overwritten (conditional ON CONFLICT)',
  () => {
    const { body } = effectiveDefinition('qualify_referral_internal');
    // The pin update must be guarded so it only fires while the cycle is still
    // awaiting a rule — an already-open cycle keeps its original pin.
    assert.match(
      body,
      /ON CONFLICT[\s\S]*?DO UPDATE[\s\S]*?WHERE\s+public\.referral_reward_progress\.cycle_state\s*=\s*'awaiting_rule'/i,
      'the pinned-rule ON CONFLICT must not overwrite an already-open cycle',
    );
  });

test('H-10: entitlement authority key is (user, entitlement_type)', () => {
  const { body } = effectiveDefinition('apply_entitlement_mutation');
  assert.ok(
    body.includes('p_user_id::text') && body.includes('p_entitlement_type'),
    'the entitlement lock must key on BOTH the user and the entitlement type',
  );
});

test('H-12: XP authority key is per-user', () => {
  const { body } = effectiveDefinition('award_gamification_for_transaction');
  assert.ok(
    body.includes("'mali_xp:' || p_user_id::text"),
    'the XP lock must key on the user (the per-user aggregate authority row), ' +
    'not the transaction id (which the claim already serializes)',
  );
});

test('security posture is preserved (SECURITY DEFINER + unchanged search_path)',
  () => {
    // Each function must keep ITS OWN original search_path — the fix must
    // neither weaken it nor opportunistically change it. (The entitlement/qualify
    // functions use the hardened `pg_catalog, public, pg_temp`; the older award
    // function uses `public`. Preserved verbatim — hardening 0074's search_path
    // would be scope creep for a concurrency batch; noted separately.)
    const originalSearchPath = {
      'apply_entitlement_mutation': 'SET search_path = pg_catalog, public, pg_temp',
      'qualify_referral_internal': 'SET search_path = pg_catalog, public, pg_temp',
      'award_gamification_for_transaction': 'SET search_path = public',
    };
    for (const name of Object.keys(FUNCS)) {
      const { body } = effectiveDefinition(name);
      assert.match(body, /SECURITY DEFINER/i, `${name} must stay SECURITY DEFINER`);
      assert.ok(body.includes(originalSearchPath[name]),
        `${name} must keep its ORIGINAL search_path (${originalSearchPath[name]})`);
    }
  });

test('0085 restates the locked-down ACLs (no privilege broadened)', () => {
  const sql = readFileSync(
    new URL('supabase/migrations/0085_concurrency_absent_row_locking.sql', root),
    'utf8',
  );
  // Internal-only functions revoked from everyone including service_role.
  assert.match(sql,
    /REVOKE ALL ON FUNCTION public\.qualify_referral_internal\(UUID\)[\s\S]*?FROM PUBLIC, anon, authenticated, service_role/i);
  assert.match(sql,
    /REVOKE ALL ON FUNCTION public\.apply_entitlement_mutation\([\s\S]*?FROM PUBLIC, anon, authenticated, service_role/i);
  // The award RPC: service_role only.
  assert.match(sql,
    /GRANT EXECUTE ON FUNCTION public\.award_gamification_for_transaction\(TEXT, UUID\)\s*\n?\s*TO service_role/i);
  // Must NOT grant these to authenticated/anon.
  assert.doesNotMatch(sql,
    /GRANT EXECUTE ON FUNCTION public\.qualify_referral_internal[\s\S]*?TO (anon|authenticated)/i);
});

test('0085 is a forward fix — the ORIGINAL function bodies are unpatched', () => {
  // The fix must live in 0085, not by mutating 0083/0074. Note 0083 already
  // uses pg_advisory_xact_lock in the rule-PUBLISHER path (referral_rule_publish)
  // — that is pre-existing and legitimate — so this asserts the SPECIFIC
  // fixed functions were not edited in place, not that the string is absent.
  const defs0083 = new RegExp(
    'create\\s+or\\s+replace\\s+function\\s+public\\.' +
    '(apply_entitlement_mutation|qualify_referral_internal)\\s*\\(', 'gi');
  const m0083 = readFileSync(
    new URL('supabase/migrations/0083_referral_rewards.sql', root), 'utf8');
  let m;
  while ((m = defs0083.exec(m0083)) !== null) {
    const rest = m0083.slice(m.index);
    const bodyEnd = rest.indexOf('$$;');
    const body = rest.slice(0, bodyEnd);
    assert.ok(!body.includes('pg_advisory_xact_lock'),
      `${m[1]} in 0083 must remain untouched — the fix is forward in 0085`);
  }
  const m0074 = readFileSync(
    new URL('supabase/migrations/0074_gamification_atomic_award.sql', root), 'utf8');
  assert.ok(!m0074.includes('pg_advisory_xact_lock'),
    '0074 must remain untouched (the fix is forward in 0085)');
});

test('0085 documents the 0084-before-0085 rollout dependency', () => {
  const sql = readFileSync(
    new URL('supabase/migrations/0085_concurrency_absent_row_locking.sql', root),
    'utf8',
  );
  assert.match(sql, /apply 0084 BEFORE 0085/i,
    'the migration order dependency must be explicit');
  assert.match(sql, /SOURCE-ONLY/i);
});

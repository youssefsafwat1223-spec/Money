// Remediation Round 2 / RB5 / H-24 residual -- STATIC migration contract.
//
// A pre-deletion JWT remains valid after auth.users deletion. Migration 0086
// must therefore make the backups Storage write policy consult auth.users, not
// merely compare auth.uid() with the object prefix. These checks exercise the
// actual migration source without credentials or real Storage.
//
// NON-VACUITY: the same policy validator is run against the pre-0086 effective
// policy source (0010) and is required to reject both historical write policies.
// LIVE enforcement -- presenting a real deleted-user JWT to deployed Storage
// and observing INSERT/UPDATE rejection -- remains EXTERNAL evidence and is
// intentionally pending an authorized project with 0086 deployed.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const migrationsDir = new URL('supabase/migrations/', root);
const migrationName = '0086_backups_owner_liveness.sql';
const m0086 = readFileSync(new URL(migrationName, migrationsDir), 'utf8');
const m0010 = readFileSync(
  new URL('0010_backups_bucket.sql', migrationsDir),
  'utf8',
);

function policyDefinition(sql, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = sql.match(
    new RegExp(`create\\s+policy\\s+"${escaped}"[\\s\\S]*?;`, 'i'),
  );
  assert.ok(match, `missing policy definition: ${name}`);
  return match[0];
}

function occurrences(source, expression) {
  return [...source.matchAll(expression)].length;
}

function assertBarrierPolicy(policy, label, requiredChecks) {
  assert.match(
    policy,
    /bucket_id\s*=\s*'backups'/i,
    `${label}: backups bucket constraint missing`,
  );
  assert.ok(
    occurrences(
      policy,
      /\(storage\.foldername\(name\)\)\s*\[1\]\s*=\s*auth\.uid\(\)::text/gi,
    ) >= requiredChecks,
    `${label}: per-uid first-path-segment check missing from a write predicate`,
  );
  assert.ok(
    occurrences(policy, /public\.backups_owner_is_live\(\)/gi) >=
      requiredChecks,
    `${label}: Auth-user liveness check missing from a write predicate`,
  );
}

test('migration numbers are unique and strictly increasing', () => {
  // Originally "0086 is the highest migration". That is a SNAPSHOT, not an
  // invariant: it must fail every time a migration is legitimately added, which
  // trains people to edit the assertion rather than read it. The real contract
  // is that numbers are never reused and never go backwards — an out-of-order
  // or duplicated number silently changes apply order between environments.
  const numbers = readdirSync(migrationsDir)
    .filter((file) => file.endsWith('.sql'))
    .map((file) => Number(file.slice(0, 4)))
    .sort((a, b) => a - b);

  assert.equal(
    new Set(numbers).size,
    numbers.length,
    'a migration number is reused — apply order becomes environment-dependent',
  );
  for (let i = 1; i < numbers.length; i++) {
    assert.ok(numbers[i] > numbers[i - 1], `non-increasing at ${numbers[i]}`);
  }
  assert.equal(
    readdirSync(migrationsDir).filter((f) => f.startsWith('0086_')).length,
    1,
    'migration number 0086 must not be reused',
  );
  assert.ok(
    readdirSync(migrationsDir).includes(migrationName),
    '0086 must still exist',
  );
});

test('0086 defines a locked-down SECURITY DEFINER liveness helper', () => {
  const definition = m0086.match(
    /create\s+or\s+replace\s+function\s+public\.backups_owner_is_live\s*\(\)[\s\S]*?\$\$\s*;/i,
  )?.[0];
  assert.ok(definition, 'backups_owner_is_live() definition is missing');
  assert.match(definition, /returns\s+boolean/i);
  assert.match(definition, /security\s+definer/i);
  assert.match(
    definition,
    /set\s+search_path\s*=\s*pg_catalog\s+as\s+\$\$/i,
    'helper search_path must be pinned to pg_catalog only',
  );
  assert.match(definition, /select\s+exists\s*\(/i);
  assert.match(definition, /from\s+auth\.users\s+as\s+u/i);
  assert.match(
    definition,
    /u\.id\s*=\s*\(\s*select\s+auth\.uid\(\)\s*\)/i,
  );
  assert.match(
    definition,
    /for\s+key\s+share/i,
    'helper must serialize a write that races Auth deletion',
  );

  assert.match(
    m0086,
    /revoke\s+all\s+on\s+function\s+public\.backups_owner_is_live\(\)\s+from\s+public\s*;/i,
  );
  assert.match(
    m0086,
    /revoke\s+all\s+on\s+function\s+public\.backups_owner_is_live\(\)\s+from\s+anon\s*;/i,
  );
  assert.match(
    m0086,
    /revoke\s+all\s+on\s+function\s+public\.backups_owner_is_live\(\)\s+from\s+authenticated\s*;/i,
  );
  assert.match(
    m0086,
    /grant\s+execute\s+on\s+function\s+public\.backups_owner_is_live\(\)\s+to\s+authenticated\s*;/i,
  );
  assert.doesNotMatch(
    m0086,
    /grant\s+execute\s+on\s+function\s+public\.backups_owner_is_live\(\)\s+to\s+(?:public|anon)\b/i,
  );
});

test('0086 INSERT and UPDATE policies retain prefix ownership and add liveness', () => {
  const insert = policyDefinition(m0086, 'own backup objects write');
  const update = policyDefinition(m0086, 'own backup objects update');

  assert.match(insert, /for\s+insert\s+to\s+authenticated/i);
  assert.match(insert, /with\s+check\s*\(/i);
  assertBarrierPolicy(insert, 'INSERT policy', 1);

  assert.match(update, /for\s+update\s+to\s+authenticated/i);
  assert.match(update, /using\s*\(/i);
  assert.match(update, /with\s+check\s*\(/i);
  assertBarrierPolicy(update, 'UPDATE USING/WITH CHECK', 2);
});

test('contract is non-vacuous: both pre-0086 policies fail its liveness rule', () => {
  const historicalInsert = policyDefinition(
    m0010,
    'own backup objects write',
  );
  const historicalUpdate = policyDefinition(
    m0010,
    'own backup objects update',
  );

  // Prove these are the real old ownership policies, then prove the new
  // validator rejects them for precisely the missing Auth-row barrier.
  assert.match(historicalInsert, /storage\.foldername\(name\)/i);
  assert.match(historicalUpdate, /storage\.foldername\(name\)/i);
  assert.throws(
    () => assertBarrierPolicy(historicalInsert, 'historical INSERT', 1),
    /Auth-user liveness check missing/,
  );
  assert.throws(
    () => assertBarrierPolicy(historicalUpdate, 'historical UPDATE', 1),
    /Auth-user liveness check missing/,
  );
});

test('0086 is forward-only and does not alter backup read/delete authority', () => {
  assert.doesNotMatch(m0010, /backups_owner_is_live/i,
    'historical migration 0010 must remain unpatched');
  assert.doesNotMatch(
    m0086,
    /(?:drop|alter|create)\s+policy\s+(?:if\s+exists\s+)?"own backup objects (?:read|delete)"/i,
    '0086 must not touch the backups SELECT or DELETE policies',
  );
});

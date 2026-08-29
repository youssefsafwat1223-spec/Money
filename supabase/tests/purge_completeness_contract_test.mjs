// Cross-model audit 2026-08-23 — findings C-3 (CRITICAL) and H-14 (HIGH).
//
// `purge_user_data()` is the ONE account-deletion authority. It has been
// re-created by several migrations, and 0083 re-created it from the **0065**
// body instead of the current (0072) one — silently dropping four deletions
// while its own comment claimed the body was "reproduced verbatim".
//
// The existing suites could not catch that: backend_hardening_contract_test
// extracts the definition from 0072 (now obsolete), and
// referral_rewards_contract_test spot-checks four representative tables in
// 0083. Both stayed green.
//
// The invariant enforced here is ORDER-AWARE and regression-proof: fold every
// migration in numeric order, and require that each successive definition of
// purge_user_data deletes from a SUPERSET of the previous one's tables. A body
// copied from an older revision then fails automatically, whatever the reason.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const migrationsDir = new URL('supabase/migrations/', root);

const migrationFiles = readdirSync(migrationsDir)
  .filter((f) => f.endsWith('.sql'))
  .sort((a, b) => Number(a.slice(0, 4)) - Number(b.slice(0, 4)));

/** Every `create or replace function public.purge_user_data` body, in order. */
function purgeDefinitions() {
  const defs = [];
  for (const file of migrationFiles) {
    const sql = readFileSync(new URL(file, migrationsDir), 'utf8');
    const re =
      /create\s+or\s+replace\s+function\s+public\.purge_user_data\s*\(/gi;
    let match;
    while ((match = re.exec(sql)) !== null) {
      // Body runs to the closing `$$;` of this function.
      const rest = sql.slice(match.index);
      const end = rest.search(/\n\$\$\s*;/);
      assert.ok(end > 0, `${file}: unterminated purge_user_data body`);
      defs.push({ file, body: rest.slice(0, end) });
    }
  }
  return defs;
}

/** Tables this definition removes rows from (delete-from targets only). */
function deletedTables(body) {
  const tables = new Set();
  const re = /delete\s+from\s+public\.([a-z0-9_]+)/gi;
  let m;
  while ((m = re.exec(body)) !== null) tables.add(m[1].toLowerCase());
  return tables;
}

test('purge_user_data is defined at least twice (it is re-created over time)', () => {
  const defs = purgeDefinitions();
  assert.ok(
    defs.length >= 2,
    `expected multiple purge_user_data definitions, found ${defs.length}`,
  );
});

// Applied migrations are immutable, so the ONE historical regression cannot be
// edited away — it is recorded here exactly, and repaired forward by 0084.
// The entry is deliberately exact: if 0083 turns out to have dropped anything
// beyond these four, this guard still fails.
const KNOWN_HISTORICAL_REGRESSIONS = {
  '0083_referral_rewards.sql': [
    'ai_request_idempotency',
    'gamification_awarded_transactions',
    'metrics_rate_limits',
    'user_engagement_events',
  ],
};

test('no re-definition of purge_user_data may delete FEWER tables than before', () => {
  const defs = purgeDefinitions();
  const regressions = [];
  let cumulative = new Set();

  for (const def of defs) {
    const current = deletedTables(def.body);
    const dropped = [...cumulative].filter((t) => !current.has(t)).sort();
    const known = (KNOWN_HISTORICAL_REGRESSIONS[def.file] ?? []).slice().sort();
    if (dropped.length && JSON.stringify(dropped) !== JSON.stringify(known)) {
      regressions.push(
        `${def.file} stopped deleting: ${dropped.join(', ')}`,
      );
    }
    cumulative = new Set([...cumulative, ...current]);
  }

  assert.deepEqual(
    regressions,
    [],
    'a later migration re-created purge_user_data from an OLDER body and lost ' +
      'deletions — account deletion would leave identity-bearing rows behind ' +
      `(audit C-3):\n${regressions.join('\n')}`,
  );
});

test('every known historical regression is repaired by the final definition', () => {
  // The allowlist above tolerates history; it must never become a way to leave
  // a table permanently unpurged.
  const defs = purgeDefinitions();
  const final = deletedTables(defs[defs.length - 1].body);
  const unrepaired = Object.entries(KNOWN_HISTORICAL_REGRESSIONS).flatMap(
    ([file, tables]) =>
      tables.filter((t) => !final.has(t)).map((t) => `${file}: ${t}`),
  );
  assert.deepEqual(
    unrepaired,
    [],
    `tolerated as history but never restored:\n${unrepaired.join('\n')}`,
  );
});

test('the FINAL definition deletes every table 0072 introduced', () => {
  // These four are exactly what 0083 dropped. Three of them have no auth FK, so
  // deleting auth.users cannot reach them; they survive erasure entirely.
  const required = [
    'ai_request_idempotency',
    'user_engagement_events',
    'metrics_rate_limits',
    'gamification_awarded_transactions',
  ];
  const defs = purgeDefinitions();
  const final = defs[defs.length - 1];
  const tables = deletedTables(final.body);
  const missing = required.filter((t) => !tables.has(t));
  assert.deepEqual(
    missing,
    [],
    `${final.file} (the effective definition) never deletes: ${missing.join(', ')}`,
  );
});

test('the FINAL definition removes AI idempotency before its device anchor', () => {
  // ai_request_idempotency resolves `d:<installHash>` through capture_devices,
  // so deleting the devices first would strand those rows.
  const defs = purgeDefinitions();
  const body = defs[defs.length - 1].body;
  const ai = body.search(/delete\s+from\s+public\.ai_request_idempotency/i);
  const devices = body.search(/delete\s+from\s+public\.capture_devices/i);
  assert.ok(ai > 0 && devices > 0, 'both deletions must be present');
  assert.ok(
    ai < devices,
    'ai_request_idempotency must be purged BEFORE capture_devices',
  );
});

test('H-14: purge de-identifies admin audit free text, not just the target ids', () => {
  const defs = purgeDefinitions();
  const body = defs[defs.length - 1].body;
  const update = body.slice(
    body.search(/update\s+public\.referral_admin_audit/i),
  );
  assert.ok(
    /target_user_id\s*=\s*null/i.test(update),
    'target_user_id must be nulled',
  );
  assert.ok(/target_ref\s*=\s*null/i.test(update), 'target_ref must be nulled');
  // `reason` is NOT NULL with a length CHECK, so it must be REDACTED.
  assert.ok(
    /reason\s*=\s*'/i.test(update),
    'operator-entered `reason` must be redacted — it is unvalidated free text ' +
      'and routinely contains an email/phone/code/uuid (audit H-14)',
  );
  assert.ok(
    /before_state\s*=\s*null/i.test(update) &&
      /after_state\s*=\s*null/i.test(update),
    'both state snapshots must be cleared — rejection_reason is copied into ' +
      'after_state',
  );
});

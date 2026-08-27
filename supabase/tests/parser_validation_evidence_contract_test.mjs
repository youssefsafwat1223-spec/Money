// C-1 — static contract checks for the parser-validation evidence invariant.
//
// The defect these guard (QIRSH_MASTER_PLAN_V2.md §10.1):
//   `catalog-delta` refuses to serve parsers unless validation_status='passed',
//   but `0004_parser_lab.sql:15` blanket-stamped every pre-existing parser
//   'passed' without running a golden test. Combined with F-016 (catalog rules
//   became the first parsing authority) an untested admin regex could set
//   CONFIRMED money on the automatic capture path.
//
// Invariant asserted here: "passed" must require EVIDENCE, both in the stored
// data (0087) and at the serving gate (catalog-delta). These run WITHOUT
// credentials — they assert the committed contract, not a live database.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');

const stripComments = (sql) =>
  sql
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('--'))
    .join('\n');

const migrationRaw = read('supabase/migrations/0087_parser_validation_evidence.sql');
const migration = stripComments(migrationRaw);
const edge = read('supabase/functions/catalog-delta/index.ts');

test('0087 returns evidence-free "passed" parsers to pending', () => {
  assert.match(
    migration,
    /UPDATE\s+public\.sms_parsers[\s\S]*?SET\s+validation_status\s*=\s*'pending'/i,
    'migration must reset the backfilled rows',
  );
  assert.match(
    migration,
    /validated_at\s+IS\s+NULL\s+OR\s+golden_test_count\s*=\s*0/i,
    'the reset must target exactly the evidence-free rows, not every parser',
  );
});

test('0087 preserves a pre-image so the reset is exactly reversible', () => {
  assert.match(
    migration,
    /CREATE TABLE IF NOT EXISTS public\.sms_parsers_validation_reset_0087/i,
  );
  assert.match(
    migration,
    /INSERT INTO public\.sms_parsers_validation_reset_0087/i,
    'rows must be recorded BEFORE they are mutated',
  );
  assert.ok(
    migrationRaw.includes('ROLLBACK'),
    'an irreversible-looking data migration must ship its inverse',
  );
});

test('0087 makes "passed requires evidence" structural, not conventional', () => {
  assert.match(
    migration,
    /ADD CONSTRAINT\s+sms_parsers_passed_requires_evidence[\s\S]*?CHECK\s*\(/i,
    'a comment or a one-off UPDATE is not an invariant — it needs a constraint',
  );
  assert.match(
    migration,
    /validation_status\s*<>\s*'passed'\s*OR\s*\(\s*validated_at IS NOT NULL AND golden_test_count > 0\s*\)/i,
  );
});

test('the reset runs before the constraint is added', () => {
  const resetAt = migration.search(/SET\s+validation_status\s*=\s*'pending'/i);
  const constraintAt = migration.search(/ADD CONSTRAINT\s+sms_parsers_passed_requires_evidence/i);
  assert.ok(resetAt > -1 && constraintAt > -1);
  assert.ok(
    resetAt < constraintAt,
    'adding the CHECK first would fail validation against the backfilled rows',
  );
});

test('catalog-delta requires evidence, not just the status label', () => {
  const gate = edge.slice(
    edge.indexOf("category === 'parsers'"),
    edge.indexOf("category === 'parsers'") + 600,
  );
  assert.match(gate, /\.eq\(\s*'validation_status'\s*,\s*'passed'\s*\)/);
  assert.match(
    gate,
    /\.not\(\s*'validated_at'\s*,\s*'is'\s*,\s*null\s*\)/,
    'a manual status flip must not be able to serve an untested rule',
  );
  assert.match(gate, /\.gt\(\s*'golden_test_count'\s*,\s*0\s*\)/);
});

test('the 0004 blanket backfill is still present and unmodified', () => {
  // If someone "fixes" C-1 by editing history instead of adding 0087, the
  // deployed databases keep the bad data while the repo looks clean.
  const legacy = read('supabase/migrations/0004_parser_lab.sql');
  assert.match(
    legacy,
    /UPDATE sms_parsers SET validation_status = 'passed'/,
    'applied migrations must never be rewritten — 0087 is the forward fix',
  );
});

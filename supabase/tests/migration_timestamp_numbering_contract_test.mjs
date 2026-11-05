import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const version = '20261105122315';
const migrationName = `${version}_persist_transaction_achievement_badges.sql`;
const root = new URL('../../', import.meta.url);
const lint = new URL('supabase/tools/check_migrations.sh', root);
function check(names) {
  const dir = mkdtempSync(join(tmpdir(), 'migration-numbering-'));
  try {
    for (const name of names) writeFileSync(join(dir, name), '-- fixture\n');
    return spawnSync('bash', [lint.pathname, dir], {encoding:'utf8'});
  } finally {
    rmSync(dir, {recursive:true,force:true});
  }
}

test('generated remote timestamp can follow the legacy chain without rewriting server history', () => {
  const result = check(['0001_fixture.sql','0002_fixture.sql',migrationName]);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /0001\.\.0002, 1 timestamped/);
});

test('allowing timestamp migrations still rejects gaps and duplicate sequential versions', () => {
  for (const names of [
    ['0001_fixture.sql','0003_gap.sql',migrationName],
    ['0001_fixture.sql','0001_duplicate.sql',migrationName],
  ]) {
    const result = check(names);
    assert.notEqual(result.status,0,'invalid legacy chain must fail');
    assert.match(result.stderr, /gap in migration numbers|duplicate migration number/);
  }
});

test('duplicate timestamp versions are rejected even with different names', () => {
  const result = check(['0001_fixture.sql',migrationName,`${version}_duplicate.sql`]);
  assert.notEqual(result.status,0);
  assert.match(result.stderr, new RegExp(`duplicate migration number: ${version}`));
});

test('badge migration and rollback retain the server-generated version', () => {
  const migration = readFileSync(new URL(`supabase/migrations/${migrationName}`,root),'utf8');
  const rollback = readFileSync(new URL(`supabase/rollback/${migrationName.replace('.sql','_rollback.sql')}`,root),'utf8');
  assert.match(migration, /INSERT INTO public\.user_achievements/);
  assert.match(rollback, /perform account_fence\.admit\(p_user_id\)/i);
});

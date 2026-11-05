#!/usr/bin/env node
// Real Postgres regression proof on a disposable, socket-only local cluster.
// Runs the production award function and deletion-admission helpers against a
// minimal schema; does not contact Supabase or load application credentials.
// PG_BINDIR=/path/to/postgres/bin node --test <this file>
import assert from 'node:assert/strict';
import { execFile, execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import test from 'node:test';

const run = promisify(execFile);
const bin = process.env.PG_BINDIR ?? '/opt/homebrew/opt/postgresql@17/bin';
const dir = mkdtempSync(join(tmpdir(), 'qirsh-badges-pg-'));
const data = join(dir, 'data');
const source = readFileSync(new URL('../migrations/0117_account_deletion_fence.sql', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../migrations/20261105122315_persist_transaction_achievement_badges.sql', import.meta.url), 'utf8');
function definition(name) {
  const start = source.search(new RegExp(`^create (?:or replace )?function ${name.replaceAll('.', '\\.')}\\(`, 'im'));
  assert.ok(start >= 0, `missing ${name}`);
  const rest = source.slice(start);
  const body = rest.search(/\bas\s+\$\$/i);
  assert.ok(body >= 0, `missing body of ${name}`);
  const end = rest.indexOf('$$;', body + 5);
  assert.ok(end >= 0, `missing terminator of ${name}`);
  return rest.slice(0, end + 3);
}
const args = ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', dir, '-p', '55439', '-d', 'postgres'];
const sql = (query) => execFileSync(join(bin, 'psql'), args, { input: query, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
const value = (query) => JSON.parse(sql(query));
const uid = () => randomUUID();
function seed(n) {
  const id = uid();
  sql(`INSERT INTO auth.users VALUES ('${id}');
    INSERT INTO public.user_transactions(id,user_id)
      SELECT '${id}-' || n, '${id}' FROM generate_series(1,${n}) n;`);
  return id;
}
const award = (id, n) => value(`SELECT public.award_gamification_for_transaction('${id}-${n}', '${id}');`);
const state = (id) => value(`SELECT jsonb_build_object(
  'xp', (SELECT xp FROM user_xp_levels WHERE user_id='${id}'),
  'level', (SELECT level FROM user_xp_levels WHERE user_id='${id}'),
  'claims', (SELECT count(*) FROM gamification_awarded_transactions WHERE user_id='${id}'),
  'badges', (SELECT coalesce(jsonb_agg(achievement_key ORDER BY achievement_key),'[]'::jsonb)
    FROM user_achievements WHERE user_id='${id}' AND deleted_at IS NULL));`);
let started = false;
try {
  execFileSync(join(bin, 'initdb'), ['-D', data, '-A', 'trust', '--no-locale', '--encoding=UTF8'], { stdio: 'pipe' });
  execFileSync(join(bin, 'pg_ctl'), ['-D', data, '-l', join(dir, 'postgres.log'), '-o', `-k ${dir} -p 55439 -h ''`, '-w', 'start'], { stdio: 'pipe' });
  started = true;
  sql(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
    CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY);
    CREATE SCHEMA account_fence;
    CREATE TABLE account_fence.deletion_job(uid uuid, state text);
    CREATE TABLE public.user_transactions(id text PRIMARY KEY, user_id uuid);
    CREATE TABLE public.user_xp_levels(user_id uuid PRIMARY KEY, xp int, level int, updated_at timestamptz);
    CREATE TABLE public.gamification_awarded_transactions(
      transaction_id text PRIMARY KEY,user_id uuid NOT NULL,awarded_at timestamptz NOT NULL DEFAULT now(),
      leveled_up boolean NOT NULL DEFAULT false,new_level int,achievement_code text);
    CREATE SEQUENCE public.badge_seq;
    CREATE TABLE public.user_achievements(
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
      achievement_key text NOT NULL,unlocked_at timestamptz NOT NULL DEFAULT now(),deleted_at timestamptz,
      sync_seq bigint DEFAULT nextval('public.badge_seq'),UNIQUE(user_id,achievement_key));
    ${['auth_user_exists', 'deny', 'gate_key', 'is_pending', 'admit'].map(n => definition(`account_fence.${n}`)).join('\n')}
    ${definition('public.award_gamification_for_transaction')}`);
  const historic = seed(16);
  await test('reproduce: old RPC awards 160 XP but saves no badges for a synced batch', () => {
    for (let n = 16; n >= 1; n--) award(historic, n);
    assert.deepEqual(state(historic), { xp: 160, level: 2, claims: 16, badges: [] });
    sql(`UPDATE gamification_awarded_transactions SET awarded_at='2026-01-01'::timestamptz +
      split_part(transaction_id,'-',6)::int * interval '1 hour' WHERE user_id='${historic}';`);
  });
  const pending = seed(1);
  award(pending, 1);
  sql(`INSERT INTO account_fence.deletion_job VALUES ('${pending}','pending');`);
  const gone = uid();
  sql(`INSERT INTO gamification_awarded_transactions(transaction_id,user_id) VALUES ('gone','${gone}');`);
  const tombstone = seed(1);
  award(tombstone, 1);
  sql(`INSERT INTO user_achievements(user_id,achievement_key,unlocked_at,deleted_at)
    VALUES ('${tombstone}','first_transaction','2025-01-01','2025-02-01');`);

  await test('migration backfills original earned dates, preserves XP, skips deleting/gone users and tombstones', () => {
    sql(migration);
    assert.deepEqual(state(historic), { xp: 160, level: 2, claims: 16, badges: ['first_transaction', 'tenth_transaction'] });
    assert.deepEqual(state(pending).badges, []);
    assert.equal(sql(`SELECT count(*) FROM user_achievements WHERE user_id='${gone}';`), '0');
    assert.deepEqual(state(tombstone).badges, []);
    assert.equal(sql(`SELECT count(*) FROM user_achievements a JOIN (
      SELECT user_id,awarded_at,row_number() OVER(PARTITION BY user_id ORDER BY awarded_at,transaction_id) n
      FROM gamification_awarded_transactions) l ON l.user_id=a.user_id
      WHERE a.user_id='${historic}' AND l.n=CASE a.achievement_key WHEN 'first_transaction' THEN 1 ELSE 10 END
        AND a.unlocked_at=l.awarded_at;`), '2');
    const before = sql('SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM user_achievements a;');
    sql(migration);
    assert.equal(sql('SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM user_achievements a;'), before, 'backfill must be idempotent');
  });

  await test('1/9/10/99/100 awarded operations persist exactly the earned milestones, even out of order', () => {
    const id = seed(100);
    for (let count = 1; count <= 100; count++) {
      const n = 101 - count;
      const result = award(id, n);
      const key = { 1: 'first_transaction', 10: 'tenth_transaction', 100: 'century_transaction' }[count] ?? null;
      assert.equal(result.achievement, key);
      if ([1,9,10,99,100].includes(count)) {
        const s = state(id);
        assert.equal(s.xp, count * 10);
        assert.equal(s.badges.length, count >= 100 ? 3 : count >= 10 ? 2 : 1);
      }
      if (key) {
        const before = sql(`SELECT to_jsonb(a) FROM user_achievements a WHERE user_id='${id}' AND achievement_key='${key}';`);
        const replay = award(id, n);
        assert.equal(replay.duplicate, true);
        assert.equal(replay.achievement, key);
        assert.equal(state(id).xp, count * 10);
        assert.equal(sql(`SELECT to_jsonb(a) FROM user_achievements a WHERE user_id='${id}' AND achievement_key='${key}';`), before);
      }
    }
  });

  await test('a badge write failure rolls back XP and claim; retry succeeds exactly once', () => {
    const id = seed(1);
    sql(`CREATE FUNCTION public.reject_test_badge() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test badge failure'; END $$;
      CREATE TRIGGER reject_test_badge BEFORE INSERT ON user_achievements
      FOR EACH ROW EXECUTE FUNCTION public.reject_test_badge();`);
    assert.throws(() => award(id,1), /test badge failure/);
    assert.deepEqual(state(id), { xp: null, level: null, claims: 0, badges: [] });
    sql('DROP TRIGGER reject_test_badge ON user_achievements; DROP FUNCTION public.reject_test_badge();');
    assert.equal(award(id,1).achievement, 'first_transaction');
    assert.equal(award(id,1).duplicate, true);
    assert.equal(state(id).xp, 10);
  });

  await test('ownership, deletion admission and service-only execution remain enforced', () => {
    const id = seed(1);
    assert.equal(value(`SELECT public.award_gamification_for_transaction('${id}-1','${historic}');`).reason, 'not_owner');
    assert.equal(state(id).claims, 0);
    assert.throws(() => award(pending,1), /account_deletion_pending/);
    assert.throws(() => value(`SELECT public.award_gamification_for_transaction('gone','${gone}');`), /account_gone/);
    for (const role of ['anon','authenticated']) {
      assert.equal(sql(`SELECT has_function_privilege('${role}','public.award_gamification_for_transaction(text,uuid)','EXECUTE');`), 'f');
    }
    assert.equal(sql("SELECT has_function_privilege('service_role','public.award_gamification_for_transaction(text,uuid)','EXECUTE');"), 't');
  });

  await test('concurrent distinct awards and duplicate retries produce 100 XP and two unique badges', async () => {
    const id = seed(10);
    async function concurrentAward(n) {
      for (let attempt = 0; attempt < 100; attempt++) {
        try {
          const { stdout } = await run(join(bin,'psql'), [...args, '-c', `SELECT public.award_gamification_for_transaction('${id}-${n}','${id}');`]);
          return JSON.parse(stdout);
        } catch (error) {
          // The existing deletion fence rejects a busy account; retry the whole
          // transaction, as directed by its retry_whole_transaction_no_attempt hint.
          if (!error.stderr?.includes('account_busy')) throw error;
          await new Promise(resolve => setTimeout(resolve,5));
        }
      }
      throw new Error('account remained busy');
    }
    const replies = await Promise.all(Array.from({length:30}, (_,n) => concurrentAward(n%10+1)));
    assert.equal(replies.filter(r => r.duplicate === false).length,10);
    assert.deepEqual(state(id), {xp:100,level:2,claims:10,badges:['first_transaction','tenth_transaction']});
  });
  await test('rollback restores the previous function without removing earned badges', () => {
    const before = state(historic);
    const rollback = readFileSync(new URL('../rollback/20261105122315_persist_transaction_achievement_badges_rollback.sql', import.meta.url),'utf8');
    sql(rollback);
    assert.deepEqual(state(historic), before);
    sql(migration);
    assert.deepEqual(state(historic), before);
  });
} finally {
  if (started) execFileSync(join(bin,'pg_ctl'), ['-D',data,'-m','immediate','-w','stop'], {stdio:'pipe'});
  rmSync(dir, {recursive:true,force:true});
}

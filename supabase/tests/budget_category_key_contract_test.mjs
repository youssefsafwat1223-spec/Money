// F-029 — the server-side detection contract for corrupt budget category ids.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const raw = read('supabase/migrations/0090_budget_category_key_reconciliation.sql');
const sql = raw.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');

test('0090 detects rows whose category_id is not a catalog key', () => {
  assert.match(sql, /CREATE OR REPLACE VIEW public\.budget_category_key_violations/i);
  assert.match(sql, /NOT EXISTS\s*\([\s\S]*?FROM public\.categories c WHERE c\.key = b\.category_id/i);
});

test('the all_expenses sentinel is not treated as corruption', () => {
  // The client legitimately sends this for a whole-account budget.
  assert.match(sql, /category_id <> 'all_expenses'/);
});

test('0090 MUTATES NOTHING — detection only', () => {
  // The intended category is recoverable only by the owning device. Any server
  // "repair" would be a guess, and the obvious guess ('other') is the exact
  // corruption the finding describes.
  for (const forbidden of [/^\s*UPDATE\s/im, /^\s*DELETE\s/im, /^\s*INSERT\s/im]) {
    assert.doesNotMatch(sql, forbidden, 'the migration must not mutate data');
  }
});

test('it never defaults corrupt rows to other', () => {
  assert.doesNotMatch(sql, /set[\s\S]{0,40}category_id\s*=\s*'other'/i);
});

test('the view is not exposed to app roles', () => {
  assert.match(sql, /REVOKE ALL ON public\.budget_category_key_violations FROM anon, authenticated/i);
});

test('it documents the client-side repair path and ships a rollback', () => {
  assert.match(raw, /repair path is CLIENT-side/i);
  assert.match(raw, /Do NOT add a "cleanup"/i);
  assert.ok(raw.includes('ROLLBACK'));
});

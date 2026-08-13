// MALI-026 (Phase-9B) — static contract checks for migration 0080 (record_engagement_event
// anon EXECUTE hardening) PLUS a generalized SECURITY DEFINER anon-revoke audit that
// distinguishes an explicit per-role grant from a PUBLIC grant. These run WITHOUT
// credentials; the live effective ACL (has_function_privilege) is verified in the
// credential-gated staging deploy checkpoint.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const m0080 = read('supabase/migrations/0080_record_engagement_event_execute_hardening.sql');
const m0070 = read('supabase/migrations/0070_engagement_events.sql');

/** Strip `--` comment lines so structural assertions test SQL, not prose. */
const stripComments = (sql) =>
  sql
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('--'))
    .join('\n');
const code0080 = stripComments(m0080);

const SIG = /\(\s*UUID,\s*TEXT,\s*TIMESTAMPTZ,\s*TEXT,\s*INTEGER\s*\)/i;

test('0080: explicitly revokes anon (and PUBLIC) on record_engagement_event', () => {
  assert.match(
    m0080,
    /revoke all on function public\.record_engagement_event\s*\([\s\S]*?\)\s*from public, anon/i,
  );
});

test('0080: preserves intended authenticated EXECUTE; grants nothing to anon/public', () => {
  assert.match(
    m0080,
    /grant execute on function public\.record_engagement_event\s*\([\s\S]*?\)\s*to authenticated/i,
  );
  assert.doesNotMatch(
    m0080,
    /grant execute on function public\.record_engagement_event[\s\S]*?to\s+[^;]*\b(anon|public)\b/i,
  );
});

test('0080: signature unchanged from 0070', () => {
  assert.match(m0070, /record_engagement_event\s*\(/i);
  assert.match(m0080, SIG);
  assert.match(m0070, SIG);
});

test('0080: privilege-only — no body rewrite / SECURITY DEFINER / search_path / table change', () => {
  // Assert against comment-stripped SQL (prose mentions these words deliberately).
  assert.doesNotMatch(code0080, /create\s+(or replace\s+)?function/i);
  assert.doesNotMatch(code0080, /security\s+definer/i);
  assert.doesNotMatch(code0080, /set\s+search_path/i);
  assert.doesNotMatch(code0080, /create\s+policy|alter\s+table|on\s+table/i);
});

// ── Generalized guard: every callable (non-trigger) SECURITY DEFINER function must
// explicitly REVOKE anon — a REVOKE FROM PUBLIC alone is insufficient, because
// Supabase's default privileges grant anon EXPLICITLY and PUBLIC-revoke does not
// remove an explicit per-role grant (the exact 0070 defect). ─────────────────────
function loadMigrations() {
  const dir = new URL('supabase/migrations/', root);
  const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  return files.map((f) => read(`supabase/migrations/${f}`)).join('\n');
}

/** Non-trigger SECURITY DEFINER function names, via a line state-machine. */
function securityDefinerCallables(text) {
  const lines = text.split('\n');
  let cur = null;
  let trig = false;
  const out = new Map(); // name -> isTriggerReturning
  for (const raw of lines) {
    const l = raw.toLowerCase();
    const m = l.match(/create\s+(or replace\s+)?function\s+(public\.)?([a-z0-9_]+)\s*\(/);
    if (m) {
      cur = m[3];
      trig = false;
    }
    if (cur && /returns\s+trigger/.test(l)) trig = true;
    if (cur && /security\s+definer/.test(l)) {
      out.set(cur, (out.get(cur) || false) || trig);
      cur = null;
    }
  }
  return out;
}

function revokesAnon(text, fn) {
  return new RegExp(
    `revoke\\s+(all|execute)\\s+on\\s+function\\s+(public\\.)?${fn}\\s*\\([^;]*\\)\\s*from\\s+[^;]*\\banon\\b`,
    'i',
  ).test(text);
}

test('SECURITY DEFINER audit: every callable definer function explicitly revokes anon', () => {
  const all = loadMigrations();
  const sd = securityDefinerCallables(all);
  const callable = [...sd.entries()].filter(([, isTrig]) => !isTrig).map(([n]) => n);
  // Sanity: the audit actually found the known callable definer RPCs.
  assert.ok(callable.includes('record_engagement_event'));
  assert.ok(callable.includes('record_metric'));
  assert.ok(callable.includes('award_gamification_for_transaction'));

  const offenders = callable.filter((fn) => !revokesAnon(all, fn));
  assert.deepEqual(
    offenders,
    [],
    `callable SECURITY DEFINER functions missing an explicit REVOKE ... FROM anon `
      + `(REVOKE FROM PUBLIC alone is insufficient): ${offenders.join(', ')}`,
  );
});

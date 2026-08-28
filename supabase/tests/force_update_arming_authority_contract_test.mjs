// C-2a-2 — static contract for the force-update arming authority (0089).
//
// Credential-free: asserts the committed migration, not a live database.
//
// What this protects: arming `severity='force_update' AND is_active` blocks ALL
// navigation for EVERY installed client. Confirmation used to be a
// caller-supplied boolean on the ordinary announcements PATCH, so any direct API
// call armed it. The application guard stops a misclick; these are the layers
// that stop a writer.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const stripComments = (sql) =>
  sql.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');

const raw = read('supabase/migrations/0089_force_update_arming_authority.sql');
const sql = stripComments(raw);

test('a trigger guards arming — not just application code', () => {
  // Application-layer guards live in a process an attacker can bypass by
  // calling PostgREST directly. The trigger is the layer that cannot be.
  assert.match(sql, /CREATE TRIGGER trg_guard_force_update_arming/i);
  assert.match(
    sql,
    /BEFORE INSERT OR UPDATE ON public\.announcements/i,
    'INSERT must be covered too — a row can be armed at birth',
  );
});

test('the trigger guards the TRANSITION, not the state', () => {
  // Guarding the state would make an armed announcement uneditable, including
  // edits made to defuse it, and would make disarming harder than arming.
  assert.match(sql, /was_blocking\s+BOOLEAN/i);
  assert.match(sql, /IF will_block AND NOT was_blocking THEN/i);
});

test('"blocking" includes the serving window, matching the app guard', () => {
  // C-2a-1: an expired force-update blocks nobody, so resurrecting one IS an
  // arming. A definition of "armed" that ignores valid_until reintroduces that
  // bypass at the database layer.
  assert.match(sql, /CREATE OR REPLACE FUNCTION public\.announcement_blocks_clients/i);
  assert.match(sql, /p_valid_until IS NULL OR p_valid_until > now\(\)/i);
  assert.match(sql, /p_severity = 'force_update'/i);
  assert.match(sql, /p_is_active IS TRUE/i);
});

test('the sentinel is transaction-local', () => {
  // A session-level or global setting would leak authorization into unrelated
  // statements. `set_config(..., true)` is transaction-scoped.
  assert.match(sql, /set_config\('app\.arm_force_update',[^)]*,\s*true\s*\)/i);
  assert.match(sql, /current_setting\('app\.arm_force_update',\s*true\)/i);
});

test('arm_force_update writes the audit row BEFORE mutating', () => {
  // If the mutation came first, a failure between the two would arm without a
  // record — the one ordering that loses attribution.
  const fn = sql.slice(sql.indexOf('FUNCTION public.arm_force_update'));
  const auditAt = fn.search(/INSERT INTO public\.announcement_admin_audit/i);
  const sentinelAt = fn.search(/set_config\('app\.arm_force_update'/i);
  const updateAt = fn.search(/UPDATE public\.announcements/i);
  assert.ok(auditAt > -1 && sentinelAt > -1 && updateAt > -1);
  assert.ok(auditAt < sentinelAt, 'audit must precede the sentinel');
  assert.ok(sentinelAt < updateAt, 'sentinel must precede the mutation');
});

test('arming refuses a force-update with no action_url', () => {
  // ForceUpdateScreen falls back to a placeholder store URL carrying a fake app
  // id, so arming without one strands every client behind a dead button.
  assert.match(sql, /cannot arm a force-update without an action_url/i);
});

test('the RPC locks the row it is about to arm (no TOCTOU)', () => {
  // The Next.js route read then wrote in two statements; two concurrent PATCHes
  // could each see a not-armed row. FOR UPDATE inside one transaction closes it.
  assert.match(sql, /FROM public\.announcements[\s\S]{0,80}FOR UPDATE/i);
});

test('the RPC is SECURITY DEFINER with a pinned search_path', () => {
  assert.match(sql, /SECURITY DEFINER/i);
  assert.match(
    sql,
    /SET search_path = public, pg_temp/i,
    'an unpinned search_path on a definer function is privilege escalation',
  );
});

test('the audit table is append-only to app roles', () => {
  assert.match(sql, /CREATE TABLE IF NOT EXISTS public\.announcement_admin_audit/i);
  assert.match(sql, /ENABLE ROW LEVEL SECURITY/i);
  assert.match(
    sql,
    /REVOKE ALL ON TABLE public\.announcement_admin_audit FROM anon, authenticated/i,
  );
  assert.match(sql, /action\s+TEXT NOT NULL CHECK \(action IN \('arm', 'disarm'\)\)/i);
});

test('the RPC is not callable by anon or authenticated', () => {
  assert.match(
    sql,
    /REVOKE ALL ON FUNCTION public\.arm_force_update\(UUID, TEXT, UUID\)[\s\S]{0,60}FROM PUBLIC, anon, authenticated/i,
  );
});

test('0089 ships a rollback that states what reverting costs', () => {
  assert.ok(raw.includes('ROLLBACK'));
  assert.match(
    raw,
    /ANY writer[\s\S]{0,80}no audit trail/i,
    'the rollback must say what protection is lost, not just how to undo it',
  );
});

test('no migration seeds an already-armed force-update', () => {
  // The trigger would reject it, breaking `supabase db reset` on a clean
  // environment — which is exactly what DF-002 was about.
  const migrations = read('supabase/migrations/0003_feature_flags_announcements.sql');
  assert.doesNotMatch(
    stripComments(migrations),
    /INSERT INTO announcements[\s\S]*force_update/i,
  );
});

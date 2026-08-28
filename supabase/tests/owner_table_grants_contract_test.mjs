// DF-002 / DF-005 — environment-truth contract.
//
// These assert the COMMITTED migration set, without credentials. They exist
// because "it works in production" was, for these tables, a statement about
// Supabase's platform defaults rather than about anything in this repository —
// so a fresh environment could not reproduce production, and no clean-room
// verification of the schema was possible.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');

const stripComments = (sql) =>
  sql
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('--'))
    .join('\n');

const GRANTS = stripComments(
  read('supabase/migrations/0088_explicit_owner_table_grants.sql'),
);

/** Every owner-scoped table the client reads or writes directly. */
const OWNER_TABLES = [
  'user_accounts',
  'user_transactions',
  'user_budgets',
  'user_goals',
  'user_subscriptions',
  'user_plans',
  'user_cards',
  'user_categories',
  'user_settings',
  'user_smart_inbox',
  'user_bill_payments',
  'user_goal_contributions',
  'user_plan_transaction_links',
  'profiles',
  'backups',
  'notification_logs',
  'feature_flag_overrides',
];

/**
 * Tables whose DML was deliberately revoked from `authenticated` by 0073/0079
 * because their writes go through SECURITY DEFINER RPCs. Re-granting DML here
 * would silently undo that hardening.
 */
const MUST_NOT_BE_GRANTED_DML = [
  'user_achievements',
  'user_streaks',
  'user_xp_levels',
  'user_engagement_events',
  'metrics',
  'metrics_rate_limits',
  'admin_users',
  'ai_request_idempotency',
  'gamification_awarded_transactions',
  'coupon_metrics_daily',
];

test('0088 declares privileges for every owner table the client uses', () => {
  for (const t of OWNER_TABLES) {
    assert.match(
      GRANTS,
      new RegExp(`'${t}'`),
      `${t} must appear in the explicit grant matrix — otherwise a fresh ` +
        `environment depends on Supabase platform defaults that this repo ` +
        `does not declare`,
    );
  }
});

test('0088 grants to authenticated only — never to anon', () => {
  assert.match(GRANTS, /TO authenticated/i);
  assert.doesNotMatch(
    GRANTS,
    /GRANT[\s\S]{0,120}\bTO\s+anon\b/i,
    'unauthenticated clients reach the catalog through Edge Functions only',
  );
});

test('0088 does not re-grant DML on the deliberately hardened tables', () => {
  for (const t of MUST_NOT_BE_GRANTED_DML) {
    assert.doesNotMatch(
      GRANTS,
      new RegExp(`'${t}'`),
      `${t} had its DML revoked by 0073/0079 — granting it back here would ` +
        `undo that hardening`,
    );
  }
});

test('0088 is additive: it contains no executable REVOKE', () => {
  // A REVOKE in this file would remove privileges the hosted project already
  // has and break production. The inverse belongs in the commented rollback.
  assert.doesNotMatch(
    GRANTS,
    /^\s*REVOKE\b/im,
    'this migration must be a no-op against an environment that already has ' +
      'the platform defaults',
  );
});

test('0088 tolerates a table that does not exist yet', () => {
  assert.match(
    GRANTS,
    /information_schema\.tables/i,
    'it must be safe to run at any point in the schema history',
  );
});

test('0088 ships its own rollback', () => {
  const raw = read('supabase/migrations/0088_explicit_owner_table_grants.sql');
  assert.ok(raw.includes('ROLLBACK'));
  assert.match(
    raw,
    /do not run it there|BREAK the app/i,
    'the rollback must warn that reverting on the hosted project is harmful',
  );
});

// ── DF-005 — catalog reads are Edge-only by design ─────────────────────────

test('DF-005: catalog RLS stays anon-only, and that is intentional', () => {
  const catalog = stripComments(read('supabase/migrations/0002_catalog_mvp.sql'));
  for (const t of ['banks', 'sms_parsers', 'categories', 'currencies', 'countries']) {
    assert.match(
      catalog,
      new RegExp(`CREATE POLICY ${t}_anon_select[\\s\\S]{0,120}FOR SELECT TO anon`, 'i'),
      `${t} keeps its anon-only SELECT policy`,
    );
  }
});

test('DF-005: the client never reads catalog tables directly', () => {
  // This is what makes the anon-only policies harmless: every catalog read goes
  // through an Edge Function running service-role. If a future change adds a
  // direct PostgREST read of these tables, it will silently return nothing for
  // a signed-in user — so assert the boundary instead of widening the policy.
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(new URL(dir, root), { withFileTypes: true })) {
      const next = `${dir}${entry.name}${entry.isDirectory() ? '/' : ''}`;
      if (entry.isDirectory()) walk(next);
      else if (entry.name.endsWith('.dart')) files.push(next);
    }
  };
  walk('app/lib/');

  const offenders = [];
  for (const f of files) {
    const src = read(f);
    for (const t of ['banks', 'sms_parsers', 'currencies', 'countries']) {
      if (new RegExp(`\\.from\\(\\s*['"]${t}['"]\\s*\\)`).test(src)) {
        offenders.push(`${f} -> ${t}`);
      }
    }
  }
  assert.deepEqual(
    offenders,
    [],
    'catalog tables must be read via Edge Functions, not PostgREST',
  );
});

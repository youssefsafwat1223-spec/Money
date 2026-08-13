// MALI-026 (Phase-9B) — static privilege-manifest checks for the service-internal
// table hardening (migration 0079). These lock the INTENDED direct-privilege
// manifest per table/role so an accidental re-broadening (or a future default-grant
// regression) fails the gate. Live catalog verification (actual has_table_privilege
// on the deployed DB) is the credential-gated staging deploy checkpoint; this test
// proves the migration expresses the intended contract.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const m0079 = read('supabase/migrations/0079_service_internal_privilege_hardening.sql');

// Pure service-internal (RLS deny-all / RPC-only ingress): NO direct client access.
const denyAll = [
  'metrics',
  'metrics_rate_limits',
  'ai_request_idempotency',
  'gamification_awarded_transactions',
];
for (const t of denyAll) {
  test(`0079: ${t} — all direct anon + authenticated privileges revoked, none re-granted`, () => {
    assert.match(m0079, new RegExp(`revoke all on table public\\.${t} from anon`));
    assert.match(m0079, new RegExp(`revoke all on table public\\.${t} from authenticated`));
    // no privilege of any kind granted back to a client role on these tables.
    assert.doesNotMatch(
      m0079,
      new RegExp(`grant [a-z, ]*on table public\\.${t} to (anon|authenticated)`, 'i'),
    );
  });
}

// Owner-readable (owner_select RLS): authenticated keeps SELECT only; anon nothing.
const ownerReadable = ['user_xp_levels', 'user_engagement_events'];
for (const t of ownerReadable) {
  test(`0079: ${t} — authenticated SELECT only; TRUNCATE/TRIGGER/REFERENCES/write removed; anon none`, () => {
    assert.match(m0079, new RegExp(`revoke all on table public\\.${t} from anon`));
    assert.match(m0079, new RegExp(`revoke all on table public\\.${t} from authenticated`));
    assert.match(m0079, new RegExp(`grant select on table public\\.${t} to authenticated`));
    // the ONLY privilege re-granted to authenticated is SELECT — never a write/DDL grant.
    assert.doesNotMatch(
      m0079,
      new RegExp(
        `grant [a-z, ]*(insert|update|delete|truncate|trigger|references)[a-z, ]* on table public\\.${t} to authenticated`,
        'i',
      ),
    );
  });
}

test('0079: TRUNCATE/TRIGGER/REFERENCES residuals are cleared (revoke all), not relied-on via RLS', () => {
  // `revoke all` covers TRUNCATE/TRIGGER/REFERENCES (which RLS never gates) for every
  // hardened table + client role. Assert a revoke-all exists for each of the 6 tables.
  for (const t of [...denyAll, ...ownerReadable]) {
    assert.match(m0079, new RegExp(`revoke all on table public\\.${t} from authenticated`), t);
  }
});

test('0079: does not touch service_role table authority', () => {
  assert.doesNotMatch(m0079, /from service_role/i);
});

test('0079: alters TABLE privileges only — no function EXECUTE grants changed', () => {
  // record_metric (authenticated), award_gamification_for_transaction (service_role),
  // etc. must be untouched by this migration.
  assert.doesNotMatch(m0079, /on function/i);
});

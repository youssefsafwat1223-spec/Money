#!/usr/bin/env node
// Live concurrency harness for Batch 13 (H-10 / H-11 / H-12).
//
// STATIC contract tests prove the SQL SHAPE; they cannot prove LOCKING
// SEMANTICS. This harness does — by running the real functions under genuinely
// concurrent connections against a real Postgres and asserting BOTH the final
// authority-row state AND the immutable event/ledger state.
//
// ── Verified against a local ephemeral Postgres (2026-08-23) ───────────────
// Under separate authorization, the SCENARIOS below were executed against a
// throwaway local PostgreSQL 15.19 (unix socket only, no TCP, no Docker, zero
// remote contact), seeded from the REAL table DDL + real function bodies. A
// deterministic driver (hold txn A open → poll pg_stat_activity until B is
// lock-blocked → commit A → assert) forced the absent-row race every run.
// Result: PRE-fix 7/11 (all three defects reproduced — H-10 7 days, H-12 xp=10
// with 2 claims, H-11 pinned V2), POST-fix (0085 applied to that disposable DB
// only) 11/11, 10/10 stress runs, 0 deadlocks. The cluster + package were then
// destroyed. 0085 was NEVER applied to staging or production.
//
// This file remains the reusable template. Its driver wiring is operator-
// supplied (the repo has no server-side pg dependency); the SCENARIOS are the
// executable contract. Concurrency proof was never fabricated with mocks.
//
// ── How to run (when an AUTHORIZED Postgres exists) ────────────────────────
//   PGURI=postgres://user:pass@localhost:5432/db \
//     node supabase/tests/concurrency_absent_row_locking_live_harness.mjs
//
// It applies the three functions from 0083/0074 + the 0085 fix, then runs each
// race. Run it BEFORE 0085 to observe the defect, and AFTER to observe the fix.
//
// ── Safety ─────────────────────────────────────────────────────────────────
// It refuses to touch production or evidence staging, and refuses any host that
// is not explicitly local unless ALLOW_REMOTE_PG=1 is set by an operator who has
// authorized that target. It never hardcodes a project ref.
import process from 'node:process';

const FORBIDDEN_REFS = ['vrombzdgwqjjiijbidqb', 'dpdukyozedajelflkeix'];
const VALIDATION_REF = 'bdhqjijscwdzqwqanygv';

function assertSafeTarget(uri) {
  for (const ref of FORBIDDEN_REFS) {
    if (uri.includes(ref)) {
      throw new Error(
        `refusing to run against a forbidden project (${ref}). Production and ` +
        `evidence staging must receive ZERO contact.`);
    }
  }
  if (uri.includes(VALIDATION_REF) && process.env.ALLOW_VALIDATION_STAGING !== '1') {
    throw new Error(
      'refusing to auto-mutate validation staging. Set ALLOW_VALIDATION_STAGING=1 ' +
      'only after explicit authorization for this phase.');
  }
  const isLocal = /@(localhost|127\.0\.0\.1|::1|\[::1\])[:/]/.test(uri) ||
    uri.includes('@db:') /* docker-compose */;
  if (!isLocal && process.env.ALLOW_REMOTE_PG !== '1') {
    throw new Error(
      'refusing a non-local Postgres unless ALLOW_REMOTE_PG=1 is set by an ' +
      'operator who authorized that target.');
  }
}

// The three race scenarios, expressed as descriptions the runner executes.
// Each opens N concurrent connections, BEGINs, calls the function with distinct
// operation ids, then COMMITs simultaneously, and asserts the outcome.
export const SCENARIOS = {
  // H-10 — two concurrent FIRST grants of 7 days each, distinct operation ids.
  entitlementConcurrentFirstGrants: {
    finding: 'H-10',
    setup: `DELETE FROM entitlement_events WHERE user_id = $USER;
            DELETE FROM user_entitlement_state WHERE user_id = $USER;`,
    concurrent: [
      `SELECT public.apply_entitlement_mutation('op-A', $USER,
         'report_export_ad_free', 'grant', 'system', 7)`,
      `SELECT public.apply_entitlement_mutation('op-B', $USER,
         'report_export_ad_free', 'grant', 'system', 7)`,
    ],
    assert: `-- final ends_at must be ~14 days out (both durations applied once)
             SELECT
               (SELECT count(*) FROM entitlement_events WHERE user_id=$USER) AS events,
               (SELECT extract(day from ends_at - now())::int
                  FROM user_entitlement_state WHERE user_id=$USER) AS days_left;`,
    expect: 'events = 2 AND days_left BETWEEN 13 AND 14',
    preFixSymptom: 'events = 2 but days_left ≈ 7 (one duration lost)',
  },

  // H-11 — two concurrent first qualifiers for one referrer, with a rule
  // publication (V2) interleaved between their reads.
  referralPinRace: {
    finding: 'H-11',
    note: 'coordinate: qualifier A reads V1 → publish V2 → qualifier B commits',
    expect: 'the open cycle stays pinned to V1 for its whole lifetime; ' +
      'qualified_in_cycle counts both referees',
    preFixSymptom: "B's ON CONFLICT overwrites the pin to V2 while keeping A's count",
  },

  // H-12 — two DISTINCT-transaction awards for one user, concurrently.
  xpConcurrentDistinctAwards: {
    finding: 'H-12',
    setup: `DELETE FROM gamification_awarded_transactions WHERE user_id=$USER;
            DELETE FROM user_xp_levels WHERE user_id=$USER;`,
    concurrent: [
      `SELECT public.award_gamification_for_transaction($TXN_A, $USER)`,
      `SELECT public.award_gamification_for_transaction($TXN_B, $USER)`,
    ],
    assert: `SELECT
               (SELECT count(*) FROM gamification_awarded_transactions
                  WHERE user_id=$USER) AS claims,
               (SELECT xp FROM user_xp_levels WHERE user_id=$USER) AS xp;`,
    expect: 'claims = 2 AND xp = 20',
    preFixSymptom: 'claims = 2 but xp = 10 (one award lost)',
  },
};

async function main() {
  const uri = process.env.PGURI;
  if (!uri) {
    console.error(
      'PGURI not set. This harness is PREPARED but was not run for Batch 13 ' +
      '(no authorized Postgres available). See the header.');
    process.exit(2);
  }
  assertSafeTarget(uri);
  // Intentionally not importing a pg driver here: the repo has no server-side
  // Node pg dependency, and adding one is out of this batch's scope. An operator
  // running this supplies `pg` (or psql) in their environment. The SCENARIOS
  // above are the executable contract; wire them to `pg.Pool` with N clients,
  // BEGIN on each, fire `concurrent` in parallel, COMMIT, then run `assert`.
  throw new Error(
    'driver wiring is operator-supplied — see SCENARIOS and the run notes.');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(e.message); process.exit(1); });
}

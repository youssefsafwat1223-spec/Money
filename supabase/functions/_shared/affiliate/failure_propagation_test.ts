// Affiliate failure propagation — the defects that let a broken run look healthy.
//
// Two of the three DAO methods in `affiliate-sync` discarded the Supabase
// `{ error }` entirely, and the third — the READ — discarded it too, which is
// the worst of them: a failed read returns null, the caller concludes "no such
// conversion", and INSERTS A DUPLICATE of money already recorded.
//
// These tests pin the propagation contract at the port boundary, which is where
// `reconcileConversions` consumes it.

import { assertEquals, assertRejects } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import { FixtureAffiliateAdapter } from './fixture_adapter.ts';
import { type ConversionStore, reconcileConversions } from './ingest.ts';

const OPTIONS = {
  networkId: 'net-1',
  cursor: null,
  limit: 100,
  secrets: {},
};

/// A store whose chosen method fails the way Supabase fails: by returning an
/// error the caller must not ignore.
class FailingConversions implements ConversionStore {
  constructor(private readonly failOn: 'find' | 'insert' | 'update') {}
  rows = new Map<string, { id: string; status: string }>();

  findConversion(_network: string, _external: string) {
    if (this.failOn === 'find') {
      return Promise.reject(new Error('find_conversion_failed:PGRST301'));
    }
    return Promise.resolve(null);
  }

  insertConversion(_network: string, _row: Record<string, unknown>) {
    if (this.failOn === 'insert') {
      return Promise.reject(new Error('insert_conversion_failed:23505'));
    }
    return Promise.resolve();
  }

  updateConversion(_id: string, _row: Record<string, unknown>) {
    if (this.failOn === 'update') {
      return Promise.reject(new Error('update_conversion_failed:23514'));
    }
    return Promise.resolve();
  }
}

Deno.test('a failed conversion READ propagates — it must not read as "not found"', async () => {
  // The duplicate-money bug: swallowing this made the caller insert a second
  // copy of a conversion that already existed.
  await assertRejects(
    () =>
      reconcileConversions(
        new FixtureAffiliateAdapter(),
        new FailingConversions('find'),
        OPTIONS,
      ),
    Error,
    'find_conversion_failed',
  );
});

Deno.test('a failed conversion INSERT propagates', async () => {
  // Previously the run reported success while the money record was never
  // stored: a healthy-looking ingestion with no revenue behind it.
  await assertRejects(
    () =>
      reconcileConversions(
        new FixtureAffiliateAdapter(),
        new FailingConversions('insert'),
        OPTIONS,
      ),
    Error,
    'insert_conversion_failed',
  );
});

Deno.test('a healthy store still reconciles — the guards are not blanket failure', async () => {
  // Non-vacuity: without this, the two tests above would pass if reconcile
  // simply always threw.
  class OkConversions implements ConversionStore {
    findConversion() { return Promise.resolve(null); }
    insertConversion() { return Promise.resolve(); }
    updateConversion() { return Promise.resolve(); }
  }
  const result = await reconcileConversions(
    new FixtureAffiliateAdapter(),
    new OkConversions(),
    OPTIONS,
  );
  assertEquals(typeof result.created, 'number');
});

// ---------------------------------------------------------------------------
// Transition-rule regressions found in review.
// ---------------------------------------------------------------------------

import { shouldApplyTransition } from './attribution.ts';

Deno.test('pending never demotes a conversion that has moved on', () => {
  // Receipts are pruned after 180 days while conversions live forever, so an
  // old replayed `pending` can arrive with no replay guard left. Applying it
  // would un-confirm a settled commission and blank its amounts.
  assertEquals(shouldApplyTransition('approved', 'pending'), false);
  assertEquals(shouldApplyTransition('returned', 'pending'), false);
  assertEquals(shouldApplyTransition('rejected', 'pending'), false);
});

Deno.test('the forward lifecycle still applies', () => {
  // Non-vacuity: the rule must not have become "reject everything".
  assertEquals(shouldApplyTransition('pending', 'approved'), true);
  assertEquals(shouldApplyTransition('pending', 'returned'), true);
  // A clawback is news even after approval.
  assertEquals(shouldApplyTransition('approved', 'returned'), true);
  assertEquals(shouldApplyTransition('approved', 'rejected'), true);
});

Deno.test('terminal-negative states stay sticky', () => {
  assertEquals(shouldApplyTransition('returned', 'approved'), false);
  assertEquals(shouldApplyTransition('rejected', 'approved'), false);
  assertEquals(shouldApplyTransition('cancelled', 'approved'), false);
});

Deno.test('an identical status is never re-applied', () => {
  for (const s of ['pending', 'approved', 'returned', 'rejected', 'cancelled']) {
    assertEquals(shouldApplyTransition(s, s), false, s);
  }
});

Deno.test('the full 5x5 matrix has no surprises', () => {
  const states = ['pending', 'approved', 'returned', 'rejected', 'cancelled'];
  const terminalNegative = ['returned', 'rejected', 'cancelled'];
  for (const from of states) {
    for (const to of states) {
      const expected = from === to
        ? false
        : terminalNegative.includes(from) && !terminalNegative.includes(to)
            ? false
            : to === 'pending'
                ? false
                : true;
      assertEquals(shouldApplyTransition(from, to), expected, '$from -> $to');
    }
  }
});

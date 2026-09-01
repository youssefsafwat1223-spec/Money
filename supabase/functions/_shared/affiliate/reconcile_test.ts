// COUPONS Phase 3 — polling reconciliation.
//
// The postback path is push. This is the pull backstop, and the property that
// matters is that the two agree: a polled status must go through the SAME
// transition rule as a pushed one. A poll and a push are two views of one state
// machine, and giving them different rules is exactly how they end up
// disagreeing about whether money was clawed back.

import { assert, assertEquals, assertRejects } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import {
  FIXTURE_CONVERSION_COUNT,
  FIXTURE_INVALID_CONVERSION_COUNT,
  FixtureAffiliateAdapter,
} from './fixture_adapter.ts';
import { type ConversionStore, reconcileConversions } from './ingest.ts';
import type { AdapterContext, AffiliateAdapter, ConversionPage, OfferPage } from './types.ts';

class MemoryConversions implements ConversionStore {
  rows = new Map<string, { id: string; status: string; row: Record<string, unknown> }>();
  private seq = 0;

  findConversion(networkKey: string, externalConversionId: string) {
    const hit = this.rows.get(`${networkKey}:${externalConversionId}`);
    return Promise.resolve(hit == null ? null : { id: hit.id, status: hit.status });
  }

  insertConversion(networkKey: string, row: Record<string, unknown>) {
    const id = `conv-${this.seq++}`;
    this.rows.set(`${networkKey}:${row.external_conversion_id}`, {
      id,
      status: row.status as string,
      row,
    });
    return Promise.resolve();
  }

  updateConversion(id: string, row: Record<string, unknown>) {
    for (const entry of this.rows.values()) {
      if (entry.id === id) {
        entry.status = row.status as string;
        entry.row = { ...entry.row, ...row };
        return Promise.resolve();
      }
    }
    throw new Error(`no such conversion ${id}`);
  }
}

const OPTIONS = {
  networkId: 'net-1',
  cursor: null,
  limit: 100,
  secrets: {},
};

Deno.test('polls the whole report, rejecting malformed rows without failing the run', async () => {
  const store = new MemoryConversions();
  const result = await reconcileConversions(new FixtureAffiliateAdapter(), store, OPTIONS);

  assertEquals(result.fetched, FIXTURE_CONVERSION_COUNT);
  assertEquals(result.rejected, FIXTURE_INVALID_CONVERSION_COUNT);
  assertEquals(result.created, FIXTURE_CONVERSION_COUNT - FIXTURE_INVALID_CONVERSION_COUNT);
  // The malformed row — an amount with no currency — is dropped, not stored.
  assertEquals(store.rows.size, result.created);
  assert(result.rejections.includes('amount_without_currency'));
});

Deno.test('a second poll of an unchanged report changes nothing', async () => {
  const store = new MemoryConversions();
  await reconcileConversions(new FixtureAffiliateAdapter(), store, OPTIONS);
  const again = await reconcileConversions(new FixtureAffiliateAdapter(), store, OPTIONS);

  assertEquals(again.created, 0);
  assertEquals(again.updated, 0);
  assertEquals(again.unchanged, FIXTURE_CONVERSION_COUNT - FIXTURE_INVALID_CONVERSION_COUNT);
});

/** An adapter whose report we control, to drive specific transitions. */
class ScriptedAdapter implements AffiliateAdapter {
  readonly networkKey = 'fixture';
  readonly version = 1;
  constructor(private readonly page: ConversionPage) {}
  fetchOffers(_ctx: AdapterContext): Promise<OfferPage> {
    return Promise.resolve({ offers: [], nextCursor: null });
  }
  fetchConversions(_ctx: AdapterContext): Promise<ConversionPage> {
    return Promise.resolve(this.page);
  }
}

function report(status: ConversionPage['conversions'][number]['status']): ScriptedAdapter {
  return new ScriptedAdapter({
    conversions: [{ externalConversionId: 'c-1', clickId: null, status }],
    nextCursor: null,
  });
}

Deno.test('a polled approved does NOT resurrect a returned conversion', async () => {
  const store = new MemoryConversions();
  // A webhook already told us this was returned — money clawed back.
  await store.insertConversion('fixture', {
    external_conversion_id: 'c-1',
    status: 'returned',
  });

  const result = await reconcileConversions(report('approved'), store, OPTIONS);

  // The provider's report still lists it as approved, because the report is a
  // snapshot of a lagging system. Applying it would count revenue that no
  // longer exists, and would show the user a saving that was reversed.
  assertEquals(result.updated, 0);
  assertEquals(result.unchanged, 1);
  assertEquals(store.rows.get('fixture:c-1')!.status, 'returned');
});

Deno.test('a polled clawback IS applied on top of an approved conversion', async () => {
  const store = new MemoryConversions();
  await store.insertConversion('fixture', {
    external_conversion_id: 'c-1',
    status: 'approved',
  });

  const result = await reconcileConversions(report('returned'), store, OPTIONS);

  // The direction that matters. A lost `returned` webhook is precisely the case
  // polling exists to catch, so this transition must go through.
  assertEquals(result.updated, 1);
  assertEquals(store.rows.get('fixture:c-1')!.status, 'returned');
});

Deno.test('pending → approved is applied', async () => {
  const store = new MemoryConversions();
  await store.insertConversion('fixture', {
    external_conversion_id: 'c-1',
    status: 'pending',
  });
  const result = await reconcileConversions(report('approved'), store, OPTIONS);
  assertEquals(result.updated, 1);
  assertEquals(store.rows.get('fixture:c-1')!.status, 'approved');
});

Deno.test('an update never rewrites the identity it matched on', async () => {
  const store = new MemoryConversions();
  await store.insertConversion('fixture', {
    external_conversion_id: 'c-1',
    status: 'pending',
  });
  await reconcileConversions(report('approved'), store, OPTIONS);
  assertEquals(
    store.rows.get('fixture:c-1')!.row.external_conversion_id,
    'c-1',
  );
});

Deno.test('an adapter with no polling API is a no-op, not zero conversions', async () => {
  class PushOnly implements AffiliateAdapter {
    readonly networkKey = 'push_only';
    readonly version = 1;
    fetchOffers(_ctx: AdapterContext): Promise<OfferPage> {
      return Promise.resolve({ offers: [], nextCursor: null });
    }
  }
  const store = new MemoryConversions();
  const result = await reconcileConversions(new PushOnly(), store, OPTIONS);

  // Zeros across the board AND a null cursor — the worker distinguishes this
  // from a real empty poll by checking the adapter itself, and records a
  // SKIPPED run rather than an `ok` run that fetched nothing.
  assertEquals(result.fetched, 0);
  assertEquals(result.created, 0);
  assertEquals(result.nextCursor, null);
  assertEquals(store.rows.size, 0);
});

Deno.test('a corrupt cursor fails the run rather than restarting the report', async () => {
  const store = new MemoryConversions();
  await assertRejects(
    () =>
      reconcileConversions(new FixtureAffiliateAdapter(), store, {
        ...OPTIONS,
        cursor: 'not-a-number',
      }),
    Error,
    'invalid_cursor',
  );
  // Nothing was written. A failed run must leave state exactly as it was.
  assertEquals(store.rows.size, 0);
});

Deno.test('reconciliation resumes from a cursor rather than re-reading the report', async () => {
  const store = new MemoryConversions();
  const first = await reconcileConversions(new FixtureAffiliateAdapter(), store, {
    ...OPTIONS,
    limit: 1,
  });
  assertEquals(first.fetched, 1);
  assertEquals(first.nextCursor, '1');

  const second = await reconcileConversions(new FixtureAffiliateAdapter(), store, {
    ...OPTIONS,
    cursor: first.nextCursor,
    limit: 1,
  });
  assertEquals(second.fetched, 1);
  assertEquals(second.created, 1);
});

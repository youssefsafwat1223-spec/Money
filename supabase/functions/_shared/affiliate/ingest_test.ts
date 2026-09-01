// COUPONS Phase 2 — the ingestion algorithm.
//
// Two guarantees are load-bearing and everything here exists to pin them:
//
//   1. A provider outage cannot damage the published catalog. Nothing in this
//      pipeline writes to `coupons`; the worst a broken feed can do is fail a
//      run and say so in the ledger.
//   2. Nothing publishes itself. Every staged row lands `pending`, and there is
//      no code path that produces `published` — making it automatic would take
//      a schema change, not a config flag.

import { assert, assertEquals, assertRejects } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import { FIXTURE_INVALID_COUNT, FIXTURE_OFFER_COUNT, FixtureAffiliateAdapter } from './fixture_adapter.ts';
import { offerFingerprint } from './fingerprint.ts';
import { ingestOffers, type IngestStore, type StagedSource } from './ingest.ts';
import { type NormalizedOffer, validateOffer } from './types.ts';

/** An in-memory store, so the algorithm is tested without a database. */
class MemoryStore implements IngestStore {
  programs = new Map<string, string>();
  sources = new Map<string, StagedSource & { id: string }>();
  aliasSuggestions: Array<{ programId: string; aliasRaw: string; kind: string }> = [];
  private seq = 0;

  ensureProgram(networkId: string, externalProgramId: string): Promise<string> {
    const key = `${networkId}:${externalProgramId}`;
    if (!this.programs.has(key)) this.programs.set(key, `prog-${this.programs.size}`);
    return Promise.resolve(this.programs.get(key)!);
  }

  findSource(programId: string, externalOfferId: string) {
    for (const row of this.sources.values()) {
      if (row.program_id === programId && row.external_offer_id === externalOfferId) {
        return Promise.resolve({
          id: row.id,
          source_fingerprint: row.source_fingerprint,
          review_state: row.review_state,
        });
      }
    }
    return Promise.resolve(null);
  }

  insertSource(row: StagedSource): Promise<void> {
    const id = `src-${this.seq++}`;
    this.sources.set(id, { ...row, id });
    return Promise.resolve();
  }

  updateSource(id: string, patch: Partial<StagedSource>): Promise<void> {
    const existing = this.sources.get(id);
    if (existing) this.sources.set(id, { ...existing, ...patch });
    return Promise.resolve();
  }

  suggestAlias(programId: string, aliasRaw: string, kind: 'name' | 'domain'): Promise<void> {
    this.aliasSuggestions.push({ programId, aliasRaw, kind });
    return Promise.resolve();
  }
}

const OPTS = { networkId: 'net-1', cursor: null, limit: 50, secrets: {} };

function offer(over: Partial<NormalizedOffer> = {}): NormalizedOffer {
  return {
    externalOfferId: 'o-1',
    externalProgramId: 'p-1',
    titleAr: 'عنوان',
    descriptionAr: 'وصف',
    redemptionType: 'link',
    url: 'https://example.test/x',
    markets: ['SA'],
    ...over,
  };
}

class OneShotAdapter {
  readonly networkKey = 'test';
  readonly version = 1;
  constructor(private readonly offers: NormalizedOffer[]) {}
  fetchOffers() {
    return Promise.resolve({ offers: this.offers, nextCursor: null });
  }
}

Deno.test('NOTHING publishes itself — every staged row is pending', async () => {
  const store = new MemoryStore();
  await ingestOffers(new FixtureAffiliateAdapter(), store, OPTS);
  assert(store.sources.size > 0);
  for (const row of store.sources.values()) {
    assertEquals(row.review_state, 'pending');
  }
});

Deno.test('a malformed offer is dropped WITHOUT failing the run', async () => {
  // A real feed reliably contains a few bad rows. Aborting the ingestion for one
  // means the catalog stops updating because a partner typed a bad date.
  const store = new MemoryStore();
  const result = await ingestOffers(new FixtureAffiliateAdapter(), store, OPTS);
  assertEquals(result.fetched, FIXTURE_OFFER_COUNT);
  assertEquals(result.rejected, FIXTURE_INVALID_COUNT);
  assertEquals(result.created, FIXTURE_OFFER_COUNT - FIXTURE_INVALID_COUNT);
  assert(result.rejections.includes('bad_benefit_shape'));
});

Deno.test('re-running an unchanged feed creates NO new review items', async () => {
  // Otherwise the queue fills with copies every hour and reviewers stop reading
  // it — which is the same as having no review step.
  const store = new MemoryStore();
  await ingestOffers(new FixtureAffiliateAdapter(), store, OPTS);
  const afterFirst = store.sources.size;

  const second = await ingestOffers(new FixtureAffiliateAdapter(), store, OPTS);
  assertEquals(store.sources.size, afterFirst);
  assertEquals(second.created, 0);
  assertEquals(second.unchanged, FIXTURE_OFFER_COUNT - FIXTURE_INVALID_COUNT);
});

Deno.test('an unchanged offer keeps its review decision', async () => {
  // A published offer must stay published, and a rejected one must stay
  // rejected rather than reappearing in the queue on every run.
  const store = new MemoryStore();
  await ingestOffers(new OneShotAdapter([offer()]), store, OPTS);
  const id = [...store.sources.keys()][0];
  await store.updateSource(id, { review_state: 'rejected' });

  await ingestOffers(new OneShotAdapter([offer()]), store, OPTS);
  assertEquals(store.sources.get(id)!.review_state, 'rejected');
});

Deno.test('CHANGED content returns a published offer to the queue', async () => {
  // The case that matters most: a provider quietly moving a discount from 20%
  // to 5% on an offer a human already approved. The approval was for the old
  // content.
  const store = new MemoryStore();
  await ingestOffers(new OneShotAdapter([
    offer({ benefitType: 'percent', discountBps: 2000, benefitCurrency: 'SAR' }),
  ]), store, OPTS);
  const id = [...store.sources.keys()][0];
  await store.updateSource(id, { review_state: 'published' });

  const second = await ingestOffers(new OneShotAdapter([
    offer({ benefitType: 'percent', discountBps: 500, benefitCurrency: 'SAR' }),
  ]), store, OPTS);
  assertEquals(second.updated, 1);
  assertEquals(store.sources.get(id)!.review_state, 'pending');
});

Deno.test('merchant hints become UNREVIEWED suggestions, never identity', async () => {
  // A provider's idea of a merchant name is a suggestion from a commercial
  // partner. Promoting it to a reviewed alias automatically is how a user's
  // spending gets attributed to the wrong business.
  const store = new MemoryStore();
  await ingestOffers(new FixtureAffiliateAdapter(), store, OPTS);
  assert(store.aliasSuggestions.length > 0);
  assert(store.aliasSuggestions.some((s) => s.kind === 'name'));
  assert(store.aliasSuggestions.some((s) => s.kind === 'domain'));
  // The store interface has no way to create a REVIEWED alias, so ingestion
  // structurally cannot.
  assert(!('approveAlias' in store));
});

Deno.test('a provider throw fails the run and writes nothing', async () => {
  const store = new MemoryStore();
  class Broken {
    readonly networkKey = 'broken';
    readonly version = 1;
    fetchOffers(): Promise<never> {
      return Promise.reject(new Error('upstream 503'));
    }
  }
  await assertRejects(() => ingestOffers(new Broken(), store, OPTS));
  assertEquals(store.sources.size, 0, 'a failed run must not stage anything');
});

Deno.test('work is BOUNDED and resumable', async () => {
  // A cron invocation that runs until the platform kills it dies mid-write. And
  // a feed larger than one run must resume, or it either re-reads forever or
  // silently stops at the bound.
  const store = new MemoryStore();
  const first = await ingestOffers(
    new FixtureAffiliateAdapter(), store, { ...OPTS, limit: 2 });
  assertEquals(first.fetched, 2);
  assert(first.nextCursor !== null, 'a truncated page must hand back a cursor');

  const second = await ingestOffers(
    new FixtureAffiliateAdapter(), store, { ...OPTS, limit: 2, cursor: first.nextCursor });
  assertEquals(second.nextCursor, null, 'the feed is exhausted');
  assertEquals(store.sources.size, FIXTURE_OFFER_COUNT - FIXTURE_INVALID_COUNT);
});

Deno.test('a corrupt cursor fails rather than silently restarting the feed', async () => {
  // Restarting would re-ingest everything and look like a burst of new offers,
  // which is indistinguishable from a provider actually publishing a lot.
  const store = new MemoryStore();
  await assertRejects(() =>
    ingestOffers(new FixtureAffiliateAdapter(), store, { ...OPTS, cursor: 'nonsense' }));
});

// ── fingerprint ────────────────────────────────────────────────────────────

Deno.test('the fingerprint ignores field ORDER but not field VALUES', async () => {
  const a = await offerFingerprint(offer({ titleAr: 'أ', descriptionAr: 'ب' }));
  const b = await offerFingerprint(offer({ descriptionAr: 'ب', titleAr: 'أ' }));
  assertEquals(a, b, 'assignment order must not change the hash');

  const c = await offerFingerprint(offer({ titleAr: 'أ', descriptionAr: 'ج' }));
  assert(a !== c);
});

Deno.test('reordering markets is not a content change', async () => {
  const a = await offerFingerprint(offer({ markets: ['SA', 'EG'] }));
  const b = await offerFingerprint(offer({ markets: ['EG', 'SA'] }));
  assertEquals(a, b);
});

Deno.test('adjacent fields cannot collide across the separator', async () => {
  // Without a separator that cannot appear in copy, "ab"+"c" and "a"+"bc" would
  // produce the same canonical string and two different offers would dedupe
  // into one.
  const a = await offerFingerprint(offer({ titleAr: 'ab', descriptionAr: 'c' }));
  const b = await offerFingerprint(offer({ titleAr: 'a', descriptionAr: 'bc' }));
  assert(a !== b);
});

Deno.test('every structured value participates in the hash', async () => {
  // A cap appearing or a minimum spend changing are things a human approved a
  // specific version of.
  const base = offer({ benefitType: 'percent', discountBps: 2000, benefitCurrency: 'SAR' });
  const withCap = { ...base, maxSavingMinor: 5000 };
  const withMin = { ...base, minSpendMinor: 10000 };
  const hashes = new Set(await Promise.all(
    [base, withCap, withMin].map(offerFingerprint)));
  assertEquals(hashes.size, 3);
});

// ── validation mirrors the database ────────────────────────────────────────

Deno.test('validation rejects what 0095 would reject', () => {
  const cases: Array<[Partial<NormalizedOffer>, string]> = [
    [{ benefitType: 'percent' }, 'bad_benefit_shape'],
    [{ benefitType: 'percent', discountBps: 20001, benefitCurrency: 'SAR' }, 'bad_benefit_shape'],
    [{ benefitType: 'fixed_amount', fixedAmountMinor: 100 }, 'bad_currency'],
    [{ benefitType: 'fixed_amount', fixedAmountMinor: 100, benefitCurrency: 'SAR', maxSavingMinor: 50 }, 'bad_benefit_shape'],
    [{ markets: ['SAU'] }, 'bad_market'],
    [{ url: 'http://example.test/x' }, 'insecure_url'],
    [{ redemptionType: 'code', code: null }, 'code_without_code'],
    [{ validFrom: '2030-01-01T00:00:00Z', validUntil: '2026-01-01T00:00:00Z' }, 'bad_window'],
  ];
  for (const [over, expected] of cases) {
    const problems = validateOffer(offer(over));
    assert(problems.includes(expected as never),
      `${JSON.stringify(over)} -> expected ${expected}, got ${problems.join(',')}`);
  }
});

Deno.test('a prose-only offer is VALID', () => {
  // Most of a real feed looks like this. A pipeline that demanded structured
  // values would reject the majority of what providers actually send.
  assertEquals(validateOffer(offer()), []);
});

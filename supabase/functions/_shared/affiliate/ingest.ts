import { offerFingerprint } from './fingerprint.ts';
import { type AffiliateAdapter, type NormalizedOffer, validateOffer } from './types.ts';

/// COUPONS Phase 2 — the ingestion algorithm, extracted from the HTTP handler.
///
/// Separated so it can be tested without booting an Edge Function or a
/// database: everything that decides what happens to an offer lives here, and
/// `affiliate-sync/index.ts` only supplies auth, secrets and a store.
///
/// ## The two properties this exists to guarantee
///
/// 1. **A provider outage cannot damage the published catalog.** Nothing here
///    writes to `coupons`. The worst a broken feed can do is fail a run and
///    leave a row in the ledger saying so; the last-good catalog keeps serving.
///
/// 2. **Nothing publishes itself.** Every staged row lands `review_state =
///    'pending'`. Publishing is a human act in the admin panel, and making it
///    automatic would take a schema change rather than a config flag.

/** What the worker needs from persistence. An interface so the algorithm can be
 *  tested against an in-memory store rather than a live database. */
export interface IngestStore {
  /** The program row for a provider programme id, creating it if absent. */
  ensureProgram(networkId: string, externalProgramId: string): Promise<string>;
  /** The existing staged row for (program, external offer), if any. */
  findSource(programId: string, externalOfferId: string): Promise<
    { id: string; source_fingerprint: string; review_state: string } | null
  >;
  insertSource(row: StagedSource): Promise<void>;
  updateSource(id: string, row: Partial<StagedSource>): Promise<void>;
  /** Record a merchant-name/domain suggestion as an UNREVIEWED alias candidate.
   *  Never a reviewed alias — see below. */
  suggestAlias(
    programId: string,
    aliasRaw: string,
    kind: 'name' | 'domain',
  ): Promise<void>;
}

export interface StagedSource {
  program_id: string;
  external_offer_id: string;
  source_fingerprint: string;
  normalized: NormalizedOffer;
  provider_status: string;
  review_state: string;
  last_seen_at: string;
}

export interface IngestResult {
  fetched: number;
  created: number;
  updated: number;
  rejected: number;
  unchanged: number;
  nextCursor: string | null;
  /** Per-offer rejection codes, for the run ledger. Codes only — provider text
   *  can echo a request that carried a credential. */
  rejections: string[];
}

export interface IngestOptions {
  networkId: string;
  cursor: string | null;
  /** Hard ceiling on offers processed in one run. Bounded work is what keeps a
   *  cron invocation from running until the platform kills it mid-write. */
  limit: number;
  secrets: Record<string, string>;
  now?: () => string;
}

export async function ingestOffers(
  adapter: AffiliateAdapter,
  store: IngestStore,
  options: IngestOptions,
): Promise<IngestResult> {
  const now = options.now ?? (() => new Date().toISOString());

  // A throw here propagates to the caller, which records a FAILED run. It
  // deliberately does not catch-and-continue: a provider returning garbage for
  // page 3 of 10 must not look like a successful partial ingestion, because the
  // cursor would advance past offers nobody ever saw.
  const page = await adapter.fetchOffers({
    cursor: options.cursor,
    limit: options.limit,
    secrets: options.secrets,
  });

  const result: IngestResult = {
    fetched: page.offers.length,
    created: 0,
    updated: 0,
    rejected: 0,
    unchanged: 0,
    nextCursor: page.nextCursor,
    rejections: [],
  };

  for (const offer of page.offers) {
    // Per-offer validation. A rejection drops ONE offer and the run continues:
    // real feeds reliably contain a few malformed rows, and letting one abort
    // the ingestion means the catalog stops updating because a partner typed a
    // bad date.
    const problems = validateOffer(offer);
    if (problems.length > 0) {
      result.rejected += 1;
      result.rejections.push(...problems);
      continue;
    }

    const programId = await store.ensureProgram(
      options.networkId,
      offer.externalProgramId,
    );
    const fingerprint = await offerFingerprint(offer);
    const existing = await store.findSource(programId, offer.externalOfferId);

    if (existing == null) {
      await store.insertSource({
        program_id: programId,
        external_offer_id: offer.externalOfferId,
        source_fingerprint: fingerprint,
        normalized: offer,
        provider_status: 'active',
        // ALWAYS pending. There is no branch here that can produce
        // 'published' — that is the whole no-auto-publish guarantee, and it is
        // structural rather than a policy someone can flip.
        review_state: 'pending',
        last_seen_at: now(),
      });
      result.created += 1;
    } else if (existing.source_fingerprint === fingerprint) {
      // Byte-identical to what we already hold. Touch last_seen_at only — so
      // "still in the feed" is recorded — and leave the review state alone. A
      // published offer stays published; a rejected one stays rejected rather
      // than reappearing in the queue every hour.
      await store.updateSource(existing.id, {
        last_seen_at: now(),
        provider_status: 'active',
      });
      result.unchanged += 1;
    } else {
      // The content CHANGED. This is the case that matters: a provider quietly
      // moving a discount from 20% to 5%, or pulling a cap, on an offer a human
      // already approved. The previous approval was for the previous content,
      // so it goes back into the queue.
      await store.updateSource(existing.id, {
        source_fingerprint: fingerprint,
        normalized: offer,
        provider_status: 'active',
        review_state: 'pending',
        last_seen_at: now(),
      });
      result.updated += 1;
    }

    // Merchant hints become UNREVIEWED alias candidates, never reviewed
    // aliases. A provider's idea of a merchant name is a suggestion from a
    // commercial partner, and promoting it to identity automatically is exactly
    // how a user's spending gets attributed to the wrong business. A human
    // decides, in the same queue as everything else.
    for (const hint of offer.merchantNameHints ?? []) {
      await store.suggestAlias(programId, hint, 'name');
    }
    for (const hint of offer.merchantDomainHints ?? []) {
      await store.suggestAlias(programId, hint, 'domain');
    }
  }

  return result;
}

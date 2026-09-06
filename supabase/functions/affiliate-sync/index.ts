// COUPONS Phase 2 — the affiliate ingestion worker.
//
// Invoked ONLY by pg_cron via `run_affiliate_sync()` (0096), which reads the
// shared secret from Vault. There is no user-facing path to it: an ingestion run
// spends provider quota and writes to the review queue, so anything that could
// trigger it from a client would be a free denial-of-wallet.
//
// ## Auth is a bearer secret, not a JWT, and it fails CLOSED
//
// `verify_jwt = false` in config.toml, because the caller is a cron job with no
// Supabase session. The compensating control is a constant-time comparison
// against AFFILIATE_WORKER_SECRET, and `bearerSecretAuthorized` returns false
// when the configured secret is EMPTY — so an unconfigured deployment refuses
// every request rather than accepting every request, which is the direction a
// misconfiguration has to fail in.
//
// ## What a run can and cannot do
//
// It can stage candidates and write a ledger row. It cannot publish: nothing
// here touches `coupons`, and `ingestOffers` has no code path that produces
// `review_state = 'published'`. A provider outage therefore leaves the live
// catalog exactly as it was — the worst case is a failed run and a row saying
// so.

import { corsHeaders } from '../_shared/capture_auth.ts';
import { bearerSecretAuthorized, serviceClient } from '../_shared/capture_auth.ts';
import { safeLog } from '../_shared/ai_endpoint.ts';
import { FixtureAffiliateAdapter } from '../_shared/affiliate/fixture_adapter.ts';
import {
  type ConversionStore,
  ingestOffers,
  type IngestStore,
  reconcileConversions,
  type StagedSource,
} from '../_shared/affiliate/ingest.ts';
import type { AffiliateAdapter } from '../_shared/affiliate/types.ts';

const WORKER_SECRET = Deno.env.get('AFFILIATE_WORKER_SECRET') ?? '';

/// How many offers one invocation may process.
///
/// Bounded work is not a performance choice. A cron invocation that runs until
/// the platform kills it dies mid-write, leaving a `running` ledger row that
/// never resolves and a cursor that never advances — and the next run starts
/// from the same place and dies the same way.
const RUN_LIMIT = 200;

/// The adapter registry.
///
/// A new network is a new entry here and nothing else. If adding a provider ever
/// requires touching the worker, the review queue or the admin panel, the
/// abstraction has failed and the second provider costs as much as the first.
const ADAPTERS: Record<string, AffiliateAdapter> = {
  fixture: new FixtureAffiliateAdapter(),
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

/** The database-backed store. Kept thin: every decision lives in ingest.ts. */
function makeStore(supabase: ReturnType<typeof serviceClient>): IngestStore {
  return {
    async ensureProgram(networkId: string, externalProgramId: string) {
      // Same class as findConversion: a failed READ that looks like "absent"
      // makes the caller CREATE a duplicate program.
      const { data: existing, error: existingError } = await supabase
        .from('affiliate_programs')
        .select('id')
        .eq('network_id', networkId)
        .eq('external_program_id', externalProgramId)
        .maybeSingle();
      if (existingError) {
        throw new Error(`find_program_failed:${existingError.code ?? 'unknown'}`);
      }
      if (existing?.id) return existing.id as string;

      const { data, error } = await supabase
        .from('affiliate_programs')
        .insert({ network_id: networkId, external_program_id: externalProgramId })
        .select('id')
        .single();
      if (error) throw error;
      return data.id as string;
    },

    async findSource(programId: string, externalOfferId: string) {
      // A failed read here reports "no such offer", and the caller then inserts
      // a duplicate offer source.
      const { data, error: findError } = await supabase
        .from('affiliate_offer_sources')
        .select('id, source_fingerprint, review_state')
        .eq('program_id', programId)
        .eq('external_offer_id', externalOfferId)
        .maybeSingle();
      if (findError) {
        throw new Error(`find_source_failed:${findError.code ?? 'unknown'}`);
      }
      return (data as never) ?? null;
    },

    async insertSource(row: StagedSource) {
      const { error } = await supabase.from('affiliate_offer_sources').insert(row);
      if (error) throw error;
    },

    async updateSource(id: string, patch: Partial<StagedSource>) {
      const { error } = await supabase
        .from('affiliate_offer_sources')
        .update(patch)
        .eq('id', id);
      if (error) throw error;
    },

    async suggestAlias(programId: string, aliasRaw: string, kind: 'name' | 'domain') {
      // A suggestion is only meaningful once the programme is bound to a
      // canonical merchant. Until an admin does that binding there is nothing
      // to attach the alias to, and inventing a merchant from a provider's
      // string is precisely what must not happen.
      const { data: program } = await supabase
        .from('affiliate_programs')
        .select('merchant_id')
        .eq('id', programId)
        .maybeSingle();
      const merchantId = program?.merchant_id as string | null | undefined;
      if (!merchantId) return;

      // UNREVIEWED, provenance `provider`. It reaches no device until a human
      // approves it — catalog-delta filters on is_reviewed, and RLS hides it
      // besides.
      //
      // Errors are swallowed deliberately: a duplicate suggestion, or one the
      // 0094 boilerplate guard refuses, is a normal outcome of a provider feed
      // and must not fail an otherwise good ingestion run. The offer is the
      // payload; the alias hint is a bonus.
      // Alias creation is best-effort by design (an alias that already exists
      // is not an error), but a genuine failure must still be visible rather
      // than vanish.
      const { error: aliasError } = await supabase
          .from('catalog_merchant_aliases')
          .insert({
        merchant_id: merchantId,
        alias_raw: aliasRaw,
        alias_kind: kind,
        provenance: 'provider',
        is_reviewed: false,
          });
      // A duplicate alias is expected and harmless; anything else is a real
      // ingestion failure and must reach the run status rather than vanish.
      if (aliasError && aliasError.code !== '23505') {
        throw new Error(`insert_alias_failed:${aliasError.code ?? 'unknown'}`);
      }
    },
  };
}

/// Persistence for the conversions run.
///
/// Deliberately a SEPARATE interface from `IngestStore`, and separate rows: the
/// offers run writes staged catalog content, the conversions run writes money.
/// One store spanning both would let a catalog bug reach a conversion row.
function makeConversionStore(
  supabase: ReturnType<typeof serviceClient>,
): ConversionStore {
  return {
    async findConversion(networkKey: string, externalConversionId: string) {
      const { data, error } = await supabase
        .from('affiliate_conversions')
        .select('id, status')
        .eq('network_key', networkKey)
        .eq('external_conversion_id', externalConversionId)
        .maybeSingle();
      // A FAILED READ IS NOT "NOT FOUND". Swallowing this error was the worst of
      // the three: the caller reads null, concludes no conversion exists, and
      // INSERTS A DUPLICATE of a conversion that was already recorded. Throwing
      // routes it to the run's catch, which records status 'failed'.
      if (error) {
        throw new Error(`find_conversion_failed:${error.code ?? 'unknown'}`);
      }
      return data == null
        ? null
        : { id: data.id as string, status: data.status as string };
    },
    async insertConversion(networkKey: string, row: Record<string, unknown>) {
      const { error } = await supabase
        .from('affiliate_conversions')
        .insert({ network_key: networkKey, ...row });
      // Money records. A dropped insert previously let the run report success
      // while the conversion was never stored — the ingestion looked healthy and
      // the revenue simply did not exist.
      if (error) {
        throw new Error(`insert_conversion_failed:${error.code ?? 'unknown'}`);
      }
    },
    async updateConversion(id: string, row: Record<string, unknown>) {
      // external_conversion_id is the identity we matched on and must not be
      // rewritten by an update.
      const { external_conversion_id: _ignored, ...mutable } = row;
      const { error } = await supabase
        .from('affiliate_conversions')
        .update(mutable)
        .eq('id', id);
      if (error) {
        throw new Error(`update_conversion_failed:${error.code ?? 'unknown'}`);
      }
    },
  };
}

/// The handler, exported so the run-status and response contracts can be
/// exercised behaviourally. `Deno.serve` below is the only production entry.
export async function handleSync(
  req: Request,
  makeClient: () => ReturnType<typeof serviceClient> = serviceClient,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  if (!bearerSecretAuthorized(req.headers.get('Authorization'), WORKER_SECRET)) {
    // No detail in the body. A caller probing this endpoint learns only that it
    // exists.
    return json({ error: 'unauthorized' }, 401);
  }

  const supabase = makeClient();

  // Only networks an operator has deliberately promoted. A network row existing
  // is configuration; a network being `sandbox`/`live` is a decision, and the
  // fixture adapter is intended to sit at `sandbox` permanently.
  const { data: networks, error: networkError } = await supabase
    .from('affiliate_networks')
    .select('id, network_key, status')
    .neq('status', 'disabled');
  if (networkError) {
    safeLog({ event: 'affiliate_sync_network_query_failed', fn: 'affiliate-sync' });
    return json({ error: 'internal_error' }, 500);
  }

  const summary: Array<Record<string, unknown>> = [];

  for (const network of networks ?? []) {
    const adapter = ADAPTERS[network.network_key as string];
    if (!adapter) {
      // An enabled network with no adapter is a configuration error, recorded
      // as a SKIPPED run rather than silently ignored — otherwise "the feed
      // stopped updating" has no trace anywhere.
      await supabase.from('affiliate_ingestion_runs').insert({
        network_key: network.network_key,
        kind: 'offers',
        status: 'skipped',
        safe_error_code: 'no_adapter',
        finished_at: new Date().toISOString(),
      });
      summary.push({ network: network.network_key, status: 'skipped' });
      continue;
    }

    // Resume from the last SUCCESSFUL run. Resuming from a failed one would
    // advance past offers that were never actually processed.
    const { data: lastRun } = await supabase
      .from('affiliate_ingestion_runs')
      .select('cursor')
      .eq('network_key', network.network_key)
      .eq('kind', 'offers')
      .eq('status', 'ok')
      .order('started_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    // If the run row cannot be created we have no auditable record to close.
    // Proceeding would do real ingestion work whose status could never be
    // updated, leaving a run STUCK at 'running' forever — or no record at all.
    // Skip this network and report it, rather than working invisibly.
    const { data: run, error: runError } = await supabase
      .from('affiliate_ingestion_runs')
      .insert({ network_key: network.network_key, kind: 'offers', status: 'running' })
      .select('id')
      .single();
    if (runError || run?.id == null) {
      summary.push({ network: network.network_key, kind: 'offers', status: 'failed' });
      continue;
    }

    try {
      const result = await ingestOffers(adapter, makeStore(supabase), {
        networkId: network.id as string,
        cursor: (lastRun?.cursor as string | null) ?? null,
        limit: RUN_LIMIT,
        // Provider credentials come from Edge secrets, never from a database
        // row: a credential in a row is a credential in every backup, every
        // replica and every admin session.
        secrets: { apiKey: Deno.env.get(`AFFILIATE_${adapter.networkKey.toUpperCase()}_KEY`) ?? '' },
      });

      await supabase
        .from('affiliate_ingestion_runs')
        .update({
          status: 'ok',
          cursor: result.nextCursor,
          fetched_count: result.fetched,
          new_count: result.created,
          updated_count: result.updated,
          rejected_count: result.rejected,
          finished_at: new Date().toISOString(),
        })
        .eq('id', run!.id);

      summary.push({ network: network.network_key, ...result, rejections: undefined });
    } catch (_error) {
      // A code, never the provider's message: upstream error text can echo the
      // request that produced it, and that request carried a credential. This
      // row is read by the admin panel.
      await supabase
        .from('affiliate_ingestion_runs')
        .update({
          status: 'failed',
          safe_error_code: 'adapter_failed',
          finished_at: new Date().toISOString(),
        })
        .eq('id', run!.id);
      safeLog({ event: 'affiliate_sync_run_failed', fn: 'affiliate-sync' });
      summary.push({ network: network.network_key, status: 'failed' });
      // Continue to the next network. One provider being down must not stop
      // ingestion for the others.
    }

    // ── Conversions reconciliation ──────────────────────────────────────────
    //
    // A SECOND run, of its own kind, with its own cursor. Kept separate from
    // the offers run on purpose: a provider whose catalog endpoint is down must
    // still have its conversions reconciled, because a status update that never
    // arrives leaves a user's saving pending forever — and the reverse, a
    // conversions outage silently halting catalog updates, is equally wrong.
    //
    // This is also why it runs for push networks and not only polling ones.
    // Webhooks are lost; this is the backstop, not the fallback.
    if (typeof adapter.fetchConversions !== 'function') {
      // Recorded, not silent. "No conversions this run" and "this provider has
      // no polling API" are different facts, and reporting them identically is
      // how a broken poll hides.
      await supabase.from('affiliate_ingestion_runs').insert({
        network_key: network.network_key,
        kind: 'conversions',
        status: 'skipped',
        safe_error_code: 'no_conversion_api',
        finished_at: new Date().toISOString(),
      });
      continue;
    }

    const { data: lastConvRun } = await supabase
      .from('affiliate_ingestion_runs')
      .select('cursor')
      .eq('network_key', network.network_key)
      .eq('kind', 'conversions')
      .eq('status', 'ok')
      .order('started_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    // Same guard as the offers run above, and for the same reason. Without it a
    // failed insert left convRun null, reconcileConversions still ran and wrote
    // real money rows, and the `convRun!.id` in both the success and the catch
    // branch then threw — escaping the loop, so the offers work already done for
    // every network was reported as a 500 with no summary at all.
    const { data: convRun, error: convRunError } = await supabase
      .from('affiliate_ingestion_runs')
      .insert({ network_key: network.network_key, kind: 'conversions', status: 'running' })
      .select('id')
      .single();
    if (convRunError || convRun?.id == null) {
      summary.push({ network: network.network_key, kind: 'conversions', status: 'failed' });
      continue;
    }

    try {
      const result = await reconcileConversions(adapter, makeConversionStore(supabase), {
        networkId: network.id as string,
        cursor: (lastConvRun?.cursor as string | null) ?? null,
        limit: RUN_LIMIT,
        secrets: { apiKey: Deno.env.get(`AFFILIATE_${adapter.networkKey.toUpperCase()}_KEY`) ?? '' },
      });
      await supabase
        .from('affiliate_ingestion_runs')
        .update({
          status: 'ok',
          cursor: result.nextCursor,
          fetched_count: result.fetched,
          new_count: result.created,
          updated_count: result.updated,
          rejected_count: result.rejected,
          finished_at: new Date().toISOString(),
        })
        .eq('id', convRun!.id);
      summary.push({ network: network.network_key, kind: 'conversions', ...result, rejections: undefined });
    } catch (_error) {
      await supabase
        .from('affiliate_ingestion_runs')
        .update({
          status: 'failed',
          safe_error_code: 'adapter_failed',
          finished_at: new Date().toISOString(),
        })
        .eq('id', convRun!.id);
      safeLog({ event: 'affiliate_conversions_run_failed', fn: 'affiliate-sync' });
      summary.push({ network: network.network_key, kind: 'conversions', status: 'failed' });
    }
  }

  // TRUTHFUL RESULT. This was an unconditional `ok: true`, so a run in which
  // every network failed still reported success to its caller — and the pg_cron
  // dispatcher does not read the per-network summary. A monitor watching `ok`
  // would have seen a healthy ingestion that stored nothing.
  const failed = summary.filter((s) => s.status === 'failed');
  const ok = failed.length === 0;
  return json(
    {
      ok,
      networks: summary,
      failed_count: failed.length,
    },
    // 207 rather than 500: some networks may have succeeded, and the body says
    // which. A non-2xx makes the failure visible to anything checking status.
    ok ? 200 : 207,
  );
}

Deno.serve((req) => handleSync(req));

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-app-version',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

// Exported so it can be unit-tested directly (see index_test.ts) without a
// live Supabase project.
export function isValidCountryParam(value: string): boolean {
  return /^[A-Z]{2,3}$/.test(value);
}

const tableByCategory: Record<string, string> = {
  banks: 'banks',
  parsers: 'sms_parsers',
  currencies: 'currencies',
  countries: 'countries',
  categories: 'categories',
  merchant_keywords: 'merchant_keywords',
  // COUPONS Phase 1 — the canonical merchant catalog. Standard versioned delta;
  // the alias table needs one extra serving filter, applied below.
  catalog_merchants: 'catalog_merchants',
  merchant_aliases: 'catalog_merchant_aliases',
};

const idColumnByCategory: Record<string, string> = {
  banks: 'id',
  parsers: 'id',
  currencies: 'code',
  countries: 'code',
  categories: 'id',
  merchant_keywords: 'id',
  catalog_merchants: 'id',
  merchant_aliases: 'id',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const appVersion = req.headers.get('x-app-version') ?? 'unknown';
  console.log(`catalog-delta requested by app version: ${appVersion}`);

  try {
    const url = new URL(req.url);
    const category = url.searchParams.get('category') ?? '';
    const table = tableByCategory[category];
    if (!table) {
      return json({ error: 'Unsupported catalog category' }, 400);
    }

    const sinceVersion = Number.parseInt(
      url.searchParams.get('since_version') ?? '0',
      10,
    );
    const since = Number.isFinite(sinceVersion) && sinceVersion > 0 ? sinceVersion : 0;
    const rawCountry = url.searchParams.get('country')?.trim().toUpperCase();
    if (rawCountry && !isValidCountryParam(rawCountry)) {
      return json({ error: 'Invalid country parameter' }, 400);
    }
    const country = rawCountry;

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ??
      Deno.env.get('SUPABASE_ANON_KEY');
    if (!supabaseUrl || !serviceKey) {
      return json({ error: 'Supabase environment is not configured' }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: versionRows, error: versionError } = await client
      .from('catalog_versions')
      .select('version')
      .eq('category', category)
      .limit(1);
    if (versionError) return json({ error: versionError.message }, 500);
    const version = Number(versionRows?.[0]?.version ?? 0);

    if (category === 'merchant_keywords') {
      const result = await fetchMerchantKeywordsDelta(
        client,
        since,
        version,
        country,
      );
      if ('error' in result) return json({ error: result.error }, 500);
      return json({
        meta: { category, version, since_version: since },
        items: result.items,
        deleted_ids: result.deletedIds,
      });
    }

    let baseItemQuery = client.from(table).select('*').gt('updated_version', since);
    // Parsers: only serve rules that have passed golden-test validation.
    //
    // C-1: the status label alone is not sufficient evidence. `0004_parser_lab.sql:15`
    // blanket-stamped every pre-existing parser 'passed' without running a test,
    // which let unvalidated rules through this gate — and, once F-016 made catalog
    // rules the first parsing authority, into confirmed money. Require the
    // EVIDENCE columns too, so neither a future backfill nor a manual status flip
    // can serve an untested rule to a device. `0087` restores the data and adds
    // the matching CHECK constraint; this is the serving-side half of the pair.
    if (category === 'parsers') {
      baseItemQuery = (baseItemQuery as any)
        .eq('validation_status', 'passed')
        .not('validated_at', 'is', null)
        .gt('golden_test_count', 0);
    }
    // Merchant aliases: serve REVIEWED rows only.
    //
    // Provider-suggested aliases land as `observed_candidate`/`provider` with
    // is_reviewed = false and sit in the admin queue. RLS already hides them
    // from anon and authenticated, but this function runs with the service-role
    // client, which bypasses RLS — so without this filter the delta would hand
    // devices exactly the unreviewed guesses the review step exists to catch,
    // and an unreviewed alias resolving a merchant is a wrong attribution of
    // someone's spending.
    if (category === 'merchant_aliases') {
      baseItemQuery = (baseItemQuery as any).eq('is_reviewed', true);
    }
    const itemQuery = applyCountryFilter(
      applyActiveDeltaFilter(baseItemQuery, since),
      category,
      country,
      client,
    );
    const { data: items, error: itemError } = await itemQuery;
    if (itemError) return json({ error: itemError.message }, 500);

    const deletedQuery = applyCountryFilter(
      client
        .from(table)
        .select(idColumnByCategory[category])
        .gt('deleted_version', since)
        .eq('is_deleted', true),
      category,
      country,
      client,
    );
    const { data: deletedRows, error: deletedError } = await deletedQuery;
    if (deletedError) return json({ error: deletedError.message }, 500);

    const idColumn = idColumnByCategory[category];
    const deletedIds = (deletedRows ?? [])
      .map((row: Record<string, unknown>) => row[idColumn])
      .filter((id: unknown): id is string => typeof id === 'string');

    return json({
      meta: { category, version, since_version: since },
      items: items ?? [],
      deleted_ids: deletedIds,
    });
  } catch (error) {
    console.error('catalog-delta failed', error);
    return json({ error: 'Unexpected catalog delta failure' }, 500);
  }
});

function applyActiveDeltaFilter(query: any, since: number): any {
  if (since === 0) {
    return query.eq('is_active', true).eq('is_deleted', false);
  }
  return query.or('is_active.eq.true,is_deleted.eq.true');
}

function applyCountryFilter(
  query: any,
  category: string,
  country: string | undefined,
  client: any,
): any {
  if (!country) return query;
  if (category === 'banks') return query.eq('country_code', country);
  if (category === 'currencies') return query.contains('country_codes', [country]);
  if (category === 'countries') return query.eq('code', country);
  if (category === 'parsers') {
    // Parser country filtering is reserved for the app-side sync service where
    // the bank cache is available. Returning all active parser deltas is safer
    // than dropping a parser because the country-bank join is incomplete.
    return query;
  }
  return query;
}

async function fetchMerchantKeywordsDelta(
  client: any,
  since: number,
  version: number,
  country: string | undefined,
): Promise<
  | { items: unknown[]; deletedIds: string[] }
  | { error: string }
> {
  // merchant_keywords is intentionally a lightweight public dictionary table.
  // It is versioned at category level through catalog_versions, not per row.
  // When the category version is newer than the client version, return a
  // complete active snapshot plus deleted ids so clients can converge safely.
  if (since >= version) {
    return { items: [], deletedIds: [] };
  }

  let itemQuery = client
    .from('merchant_keywords')
    .select('*')
    .eq('is_active', true)
    .eq('is_deleted', false);
  itemQuery = applyMerchantKeywordCountryFilter(itemQuery, country);
  const { data: items, error: itemError } = await itemQuery;
  if (itemError) return { error: itemError.message };

  let deletedQuery = client
    .from('merchant_keywords')
    .select('id')
    .eq('is_deleted', true);
  deletedQuery = applyMerchantKeywordCountryFilter(deletedQuery, country);
  const { data: deletedRows, error: deletedError } = await deletedQuery;
  if (deletedError) return { error: deletedError.message };

  const deletedIds = (deletedRows ?? [])
    .map((row: Record<string, unknown>) => row.id)
    .filter((id: unknown): id is string => typeof id === 'string');
  return { items: items ?? [], deletedIds };
}

function applyMerchantKeywordCountryFilter(query: any, country: string | undefined): any {
  if (!country) return query;
  // Parameterized — country is validated (^[A-Z]{2,3}$) before reaching here,
  // but .in() with an array avoids ever building a filter expression by
  // string interpolation regardless.
  return query.in('country_code', ['ALL', country]);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
    },
  });
}

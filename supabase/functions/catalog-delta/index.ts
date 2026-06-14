import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-app-version",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

const tableByCategory: Record<string, string> = {
  banks: "banks",
  parsers: "sms_parsers",
  currencies: "currencies",
  countries: "countries",
  categories: "categories",
};

const idColumnByCategory: Record<string, string> = {
  banks: "id",
  parsers: "id",
  currencies: "code",
  countries: "code",
  categories: "id",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const appVersion = req.headers.get("x-app-version") ?? "unknown";
  console.log(`catalog-delta requested by app version: ${appVersion}`);

  try {
    const url = new URL(req.url);
    const category = url.searchParams.get("category") ?? "";
    const table = tableByCategory[category];
    if (!table) {
      return json({ error: "Unsupported catalog category" }, 400);
    }

    const sinceVersion = Number.parseInt(
      url.searchParams.get("since_version") ?? "0",
      10,
    );
    const since = Number.isFinite(sinceVersion) && sinceVersion > 0
      ? sinceVersion
      : 0;
    const country = url.searchParams.get("country")?.trim().toUpperCase();

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey =
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
      Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !serviceKey) {
      return json({ error: "Supabase environment is not configured" }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: versionRows, error: versionError } = await client
      .from("catalog_versions")
      .select("version")
      .eq("category", category)
      .limit(1);
    if (versionError) return json({ error: versionError.message }, 500);
    const version = Number(versionRows?.[0]?.version ?? 0);

    let baseItemQuery = client.from(table).select("*").gt("updated_version", since);
    // Parsers: only serve rules that have passed golden-test validation.
    if (category === "parsers") {
      baseItemQuery = (baseItemQuery as any).eq("validation_status", "passed");
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
        .gt("deleted_version", since)
        .eq("is_deleted", true),
      category,
      country,
      client,
    );
    const { data: deletedRows, error: deletedError } = await deletedQuery;
    if (deletedError) return json({ error: deletedError.message }, 500);

    const idColumn = idColumnByCategory[category];
    const deletedIds = (deletedRows ?? [])
      .map((row) => row[idColumn])
      .filter((id) => typeof id === "string");

    return json({
      meta: { category, version, since_version: since },
      items: items ?? [],
      deleted_ids: deletedIds,
    });
  } catch (error) {
    console.error("catalog-delta failed", error);
    return json({ error: "Unexpected catalog delta failure" }, 500);
  }
});

function applyActiveDeltaFilter(query: any, since: number): any {
  if (since === 0) {
    return query.eq("is_active", true).eq("is_deleted", false);
  }
  return query.or("is_active.eq.true,is_deleted.eq.true");
}

function applyCountryFilter(
  query: any,
  category: string,
  country: string | undefined,
  client: any,
): any {
  if (!country) return query;
  if (category === "banks") return query.eq("country_code", country);
  if (category === "currencies") return query.contains("country_codes", [country]);
  if (category === "countries") return query.eq("code", country);
  if (category === "parsers") {
    // Parser country filtering is reserved for the app-side sync service where
    // the bank cache is available. Returning all active parser deltas is safer
    // than dropping a parser because the country-bank join is incomplete.
    return query;
  }
  return query;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
